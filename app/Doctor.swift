import Foundation
import SwiftUI

/// Готовность окружения глазами ядра.
///
/// Решение о том, чего не хватает, принимает ядро — одно и то же на маке,
/// Windows и Linux. Интерфейс только показывает список и нажимает кнопку:
/// иначе «готово» на разных системах означало бы разное, а расходиться эти
/// два ответа начали бы в первый же месяц.
struct Readiness: Decodable {
    struct Item: Decodable, Identifiable {
        let key: String
        let title: String
        let state: String
        let detail: String
        let size_mb: Int
        let fixable: Bool

        var id: String { key }
        var ok: Bool { state == "ok" }
    }

    let ok: Bool
    let items: [Item]
    let can_repair: Bool
    let needs_setup: Bool
    let size_mb: Int

    var missing: [Item] { items.filter { !$0.ok } }

    /// Чего не хватает — одной строкой под заголовком карточки.
    var listing: String {
        missing.map { item in
            item.detail.isEmpty ? item.title : "\(item.title) — \(item.detail)"
        }.joined(separator: "; ")
    }

    /// Сколько качать. Ноль — тоже ответ: Ollama бывает просто не запущена.
    var weight: String? {
        guard size_mb > 0 else { return nil }
        return size_mb >= 1024
            ? String(format: "%.1f ГБ", Double(size_mb) / 1024)
            : "\(size_mb) МБ"
    }
}

/// Спрашивает ядро о готовности — в стороне от главного потока.
@MainActor
@Observable
final class Doctor {
    private(set) var report: Readiness?
    private(set) var busy = false

    /// Перепроверить. По коду вызов дешёвый, по времени — нет: когда Ollama
    /// не отвечает, ядро ждёт её несколько секунд. Поэтому в фоне, а окно
    /// в это время живёт своей жизнью.
    func refresh() {
        guard !busy, Paths.isReady else { return }
        busy = true
        Task.detached(priority: .utility) {
            let fresh = Doctor.ask()
            await MainActor.run {
                self.report = fresh
                self.busy = false
            }
        }
    }

    /// Один запуск ядра с `--check --json`. Ядро печатает ровно один JSON,
    /// поэтому разбирать вывод не приходится.
    nonisolated static func ask() -> Readiness? {
        guard FileManager.default.fileExists(atPath: Paths.venvPython.path),
              FileManager.default.fileExists(atPath: Paths.core.path)
        else { return nil }

        let process = Process()
        process.executableURL = Paths.venvPython
        process.arguments = ["-B", Paths.core.path, "--check", "--json"]
        process.currentDirectoryURL = Paths.core.deletingLastPathComponent()
        process.environment = AppConfiguration.environment()

        let pipe = Pipe()
        process.standardOutput = pipe
        // Предупреждения ядра здесь не нужны: ответ — это JSON в stdout.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 40, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONDecoder().decode(Readiness.self, from: data)
    }
}
