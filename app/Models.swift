import Foundation
import SwiftUI

/// Пути, по которым живут данные. Совпадают с тем, что пишет питоновское
/// ядро: интерфейс ничего своего не выдумывает, а читает готовое.
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var support: URL {
        AppConfiguration.support
    }

    static var settings: URL { support.appending(path: "settings.json") }
    static var configEnv: URL { support.appending(path: "config.env") }
    static var venvPython: URL { support.appending(path: "env/bin/python3") }

    /// Окружение развёрнуто и обработка запустится.
    static var isReady: Bool {
        FileManager.default.fileExists(atPath: venvPython.path)
    }

    /// Открыть установщик в Терминале.
    ///
    /// Скрипт и списки библиотек копируются к себе, в Application Support:
    /// файл, скачанный из интернета, помечен карантином, и Терминал открыть
    /// его откажется. У своей копии карантин снимаем сами - на своё имущество
    /// прав хватает. Мастер работает в Терминале, потому что должен доделать
    /// установку ДО того, как появится нормальный Python.
    static func runSetup() {
        let fm = FileManager.default
        let dir = support.appending(path: "setup")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let resources = Bundle.main.resourceURL else { return }
        for name in ["setup.command", "requirements.txt",
                     "requirements-faster-whisper.txt", "requirements-gigaam.txt"] {
            let source = resources.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = dir.appending(path: name)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: source, to: target)
        }

        let script = dir.appending(path: "setup.command")
        guard fm.fileExists(atPath: script.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-cr", dir.path]
        try? strip.run(); strip.waitUntilExit()

        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-a", "Terminal", script.path]
        try? launch.run()
    }
    static var profiles: URL {
        URL(fileURLWithPath: (AppConfiguration.environment()["MEETING_TRANSCRIBER_PROFILES"]! as NSString).expandingTildeInPath)
    }
    static var glossary: URL {
        URL(fileURLWithPath: (AppConfiguration.environment()["MEETING_TRANSCRIBER_GLOSSARY"]! as NSString).expandingTildeInPath)
    }
    /// Список проектов: лежит рядом со словарём терминов — оба про то, как
    /// программа понимает вашу работу, и оба правятся руками.
    static var projects: URL { glossary.deletingLastPathComponent().appending(path: "projects.json") }

    /// Каталог с промежуточными файлами внутри результата. Имя задаётся ядром.
    static let extraDir = "доп файлы, на случай ошибки summary"
    static let unknownDir = "Новые спикеры"
    /// Голоса, которых человек опознать не смог. Лежат подпапкой внутри
    /// «Новых спикеров»: список читает только верхний уровень, поэтому
    /// отложенные пропадают из него сами, но остаются файлами на диске.
    static let dismissedDir = "Не удалось определить"

    /// Ядро приложения внутри бандла.
    static var core: URL {
        Bundle.main.resourceURL?.appending(path: "core/meeting_transcriber_v25_1.py")
            ?? URL(fileURLWithPath: "meeting_transcriber_v25_1.py")
    }
}

// MARK: - Настройки

extension Settings {
    var palette: Palette {
        switch theme {
        case "light": return .light
        case "system": return NSAppearanceIsDark() ? .dark : .light
        default: return .dark
        }
    }
}

func NSAppearanceIsDark() -> Bool {
    if let name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
        return name.lowercased().contains("dark")
    }
    return false
}

// MARK: - Люди

struct Speaker: Identifiable, Hashable {
    let key: String
    var name: String
    var position: String
    var company: String
    var samples: Int
    var id: String { key }

    var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var subtitle: String {
        [position, company].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Реплика на встрече: кто, когда и сколько говорил.
struct Turn: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let speaker: String        // SPEAKER_00 из диаризации
    let name: String           // человеческое имя, если голос опознан
    var duration: Double { max(0, end - start) }
}

/// Неопознанный голос, ждущий, чтобы его назвали.
struct UnknownVoice: Identifiable {
    let id = UUID()
    let url: URL
    let record: URL
    /// Имя, которое ядро определило по разговору. Может быть уже принято
    /// (тогда оно лежит в speaker_names.json) или только предложено.
    var inferred: String = ""

    /// Ядро кладёт догадку прямо в имя файла: «SPEAKER_01 — возможно, Богдан».
    var guess: String? {
        if !inferred.isEmpty { return inferred }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: "возможно,") else { return nil }
        let value = stem[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    var label: String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.components(separatedBy: " — ").first ?? stem
    }
}

/// Обработанная встреча.
/// Что ядро решило о принадлежности встречи: проект, тип и — если решить не
/// смогло — вопросы человеку.
struct MeetingCard: Decodable {
    var project = ""
    var known = false
    var confidence = 0.0
    var type = ""
    var why = ""
    var questions: [String] = []
    var needs_review = false
}

struct Record: Identifiable {
    var id: URL { dir }
    let dir: URL
    let title: String
    let date: Date
    var turns: [Turn] = []

    var speakerCount: Int { Set(turns.map(\.speaker)).count }
    var length: Double { turns.map(\.end).max() ?? 0 }

    /// Резюме встречи: решения, поручения и кто за что отвечает.
    /// Появляется после расшифровки и разделения по голосам.
    var summary: URL? { existing("02_summary_todo.docx") }

    /// Проект и тип встречи. Пусто, пока не собрано резюме или пока
    /// автоопределение выключено.
    var meeting: MeetingCard? {
        guard let url = existing("meeting.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingCard.self, from: data)
    }
    var transcript: URL? { existing("01_transcript.docx") }

    /// Исходная запись встречи. Ядро удаляет свою рабочую копию после
    /// обработки, но оригинал остаётся рядом с папкой результата — из него
    /// и слушаем фрагменты, вместо того чтобы просить включить хранение
    /// диагностических данных.
    var source: URL? {
        // Ядро записывает полный путь исходника: результат может лежать в
        // отдельной папке, и тогда искать запись рядом с ним бессмысленно.
        if let path = sourceField("source_path") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let folder = dir.deletingLastPathComponent()
        if let name = sourceName {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for ext in ["wav", "mp4", "m4a", "mp3", "mov", "webm", "mkv"] {
            let url = folder.appending(path: "\(title).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Рабочая копия — последний вариант: она есть, только если включено
        // хранение диагностических данных.
        return existing("\(Paths.extraDir)/work/audio_16k.wav")
    }

    /// Дорожка с вашим голосом — у записей, сделанных до сведения дорожек.
    ///
    /// Тогда живой захват оставлял два файла, и реплики с меткой OWN звучали
    /// из микрофонного. Новые записи сводятся в одну дорожку ещё при
    /// остановке, метки OWN в них нет, и этот путь просто не находит файла.
    var ownTrack: URL? {
        // Ищем рядом с самой записью, а не рядом с результатом: при живом
        // захвате обе дорожки пишутся в одну папку, но результат может
        // уехать в другую.
        var folders = [dir.deletingLastPathComponent()]
        if let source { folders.insert(source.deletingLastPathComponent(), at: 0) }
        for folder in folders {
            let url = folder.appending(path: "\(title) — мой голос.wav")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private var sourceName: String? { sourceField("source") }

    private func sourceField(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: dir.appending(path: "transcript.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return raw[key] as? String
    }

    private func existing(_ name: String) -> URL? {
        let url = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Чтение данных

@Observable
final class Library {
    var settings = Settings.load()
    var speakers: [Speaker] = []
    var records: [Record] = []
    var unknown: [UnknownVoice] = []

    /// Цвет закрепляется за человеком по месту в отсортированном списке.
    /// Не по хешу: хеш давал коллизии, и двое на одной встрече оказывались
    /// одного оттенка — ровно то, что лента должна различать.
    private(set) var colors: [String: Color] = [:]

    var palette: Palette { settings.palette }

    func reload() {
        speakers = Self.readSpeakers()
        records = Self.readRecords(in: settings.results_dir)
        unknown = records.flatMap(Self.readUnknown)
        let shades = palette.speakers
        colors = Dictionary(uniqueKeysWithValues:
            speakers.map(\.key).sorted().enumerated().map { ($1, shades[$0 % shades.count]) })
        adoptMyCard()
    }

    // MARK: о себе

    /// Карточка самого владельца среди «Спикеров» — та, что названа его именем.
    var mySpeaker: Speaker? {
        let mine = settings.my_name.trimmingCharacters(in: .whitespaces)
        guard !mine.isEmpty else { return nil }
        return speakers.first { $0.name.caseInsensitiveCompare(mine) == .orderedSame }
    }

    /// Голоса, отложенные как неопознаваемые, по всем встречам.
    var dismissed: [UnknownVoice] { records.flatMap(Self.readDismissed) }

    /// Отложить голос: человек его не узнаёт, и в списке он только мешает.
    ///
    /// Файл переезжает в подпапку, а не удаляется: голос — единственный след
    /// живого человека на записи, и стереть его насовсем из-за того, что не
    /// вспомнили имя, — потеря без возврата.
    func dismissUnknown(_ voice: UnknownVoice) {
        let bin = voice.url.deletingLastPathComponent().appending(path: Paths.dismissedDir)
        move(voice.url, to: bin)
    }

    /// Вернуть отложенный голос обратно в список.
    func restoreUnknown(_ voice: UnknownVoice) {
        move(voice.url, to: voice.url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func move(_ url: URL, to folder: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: url.lastPathComponent)
        guard !files.fileExists(atPath: target.path) else { return }
        do { try files.moveItem(at: url, to: target) } catch { return }
        unknown = records.flatMap(Self.readUnknown)
    }

    /// Сохранить «о себе» и продублировать в свою карточку.
    ///
    /// Должность и компания видны в двух местах — в настройках и под именем в
    /// «Спикерах». Пишем сразу в оба: иначе человек, поправив одно, увидит в
    /// другом старое и не поймёт, какое из них настоящее.
    func saveMyCard() {
        settings.save()
        guard let mine = mySpeaker else { return }
        writeCard(key: mine.key, position: settings.my_position, company: settings.my_company)
        guard let index = speakers.firstIndex(where: { $0.key == mine.key }) else { return }
        speakers[index].position = settings.my_position
        speakers[index].company = settings.my_company
    }

    /// Подхватить должность и компанию из своей карточки.
    ///
    /// Раньше вписать их можно было только при заведении человека, и у тех,
    /// кто так и сделал, они лежат в profiles.json. Если в настройках пусто —
    /// берём оттуда, иначе поля «о себе» встретят человека пустыми, и он
    /// решит, что введённое пропало.
    private func adoptMyCard() {
        guard settings.my_position.isEmpty, settings.my_company.isEmpty,
              let mine = mySpeaker,
              !(mine.position.isEmpty && mine.company.isEmpty) else { return }
        settings.my_position = mine.position
        settings.my_company = mine.company
        settings.save()
    }

    /// Переписать в profiles.json две строки одной карточки.
    ///
    /// Файл перечитывается перед записью и меняется по одному ключу: ядро
    /// пишет туда же — новые профили и отпечатки, — и целиком записанный
    /// файл затёр бы его работу.
    private func writeCard(key: String, position: String, company: String) {
        let path = Paths.profiles.appending(path: "profiles.json")
        guard let data = try? Data(contentsOf: path),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var info = stored[key] as? [String: Any] else { return }
        info["position"] = position
        info["company"] = company
        var raw = stored
        raw[key] = info
        guard let out = try? JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return }
        try? out.write(to: path, options: .atomic)
    }

    /// Цвет реплики.
    ///
    /// У зарегистрированного человека цвет постоянный — он узнаётся на любой
    /// встрече. У ещё не названного голоса цвет раздаётся внутри встречи по
    /// порядку: без этого лента новой встречи была бы сплошь серой, а именно
    /// на ней различать говорящих нужнее всего.
    func color(for turn: Turn, in record: Record?) -> Color {
        if !turn.name.isEmpty,
           let match = speakers.first(where: { $0.name == turn.name }),
           let colour = colors[match.key] {
            return colour
        }
        guard let record else { return palette.unknown }
        let ids = Set(record.turns.map(\.speaker)).sorted()
        guard let index = ids.firstIndex(of: turn.speaker) else { return palette.unknown }
        return palette.speakers[index % palette.speakers.count]
    }

    func color(forName name: String) -> Color {
        guard !name.isEmpty,
              let match = speakers.first(where: { $0.name == name }),
              let colour = colors[match.key]
        else { return palette.unknown }
        return colour
    }

    func color(for speaker: Speaker) -> Color {
        colors[speaker.key] ?? palette.unknown
    }

    /// Человеческая подпись неопознанного голоса.
    ///
    /// «SPEAKER_01» — внутренний идентификатор диаризации, ему не место в
    /// интерфейсе. Нумеруем так же, как в легенде, чтобы карточка и лента
    /// говорили об одном и том же голосе одинаково.
    func label(for voice: UnknownVoice) -> String {
        if let guess = voice.guess { return guess }
        guard let record = records.first(where: { $0.dir == voice.record }) else {
            return "Неизвестный голос"
        }
        let ids = Set(record.turns.map(\.speaker)).sorted()
        guard let index = ids.firstIndex(of: voice.label) else { return "Неизвестный голос" }
        return "Голос \(index + 1)"
    }

    /// Цвет голоса на ленте — тот же, что у его карточки.
    func color(for voice: UnknownVoice) -> Color {
        guard let record = records.first(where: { $0.dir == voice.record }),
              let turn = record.turns.first(where: { $0.speaker == voice.label })
        else { return palette.unknown }
        return color(for: turn, in: record)
    }

    // MARK: разбор файлов

    static func readSpeakers() -> [Speaker] {
        let path = Paths.profiles.appending(path: "profiles.json")
        guard let data = try? Data(contentsOf: path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        return raw.compactMap { key, value in
            guard let info = value as? [String: Any] else { return nil }
            return Speaker(
                key: key,
                name: info["name"] as? String ?? key,
                position: info["position"] as? String ?? "",
                company: info["company"] as? String ?? "",
                samples: info["samples"] as? Int ?? 0
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Названия проектов из списка — для выбора руками.
    static func projectNames() -> [String] {
        guard let data = try? Data(contentsOf: Paths.projects),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = raw["projects"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func readRecords(in folder: String) -> [Record] {
        let root = URL(fileURLWithPath: folder)
        let manager = FileManager.default
        let top = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        // Разложенные по проектам встречи лежат на уровень глубже. Ищем и там,
        // иначе включённая группировка выглядела бы как пропажа записей.
        var items = top
        for folder in top where !folder.lastPathComponent.hasSuffix("_result") {
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            items += (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }

        return items
            .filter { $0.lastPathComponent.hasSuffix("_result") }
            .compactMap { dir -> Record? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue,
                      (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
                // Папка без стенограммы — след неудачного прогона, а не
                // запись. Показывать её в списке значит выдавать сбой за
                // результат.
                guard FileManager.default.fileExists(
                    atPath: dir.appending(path: "transcript.json").path) else { return nil }
                let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let raw = dir.lastPathComponent.replacingOccurrences(
                    of: "_result", with: "", options: .backwards)
                // Ядро сохраняет прошлый прогон как «<имя>_<дата>_result».
                // В названии встречи метка не нужна, а сами копии ниже
                // отсеиваются: в списке должна быть одна строка на встречу.
                let title = raw.replacingOccurrences(
                    of: "_\\d{8}_\\d{6}$", with: "", options: .regularExpression)
                return Record(dir: dir, title: title, date: date, turns: readTurns(in: dir))
            }
            .sorted { $0.date > $1.date }
            .reduce(into: [Record]()) { list, record in
                // Оставляем только свежий прогон каждой встречи: старые копии
                // лежат на диске, но в списке они лишний шум.
                if let index = list.firstIndex(where: { $0.title == record.title }) {
                    if record.dir.lastPathComponent == record.title + "_result" {
                        list[index] = record
                    }
                } else { list.append(record) }
            }
            .sorted { $0.date > $1.date }
    }

    static func readTurns(in record: URL) -> [Turn] {
        let extra = record.appending(path: Paths.extraDir)
        guard let data = try? Data(contentsOf: extra.appending(path: "diarization.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let names = readNames(in: record)

        return raw.compactMap { item in
            guard let start = item["start"] as? Double,
                  let end = item["end"] as? Double else { return nil }
            let speaker = item["speaker"] as? String ?? ""
            return Turn(start: start, end: end, speaker: speaker, name: names[speaker] ?? "")
        }.sorted { $0.start < $1.start }
    }

    static func readUnknown(in record: Record) -> [UnknownVoice] {
        let folder = record.dir.appending(path: Paths.extraDir).appending(path: Paths.unknownDir)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = readNames(in: record.dir)
        return items.filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: " — ").first ?? ""
                return UnknownVoice(url: url, record: record.dir, inferred: names[id] ?? "")
            }
    }

    /// Отложенные голоса — те же карточки, только из подпапки.
    static func readDismissed(in record: Record) -> [UnknownVoice] {
        let folder = record.dir.appending(path: Paths.extraDir)
            .appending(path: Paths.unknownDir).appending(path: Paths.dismissedDir)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = readNames(in: record.dir)
        return items.filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: " — ").first ?? ""
                return UnknownVoice(url: url, record: record.dir, inferred: names[id] ?? "")
            }
    }

    static func readNames(in record: URL) -> [String: String] {
        let path = record.appending(path: Paths.extraDir).appending(path: "speaker_names.json")
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] { names = parsed }
        let profiles = Dictionary(uniqueKeysWithValues: readSpeakers().map { ($0.key, $0.name) })
        let extra = record.appending(path: Paths.extraDir)
        if let data = try? Data(contentsOf: extra.appending(path: "speaker_recognition.json")),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for row in rows {
                if let voice = row["speaker_id"] as? String, let key = row["profile_key"] as? String,
                   let name = profiles[key] { names[voice] = name }
            }
        }
        if let data = try? Data(contentsOf: extra.appending(path: "speaker_links.json")),
           let links = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (voice, key) in links {
                if let name = profiles[key] { names[voice] = name }
            }
        }
        return names
    }
}

// MARK: - Формат времени

func hms(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let (h, rest) = (total / 3600, total % 3600)
    let (m, s) = (rest / 60, rest % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

func humanDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "d MMMM, HH:mm"
    return formatter.string(from: date)
}
