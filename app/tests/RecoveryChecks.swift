import AVFoundation
import Foundation

/// Восстановление прерванной записи: черновики после падения, починка
/// заголовка, сведение и уборка.
@main struct RecoveryChecks {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slavator-recovery-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true)!

        /// Дорожка, какой её оставляет падение: звук на диске целиком, а в
        /// заголовке размеры на момент открытия (проверено на AVAudioFile,
        /// убитом SIGKILL посреди записи: RIFF 4088, data 0).
        func crashed(_ name: String, seconds: Double, age: TimeInterval) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let frames = AVAudioFrameCount(16000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for k in 0..<Int(frames) { buffer.int16ChannelData![0][k] = Int16(k % 2000 - 1000) }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                           commonFormat: .pcmFormatInt16, interleaved: true)
                try file.write(from: buffer)
            }
            let handle = try FileHandle(forUpdating: url)
            var bytes = [UInt8](try handle.read(upToCount: 8192)!)
            let data = (12..<bytes.count - 4).first {
                String(decoding: bytes[$0..<$0 + 4], as: UTF8.self) == "data"
            }!
            for i in 0..<4 { bytes[data + 4 + i] = 0 }
            let riff = UInt32(data).littleEndian
            withUnsafeBytes(of: riff) { for (i, b) in $0.enumerated() { bytes[4 + i] = b } }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(bytes))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                                  ofItemAtPath: url.path)
            return url
        }

        func length(_ url: URL) throws -> AVAudioFramePosition {
            try AVAudioFile(forReading: url).length
        }

        // Заголовок после падения: длина ноль, после починки — вся запись.
        let probe = try crashed("probe.wav", seconds: 2, age: 0)
        let before = try length(probe)
        precondition(before == 0, "падение должно оставлять пустой заголовок")
        try Recovery.repairHeader(probe)
        let after = try length(probe)
        precondition(after == 32000, "после починки видна вся запись: \(after)")

        // Список: старая пара — прерванная запись, свежая — возможно, живая.
        let base = "Встреча 2026-09-30_18-40-00"
        _ = try crashed(base + Recovery.systemSuffix, seconds: 3, age: 600)
        _ = try crashed(base + Recovery.microphoneSuffix, seconds: 3, age: 600)
        _ = try crashed("Встреча 2026-10-01_10-00-00" + Recovery.systemSuffix, seconds: 3, age: 5)
        let found = Recovery.interrupted(in: dir)
        precondition(found.map(\.base) == [base], "найдено не то: \(found.map(\.base))")
        precondition(found[0].system != nil && found[0].microphone != nil)

        // Восстановление: одна сведённая запись встречи, черновиков нет.
        let out = dir.appendingPathComponent("Протоколы")
        let restored = try Recovery.restore(found[0], into: out)
        precondition(restored.lastPathComponent == base + ".wav")
        let mixed = try length(restored)
        precondition(mixed >= 47000, "сведено слишком мало: \(mixed)")
        precondition(!FileManager.default.fileExists(atPath: found[0].system!.path))
        precondition(!FileManager.default.fileExists(atPath: found[0].microphone!.path))

        // Одна дорожка — переносится как есть; одноимённая запись не затирается.
        let single = "Встреча 2026-09-29_09-00-00"
        _ = try crashed(single + Recovery.microphoneSuffix, seconds: 2, age: 600)
        FileManager.default.createFile(atPath: out.appendingPathComponent(single + ".wav").path,
                                       contents: Data("занято".utf8))
        let one = Recovery.interrupted(in: dir).first { $0.base == single }!
        let moved = try Recovery.restore(one, into: out)
        precondition(moved.lastPathComponent == single + " (восстановлена).wav")
        let movedLength = try length(moved)
        precondition(movedLength == 32000, "перенесено не всё: \(movedLength)")

        print("PASS: восстановление записи — заголовок после падения, список, сведение, одна дорожка")
    }
}
