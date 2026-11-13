import Foundation

@main struct LibraryChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slavator-library-check-\(UUID())")
        let profiles = root.appendingPathComponent("profiles")
        try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        setenv("MEETING_TRANSCRIBER_APP_SUPPORT", root.path, 1)
        setenv("MEETING_TRANSCRIBER_PROFILES", profiles.path, 1)

        try fm.createDirectory(at: Paths.venvPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: Paths.venvPython)
        precondition(!Paths.isReady, "Наличие Python ещё не означает готовность распознавания")
        let readyMarker = root.appendingPathComponent(".ready")
        try Data("Fri Nov 13 2026\n".utf8).write(to: readyMarker)
        precondition(!Paths.isReady, "Старый установщик писал дату без проверки моделей")
        try Data("speech-ready\n".utf8).write(to: readyMarker)
        precondition(Paths.isReady)
        try fm.removeItem(at: readyMarker)
        precondition(!Paths.isReady, "Прерванная установка снимает готовность")
        print("PASS: Python без подтверждённой установки не считается готовым окружением")

        func write(_ value: Any, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try write(["anna": ["name": "Анна"], "anna2": ["name": "Анна Иванова"]],
                  to: profiles.appendingPathComponent("profiles.json"))
        let current = root.appendingPathComponent("meeting_result")
        let archived = root.appendingPathComponent("meeting_20260908_101010_result")
        for dir in [current, archived] {
            try write(["utterances": []], to: dir.appendingPathComponent("transcript.json"))
            try write([["speaker": "SPEAKER_00", "start": 0, "end": 10]],
                      to: dir.appendingPathComponent(Paths.extraDir + "/diarization.json"))
        }
        try write(["SPEAKER_00": "Имя по разговору"],
                  to: current.appendingPathComponent(Paths.extraDir + "/speaker_names.json"))
        try write([["speaker_id": "SPEAKER_00", "profile_key": "anna"]],
                  to: current.appendingPathComponent(Paths.extraDir + "/speaker_recognition.json"))
        try write(["SPEAKER_00": "anna2"],
                  to: current.appendingPathComponent(Paths.extraDir + "/speaker_links.json"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: current.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: archived.path)
        let records = Library.readRecords(in: root.path)
        precondition(records.count == 1 && records[0].dir.standardizedFileURL.path == current.standardizedFileURL.path,
                     "Архив не должен подменять актуальную встречу из-за свежего mtime")
        precondition(records[0].turns[0].name == "Анна Иванова",
                     "Ручное назначение важнее опознания и догадки по разговору")
        try write(["anna": ["name": "Анна"], "anna2": ["name": "Новое имя"]],
                  to: profiles.appendingPathComponent("profiles.json"))
        precondition(Library.readTurns(in: current)[0].name == "Новое имя")
        let unknownFolder = current.appendingPathComponent(Paths.extraDir + "/" + Paths.unknownDir)
        try fm.createDirectory(at: unknownFolder, withIntermediateDirectories: true)
        try Data().write(to: unknownFolder.appendingPathComponent("SPEAKER_00.wav"))
        try Data().write(to: unknownFolder.appendingPathComponent("SPEAKER_01.wav"))
        precondition(Library.readUnknown(in: records[0]).map(\.label) == ["SPEAKER_01"],
                     "Привязанный в карточке голос исчезает из новых без удаления аудио")
        try write(["SPEAKER_01": "Имя вручную"],
                  to: current.appendingPathComponent(Paths.extraDir + "/speaker_labels.json"))
        precondition(Library.readUnknown(in: records[0]).isEmpty, "Ручное имя тоже подтверждает голос")
        try write(["anna": ["name": "Анна", "samples": 5]], to: profiles.appendingPathComponent("profiles.json"))
        precondition(Library.readSpeakers()[0].samples == 0, "Счётчик не обещает отсутствующие аудиофайлы")
        let samples = profiles.appendingPathComponent("samples/anna")
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)
        try Data().write(to: samples.appendingPathComponent("one.wav"))
        precondition(Library.readSpeakers()[0].samples == 1)
        let library = Library()
        let ribbonRecord = Record(dir: current, title: "Лента", date: Date(), turns: [
            Turn(start: 0, end: 1, speaker: "B", name: ""),
            Turn(start: 1, end: 2, speaker: "A", name: ""),
            Turn(start: 2, end: 3, speaker: "A", name: "Анна")])
        let ribbonTurns = ribbonRecord.turns + [Turn(start: 3, end: 4, speaker: "", name: "")]
        precondition(library.ribbonColors(for: ribbonTurns, in: ribbonRecord)
                     == ribbonTurns.map { library.color(for: $0, in: ribbonRecord) },
                     "Быстрый расчёт сохраняет цвета голосов и приглушённых отрезков")
        precondition(library.ribbonColors(for: ribbonTurns, in: nil)
                     == ribbonTurns.map { library.color(for: $0, in: nil) })
        print("PASS: библиотека — актуальная версия, ручные имена, переименование профиля")
    }
}
