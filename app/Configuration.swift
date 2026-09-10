import Foundation

/// Тот же контракт настроек и цветов, который читает Windows-интерфейс.
enum DesktopContract {
    static let raw: [String: Any] = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("core/desktop_contract.json"),
                          URL(fileURLWithPath: "core/desktop_contract.json")].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return value }
        }
        return [:]
    }()
    static var defaults: [String: Any] { raw["settings"] as? [String: Any] ?? [:] }
    static func theme(_ name: String) -> [String: Any] {
        (raw["themes"] as? [String: [String: Any]])?[name] ?? [:]
    }
}

enum AppConfiguration {
    static var support: URL {
        let path = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBER_APP_SUPPORT"] ?? ""
        if !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Славатор")
    }
    static var settingsURL: URL { support.appendingPathComponent("settings.json") }
    static var usesLocalModel: Bool {
        let host = environment()["MEETING_TRANSCRIBER_OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(URL(string: host)?.host?.lowercased() ?? "")
    }

    static func readEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\u{FEFF}", with: "").split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.hasPrefix("#"), let eq = clean.firstIndex(of: "=") else { continue }
            let key = clean[..<eq].trimmingCharacters(in: .whitespaces)
            var value = clean[clean.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last,
               first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    static func environment(settings: Settings? = nil) -> [String: String] {
        let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("whisper-work")
        var env = ["MEETING_TRANSCRIBER_APP_SUPPORT": support.path,
                   "MEETING_TRANSCRIBER_PROFILES": data.appendingPathComponent("speaker_profiles").path,
                   "MEETING_TRANSCRIBER_MODELS": data.appendingPathComponent("models").path,
                   "MEETING_TRANSCRIBER_WHISPER_MODEL": DesktopContract.defaults["asr_model"] as? String ?? "small",
                   "MEETING_TRANSCRIBER_GLOSSARY": data.appendingPathComponent("glossary.txt").path]
        if let text = try? String(contentsOf: support.appendingPathComponent("config.env"), encoding: .utf8) {
            env.merge(readEnv(text)) { _, new in new }
        }
        if let settings {
            env["MEETING_TRANSCRIBER_LLM"] = settings.llm_model
            env["MEETING_TRANSCRIBER_WHISPER_MODEL"] = settings.asr_model
            env["MEETING_TRANSCRIBER_VOICE_THRESHOLD"] = String(format: "%.2f", settings.voice_threshold)
        }
        else if let data = try? Data(contentsOf: settingsURL),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let model = raw["llm_model"] as? String, !model.isEmpty {
            env["MEETING_TRANSCRIBER_LLM"] = model
        }
        if settings == nil, let data = try? Data(contentsOf: settingsURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = raw["asr_model"] as? String, !model.isEmpty {
            env["MEETING_TRANSCRIBER_WHISPER_MODEL"] = model
        }
        env.merge(ProcessInfo.processInfo.environment) { _, new in new }
        if let host = env["MEETING_TRANSCRIBER_OLLAMA_HOST"] ?? env["MEETING_TRANSCRIBER_OLLAMA"] {
            let normalized = host.hasSuffix("/") ? String(host.dropLast()) : host
            env["MEETING_TRANSCRIBER_OLLAMA_HOST"] = normalized
            env["MEETING_TRANSCRIBER_OLLAMA"] = normalized
        }
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUTF8"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }
}

struct Settings: Codable {
    var theme = DesktopContract.defaults["theme"] as? String ?? "dark"
    var results_dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    /// Куда класть саму запись встречи. Пусто — туда же, где результаты:
    /// так было раньше, и менять это молча у тех, кто уже привык, незачем.
    var recordings_dir = ""
    var menubar_enabled = true
    var meeting_watch_enabled = false
    var dictation_hotkey = "ropt"
    var dictation_tidy_hotkey = "opt+shift"
    var memory_graph_enabled = true
    var chat_memory_enabled = true
    /// Чей голос считать вашим. Пусто — ещё не спрашивали, значение
    /// подставится само по имени из настроек; `noVoice` — отказались явно,
    /// и подставлять больше нечего.
    var my_profile_key = ""
    static let noVoice = "-"
    var widget_enabled = false
    /// small | medium | large — насколько подробен виджет.
    var widget_size = "medium"
    var widget_output_dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    var keep_diagnostics = false
    var my_name = DesktopContract.defaults["my_name"] as? String ?? "Вы"
    /// Должность и компания владельца. Живут здесь, а не только в профиле:
    /// вписать их человек должен уметь, ни разу не заводя голосовую карточку.
    var my_position = ""
    var my_company = ""
    /// Определять проект встречи и раскладывать результаты по его папке.
    var project_grouping = false
    var dictation_enabled = false
    var dictation_model = DesktopContract.defaults["dictation_model"] as? String ?? "small"
    var dictation_level = DesktopContract.defaults["dictation_level"] as? String ?? "structure"
    /// Приглушать системный звук на время диктовки. Говорить поверх музыки
    /// или чужой речи — значит отдавать их микрофону вместе со своим голосом.
    var dictation_duck = true
    var llm_model = DesktopContract.defaults["llm_model"] as? String ?? "qwen3:8b"
    var asr_model = DesktopContract.defaults["asr_model"] as? String ?? "small"
    /// Порог узнавания голоса, 0.70–0.98. Измеренное значение — 0.90: ниже
    /// начинают склеиваться разные люди, выше не узнаётся никто. Зоны своих и
    /// чужих перекрываются, единственно верного значения нет, поэтому оно
    /// вынесено наружу.
    var voice_threshold = 0.90

    enum CodingKeys: String, CodingKey {
        case menubar_enabled, meeting_watch_enabled, dictation_hotkey, dictation_tidy_hotkey, memory_graph_enabled, chat_memory_enabled, my_profile_key
        case theme, results_dir, recordings_dir, widget_enabled, widget_size, widget_output_dir
        case keep_diagnostics, my_name, my_position, my_company, project_grouping
        case dictation_enabled, dictation_model, dictation_level, dictation_duck
        case llm_model, asr_model
        case voice_threshold
    }
    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Отсутствующее или неверное поле не сбрасывает остальные настройки.
        theme = (try? values.decode(String.self, forKey: .theme)) ?? theme
        if !["dark", "light", "system"].contains(theme) { theme = "dark" }
        results_dir = (try? values.decode(String.self, forKey: .results_dir)) ?? results_dir
        if results_dir.trimmingCharacters(in: .whitespaces).isEmpty { results_dir = Settings().results_dir }
        menubar_enabled = (try? values.decode(Bool.self, forKey: .menubar_enabled)) ?? menubar_enabled
        meeting_watch_enabled = (try? values.decode(Bool.self, forKey: .meeting_watch_enabled)) ?? meeting_watch_enabled
        dictation_hotkey = (try? values.decode(String.self, forKey: .dictation_hotkey)) ?? dictation_hotkey
        dictation_tidy_hotkey = (try? values.decode(String.self, forKey: .dictation_tidy_hotkey)) ?? dictation_tidy_hotkey
        memory_graph_enabled = (try? values.decode(Bool.self, forKey: .memory_graph_enabled)) ?? memory_graph_enabled
        chat_memory_enabled = (try? values.decode(Bool.self, forKey: .chat_memory_enabled)) ?? chat_memory_enabled
        my_profile_key = (try? values.decode(String.self, forKey: .my_profile_key)) ?? my_profile_key
        recordings_dir = (try? values.decode(String.self, forKey: .recordings_dir)) ?? recordings_dir
        widget_enabled = (try? values.decode(Bool.self, forKey: .widget_enabled)) ?? widget_enabled
        widget_size = (try? values.decode(String.self, forKey: .widget_size)) ?? widget_size
        widget_output_dir = (try? values.decode(String.self, forKey: .widget_output_dir)) ?? widget_output_dir
        keep_diagnostics = (try? values.decode(Bool.self, forKey: .keep_diagnostics)) ?? keep_diagnostics
        my_name = (try? values.decode(String.self, forKey: .my_name)) ?? my_name
        my_position = (try? values.decode(String.self, forKey: .my_position)) ?? my_position
        my_company = (try? values.decode(String.self, forKey: .my_company)) ?? my_company
        project_grouping = (try? values.decode(Bool.self, forKey: .project_grouping)) ?? project_grouping
        dictation_enabled = (try? values.decode(Bool.self, forKey: .dictation_enabled)) ?? dictation_enabled
        dictation_model = (try? values.decode(String.self, forKey: .dictation_model)) ?? dictation_model
        dictation_level = (try? values.decode(String.self, forKey: .dictation_level)) ?? dictation_level
        dictation_duck = (try? values.decode(Bool.self, forKey: .dictation_duck)) ?? dictation_duck
        llm_model = (try? values.decode(String.self, forKey: .llm_model)) ?? llm_model
        asr_model = (try? values.decode(String.self, forKey: .asr_model)) ?? asr_model
        voice_threshold = (try? values.decode(Double.self, forKey: .voice_threshold)) ?? voice_threshold
        if !(0.70...0.98).contains(voice_threshold) { voice_threshold = Settings().voice_threshold }
        if asr_model.trimmingCharacters(in: .whitespaces).isEmpty { asr_model = Settings().asr_model }
        if llm_model.trimmingCharacters(in: .whitespaces).isEmpty { llm_model = Settings().llm_model }
    }

    static func load() -> Settings {
        var settings = Settings()
        var hasSavedModel = false
        var hasSavedASR = false
        if let data = try? Data(contentsOf: AppConfiguration.settingsURL) {
            settings = (try? JSONDecoder().decode(Settings.self, from: data)) ?? settings
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = raw["llm_model"] as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                hasSavedModel = true
            }
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = raw["asr_model"] as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                hasSavedASR = true
            }
        }
        if !hasSavedModel, let model = AppConfiguration.environment()["MEETING_TRANSCRIBER_LLM"], !model.isEmpty {
            settings.llm_model = model
        }
        // Настройки, записанные до слияния веток, знают не имя модели, а две
        // ступени: «точнее» и «быстрее». Без переноса человек молча съезжает
        // с large-v3 на умолчание контракта и не понимает, почему стало хуже.
        if !hasSavedASR, let data = try? Data(contentsOf: AppConfiguration.settingsURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let speed = raw["asr_speed"] as? String {
            settings.asr_model = speed == "fast" ? "large-v3-turbo" : "large-v3"
            hasSavedASR = true
        }
        if !hasSavedASR, let model = AppConfiguration.environment()["MEETING_TRANSCRIBER_WHISPER_MODEL"], !model.isEmpty {
            settings.asr_model = model
        }
        return settings
    }

    func save() {
        let path = AppConfiguration.settingsURL
        var stored: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { stored = raw }
        guard let encoded = try? JSONEncoder().encode(self),
              let values = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        stored.merge(values) { _, new in new }
        do {
            try FileManager.default.createDirectory(at: AppConfiguration.support, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
                .write(to: path, options: .atomic)
        } catch {
            NotificationCenter.default.post(name: .settingsSaveFailed, object: error.localizedDescription)
        }
    }
}

extension Settings {
    /// Папка, куда ложится запись встречи.
    var recordingsFolder: String {
        recordings_dir.isEmpty ? results_dir : recordings_dir
    }
}

extension Notification.Name {
    static let settingsSaveFailed = Notification.Name("slavator.settingsSaveFailed")
}

enum MediaInput {
    static let extensions: Set<String> = ["wav", "mp3", "m4a", "mp4", "mov", "webm", "mkv",
                                           "flac", "ogg", "opus", "aac", "aif", "aiff", "avi", "m4v", "wma"]
    static func validate(_ url: URL) throws {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else {
            throw Failure("Выберите аудио или видео: WAV, MP3, M4A, MP4 и другие медиаформаты.")
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) > 0,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure("Файл пуст или недоступен для чтения. Выберите другую запись.")
        }
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
