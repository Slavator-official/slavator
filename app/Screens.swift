import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Главная

/// «Обзор» и «Живая встреча» сведены на один экран: и то и другое — способ
/// начать работу, разводить их по вкладкам незачем.
struct MainScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var doctor: Doctor
    @Binding var picked: URL?
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    @State private var dropTargeted = false
    @State private var inputError: String?
    @State private var source = "sys"
    @State private var pulse = false
    @State private var ready = Paths.isReady
    /// Сколько человек на встрече. 0 — пусть определит сама.
    @State private var speakers = 0
    @State private var setupStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Главная").font(Kind.title(28))
                    Text("От записи встречи к стенограмме, голосам и решениям.")
                        .font(Kind.body(13)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 12)
                Pill(text: "Записи: \(library.records.count)", fg: p.muted, bg: p.raised)
            }.padding(.bottom, 10)

            if !ready {
                setupCard
            } else if let report = doctor.report, !report.ok {
                updateCard(report)
            }

            // Обе карточки одной высоты: разъехавшиеся по высоте блоки
            // сразу читаются как небрежность.
            // Высоту выравнивает сам Card(fill:): стек берёт высоту большей
            // карточки, а обе растягиваются до неё.
            HStack(spacing: 14) {
                pickCard
                liveCard
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.45)

            if let inputError {
                Label(inputError, systemImage: "exclamationmark.circle")
                    .font(Kind.body(13)).foregroundStyle(p.warn)
            }

            if pipeline.isRunning { progressCard }
            lastMeeting

            if !library.unknown.isEmpty { unknownCard }
        }
        // Установка идёт в Терминале, отдельным процессом. Возвращение в
        // приложение - самый надёжный момент, чтобы проверить, чем кончилось.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = Paths.isReady
            doctor.refresh()
        }
        .onAppear { doctor.refresh() }
        // Дозагрузка кончилась — спрашиваем ядро заново, а не верим на слово.
        .onChange(of: pipeline.isRunning) { _, running in
            if !running { doctor.refresh() }
        }
    }

    // первый запуск: окружения ещё нет
    private var setupCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19)).foregroundStyle(p.accent).frame(width: 26)
                Text(setupStarted ? "Идёт установка" : "Славатор ещё не настроен")
                    .font(Kind.strong(14.5))
                Spacer()
            }
            Text(setupStarted
                 ? "Установка идёт в окне Терминала. Когда там появится «Готово», вернитесь сюда — программа сама подхватит окружение."
                 : "Нужно один раз развернуть распознавание речи и языковую модель: около 6 ГБ загрузки и 20–40 минут. Всё останется на этом компьютере.")
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            if !setupStarted {
                Button("Установить") {
                    setupStarted = true
                    Paths.runSetup()
                }
                .buttonStyle(PrimaryButton(wide: true))
                .padding(.top, 10)
            }
        }
    }

    // окружение стоит, но чего-то не хватает
    //
    // Отдельная карточка, а не строчка в углу: без языковой модели не будет
    // резюме, без моделей разделения — голосов. Человек должен узнать об этом
    // до того, как отдаст программе часовую запись и подождёт полчаса.
    @ViewBuilder
    private func updateCard(_ report: Readiness) -> some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.system(size: 19)).foregroundStyle(p.warn).frame(width: 26)
                Text("Требуется дозагрузка").font(Kind.strong(14.5))
                Spacer()
                if let weight = report.weight {
                    Pill(text: weight, fg: p.warn, bg: p.warnBg)
                }
            }
            Text(report.listing)
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            if report.needs_setup {
                // Библиотеки ставит установщик: ему нужны интернет, компилятор
                // и права, которых у окна программы нет.
                Text("Это доставляет установщик — он пропустит то, что уже стоит.")
                    .font(Kind.body(12)).foregroundStyle(p.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Button(setupStarted ? "Установка идёт в Терминале" : "Установить") {
                    setupStarted = true
                    Paths.runSetup()
                }
                .buttonStyle(PrimaryButton(wide: true))
                .disabled(setupStarted)
                .padding(.top, 10)
            } else {
                Button(pipeline.isRunning ? "Идёт дозагрузка" : "Дозагрузить") {
                    let alert = NSAlert()
                    alert.messageText = "Разрешить загрузку моделей из интернета?"
                    alert.informativeText = "Будут загружены недостающие модели и запущена локальная Ollama. Объём может составить несколько гигабайт. Записи встреч не отправляются."
                    alert.addButton(withTitle: "Разрешить и загрузить")
                    alert.addButton(withTitle: "Отмена")
                    if alert.runModal() == .alertFirstButtonReturn { pipeline.repair(library: library) }
                }
                .buttonStyle(PrimaryButton(wide: true))
                .disabled(pipeline.isRunning || capture.isRecording)
                .padding(.top, 10)
            }
        }
    }

    // выбрать запись
    private var pickCard: some View {
        Card(fill: true) {
            if let picked {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 21)).foregroundStyle(p.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(picked.lastPathComponent)
                            .font(Kind.strong(14)).lineLimit(1).truncationMode(.middle)
                        Text(fileInfo(picked)).font(Kind.body(12)).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 8)
                    // Выбрали не тот файл - должно быть видно, как отменить.
                    // «Другой файл» открывает диалог заново и требует что-то
                    // выбрать; отказаться было нельзя.
                    Button { self.picked = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(p.faint)
                    }
                    .buttonStyle(.plain)
                    .disabled(pipeline.isRunning)
                    .help("Убрать файл")
                }
                // Кнопки прижаты к низу, как в соседней карточке: действие
                // всегда на одной высоте, а не гуляет вслед за содержимым.
                Spacer(minLength: 14)
                // Оба ряда в общем стеке с явным зазором. На отступах они
                // налезали друг на друга: у кнопок своя внутренняя высота,
                // и складывать её с padding на глаз бесполезно.
                VStack(alignment: .leading, spacing: 14) {
                    // Число участников снимает главную причину дробления
                    // голосов: без него движок гадает и выдаёт десятки «людей».
                    HStack(spacing: 10) {
                        Text("Участников").font(Kind.body(12.5)).foregroundStyle(p.muted)
                        HStack(spacing: 0) {
                            stepButton("−") { speakers = max(0, speakers - 1) }
                            Text(speakers == 0 ? "—" : String(speakers))
                                .font(Kind.mono(13)).frame(width: 30)
                            stepButton("+") { speakers = min(12, speakers + 1) }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                        Text(speakers == 0 ? "определю сама" : "разложу ровно на \(speakers)")
                            .font(Kind.body(12)).foregroundStyle(p.faint)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Button("Начать транскрибацию") {
                            pipeline.run(input: picked, library: library, speakers: speakers)
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(pipeline.isRunning || capture.isRecording)
                        Button("Другой файл") { pick() }.buttonStyle(QuietButton())
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Button(action: pick) {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(p.accent2)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangle(cornerRadius: 13).fill(p.accentSoft))
                        Text("Выбрать запись").font(Kind.head(16)).foregroundStyle(p.text)
                        Text("или перетащите аудио / видео сюда")
                            .font(Kind.body(12.5)).foregroundStyle(p.muted)
                        Text("WAV · MP3 · M4A · MP4 · другие форматы")
                            .font(Kind.body(11)).foregroundStyle(p.faint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 172)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(dropTargeted ? p.accent2 : p.line,
                          style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: picked == nil ? [5, 4] : [])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard ready, !pipeline.isRunning, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { selectFile(url) } }
            }
            return true
        }
    }

    /// Кнопка счётчика: тихая, без собственной рамки — рамка общая на группе.
    private func stepButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(Kind.strong(15)).foregroundStyle(p.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // слушать встречу
    private var liveCard: some View {
        Card(fill: true) {
            if capture.isRecording {
                HStack(spacing: 12) {
                    Circle().fill(Color.hex(0xE0705F)).frame(width: 10, height: 10)
                        .opacity(pulse ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                    Text(hms(capture.seconds))
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                    LevelMeter(level: capture.level)
                    Button("Остановить") { finishRecording() }.buttonStyle(QuietButton())
                }
                .onAppear { pulse = true }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "mic")
                        .font(.system(size: 19)).foregroundStyle(p.accent2).frame(width: 26)
                    Text("Записать встречу").font(Kind.strong(14.5))
                    Spacer()
                }
                // Как в прототипе: сначала выбор источника во всю ширину,
                // под ним — кнопка запуска. Так решение и действие разнесены
                // по строкам, а не толкаются в одной.
                Segmented(options: [("sys", "Звонок"), ("mic", "Только микрофон")],
                          selection: $source)
                    .padding(.top, 12)
                Text(source == "sys"
                     ? "Собеседников из динамиков и вас с микрофона"
                     : "Только микрофон — для встречи в одной комнате")
                    .font(Kind.body(12)).foregroundStyle(p.muted)
                    .padding(.top, 6)
                Button("Начать запись") { startRecording() }
                    .buttonStyle(PrimaryButton(wide: true))
                    .padding(.top, 8)
                    .disabled(pipeline.isRunning)
                Spacer(minLength: 10)
                Text("Расшифровка начнётся после остановки записи.")
                    .font(Kind.body(11.5)).foregroundStyle(p.faint)
                if let failure = capture.failure {
                    Text(failure).font(Kind.body(12)).foregroundStyle(p.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            }
        }
        .frame(minHeight: 220)
    }

    private func startRecording() {
        let folder = URL(fileURLWithPath: library.settings.recordingsFolder)
        capture.start(source: source == "mic" ? .microphone : .meeting, folder: folder)
    }

    /// Остановка сразу отправляет запись в обычную обработку: живой режим и
    /// файл сходятся в один пайплайн, иначе качество разъедется.
    private func finishRecording() {
        picked = finishMeeting(capture: capture, pipeline: pipeline, library: library)
    }

    /// Обработка идёт долго — час записи считается десятки минут. Без
    /// внятного прогресса это неотличимо от зависшего приложения.
    private var progressCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Обработка")
                    Text(pipeline.stage).font(Kind.head(17)).padding(.top, 2)
                    if !pipeline.detail.isEmpty {
                        Text(pipeline.detail).font(Kind.body(13)).foregroundStyle(p.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(pipeline.percent))%")
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.text)
                    if let left = pipeline.remainingText, !pipeline.isSuspended {
                        Text(left).font(Kind.body(12)).foregroundStyle(p.muted)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.raised).frame(height: 8)
                    Capsule().fill(p.accent)
                        .frame(width: max(0, geo.size.width * pipeline.percent / 100), height: 8)
                        .animation(.easeOut(duration: 0.3), value: pipeline.percent)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 8)
            .padding(.top, 14)

            HStack(spacing: 10) {
                ForEach(pipeline.stageOrder, id: \.self) { key in
                    Circle()
                        .fill(pipeline.reached(key) ? p.accent : p.line)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Button(pipeline.isCancelling ? "Останавливаю…" : "Прервать") { pipeline.cancel() }
                    .buttonStyle(QuietButton()).disabled(pipeline.isCancelling)
            }
            .padding(.top, 14)
        }
    }

    // последняя встреча с лентой
    @ViewBuilder private var lastMeeting: some View {
        if let record = library.records.first {
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Последняя встреча")
                        Text(record.title).font(Kind.head(17)).lineLimit(1)
                    }
                    Spacer()
                    Button("Все записи") { screen = .records }
                        .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
                }
                Text(meta(record)).font(Kind.body(13)).foregroundStyle(p.muted)
                    .padding(.top, 2).padding(.bottom, 16)

                Ribbon(turns: record.turns, height: 46, library: library, record: record) { turn in
                    playTurn(turn, in: record)
                }
                Ruler(length: record.length).padding(.top, 7)
                Legend(turns: record.turns, library: library, record: record)
                    .padding(.top, 14)
            }
        } else {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 26)).foregroundStyle(p.faint)
                    Text("Пока нет обработанных встреч")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                    Text("Выберите запись выше и нажмите «Начать транскрибацию»")
                        .font(Kind.body(12.5)).foregroundStyle(p.faint)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 26)
            }
        }
    }

    private var unknownCard: some View {
        Card {
            HStack {
                Text(unknownTitle).font(Kind.head(16))
                Spacer()
                Button("Открыть") { screen = .newVoices }
                    .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
            }
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(library.unknown.prefix(2)) { voice in
                    RowBox {
                        PlayDot(size: 28) {
                            player.play(url: voice.url, label: library.label(for: voice),
                                        subtitle: "неопознанный голос",
                                        colour: library.color(for: voice))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(voice.guess.map { "Похоже, это \($0)" }
                                 ?? library.label(for: voice))
                                .font(Kind.strong(14))
                            Text(voice.guess != nil ? "имя определено по разговору"
                                                    : "по имени к нему не обращались")
                                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 8)
                        Button(voice.guess != nil ? "Подтвердить" : "Выбрать человека") {
                            screen = .newVoices
                        }
                        .buttonStyle(voice.guess != nil ? AnyButtonStyle(PrimaryButton())
                                                        : AnyButtonStyle(QuietButton()))
                    }
                }
            }
        }
    }

    private var unknownTitle: String {
        let n = library.unknown.count
        let tail = n % 10, hundred = n % 100
        if hundred >= 11 && hundred <= 14 { return "\(n) голосов не узнано" }
        if tail == 1 { return "\(n) голос не узнан" }
        if tail >= 2 && tail <= 4 { return "\(n) голоса не узнаны" }
        return "\(n) голосов не узнано"
    }

    private func meta(_ record: Record) -> String {
        var parts = [humanDate(record.date)]
        if record.length > 0 { parts.append(hms(record.length)) }
        if record.speakerCount > 0 { parts.append("Участники: \(record.speakerCount)") }
        return parts.joined(separator: " · ")
    }

    private func playTurn(_ turn: Turn, in record: Record) {
        // Свои реплики лежат на отдельной дорожке — системная их не слышала.
        let wav = turn.speaker == "OWN" ? (record.ownTrack ?? record.source) : record.source
        guard let wav else {
            showAlert("Фрагмент недоступен",
                      "Исходная запись встречи не найдена рядом с результатом — возможно, её перенесли или удалили.")
            return
        }
        player.play(url: wav,
                    label: Legend.label(for: turn, in: record),
                    subtitle: "\(record.title) · \(hms(turn.start))",
                    colour: library.color(for: turn, in: record),
                    from: turn.start, to: turn.end)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url { selectFile(url) }
    }

    private func selectFile(_ url: URL) {
        guard !pipeline.isRunning else { return }
        do {
            try MediaInput.validate(url)
            picked = url
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }

    private func fileInfo(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(url.pathExtension.uppercased()) · \(formatter.string(fromByteCount: Int64(size)))"
    }
}

/// Одинаковая остановка на главной и в постоянной нижней панели.
@discardableResult
func finishMeeting(capture: LiveCapture, pipeline: Pipeline, library: Library) -> URL? {
    guard let url = capture.stop() else { return nil }
    if let warning = capture.failure { showAlert("Запись сохранена с ограничением", warning) }
    guard capture.seconds >= 3 else {
        showAlert("Слишком короткая запись", "Записано меньше трёх секунд. Аудиофайл сохранён в папке результатов.")
        return url
    }
    guard !pipeline.isRunning else {
        showAlert("Запись сохранена", "Другая встреча ещё обрабатывается. Новая запись выбрана на главной — запустите её, когда обработка завершится.")
        return url
    }
    // Дорожки сведены в один файл ещё при остановке, отдельной микрофонной
    // больше нет: второй проход распознавания по ней стоил на встрече в
    // двадцать минут лишние полчаса ожидания.
    pipeline.run(input: url, library: library)
    return url
}

func showAlert(_ title: String, _ text: String) {
    let box = NSAlert()
    box.messageText = title
    box.informativeText = text
    box.addButton(withTitle: "Понятно")
    box.runModal()
}

/// Обёртка, чтобы стиль кнопки можно было выбирать по условию.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Записи

struct RecordsScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    @Bindable var memory: SpeakerMemory
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    /// Встреча, у которой спрашиваем проект.
    @State private var asking: Record?
    @State private var query = ""
    @State private var onlyUnknown = false

    private var visibleRecords: [Record] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.records.filter { record in
            (!onlyUnknown || library.unknown.contains { $0.record == record.dir }) &&
            (needle.isEmpty || record.title.localizedStandardContains(needle) ||
             record.turns.contains { $0.name.localizedStandardContains(needle) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ScreenTitle(text: "Записи")
                Spacer()
                // Корзина — не действие экрана, а место, куда изредка
                // заглядывают. Широкая кнопка с числом стояла рядом с
                // заголовком и читалась как главное здесь; значок с меткой
                // занимает угол и не спорит со списком записей.
                Menu {
                    if memory.deleted.isEmpty { Text("Корзина пуста") }
                    ForEach(memory.deleted) { entry in
                        Button("Восстановить: \(entry.title) · \(entry.date.prefix(10))") {
                            guard !pipeline.isRunning, !memory.busy else { return }
                            memory.restoreMeeting(entry, settings: library.settings) { library.reload() }
                        }
                    }
                    Divider()
                    Button("Показать папку корзины") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: library.settings.results_dir).appending(path: ".slavator-trash"))
                    }.disabled(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: library.settings.results_dir).appending(path: ".slavator-trash").path))
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(p.muted)
                            .frame(width: 28, height: 24)
                        if !memory.deleted.isEmpty {
                            Text("\(memory.deleted.count)")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(p.accent))
                                .offset(x: 5, y: -2)
                        }
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 34)
                .disabled(memory.busy || pipeline.isRunning)
                .help(memory.deleted.isEmpty ? "Корзина Славатора пуста"
                      : "Корзина Славатора: \(memory.deleted.count)")
            }
            if memory.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(memory.progress).font(Kind.body(12)).foregroundStyle(p.muted)
                }
            }
            if let failure = memory.failure {
                Text(failure).font(Kind.body(13)).foregroundStyle(p.warn).textSelection(.enabled)
            }
            if !memory.notice.isEmpty {
                Text(memory.notice).font(Kind.body(12)).foregroundStyle(p.muted)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(p.faint)
                    TextField("Название встречи или имя участника", text: $query)
                        .textFieldStyle(.plain).font(Kind.body())
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(p.muted).help("Очистить поиск")
                    }
                }
                .padding(11).background(RoundedRectangle(cornerRadius: 9).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.line, lineWidth: 1))
                Toggle("Новые голоса", isOn: $onlyUnknown).toggleStyle(.checkbox).font(Kind.body(12))
            }
            Text("Показано: \(visibleRecords.count) из \(library.records.count)")
                .font(Kind.body(12)).foregroundStyle(p.faint)
            if visibleRecords.isEmpty {
                Card {
                    VStack(spacing: 10) {
                        Image(systemName: library.records.isEmpty ? "tray" : "magnifyingglass")
                            .font(.system(size: 28)).foregroundStyle(p.accent2)
                        Text(library.records.isEmpty ? "Здесь появятся ваши встречи" : "Ничего не найдено")
                            .font(Kind.head(16))
                        Text(library.records.isEmpty ? "Начните с аудио или видео на главном экране." : "Попробуйте другое название или отключите фильтр голосов.")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                        if library.records.isEmpty {
                            Button("Перейти на главную") { screen = .main }.buttonStyle(PrimaryButton())
                        } else {
                            Button("Сбросить поиск") { query = ""; onlyUnknown = false }.buttonStyle(QuietButton())
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 26)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visibleRecords) { record in recordCard(record) }
                }
            }
        }
        .onAppear { memory.loadCatalog(settings: library.settings) }
    }

    private func confirmDeletion(_ record: Record) {
        guard !pipeline.isRunning, !memory.busy else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить встречу «\(record.title)»?"
        alert.informativeText = "Все сохранённые версии этой встречи будут перемещены в корзину Славатора и исчезнут из записей, поиска и графа. Исходное аудио и общие голосовые профили сохранятся. Встречу можно восстановить через меню корзины на этом экране."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Переместить в корзину")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn,
              !pipeline.isRunning, !memory.busy else { return }
        player.stop()
        memory.deleteMeeting(record, settings: library.settings) { library.reload() }
    }

    /// Переименовать встречу.
    ///
    /// Имя встречи — это имя её папки: так его видит и список записей, и
    /// память. Поэтому переименование трогает папку, а не запись в базе —
    /// иначе имя разъехалось бы между экраном и поиском.
    ///
    /// Прошлые версии переезжают вместе с текущей: они узнаются по общему
    /// началу имени, и оставленная позади копия «Старое имя_20260909_111354»
    /// висела бы в списке отдельной встречей.
    ///
    /// Исходную запись не трогаем: на неё ссылается стенограмма, по ней
    /// работает проигрыватель, и переносить файл ради названия папки — цена
    /// выше пользы.
    private func renameMeeting(_ record: Record) {
        guard !pipeline.isRunning, !memory.busy else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = record.title
        let alert = NSAlert()
        alert.messageText = "Новое название встречи"
        alert.informativeText = "Так она будет называться в записях, поиске и на графе. Файлы внутри папки останутся прежними."
        alert.accessoryView = field
        alert.addButton(withTitle: "Переименовать")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != record.title else { return }
        guard !title.isEmpty, !title.hasPrefix("."),
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            showAlert("Так назвать нельзя",
                      "Название не должно быть пустым, начинаться с точки или содержать «/» и «:».")
            return
        }

        let root = record.dir.deletingLastPathComponent()
        let files = FileManager.default
        // Текущая версия — «Имя_result», прошлые — «Имя_20260909_111354_result».
        let family = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { folder in
                let name = folder.lastPathComponent
                guard name.hasSuffix("_result") else { return false }
                let base = String(name.dropLast("_result".count))
                return base == record.title
                    || (base.hasPrefix(record.title + "_")
                        && String(base.dropFirst(record.title.count + 1))
                            .range(of: #"^\d{8}_\d{6}$"#, options: .regularExpression) != nil)
            } ?? []
        guard !family.isEmpty else { return }

        var moves: [(URL, URL)] = []
        for folder in family {
            let tail = folder.lastPathComponent.dropFirst(record.title.count)
            let target = root.appending(path: title + tail)
            if files.fileExists(atPath: target.path) {
                showAlert("Такая встреча уже есть",
                          "В папке результатов уже лежит «\(target.lastPathComponent)». Выберите другое название.")
                return
            }
            moves.append((folder, target))
        }

        player.stop()
        var done: [(URL, URL)] = []
        do {
            for (from, to) in moves {
                try files.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            // Переименование на полпути хуже, чем несделанное: возвращаем как было.
            for (from, to) in done.reversed() { try? files.moveItem(at: to, to: from) }
            showAlert("Не удалось переименовать", error.localizedDescription)
            return
        }
        for (_, folder) in done { retitle(folder, to: title) }
        library.reload()
        memory.invalidate(settings: library.settings)
    }

    /// Стенограмма хранит своё название отдельно от папки, и память берёт его
    /// оттуда. Не поправив, получим одну встречу под двумя именами.
    private func retitle(_ folder: URL, to title: String) {
        for path in [folder.appending(path: "transcript.json"),
                     folder.appending(path: Paths.extraDir).appending(path: "transcript.json")] {
            guard let data = try? Data(contentsOf: path),
                  var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            raw["source"] = title
            guard let out = try? JSONSerialization.data(withJSONObject: raw,
                                                        options: [.prettyPrinted, .withoutEscapingSlashes])
            else { continue }
            try? out.write(to: path, options: .atomic)
        }
    }

    private func recordCard(_ record: Record) -> some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title).font(Kind.head(16)).lineLimit(2).textSelection(.enabled)
                    Text("\(humanDate(record.date)) · \(hms(record.length)) · Участники: \(record.speakerCount)")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
                statusPill(for: record)
            }
            if !record.turns.isEmpty {
                Ribbon(turns: record.turns, height: 18, library: library, record: record)
                    .padding(.vertical, 16)
            }
            HStack(spacing: 18) {
                Button {
                    player.playMeeting(record, colour: p.accent2)
                } label: {
                    Label(player.recordingID == record.dir && player.isPlaying ? "Пауза" : "Слушать запись",
                          systemImage: player.recordingID == record.dir && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(Kind.strong(12))
                }.buttonStyle(.plain).foregroundStyle(p.accent2)
                    .disabled((record.source ?? record.ownTrack) == nil ||
                              (player.recordingID == record.dir && player.isPreparing))
                    .help((record.source ?? record.ownTrack) == nil
                          ? "Исходное аудио не найдено: возможно, файл перенесли или удалили."
                          : "Вся запись: перемотка и скорость доступны в панели снизу.")
                Label("Стенограмма", systemImage: "doc.text").font(Kind.body(12)).foregroundStyle(p.muted)
                fileButton(record.transcript, hint: "Открыть стенограмму")
                Divider().frame(height: 14)
                Text("Резюме").font(Kind.body(12)).foregroundStyle(p.muted)
                summaryButton(for: record)
                Spacer()
                Button { renameMeeting(record) } label: {
                    Label("Переименовать", systemImage: "pencil").font(Kind.body(12))
                }.buttonStyle(.plain).foregroundStyle(p.muted)
                    .disabled(pipeline.isRunning || memory.busy)
                    .help("Сменить название встречи вместе с её прошлыми версиями")
                Button { NSWorkspace.shared.open(record.dir) } label: {
                    Label("Папка", systemImage: "folder").font(Kind.body(12))
                }.buttonStyle(.plain).foregroundStyle(p.muted).help("Показать файлы встречи")
                Button { confirmDeletion(record) } label: {
                    Label("Удалить", systemImage: "trash").font(Kind.body(12))
                }.buttonStyle(.plain).foregroundStyle(p.warn)
                    .disabled(pipeline.isRunning || memory.busy)
                    .help("Переместить встречу и её прошлые версии в корзину Славатора")
            }.padding(.top, record.turns.isEmpty ? 14 : 0)
        }
        .sheet(item: $asking) { record in
            ProjectSheet(record: record, library: library, pipeline: pipeline)
        }
    }
}

/// Разговор о том, к какому проекту отнести встречу.
///
/// Спрашиваем здесь, а не окном сразу после обработки: разбор заканчивается
/// когда придётся, и перебивать человека вопросом о папке — плохая цена за
/// аккуратность. Встреча ждёт в списке столько, сколько нужно.
private struct ProjectSheet: View {
    let record: Record
    @Bindable var library: Library
    var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var answers = ""
    @State private var chosen = ""

    private var card: MeetingCard { record.meeting ?? MeetingCard() }
    private var known: [String] { Library.projectNames() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("К какому проекту отнести встречу").font(Kind.head(16))
            Text(record.title).font(Kind.body(13)).foregroundStyle(p.muted)

            if !card.project.isEmpty {
                Card {
                    Text("Ядро предполагает: «\(card.project)»").font(Kind.strong(13.5))
                    if !card.why.isEmpty {
                        Text(card.why).font(Kind.body(12.5)).foregroundStyle(p.muted)
                            .padding(.top, 4)
                    }
                }
            }

            if !card.questions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Вопросы к вам").font(Kind.eyebrow()).foregroundStyle(p.faint)
                    ForEach(card.questions, id: \.self) { question in
                        Text("— \(question)").font(Kind.body(13))
                    }
                }
                TextEditor(text: $answers)
                    .font(Kind.body(13)).frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                Button("Ответить и переспросить") {
                    pipeline.clarify(record: record, answers: answers, library: library)
                    dismiss()
                }
                .buttonStyle(QuietButton(wide: true))
                .disabled(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider().overlay(p.line2)

            Text("Или выберите сами").font(Kind.eyebrow()).foregroundStyle(p.faint)
            HStack(spacing: 10) {
                Picker("", selection: $chosen) {
                    Text("не выбран").tag("")
                    ForEach(known, id: \.self) { Text($0).tag($0) }
                    // Предложение модели можно принять одним нажатием — оно
                    // и есть самый вероятный ответ.
                    if !card.project.isEmpty, !known.contains(card.project) {
                        Divider()
                        Text("Добавить «\(card.project)»").tag(card.project)
                    }
                }
                .labelsHidden().frame(width: 260)

                Button("Сохранить") {
                    pipeline.assign(record: record, project: chosen,
                                    remember: !known.contains(chosen), library: library)
                    dismiss()
                }
                .buttonStyle(PrimaryButton())
                .disabled(chosen.isEmpty)
            }

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton())
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(p.surface)
    }
}

// MARK: - Спикеры

extension RecordsScreen {
    /// Кнопка открытия документа встречи. Пока обработка не дошла до этого
    /// шага, файла нет — и честнее показать это, чем неработающую кнопку.
    @ViewBuilder func fileButton(_ url: URL?, hint: String) -> some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 12))
                    Text("Открыть").font(Kind.body(12.5))
                }
                .foregroundStyle(library.palette.accent2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hint)
        } else {
            Text("нет").font(Kind.body(12.5)).foregroundStyle(library.palette.faint)
        }
    }

    /// Резюме собирается отдельно, по запросу: это самый долгий шаг и
    /// единственный, которому нужна языковая модель. Пока его не просили,
    /// в колонке стоит кнопка, а не прочерк.
    @ViewBuilder func summaryButton(for record: Record) -> some View {
        if record.summary != nil {
            fileButton(record.summary, hint: "Открыть резюме встречи")
        } else if pipeline.isRunning {
            Text("занято").font(Kind.body(12.5)).foregroundStyle(library.palette.faint)
        } else {
            Button { pipeline.summarize(record: record, library: library) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 12))
                    Text("Собрать").font(Kind.body(12.5))
                }
                .foregroundStyle(library.palette.accent2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Собрать резюме, решения и поручения по этой встрече")
        }
    }

    /// Статус встречи: важно не «готово», а есть ли неразобранные голоса.
    @ViewBuilder func statusPill(for record: Record) -> some View {
        let unknown = library.unknown.filter { $0.record == record.dir }.count
        let card = record.meeting
        if let card, card.needs_review {
            // Не «ошибка», а незаконченное дело: нажатие открывает вопросы.
            Button { asking = record } label: {
                Pill(text: "уточнить проект",
                     fg: library.palette.warn, bg: library.palette.warnBg)
            }
            .buttonStyle(.plain)
            .help("Ядро не смогло определить проект — спросите его или выберите руками")
        } else if unknown > 0 {
            Pill(text: unknown == 1 ? "1 новый голос" : "\(unknown) новых голоса",
                 fg: library.palette.warn, bg: library.palette.warnBg)
        } else if let card, !card.project.isEmpty {
            Pill(text: card.project, fg: library.palette.ok, bg: library.palette.okBg)
        } else {
            Pill(text: "Готово", fg: library.palette.ok, bg: library.palette.okBg)
        }
    }
}

struct SpeakerProfilesScreen: View {
    @Bindable var library: Library
    var player: Player
    @Binding var screen: Screen
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(text: "Спикеры")
            Card {
                HStack {
                    Text("Все люди").font(Kind.head(16))
                    Spacer()
                    if !library.unknown.isEmpty {
                        Button("Новые голоса · \(library.unknown.count)") { screen = .newVoices }
                            .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
                    }
                }
                .padding(.bottom, 14)

                if library.speakers.isEmpty {
                    Text("Пока никого нет. Люди появятся, когда вы назовёте голоса со встреч.")
                        .font(Kind.body(13.5)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    VStack(spacing: 8) {
                        ForEach(library.speakers) { person in
                            RowBox {
                                PlayDot(size: 28) { playSample(person) }
                                Avatar(text: person.initials, colour: library.color(for: person))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).font(Kind.strong(14.5))
                                    if !person.subtitle.isEmpty {
                                        Text(person.subtitle).font(Kind.body(12.5))
                                            .foregroundStyle(p.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("\(person.samples)").font(Kind.mono(13)).foregroundStyle(p.text)
                                    Text("образцов").font(Kind.body(11)).foregroundStyle(p.muted)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { screen = .person(person.key) }
                        }
                    }
                }
            }
        }
    }

    private func playSample(_ person: Speaker) {
        let folder = Paths.profiles.appending(path: "samples/\(person.key)")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        guard let first = items.first(where: { $0.pathExtension.lowercased() == "wav" }) else {
            showAlert("Нет образцов", "Для этого человека пока нет записей голоса.")
            return
        }
        player.play(url: first, label: person.name, subtitle: person.subtitle,
                    colour: library.color(for: person))
    }
}

// MARK: - Новые голоса

struct NewVoicesScreen: View {
    @Bindable var library: Library
    var player: Player
    @Environment(\.palette) private var p
    @State private var selected: Set<URL> = []
    @State private var enrolling = false

    private var dismissed: [UnknownVoice] { library.dismissed }
    @State private var split = VoiceSplit()

    /// Встречи с неразобранными голосами, свежие сверху.
    private var meetings: [URL] {
        var seen: [URL] = []
        for record in library.records where library.unknown.contains(where: { $0.record == record.dir }) {
            seen.append(record.dir)
        }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(text: "Новые голоса")
                Spacer()
                // Отложенные голоса не исчезают навсегда: имя может
                // вспомниться через неделю, а голос к тому времени должен
                // где-то лежать.
                Menu {
                    if dismissed.isEmpty { Text("Здесь пусто") }
                    ForEach(dismissed) { voice in
                        Button("Вернуть: \(library.label(for: voice)) · \(voice.record.lastPathComponent.replacingOccurrences(of: "_result", with: ""))") {
                            library.restoreUnknown(voice)
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.fill.xmark")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(p.muted)
                            .frame(width: 28, height: 24)
                        if !dismissed.isEmpty {
                            Text("\(dismissed.count)")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(p.accent))
                                .offset(x: 7, y: -2)
                        }
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 36)
                .help(dismissed.isEmpty ? "Отложенных голосов нет"
                      : "Отложено голосов: \(dismissed.count)")
            }

            if library.unknown.isEmpty {
                Card {
                    Text(dismissed.isEmpty ? "Все голоса определены"
                         : "Все голоса разобраны. Отложенные лежат под значком справа сверху.")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 26)
                }
            } else {
                if let failure = split.failure {
                    Text(failure).font(Kind.body(12)).foregroundStyle(p.warn)
                        .textSelection(.enabled).padding(.bottom, 10)
                }
                // Голоса разложены по встречам: SPEAKER_02 из разных встреч —
                // разные люди, и в общей куче их легко было отметить вместе
                // как одного.
                ForEach(meetings, id: \.self) { record in
                    Card {
                        Text(record.lastPathComponent.replacingOccurrences(of: "_result", with: ""))
                            .font(Kind.head(15))
                        Text("Один человек часто распадается на несколько голосов — отметьте их вместе. Голоса из разных встреч объединяйте, только если это точно один человек.")
                            .font(Kind.body(12.5)).foregroundStyle(p.muted)
                            .padding(.top, 3).padding(.bottom, 14)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                                  spacing: 12) {
                            ForEach(library.unknown.filter { $0.record == record }) { voice in
                                VoiceCard(voice: voice, library: library, player: player,
                                          selected: selected.contains(voice.url),
                                          busy: split.isRunning) {
                                    if selected.contains(voice.url) { selected.remove(voice.url) }
                                    else { selected.insert(voice.url) }
                                } assign: {
                                    selected = [voice.url]
                                    enrolling = true
                                } dismiss: {
                                    selected.remove(voice.url)
                                    library.dismissUnknown(voice)
                                } split: { count in
                                    selected.remove(voice.url)
                                    split.split(voice: voice, into: count, library: library) { }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }

                if !selected.isEmpty {
                    HStack(spacing: 12) {
                        Text(selectionTitle).font(Kind.strong(14))
                        Spacer()
                        Button("Снять выбор") { selected.removeAll() }
                            .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.muted)
                        Button(selected.count == 1 ? "Это человек…" : "Это один человек…") {
                            enrolling = true
                        }
                        .buttonStyle(PrimaryButton())
                    }
                    .padding(14)
                    .background(p.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .padding(.top, 12)
                }
            }
        }
        .sheet(isPresented: $enrolling) {
            EnrollSheet(library: library, samples: Array(selected)) {
                selected.removeAll()
            }
        }
    }

    private var selectionTitle: String {
        let n = selected.count
        let tail = n % 10, hundred = n % 100
        if hundred >= 11 && hundred <= 14 { return "Выбрано \(n) голосов" }
        if tail == 1 { return "Выбран \(n) голос" }
        if tail >= 2 && tail <= 4 { return "Выбрано \(n) голоса" }
        return "Выбрано \(n) голосов"
    }
}

private struct VoiceCard: View {
    @Environment(\.palette) private var p
    let voice: UnknownVoice
    var library: Library
    var player: Player
    var selected: Bool = false
    var busy = false
    var toggle: () -> Void = {}
    var assign: () -> Void = {}
    var dismiss: (() -> Void)? = nil
    var split: ((Int) -> Void)? = nil

    /// Реплики встречи, из которой взят голос.
    private var turns: [Turn] {
        library.records.first { $0.dir == voice.record }?.turns ?? []
    }

    /// Свои отрезки в цвете, чужие — приглушённой заливкой: сразу видно,
    /// в каких местах встречи звучит именно этот голос.
    private var highlighted: [Turn] {
        let mine = voice.label
        return turns.map {
            $0.speaker == mine ? $0
                : Turn(start: $0.start, end: $0.end, speaker: "", name: "")
        }
    }

    var body: some View {
        Card(padding: 15) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selected ? p.accent : p.faint)
                }
                .buttonStyle(.plain)
                PlayDot { player.play(url: voice.url, label: library.label(for: voice),
                                      subtitle: "неопознанный голос",
                                      colour: library.color(for: voice)) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(library.color(for: voice)).frame(width: 9, height: 9)
                        Text(library.label(for: voice)).font(Kind.strong(14))
                    }
                    Text(voice.record.lastPathComponent
                        .replacingOccurrences(of: "_result", with: ""))
                        .font(Kind.body(12.5)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            if !turns.isEmpty {
                Eyebrow(text: "Где звучит на встрече").padding(.bottom, 6)
                Ribbon(turns: highlighted, height: 26, library: library,
                       record: library.records.first { $0.dir == voice.record })
                    .padding(.bottom, 12)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: voice.guess != nil ? "sparkles" : "questionmark.circle")
                    .font(.system(size: 13)).foregroundStyle(voice.guess != nil ? p.accent2 : p.warn)
                Text(voice.guess.map { "Похоже, это \($0) — определено по разговору" }
                     ?? "По разговору имя определить не удалось: по имени к нему не обращались.")
                    .font(Kind.body(13)).foregroundStyle(p.text)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(voice.guess != nil ? p.accentSoft : p.warnBg))
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Button(voice.guess.map { "Это \($0)" } ?? "Выбрать человека") { assign() }
                    .buttonStyle(PrimaryButton())
                if let split {
                    // Сколько человек — говорит человек, а не подбор: подбор
                    // на реальной записи перескакивает нужное число, ради
                    // этого кнопка и нужна.
                    Menu {
                        ForEach(2...6, id: \.self) { count in
                            Button("Разделить на \(count) " + (count < 5 ? "человека" : "человек")) {
                                split(count)
                            }
                        }
                    } label: {
                        Label("Здесь несколько человек", systemImage: "person.2")
                            .font(Kind.body(12))
                    }
                    // Ширина задана числом: fixedSize() тянет за собой
                    // _FixedSizeLayout из SwiftUICore, которого в macOS 14 нет,
                    // и сборка такой бинарник не пропускает.
                    .menuStyle(.borderlessButton).frame(width: 205)
                    .foregroundStyle(p.accent2).disabled(busy)
                    .help("Разложить реплики этого голоса по нескольким людям и заново нарезать образцы")
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                if let dismiss {
                    Button(action: dismiss) {
                        Label("Не определяется", systemImage: "person.fill.xmark")
                            .font(Kind.body(12))
                    }
                    .buttonStyle(.plain).foregroundStyle(p.muted).disabled(busy)
                    .help("Убрать из списка: имя вспомнить не удалось. Голос останется на диске, его можно вернуть.")
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(selected ? p.accent : .clear, lineWidth: 2))
    }
}

// MARK: - Карточка человека

struct PersonScreen: View {
    @Bindable var library: Library
    var player: Player
    let key: String
    @Binding var screen: Screen
    var memory: SpeakerMemory
    @Environment(\.palette) private var p

    private var person: Speaker? { library.speakers.first { $0.key == key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackButton(title: "Спикеры") { screen = .speakers }
            if let person {
                HStack(spacing: 14) {
                    Avatar(text: person.initials, colour: library.color(for: person), size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(Kind.title(20))
                        if !person.subtitle.isEmpty {
                            Text(person.subtitle).font(Kind.body(13.5)).foregroundStyle(p.muted)
                        }
                    }
                    Spacer()
                }
                Card {
                    Text("Память о человеке").font(Kind.head(16)).padding(.bottom, 8)
                    if let info = memory.overview.people.first(where: { $0.id == "profile:" + key }) {
                        Text("\(info.meetings) встреч · \(info.quotes) фрагментов · последняя обработка \(info.last_seen.prefix(10))")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                    } else {
                        Text("История появится, когда голос будет связан с репликами сохранённых встреч.")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                    }
                    Button("Открыть высказывания и поиск") {
                        memory.person = "profile:" + key; memory.query = ""; memory.meeting = ""
                        memory.tab = "search"; screen = .memory
                        memory.search(settings: library.settings)
                    }.buttonStyle(PrimaryButton()).disabled(memory.busy).padding(.top, 12)
                }
                Card {
                    Text("Образцы голоса").font(Kind.head(16)).padding(.bottom, 14)
                    let samples = sampleFiles(person)
                    if samples.isEmpty {
                        Text("Образцов пока нет").font(Kind.body(13.5)).foregroundStyle(p.muted)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(samples, id: \.self) { url in
                                RowBox {
                                    PlayDot(size: 28) {
                                        player.play(url: url, label: person.name,
                                                    subtitle: "образец голоса",
                                                    colour: library.color(for: person))
                                    }
                                    Text(url.lastPathComponent).font(Kind.body(13))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Человек не найден").font(Kind.body()).foregroundStyle(p.muted)
            }
        }
        // Память живёт на своём экране, и раньше её считывал он же. Карточка
        // человека без этого встречала пустым «история появится»: посчитано
        // всё, но только для того, кто по дороге заглянул в «Память встреч».
        .onAppear { memory.activate(settings: library.settings) }
    }

    private func sampleFiles(_ person: Speaker) -> [URL] {
        let folder = Paths.profiles.appending(path: "samples/\(person.key)")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "wav" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

// MARK: - Настройки

struct SettingsScreen: View {
    @Bindable var library: Library
    var dictation: Dictation
    @Environment(\.palette) private var p
    /// Список моделей раскрыт. Не сохраняется: это не настройка, а состояние
    /// разговора — вернулся в настройки, значит пришёл за другим.
    @State private var modelExtras = false

    private var threshold: Double { library.settings.voice_threshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: "Настройки")

            dictationCard

            Card {
                Text("О себе").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Ваше имя",
                           subtitle: "Так подписываются ваши реплики при записи звонка") {
                    TextField("Вы", text: Binding(
                        get: { library.settings.my_name },
                        set: { library.settings.my_name = $0; library.settings.save() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Должность") {
                    TextField("", text: Binding(
                        get: { library.settings.my_position },
                        set: { library.settings.my_position = $0; library.saveMyCard() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Компания") {
                    TextField("", text: Binding(
                        get: { library.settings.my_company },
                        set: { library.settings.my_company = $0; library.saveMyCard() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if library.mySpeaker != nil {
                    Text("То же самое стоит в вашей карточке в «Спикерах».")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }

            Card {
                Text("Распознавание речи").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Что важнее",
                           subtitle: library.settings.asr_model == "large-v3-turbo"
                               ? "Быстрее: примерно столько же, сколько длится запись. Хуже с именами, терминами и латиницей"
                               : "Точнее: считает примерно вдвое дольше самой записи") {
                    Segmented(options: [("large-v3", "Точнее"), ("large-v3-turbo", "Быстрее")],
                              selection: Binding(
                                get: { library.settings.asr_model },
                                set: { library.settings.asr_model = $0; library.settings.save() }))
                        .frame(width: 200)
                }
                if library.settings.asr_model == "large-v3-turbo" {
                    Text("При первом запуске быстрая модель скачается — около 1,5 ГБ.")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                Divider().overlay(p.line2)
                // Двух ступеней хватает на каждый день, но на слабой машине
                // большая модель не поедет вовсе — для таких случаев список.
                // Обе настройки пишут в одно поле: разными они разъехались бы.
                //
                // Список убран под кнопку: на виду он спорит с переключателем
                // за один и тот же выбор, и с двух шагов легко съехать на
                // слабую модель, не поняв, что это была она.
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { modelExtras.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Доп. настройки модели").font(Kind.body(14))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(modelExtras ? 90 : 0))
                        Spacer()
                    }
                    .foregroundStyle(p.accent2)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if modelExtras {
                    SettingRow(title: "Другая модель",
                               subtitle: "Для 8 ГБ памяти: small, CPU / int8. Без видеокарты NVIDIA") {
                        Menu(library.settings.asr_model) {
                            ForEach(["base", "small", "large-v3-turbo", "large-v3"], id: \.self) { model in
                                Button(model == "small" ? "small · для 8 ГБ" : model) {
                                    library.settings.asr_model = model; library.settings.save()
                                }
                            }
                        }.frame(width: 220)
                    }
                    Text("Модель должна быть заранее установлена. Старые расшифровки не меняются; выбор применяется к следующей встрече. Для GigaAM настройка Whisper не используется.")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().overlay(p.line2)
                    // Единственно верного порога нет: у одного человека
                    // близость голоса лежит в 0,83–0,98, у разных доходит до
                    // 0,91 — зоны перекрываются, и где резать, зависит от
                    // микрофона и от того, что дороже: лишний вопрос или
                    // склеенные люди.
                    SettingRow(title: "Порог узнавания голоса",
                               subtitle: threshold == 0.90 ? "Измеренное значение — 0,90"
                                   : (threshold < 0.90 ? "Ниже измеренного: узнаёт чаще, но склеит похожих"
                                                       : "Выше измеренного: спросит лишний раз, но не перепутает")) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(
                                get: { threshold },
                                set: { library.settings.voice_threshold = (($0 * 100).rounded()) / 100
                                       library.settings.save() }),
                                in: 0.70...0.98, step: 0.01)
                                .frame(width: 170)
                            Text(String(format: "%.2f", threshold))
                                .font(Kind.mono(13)).frame(width: 38, alignment: .trailing)
                        }
                    }
                    Divider().overlay(p.line2)
                    // Языковая модель тоже «доп. настройка»: её меняют раз в
                    // жизни, а стояла она в «Оформлении» — там её никто не
                    // ищет, и рядом с темой она читалась как оформление.
                    SettingRow(title: "Модель для резюме и чата",
                               subtitle: "Имя уже установленной модели Ollama") {
                        TextField("qwen3:8b", text: Binding(
                            get: { library.settings.llm_model },
                            set: { library.settings.llm_model = $0; library.settings.save() }))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
            }

            Card {
                Text("Оформление").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Тема") {
                    Segmented(options: [("dark", "Тёмная"), ("light", "Светлая"), ("system", "Авто")],
                              selection: Binding(
                                get: { library.settings.theme },
                                set: { library.settings.theme = $0; library.settings.save(); library.reload() }))
                        .frame(width: 260)
                }
            }

            Card {
                Text("Быстрый доступ").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Значок в строке меню",
                           subtitle: "Начать запись, не открывая окно") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.menubar_enabled },
                        set: { library.settings.menubar_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Виджет на рабочем столе",
                           subtitle: "Кнопка записи поверх обоев, под окнами — как системные виджеты") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.widget_enabled },
                        set: { library.settings.widget_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if library.settings.widget_enabled {
                    Divider().overlay(p.line2)
                    SettingRow(title: "Размер виджета") {
                        // «Значок», а не «маленький»: это не уменьшенная копия
                        // остальных, а другой вид — одна кнопка без подписей.
                        Segmented(options: [("small", "Значок"), ("medium", "Средний"),
                                            ("large", "Большой")],
                                  selection: Binding(
                                    get: { library.settings.widget_size },
                                    set: { library.settings.widget_size = $0; library.settings.save() }))
                            .frame(width: 280)
                    }
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Предлагать запись, когда начинается встреча",
                           subtitle: "Славатор заметит, что микрофон занят звонком, и спросит одним уведомлением") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.meeting_watch_enabled },
                        set: { library.settings.meeting_watch_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Card {
                Text("Хранение данных").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Папка для результатов", subtitle: library.settings.results_dir) {
                    Button("Изменить") { chooseFolder() }.buttonStyle(QuietButton())
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Папка для записей",
                           subtitle: library.settings.recordings_dir.isEmpty
                               ? "Там же, где результаты: \(library.settings.results_dir)"
                               : library.settings.recordings_dir) {
                    HStack(spacing: 8) {
                        if !library.settings.recordings_dir.isEmpty {
                            Button("Сбросить") {
                                library.settings.recordings_dir = ""
                                library.settings.save()
                            }.buttonStyle(QuietButton())
                        }
                        Button("Изменить") { chooseRecordingsFolder() }.buttonStyle(QuietButton())
                    }
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Автоопределение проекта и группировка",
                           subtitle: "После резюме встреча относится к проекту и ложится в его папку. Нужна Ollama") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.project_grouping },
                        set: { library.settings.project_grouping = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Список проектов",
                           subtitle: "\(projectCount) проектов. Название и то, как его называют в речи") {
                    Button("Открыть") { openProjects() }.buttonStyle(QuietButton())
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Хранить диагностические данные",
                           subtitle: "Сохранять рабочий WAV для диагностики; занимает дополнительное место") {
                    Toggle("Хранить диагностические данные", isOn: Binding(
                        get: { library.settings.keep_diagnostics },
                        set: { library.settings.keep_diagnostics = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Card {
                Text("Термины команды").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Словарь", subtitle: "Терминов: \(glossaryCount)") {
                    Button("Открыть") { NSWorkspace.shared.open(Paths.glossary) }
                        .buttonStyle(QuietButton())
                }
            }
        }
    }

    /// Сколько проектов в списке. Считаем по файлу: его правят руками, и
    /// показывать надо то, что там сейчас, а не то, что мы помним.
    private var projectCount: Int {
        guard let data = try? Data(contentsOf: Paths.projects),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = raw["projects"] as? [Any] else { return 0 }
        return items.count
    }

    private func openProjects() {
        if !FileManager.default.fileExists(atPath: Paths.projects.path) {
            // Пустой список с примером: пустой файл человек закроет, не поняв,
            // что от него хотят.
            let sample = """
            {
              "projects": [
                {"name": "Название проекта", "aliases": ["как его зовут в речи"]}
              ]
            }
            """
            try? FileManager.default.createDirectory(
                at: Paths.projects.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? sample.write(to: Paths.projects, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.projects)
    }

    private var glossaryCount: Int {
        guard let text = try? String(contentsOf: Paths.glossary, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                   && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.results_dir = url.path
            library.settings.save()
            library.reload()
        }
    }

    /// Куда складывать сами записи встреч.
    ///
    /// Отдельно от результатов: запись — это исходник на десятки мегабайт, и
    /// держать его хочется не там, где лежат стенограммы, а иногда и не на
    /// системном диске.
    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.recordings_dir = url.path
            library.settings.save()
        }
    }
}

extension SettingsScreen {
    var dictationCard: some View {
        Card {
            HStack(spacing: 10) {
                Text("Диктовка").font(Kind.head(16))
                Spacer()
                // Когда не хватает доступа, надпись — кнопка: искать нужный
                // раздел в Системных настройках человек не обязан.
                if case .needsAccess = dictation.state {
                    Button(dictationState) { openAccessibility() }
                        .buttonStyle(.plain)
                        .font(Kind.body(12.5)).foregroundStyle(dictationColour)
                        .underline()
                } else {
                    Text(dictationState).font(Kind.body(12.5)).foregroundStyle(dictationColour)
                }
            }
            .padding(.bottom, 12)

            SettingRow(title: "Диктовать в любое поле",
                       subtitle: "Держите \(hotkeyLabel) и говорите — текст появится там, где курсор") {
                Toggle("Диктовать в любое поле", isOn: Binding(
                    get: { library.settings.dictation_enabled },
                    set: { value in
                        library.settings.dictation_enabled = value
                        library.settings.save()
                        if value { dictation.requestAccess() }
                        dictation.refresh(settings: library.settings)
                    }))
                    .labelsHidden()
            }
            SettingRow(title: "Клавиша диктовки",
                       subtitle: "Нажмите и подержите своё сочетание: ⌘, ⌥, ⌃, ⇧, fn или несколько сразу") {
                HotkeyField(combo: Binding(
                    get: { library.settings.dictation_hotkey },
                    set: { chosen in
                        library.settings.dictation_hotkey = chosen
                        library.settings.save()
                        dictation.refresh(settings: library.settings)
                    }))
            }
            SettingRow(title: "Клавиша обработки",
                       subtitle: "Диктовка сразу с обработкой. Обычно это клавиша диктовки плюс ⇧") {
                HotkeyField(combo: Binding(
                    get: { library.settings.dictation_tidy_hotkey },
                    set: { chosen in
                        library.settings.dictation_tidy_hotkey = chosen
                        library.settings.save()
                        dictation.refresh(settings: library.settings)
                    }))
            }
            SettingRow(title: "Модель",
                       subtitle: "«Быстро» пишет на ходу, «точно» вставляет целиком через 3 секунды") {
                Segmented(options: [("small", "Быстро"), ("large-v3-turbo", "Точно")],
                          selection: Binding(
                            get: { library.settings.dictation_model },
                            set: { library.settings.dictation_model = $0; library.settings.save() }))
                    .frame(width: 210)
            }
            SettingRow(title: "Что делает обработка",
                       subtitle: library.settings.dictation_tidy_hotkey == library.settings.dictation_hotkey
                           ? "Сочетания совпали — обработка забирает и обычную диктовку"
                           : "Убрать «ну» и «вот», согласовать окончания, сократить лишнее. Нужна Ollama") {
                Segmented(options: [("clean", "Чистка"), ("structure", "Структура"), ("shrink", "Сжатие")],
                          selection: Binding(
                            get: { library.settings.dictation_level },
                            set: { library.settings.dictation_level = $0; library.settings.save() }))
                    .frame(width: 280)
            }
        }
    }

    private var hotkeyLabel: String { HotCombo.label(library.settings.dictation_hotkey) }

    private func openAccessibility() {
        dictation.requestAccess()
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    private var dictationState: String {
        switch dictation.state {
        case .off:           return "выключена"
        case .needsAccess:   return "нужен доступ к вводу"
        case .starting:      return "готовится…"
        case .idle:          return "готова"
        case .listening:     return "слушаю"
        case .finishing:     return "дописываю"
        case .failed(let m): return m
        }
    }

    private var dictationColour: Color {
        switch dictation.state {
        case .idle, .listening, .finishing: return p.ok
        case .needsAccess, .failed:         return p.warn
        default:                            return p.muted
        }
    }
}

/// Ловушка модификаторов: обычный NSView, которому система сама шлёт
/// flagsChanged, когда он первый откликающийся.
///
/// Прямая доставка надёжнее слежки за чужими событиями: NSEvent-монитор
/// молчал, и понять почему со стороны было нельзя. Монитор оставлен рядом
/// вторым путём — лишним он не будет, повторы отсекаются множеством.
private final class KeyCatcher: NSView {
    var onFlags: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func flagsChanged(with event: NSEvent) { onFlags?(event.keyCode, event.modifierFlags) }
}

/// Назначение сочетания: нажали кнопку, подержали клавиши, отпустили.
///
/// Ловим отпускание, а не нажатие: пока клавиши держат, человек ещё набирает
/// сочетание, и «⌘» стало бы ответом раньше, чем он дошёл до «⌘⌥». Пока он
/// держит, набранное показывается прямо на кнопке — видно, что нажатие
/// дошло.
private struct HotkeyField: View {
    @Binding var combo: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var catcher: KeyCatcher?
    @State private var previousResponder: NSResponder?
    @State private var pressed: Set<UInt16> = []

    var body: some View {
        Button(caption) {
            if recording { finish(save: false) } else { begin() }
        }
        // Ширина и правый край — как у соседних переключателей: строки
        // настроек должны стоять по одной линии, иначе список выглядит
        // собранным на скорую руку.
        .buttonStyle(QuietButton(wide: true))
        .frame(width: 210)
        .onDisappear { finish(save: false) }
    }

    private var caption: String {
        guard recording else { return HotCombo.label(combo) }
        let now = HotCombo.tokens(fromKeyCodes: pressed)
        return now.isEmpty ? "Держите клавиши" : HotCombo.label(now)
    }

    private func take(code: UInt16, mods: NSEvent.ModifierFlags) {
        Dictation.logHotkey("код \(code), модификаторы \(mods.rawValue)")
        // Код клавиши в flagsChanged называет саму клавишу — по нему видна и
        // сторона. Через CGEvent это делать нельзя: у NSEvent его может не
        // оказаться вовсе, и запись молча ничего не ловила.
        if !mods.intersection([.command, .option, .control, .shift, .function]).isEmpty {
            pressed.insert(code)
        } else if !pressed.isEmpty {
            finish(save: true)              // отпустили всё — сочетание набрано
        }
    }

    private func begin() {
        pressed = []
        recording = true
        Dictation.assigningHotkey = true
        if let window = NSApp.keyWindow, let content = window.contentView {
            previousResponder = window.firstResponder
            let view = KeyCatcher(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            view.onFlags = { code, mods in take(code: code, mods: mods) }
            content.addSubview(view)
            window.makeFirstResponder(view)
            catcher = view
        }
        Dictation.logHotkey("запись начата")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            take(code: event.keyCode, mods: event.modifierFlags)
            return event
        }
    }

    private func finish(save: Bool) {
        Dictation.assigningHotkey = false
        if let catcher {
            catcher.window?.makeFirstResponder(previousResponder)
            catcher.removeFromSuperview()
        }
        catcher = nil; previousResponder = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        guard save else { return }
        let chosen = HotCombo.tokens(fromKeyCodes: pressed)
        Dictation.logHotkey("записано: \(chosen.isEmpty ? "ничего" : chosen)")
        if !chosen.isEmpty { combo = chosen }
    }
}

private struct SettingRow<Trailing: View>: View {
    @Environment(\.palette) private var p
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Kind.body(14))
                if let subtitle {
                    Text(subtitle).font(Kind.body(12.5)).foregroundStyle(p.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 11)
    }
}
