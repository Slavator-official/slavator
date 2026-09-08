import Foundation
import SwiftUI

/// Пути, по которым живут данные. Совпадают с тем, что пишет питоновское
/// ядро: интерфейс ничего своего не выдумывает, а читает готовое.
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBER_APP_SUPPORT"] {
            return URL(fileURLWithPath: override)
        }
        return home.appending(path: "Library/Application Support/Славатор")
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
    static var profiles: URL { home.appending(path: "whisper-work/speaker_profiles") }
    /// Образцы голоса прежнего конвейера.
    ///
    /// Он складывал их отдельной папкой верхнего уровня, а не внутри профилей.
    /// Люди, заведённые тогда, показывали «5 образцов» в списке и «образцов
    /// пока нет» на своей странице: число берётся из profiles.json, а файлы
    /// искались только в новом месте. Папку не переносим - её по-прежнему
    /// наполняют отдельные скрипты рядом с проектом.
    static var legacySamples: URL { home.appending(path: "whisper-work/speaker_samples") }
    static var glossary: URL { home.appending(path: "whisper-work/glossary.txt") }

    /// Каталог с промежуточными файлами внутри результата. Имя задаётся ядром.
    static let extraDir = "доп файлы, на случай ошибки summary"
    static let unknownDir = "Новые спикеры"

    /// Ядро приложения внутри бандла.
    static var core: URL {
        Bundle.main.resourceURL?.appending(path: "core/meeting_transcriber_v25_1.py")
            ?? URL(fileURLWithPath: "meeting_transcriber_v25_1.py")
    }

    /// Окружение для запуска ядра: настройки из config.env, который пишет
    /// установщик.
    ///
    /// Живёт здесь, а не внутри обработки: тем же окружением запускается и
    /// проверка готовности. Разъехавшись, они смотрели бы на разные модели и
    /// разные словари и отвечали бы по-разному об одном и том же.
    static func coreEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Не давать Python писать __pycache__ внутрь подписанного бандла:
        // это ломает подпись, а с ней слетают разрешения macOS.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        guard let text = try? String(contentsOf: configEnv, encoding: .utf8) else { return env }
        for line in text.split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard !clean.hasPrefix("#"), let eq = clean.firstIndex(of: "=") else { continue }
            let key = String(clean[clean.startIndex..<eq])
            var value = String(clean[clean.index(after: eq)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            env[key] = value
        }
        return env
    }
}

// MARK: - Настройки

struct Settings: Codable {
    var theme = "dark"                 // dark | light | system
    var results_dir = Paths.home.appending(path: "Downloads").path
    var widget_enabled = false
    var widget_output_dir = Paths.home.appending(path: "Downloads").path
    var keep_diagnostics = false
    /// Как подписывать ваши реплики с микрофонной дорожки.
    var my_name = "Вы"

    // MARK: быстрый доступ
    /// Значок в строке меню: начать запись, не открывая окно.
    var menubar_enabled = true
    /// small | medium | large — насколько подробен виджет.
    var widget_size = "medium"
    /// Следить, не началась ли встреча, и предлагать её записать.
    var meeting_watch_enabled = false

    // MARK: что собирать после расшифровки
    /// Собирать резюме языковой моделью. Расшифровка ценна и без него.
    var make_summary = true
    /// Строить майндкарту.
    var make_mindmap = true
    /// Разделы протокола через запятую. Чего здесь нет, у модели не
    /// спрашивается вовсе — и ответ она пишет ровно на столько же короче.
    var summary_blocks = "info,summary,notes,decisions,todos,open"

    // MARK: диктовка
    var dictation_enabled = false
    /// small — текст идёт на ходу; large-v3-turbo — точнее, но ждать 3 секунды.
    var dictation_model = "small"
    /// Что удерживать для диктовки. Только модификаторы — см. HotCombo.
    var dictation_hotkey = "ropt"
    /// Что удерживать, чтобы надиктованное сразу прошло обработку.
    var dictation_tidy_hotkey = "opt+shift"
    /// clean | structure | shrink — насколько сильно править надиктованное.
    var dictation_level = "structure"

    /// Языковая модель: и для резюме встреч, и для чата.
    var llm_model = "qwen3:8b"

    init() {}

    /// Настройки читаются по одному ключу, а не файлом целиком.
    ///
    /// Файл, записанный прежней версией, не знает ключей, добавленных позже.
    /// Синтезированный декодер на таком файле бросает ошибку на весь объект, а
    /// `load()` молча возвращает умолчания — и человек из-за одного нового
    /// переключателя теряет и имя, и папку результатов, и назначенные клавиши.
    /// Здесь каждое поле падает на своё умолчание, а остальные доживают.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        theme = read(.theme, theme)
        results_dir = read(.results_dir, results_dir)
        widget_enabled = read(.widget_enabled, widget_enabled)
        widget_output_dir = read(.widget_output_dir, widget_output_dir)
        keep_diagnostics = read(.keep_diagnostics, keep_diagnostics)
        my_name = read(.my_name, my_name)
        menubar_enabled = read(.menubar_enabled, menubar_enabled)
        widget_size = read(.widget_size, widget_size)
        meeting_watch_enabled = read(.meeting_watch_enabled, meeting_watch_enabled)
        make_summary = read(.make_summary, make_summary)
        make_mindmap = read(.make_mindmap, make_mindmap)
        summary_blocks = read(.summary_blocks, summary_blocks)
        dictation_enabled = read(.dictation_enabled, dictation_enabled)
        dictation_model = read(.dictation_model, dictation_model)
        dictation_hotkey = read(.dictation_hotkey, dictation_hotkey)
        dictation_tidy_hotkey = read(.dictation_tidy_hotkey, dictation_tidy_hotkey)
        dictation_level = read(.dictation_level, dictation_level)
        llm_model = read(.llm_model, llm_model)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let value = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return value
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Paths.settings, options: .atomic)
    }

    var chosenBlocks: [String] {
        summary_blocks.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    func hasBlock(_ id: String) -> Bool { chosenBlocks.contains(id) }

    /// Порядок разделов всегда канонический, а не тот, в котором их включали:
    /// иначе протокол у одного человека начинался бы с поручений, а у
    /// другого - с рисков, и сравнить их было бы нельзя.
    mutating func setBlock(_ id: String, _ on: Bool) {
        var picked = Set(chosenBlocks)
        if on { picked.insert(id) } else { picked.remove(id) }
        summary_blocks = SummaryBlock.all.map(\.id).filter { picked.contains($0) }
            .joined(separator: ",")
    }

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

/// Разделы протокола.
///
/// Список повторяет SUMMARY_BLOCKS в ядре. Держать его в двух местах
/// приходится: ядро одно на три платформы и о SwiftUI ничего не знает, а
/// подписи человеку нужны здесь. Порядок обязан совпадать.
struct SummaryBlock: Identifiable {
    let id: String
    let title: String
    let hint: String

    static let all: [SummaryBlock] = [
        .init(id: "info", title: "Информация о встрече",
              hint: "Дата, длительность, участники и кого упоминали"),
        .init(id: "summary", title: "Резюме",
              hint: "Связный пересказ встречи на 5–10 предложений"),
        .init(id: "notes", title: "Заметки о встрече",
              hint: "Темы и то, что по каждой сказали"),
        .init(id: "decisions", title: "Решения", hint: "Что решили"),
        .init(id: "todos", title: "Дальнейшие шаги",
              hint: "Задача, исполнитель, срок"),
        .init(id: "open", title: "Осталось нерешённым",
              hint: "Вопросы без ответа и риски"),
        .init(id: "numbers", title: "Цифры и сроки",
              hint: "Названные числа, суммы и даты — каждое с тем, к чему относится"),
        .init(id: "disputes", title: "Разногласия",
              hint: "В чём разошлись и кто какую позицию занял"),
        .init(id: "quotes", title: "Дословно",
              hint: "Ключевые фразы с автором"),
        .init(id: "timeline", title: "Хронология",
              hint: "Что когда происходило по времени встречи"),
        .init(id: "next", title: "Следующая встреча",
              hint: "О чём и когда договорились встретиться"),
        .init(id: "blockers", title: "Чего ждём от других",
              hint: "Зависимости от людей вне встречи"),
    ]
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

    /// Должность и компания по отдельности: в списке они показываются тегами.
    var tags: [String] {
        [position, company].filter { !$0.isEmpty }
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
struct Record: Identifiable {
    let id = UUID()
    let dir: URL
    let title: String
    let date: Date
    var turns: [Turn] = []

    var speakerCount: Int { Set(turns.map(\.speaker)).count }
    var length: Double { turns.map(\.end).max() ?? 0 }

    /// Резюме встречи: решения, поручения и кто за что отвечает.
    /// Появляется после расшифровки и разделения по голосам.
    var summary: URL? { existing("02_summary_todo.docx") }
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

    /// Дорожка с вашим голосом: при записи звонка она пишется отдельным
    /// файлом, и фрагменты ваших реплик звучат из неё, а не из системной.
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

    /// Сохранить, кем мы считаем этого человека.
    ///
    /// Переписываем profiles.json, трогая ровно три поля: рядом лежат ссылка
    /// на отпечаток голоса и служебные отметки движка — потерять их значит
    /// потерять сам голос. Возвращает текст ошибки или nil, если всё вышло.
    func saveSpeaker(key: String, name: String, position: String, company: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Имя не может быть пустым" }
        if let clash = speakers.first(where: { $0.key != key && Self.samePerson($0.name, clean) }) {
            return "«\(clash.name)» уже есть в списке — получатся два человека вместо одного"
        }
        let path = Paths.profiles.appending(path: "profiles.json")
        guard let data = try? Data(contentsOf: path),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var row = raw[key] as? [String: Any]
        else { return "Не удалось прочитать профили" }

        row["name"] = clean
        row["position"] = position.trimmingCharacters(in: .whitespacesAndNewlines)
        row["company"] = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"   // как пишет ядро
        row["updated_at"] = stamp.string(from: Date())
        raw[key] = row

        guard let out = try? JSONSerialization.data(
                withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: path, options: .atomic)) != nil
        else { return "Не удалось сохранить профили" }
        reload()
        return nil
    }

    /// Одно ли это имя.
    ///
    /// Правило повторяет speaker_service: «й» без надстрочного знака и «ё»
    /// через «е» не должны считаться разными людьми — ровно на этом профили
    /// уже задваивались.
    static func samePerson(_ left: String, _ right: String) -> Bool {
        func key(_ value: String) -> String {
            value.lowercased()
                .replacingOccurrences(of: "ё", with: "е")
                .replacingOccurrences(of: "й", with: "и")
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ").joined(separator: " ")
        }
        return key(left) == key(right)
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

    static func readRecords(in folder: String) -> [Record] {
        let root = URL(fileURLWithPath: folder)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        return items
            .filter { $0.lastPathComponent.hasSuffix("_result") }
            .compactMap { dir -> Record? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
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
                if !list.contains(where: { $0.title == record.title }) { list.append(record) }
            }
    }

    static func readTurns(in record: URL) -> [Turn] {
        let extra = record.appending(path: Paths.extraDir)
        guard let data = try? Data(contentsOf: extra.appending(path: "diarization.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var names: [String: String] = [:]
        if let nd = try? Data(contentsOf: extra.appending(path: "speaker_names.json")),
           let parsed = try? JSONSerialization.jsonObject(with: nd) as? [String: String] {
            names = parsed
        }

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

    static func readNames(in record: URL) -> [String: String] {
        let path = record.appending(path: Paths.extraDir).appending(path: "speaker_names.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return parsed
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
