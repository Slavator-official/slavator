import AppKit
import Foundation
import SwiftUI

/// Запуск питоновского ядра обработки.
///
/// Ядро печатает в stdout человеческие строки и машинные `@@PROGRESS@@`.
/// Прежний интерфейс на Tk клал строки лога в очередь и там же их выбрасывал —
/// пользователь видел «Обработка завершилась с ошибкой» без причины, хотя
/// ядро её называло. Здесь весь вывод сохраняется и при сбое показывается.
@Observable
final class Pipeline {
    private(set) var isRunning = false
    private(set) var stage = ""
    private(set) var detail = ""
    private(set) var percent: Double = 0
    private(set) var log: [String] = []

    private var task: Process?

    /// Порядок этапов — для точек прогресса под полосой. Зависит от того,
    /// что запущено: у сборки резюме свой, короткий путь.
    static let fullOrder = ["prepare", "audio", "asr", "quality", "diarization",
                            "identify", "names", "transcript", "documents"]
    static let summaryOrder = ["summary", "documents"]
    /// Дозагрузка: этапы свои, и порядок у них тоже свой.
    static let repairOrder = ["models", "asr", "ollama", "llm"]
    private(set) var stageOrder = fullOrder
    private(set) var stageKey = ""

    func reached(_ key: String) -> Bool {
        guard let now = stageOrder.firstIndex(of: stageKey),
              let target = stageOrder.firstIndex(of: key) else { return false }
        return target <= now
    }

    private static let stageNames: [String: String] = [
        "prepare": "Подготовка",
        "audio": "Извлечение аудио",
        "asr": "Распознавание речи",
        "quality": "Проверка качества",
        "diarization": "Разделение на спикеров",
        "identify": "Опознание голосов",
        "names": "Определение имён",
        "transcript": "Сборка стенограммы",
        "summary": "Анализ встречи",
        "documents": "Формирование документов",
        // «asr» уже есть выше и подписан «Распознавание речи» — при
        // дозагрузке это ровно тот же шаг, только качается модель.
        "models": "Модели разделения голосов",
        "ollama": "Запуск Ollama",
        "llm": "Языковая модель",
    ]

    func run(input: URL, library: Library, voiceTrack: URL? = nil, speakers: Int = 0) {
        guard !isRunning else { return }

        let python = Paths.venvPython
        guard FileManager.default.fileExists(atPath: python.path) else {
            showAlert("Окружение не установлено",
                  "Не найден Python в \(python.path).\n\nЗапустите установку заново: удалите папку «Славатор» из ~/Library/Application Support и откройте приложение.")
            return
        }
        guard FileManager.default.fileExists(atPath: Paths.core.path) else {
            showAlert("Ядро не найдено", "Внутри приложения нет файла обработки: \(Paths.core.path)")
            return
        }

        isRunning = true
        percent = 0
        stage = "Запуск"
        stageOrder = Self.fullOrder
        detail = input.lastPathComponent
        log = []

        var arguments = ["-B", Paths.core.path, input.path]
        if let voiceTrack, FileManager.default.fileExists(atPath: voiceTrack.path) {
            arguments += ["--my-voice", voiceTrack.path,
                          "--my-name", library.settings.my_name]
        }
        // Резюме отдельно, по кнопке: оно самое долгое и нужно не всегда.
        // Расшифровка и голоса ценны сами по себе - ждать ради необязательного
        // куска лишние минуты незачем.
        arguments.append("--no-summary")
        // Результат складываем туда же, где приложение его ищет. Иначе он
        // ложится рядом с исходником, и в списке записей его не видно.
        arguments += ["--out-dir", library.settings.results_dir]
        // Названное число участников — самый крупный рычаг против дробления
        // голосов: без него движок гадает.
        if speakers > 0 { arguments += ["--speakers", String(speakers)] }
        // Проект определяется по резюме, а его собирает отдельный запуск по
        // кнопке. Здесь флаг всё равно нужен: без резюме ядро просто
        // пропустит шаг, а с ним — разложит сразу, если резюме уже есть.
        if library.settings.project_grouping { arguments.append("--group-by-project") }
        launch(arguments: arguments, library: library)
    }

    /// Собрать резюме по уже готовой встрече.
    ///
    /// Отдельный запуск ядра по каталогу результата: стенограмма уже лежит
    /// там, заново распознавать нечего - остаётся только анализ.
    func summarize(record: Record, library: Library) {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: Paths.venvPython.path) else {
            showAlert("Окружение не установлено",
                      "Сначала завершите установку на вкладке «Главная».")
            return
        }

        isRunning = true
        percent = 0
        stage = "Анализ встречи"
        stageOrder = Self.summaryOrder
        stageKey = "summary"
        detail = record.title
        log = []

        var arguments = ["-B", Paths.core.path, "--summarize", record.dir.path]
        if library.settings.project_grouping { arguments.append("--group-by-project") }
        launch(arguments: arguments, library: library)
    }

    /// Дозагрузить то, чего не хватает.
    ///
    /// Что именно догружать, решает ядро: интерфейс не считает мегабайты и не
    /// знает, где лежит Ollama. Здесь остаётся показать ход работы теми же
    /// средствами, что и у обработки записи.
    func repair(library: Library) {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: Paths.venvPython.path) else {
            showAlert("Окружение не установлено",
                      "Сначала завершите установку на вкладке «Главная».")
            return
        }

        isRunning = true
        percent = 0
        stage = "Дозагрузка"
        stageOrder = Self.repairOrder
        stageKey = ""
        detail = ""
        log = []

        launch(arguments: ["-B", Paths.core.path, "--repair"], library: library)
    }

    /// Общий запуск ядра: и обработка записи, и сборка резюме идут одинаково -
    /// подпроцесс, разбор прогресса из stdout, показ настоящей ошибки.
    private func launch(arguments: [String], library: Library) {
        let process = Process()
        process.executableURL = Paths.venvPython
        process.arguments = arguments
        process.currentDirectoryURL = Paths.core.deletingLastPathComponent()
        process.environment = Paths.coreEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                DispatchQueue.main.async { self?.consume(String(line)) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.isRunning = false
                self.task = nil
                if proc.terminationStatus == 0 {
                    self.percent = 100
                    self.stage = "Готово"
                    library.reload()
                } else if proc.terminationStatus != 15 {   // 15 — прерывание пользователем
                    self.showFailure()
                }
            }
        }

        do {
            try process.run()
            task = process
        } catch {
            isRunning = false
            showAlert("Не удалось запустить обработку", error.localizedDescription)
        }
    }

    /// Придержать разбор на время диктовки.
    ///
    /// Транскрибация занимает все ядра, и на её фоне диктовка ползла бы
    /// секунды вместо долей секунды. Вы говорите секунды, встреча считается
    /// минуты — паузы не видно, а заикающийся набор был бы виден сразу.
    func suspend(_ on: Bool) {
        guard let task, task.isRunning else { return }
        if on { task.suspend() } else { task.resume() }
    }

    func cancel() {
        task?.terminate()
        isRunning = false
        stage = "Прервано"
    }

    // MARK: разбор вывода

    private func consume(_ line: String) {
        if line.hasPrefix("@@PROGRESS@@") {
            let json = line.dropFirst("@@PROGRESS@@".count)
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let pct = raw["pct"] as? Double { percent = pct }
            if let key = raw["stage"] as? String {
                stageKey = key
                stage = Self.stageNames[key] ?? key
            }
            detail = raw["detail"] as? String ?? ""
            return
        }
        log.append(line)
        // Хвост лога держим коротким: он нужен для диагноза, а не для архива.
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Показать пользователю то, что ядро реально сказало, а не общую фразу.
    private func showFailure() {
        stage = "Ошибка"
        let meaningful = log.filter {
            $0.contains("ОШИБКА") || $0.contains("Подсказка")
                || $0.hasPrefix("  - ") || $0.contains("не готов")
        }
        let body = meaningful.isEmpty ? log.suffix(12).joined(separator: "\n")
                                      : meaningful.joined(separator: "\n")

        let box = NSAlert()
        box.messageText = "Обработка не завершилась"
        box.informativeText = body.isEmpty ? "Ядро завершилось с ошибкой без объяснений." : body
        box.addButton(withTitle: "Понятно")
        box.addButton(withTitle: "Показать весь вывод")
        if box.runModal() == .alertSecondButtonReturn {
            showFullLog()
        }
    }

    private func showFullLog() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "slavator-log-\(Int(Date().timeIntervalSince1970)).txt")
        try? log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

}

