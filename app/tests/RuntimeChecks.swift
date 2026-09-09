import Foundation

@main
struct RuntimeChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slavator-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        setenv("MEETING_TRANSCRIBER_APP_SUPPORT", root.path, 1)

        let old = Data(#"{"theme":"light","results_dir":"/custom","my_name":"Алексей","dictation_enabled":"bad","future":{"value":42}}"#.utf8)
        try old.write(to: AppConfiguration.settingsURL)
        var settings = Settings.load()
        precondition(settings.theme == "light" && settings.results_dir == "/custom")
        precondition(settings.my_name == "Алексей" && !settings.dictation_enabled)
        settings.theme = "dark"
        settings.save()
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: AppConfiguration.settingsURL)) as! [String: Any]
        precondition((stored["future"] as? [String: Int])?["value"] == 42)
        print("PASS: старые настройки, повреждённое поле, сохранение неизвестных полей")

        let env = AppConfiguration.readEnv("\u{FEFF}# header\nKEY = \"C:\\Мои файлы\\a=b\"\nSINGLE='value'\n")
        precondition(env["KEY"] == "C:\\Мои файлы\\a=b" && env["SINGLE"] == "value")
        precondition(DesktopContract.theme("dark")["bg"] as? String == "0D1420")
        print("PASS: общий контракт и Windows config.env с BOM")

        let expected = ["Первый голос", "@@PROGRESS@@{\"pct\":45,\"detail\":\"Распознаю речь\"}", "Последняя строка"]
        let payload = Data(expected.joined(separator: "\n").utf8)
        var lines: [String] = []
        var buffer = LineBuffer()
        for byte in payload { lines += buffer.append(Data([byte])) }
        lines += buffer.append(Data(), endOfFile: true)
        precondition(lines == expected)
        print("PASS: UTF-8 и JSON побайтно, остаток без перевода строки")

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; [print('строка' * 100) for _ in range(3000)]; sys.stdout.write('конец')"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = AppConfiguration.environment()
        try process.run()
        var count = 0
        var last = ""
        var done = false
        ProcessOutput.read(pipe, process: process, onLine: { line in
            count += 1; last = line
        }, onExit: { status in
            precondition(status == 0 && count == 3001 && last == "конец")
            done = true
        })
        let deadline = Date().addingTimeInterval(15)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done, "Pipe не дренируется")
        print("PASS: 3 МБ stdout, отсутствие deadlock, завершение после последней строки")

        let empty = root.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        do { try MediaInput.validate(empty); preconditionFailure("Пустой файл принят") }
        catch is MediaInput.Failure {}
        do { try MediaInput.validate(root.appendingPathComponent("data.json")); preconditionFailure("JSON принят") }
        catch is MediaInput.Failure {}
        print("PASS: проверка входных файлов")
    }
}
