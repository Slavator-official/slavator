import AppKit
import Foundation

// Маленькое окружение для настоящего Pipeline, без окна, моделей и микрофона.
enum Paths {
    static var core: URL { AppConfiguration.support.appendingPathComponent("fake_backend.py") }
    static var venvPython: URL { URL(fileURLWithPath: "/usr/bin/python3") }
}
final class Library {
    var settings = Settings()
    var reloads = 0
    func reload() { reloads += 1 }
}
struct Record {
    let title: String
    let dir: URL
    var source: URL? = nil
    var ownTrack: URL? = nil
}
func showAlert(_ title: String, _ body: String) { preconditionFailure("\(title): \(body)") }

@main
struct PipelineChecks {
    static func spin(until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Не дождались состояния процесса")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slavator-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("MEETING_TRANSCRIBER_APP_SUPPORT", root.path, 1)
        let script = """
        import json, sys, time, os
        print('keep_audio=' + str('--keep-audio' in sys.argv), flush=True)
        print('args=' + json.dumps(sys.argv[1:]), flush=True)
        print('@@PROGRESS@@' + json.dumps({'stage':'asr','pct':42,'detail':'Распознаю'}), flush=True)
        if 'slow' in sys.argv[1]: time.sleep(30)
        print('Готово', flush=True)
        """
        try script.write(to: Paths.core, atomically: true, encoding: .utf8)
        let library = Library()
        library.settings.results_dir = root.path
        library.settings.keep_diagnostics = true
        let pipeline = Pipeline()
        pipeline.run(input: root.appendingPathComponent("slow.wav"), library: library)
        spin { pipeline.percent == 42 }
        precondition(pipeline.log.contains("keep_audio=True"))
        pipeline.suspend(true)
        precondition(pipeline.isSuspended)
        pipeline.cancel()
        precondition(pipeline.isRunning && pipeline.isCancelling)
        pipeline.run(input: root.appendingPathComponent("fast.wav"), library: library)
        precondition(pipeline.isCancelling, "Второй процесс запущен до выхода первого")
        spin { !pipeline.isRunning }
        precondition(pipeline.stage == "Прервано" && library.reloads == 0)
        print("PASS: отмена приостановленного процесса и запрет повторного запуска до выхода")
        pipeline.run(input: root.appendingPathComponent("fast.wav"), library: library)
        spin { !pipeline.isRunning }
        precondition(pipeline.stage == "Готово" && pipeline.percent == 100 && library.reloads == 1)
        precondition(pipeline.log.last == "Готово")
        print("PASS: новый запуск после отмены, финальный вывод, обновление библиотеки")
        let input = root.appendingPathComponent("fast.wav")
        pipeline.rerun(record: Record(title: "Встреча", dir: root, source: input), speakers: 3, library: library)
        spin { !pipeline.isRunning }
        precondition(pipeline.log.contains { $0.contains("--speakers") && $0.contains("3") })
        print("PASS: повторный разбор с заданным числом участников")
    }
}
