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
        print("PASS: библиотека — актуальная версия, ручные имена, переименование профиля")
    }
}
