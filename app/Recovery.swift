import AVFoundation
import Foundation

/// Запись встречи, оборванная падением или выключением посреди звонка.
///
/// Приём из Meetily (incremental_saver.rs, useTranscriptRecovery.ts): звук
/// там пишется кусками, а при следующем запуске программа сама предлагает
/// восстановить прерванную встречу. У нас дорожки и так пишутся на диск по
/// ходу записи — черновиками в Application Support/Славатор/capture, — но
/// после падения их никто не подбирал: через неделю они молча удалялись.
/// 30.09.2026 Славатор упал посреди диктовки; случись это на звонке,
/// встреча пропала бы целиком.
struct InterruptedRecording: Identifiable, Equatable {
    /// «Встреча 2026-09-30_18-40-00» — имя, которое получила бы запись.
    let base: String
    var system: URL?
    var microphone: URL?
    var modified: Date

    var id: String { base }

    /// Сколько записано, по размеру самой длинной дорожки: 16 кГц, 16 бит, моно.
    var seconds: Double {
        [system, microphone].compactMap { $0 }.map { url in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            return Double(max(0, bytes - 4096)) / 32000
        }.max() ?? 0
    }
}

enum Recovery {
    static let systemSuffix = " — компьютер.wav"
    static let microphoneSuffix = " — микрофон.wav"

    /// Дорожку, которую дописывали меньше двух минут назад, не трогаем: это
    /// может быть живая запись — боевая и тестовая сборки делят одну папку.
    static let quiet: TimeInterval = 120

    enum Failure: Error { case notWave, noData, nothingToRestore }

    static var drafts: URL { AppConfiguration.support.appending(path: "capture") }

    /// Прерванные записи: пары черновиков, которые давно никто не дописывает.
    static func interrupted(in folder: URL = drafts, now: Date = Date()) -> [InterruptedRecording] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var found: [String: InterruptedRecording] = [:]
        for url in items {
            let name = url.lastPathComponent
            let isSystem = name.hasSuffix(systemSuffix)
            guard isSystem || name.hasSuffix(microphoneSuffix) else { continue }
            let base = String(name.dropLast(isSystem ? systemSuffix.count : microphoneSuffix.count))
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            var item = found[base] ?? InterruptedRecording(base: base, system: nil, microphone: nil,
                                                           modified: modified)
            if isSystem { item.system = url } else { item.microphone = url }
            item.modified = max(item.modified, modified)
            found[base] = item
        }
        return found.values
            .filter { now.timeIntervalSince($0.modified) > quiet && $0.seconds >= 1 }
            .sorted { $0.modified > $1.modified }
    }

    /// Поправить размеры в заголовке WAV.
    ///
    /// При падении в заголовке остаются размеры на момент открытия файла, и
    /// любой проигрыватель видит пустую запись, хотя звук лежит на диске
    /// целиком. Размер данных — всё от начала блока data до конца файла.
    static func repairHeader(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = [UInt8](try handle.read(upToCount: 16384) ?? Data())
        func text(_ at: Int) -> String { String(decoding: head[at..<at + 4], as: UTF8.self) }
        func number(_ at: Int) -> Int {
            Int(head[at]) | Int(head[at + 1]) << 8 | Int(head[at + 2]) << 16 | Int(head[at + 3]) << 24
        }
        guard head.count >= 12, text(0) == "RIFF", text(8) == "WAVE" else { throw Failure.notWave }
        var offset = 12
        while offset + 8 <= head.count {
            guard text(offset) == "data" else {
                let length = number(offset + 4)
                offset += 8 + length + length % 2
                continue
            }
            let start = offset + 8
            var data = Int(size) - start
            data -= data % 2                    // целое число 16-битных отсчётов
            try write(UInt32(clamping: data), to: handle, at: UInt64(offset + 4))
            try write(UInt32(clamping: Int(size) - 8), to: handle, at: 4)
            return
        }
        throw Failure.noData
    }

    private static func write(_ value: UInt32, to handle: FileHandle, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    /// Свести дорожки в запись встречи, как при обычной остановке, и убрать
    /// черновики. Возвращает готовый файл.
    static func restore(_ item: InterruptedRecording, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appending(path: "\(item.base).wav")
        if fm.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(item.base) (восстановлена).wav")
        }
        if let system = item.system { try repairHeader(system) }
        if let microphone = item.microphone { try repairHeader(microphone) }
        switch (item.system, item.microphone) {
        case let (system?, microphone?):
            try Mixdown.combine(system: system, microphone: microphone, into: target)
            try? fm.removeItem(at: system)
            try? fm.removeItem(at: microphone)
        case let (one?, nil), let (nil, one?):
            try fm.moveItem(at: one, to: target)
        default:
            throw Failure.nothingToRestore
        }
        return target
    }

    static func discard(_ item: InterruptedRecording) {
        for url in [item.system, item.microphone].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
