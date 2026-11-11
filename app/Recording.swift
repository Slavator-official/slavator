import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Запись

/// «Запись» — экран, с которого начинается работа: записать звонок или
/// расшифровать готовый файл. Пока идёт запись или расшифровка, экран
/// показывает только её — так главное действие всегда на одном месте.
struct RecordScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var doctor: Doctor
    var chat: Chat
    @Bindable var memory: SpeakerMemory
    @Binding var picked: URL?
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var source = "sys"
    @State private var ready = Paths.isReady
    @State private var setupStarted = false
    /// Сколько человек на встрече. 0 — пусть определит сама.
    @State private var speakers = 0
    @State private var pulse = false
    @State private var inputError: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ScreenTitle(text: "Новая запись")
                    Text("Запишите звонок или расшифруйте готовый файл. Всё остаётся на этом Mac.")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 8)
                LocalBadge()
            }

            if !ready {
                setupCard
            } else if let report = doctor.report, !report.ok {
                updateCard(report)
            }

            if capture.isRecording {
                recordingCard
            } else if pipeline.isRunning {
                progressCard
            } else {
                HStack(alignment: .top, spacing: 16) {
                    recordCard
                    fileCard
                }
                .disabled(!ready)
                .opacity(ready ? 1 : 0.5)
            }

            if let inputError {
                Label(inputError, systemImage: "exclamationmark.circle")
                    .font(Kind.body(13)).foregroundStyle(p.error)
            }

            if !library.records.isEmpty { recent }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = Paths.isReady
            doctor.refresh()
        }
        .onAppear { doctor.refresh() }
        .onChange(of: pipeline.isRunning) { _, running in
            guard !running else { return }
            doctor.refresh()
            picked = nil
        }
    }

    // MARK: карточки

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
    }

    private func cardIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            .foregroundStyle(p.accent2)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.accentSoft))
    }

    private var recordCard: some View {
        card {
            cardIcon("mic")
            Text("Записать встречу").font(Kind.head(17)).padding(.top, 14)
            Text(source == "sys"
                 ? "Собеседники — из звука компьютера, вы — с микрофона. Подходит для любого созвона."
                 : "Только микрофон — для встречи в одной комнате.")
                .font(Kind.body(13.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            Spacer(minLength: 16)
            Segmented(options: [("sys", "Звонок"), ("mic", "Только микрофон")], selection: $source)
            Button { startRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.system(size: 15, weight: .semibold))
                    Text("Начать запись")
                }
            }
            .buttonStyle(PrimaryButton(wide: true))
            .padding(.top, 10)
            if let failure = capture.failure {
                Text(failure).font(Kind.body(12.5)).foregroundStyle(p.warn).padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var fileCard: some View {
        if let picked {
            card {
                cardIcon("waveform")
                Text(picked.lastPathComponent).font(Kind.head(16)).lineLimit(2).truncationMode(.middle)
                    .padding(.top, 14)
                Text(fileInfo(picked)).font(Kind.body(13)).foregroundStyle(p.muted).padding(.top, 2)
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    // Число участников снимает главную причину дробления
                    // голосов: без него движок гадает и выдаёт десятки «людей».
                    Text("Участников").font(Kind.body(13)).foregroundStyle(p.muted)
                    HStack(spacing: 0) {
                        stepButton("−") { speakers = max(0, speakers - 1) }
                        Text(speakers == 0 ? "авто" : String(speakers))
                            .font(Kind.body(13)).monospacedDigit().frame(width: 40)
                        stepButton("+") { speakers = min(12, speakers + 1) }
                    }
                    .background(RoundedRectangle(cornerRadius: 7).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.line, lineWidth: 1))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button("Другой файл", action: pick).buttonStyle(QuietButton())
                    Button("Расшифровать") { pipeline.run(input: picked, library: library, speakers: speakers) }
                        .buttonStyle(PrimaryButton(wide: true))
                        .disabled(pipeline.isRunning || capture.isRecording)
                }
                .padding(.top, 10)
            }
        } else {
            Button(action: pick) {
                VStack(spacing: 10) {
                    cardIcon("arrow.down.doc")
                    Text("Расшифровать файл").font(Kind.head(17)).foregroundStyle(p.text)
                    Text("Перетащите аудио или видео сюда\nили нажмите, чтобы выбрать")
                        .font(Kind.body(13.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    Text("WAV · MP3 · M4A · MP4 · WEBM").font(Kind.body(12)).foregroundStyle(p.faint)
                }
                .frame(maxWidth: .infinity, minHeight: 236)
                .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? p.accentSoft : p.surface))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dropTargeted ? p.accent : p.line,
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 5])))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard ready, !pipeline.isRunning, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { selectFile(url) } }
                }
                return true
            }
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Circle().fill(p.error).frame(width: 12, height: 12)
                    .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    // Огонёк мигает раз в секунду, как на диктофоне; при
                    // «Уменьшить движение» горит ровно.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: pulse)
                Text("Идёт запись · " + (source == "sys" ? "звонок" : "микрофон")).font(Kind.strong(15))
                Spacer()
            }
            HStack(alignment: .center, spacing: 20) {
                Text(hms(capture.seconds)).font(.system(size: 46, weight: .semibold)).monospacedDigit().kerning(-1)
                LevelMeter(level: capture.level)
                Spacer(minLength: 12)
                Button {
                    picked = finishMeeting(capture: capture, pipeline: pipeline, library: library)
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                        Text("Остановить и расшифровать")
                    }
                }
                .buttonStyle(PrimaryButton(destructive: true))
            }
            Text("Расшифровка начнётся сразу после остановки. Окно можно закрыть — запись продолжится, значок в строке меню её остановит.")
                .font(Kind.body(13)).foregroundStyle(p.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
        .onAppear { pulse = true }
    }

    /// Расшифровка идёт долго — час записи считается десятки минут. Без
    /// внятного прогресса это неотличимо от зависшего приложения, поэтому
    /// шаг назван словами, а не только процентом.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Расшифровываю").font(Kind.body(13)).foregroundStyle(p.muted)
                    Text(pipeline.isSuspended ? "Пауза на время диктовки" : pipeline.stage).font(Kind.head(18))
                    if !pipeline.detail.isEmpty {
                        Text(pipeline.detail).font(Kind.body(13)).foregroundStyle(p.muted).lineLimit(2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(pipeline.percent))%").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    if let left = pipeline.remainingText, !pipeline.isSuspended {
                        Text(left).font(Kind.body(12.5)).foregroundStyle(p.muted)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.raised)
                    Capsule().fill(p.accent)
                        .frame(width: max(0, geo.size.width * pipeline.percent / 100))
                        // Постоянное движение — равномерно, без разгона.
                        .animation(.linear(duration: 0.3), value: pipeline.percent)
                }
            }
            .frame(height: 6).padding(.top, 18)
            HStack(spacing: 8) {
                ForEach(pipeline.stageOrder, id: \.self) { key in
                    Circle().fill(pipeline.reached(key) ? p.accent : p.line).frame(width: 6, height: 6)
                }
                Spacer()
                Button(pipeline.isCancelling ? "Останавливаю…" : "Прервать") { pipeline.cancel() }
                    .buttonStyle(QuietButton()).disabled(pipeline.isCancelling)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
    }

    /// Последние встречи — чтобы сразу открыть только что расшифрованную.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Недавние встречи").font(Kind.strong(14))
            VStack(spacing: 0) {
                ForEach(Array(library.records.prefix(3).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Rectangle().fill(p.line2).frame(height: 1).padding(.leading, 14) }
                    MeetingRowButton(record: record, library: library) { screen = .meeting(record.dir) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
        }
    }

    private func stepButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(Kind.strong(15)).foregroundStyle(p.muted)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // первый запуск: окружения ещё нет
    private var setupCard: some View {
        Card {
            Label(setupStarted ? "Идёт установка" : "\(AppConfiguration.displayName) ещё не настроен",
                  systemImage: "arrow.down.circle")
                .font(Kind.strong(15))
            Text(setupStarted
                 ? "Установка идёт в окне Терминала. Когда там появится «Готово», вернитесь сюда — программа сама подхватит окружение."
                 : "Один раз развернуть распознавание речи и языковую модель: около 6 ГБ загрузки и 20–40 минут. Всё останется на этом Mac.")
                .font(Kind.body(13.5)).foregroundStyle(p.muted).padding(.top, 6)
            if !setupStarted {
                Button("Установить") { setupStarted = true; Paths.runSetup() }
                    .buttonStyle(PrimaryButton()).padding(.top, 12)
            }
        }
    }

    // окружение стоит, но чего-то не хватает: узнать об этом нужно до того,
    // как отдать программе часовую запись и подождать полчаса.
    private func updateCard(_ report: Readiness) -> some View {
        Card {
            HStack(spacing: 8) {
                Label(report.needs_setup ? "Нужно восстановить окружение"
                      : (report.needsDownload ? "Не хватает моделей" : "Локальные службы ещё не готовы"),
                      systemImage: "arrow.down.circle.dotted")
                    .font(Kind.strong(15))
                Spacer()
                if let weight = report.weight { Pill(text: weight, fg: p.warn, bg: p.warnBg) }
            }
            Text(report.listing).font(Kind.body(13.5)).foregroundStyle(p.muted).padding(.top, 6)
            Group {
                if report.needs_setup {
                    Button(setupStarted ? "Установка идёт в Терминале" : "Установить") {
                        setupStarted = true; Paths.runSetup()
                    }
                    .buttonStyle(PrimaryButton()).disabled(setupStarted)
                } else if !report.needsDownload {
                    Button(doctor.busy ? "Запускаю и проверяю…" : "Запустить и проверить") { doctor.refresh() }
                        .buttonStyle(PrimaryButton()).disabled(doctor.busy)
                } else {
                    Button(pipeline.isRunning ? "Идёт дозагрузка" : "Дозагрузить") {
                        let alert = NSAlert()
                        alert.messageText = "Разрешить загрузку моделей из интернета?"
                        alert.informativeText = "Будут загружены недостающие модели и запущена локальная Ollama. Объём может составить несколько гигабайт. Записи встреч не отправляются."
                        alert.addButton(withTitle: "Разрешить и загрузить")
                        alert.addButton(withTitle: "Отмена")
                        if alert.runModal() == .alertFirstButtonReturn { pipeline.repair(library: library) }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(pipeline.isRunning || capture.isRecording)
                }
            }
            .padding(.top, 12)
        }
    }

    private func startRecording() {
        let folder = URL(fileURLWithPath: library.settings.recordingsFolder)
        capture.start(source: source == "mic" ? .microphone : .meeting, folder: folder)
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

// MARK: - Встречи

/// «Встречи» — все расшифрованные встречи списком. Нажатие открывает
/// встречу в этом же окне.
struct RecordsScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var chat: Chat
    @Bindable var memory: SpeakerMemory
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    /// Встреча, у которой спрашиваем проект.
    @State var asking: Record?
    @State private var query = ""
    @State private var onlyUnknown = false

    private var visibleRecords: [Record] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.records.filter { record in
            (!onlyUnknown || library.unknown.contains { $0.record == record.dir }) &&
            (needle.isEmpty || record.title.localizedStandardContains(needle) ||
             meetingTitle(record).localizedStandardContains(needle) ||
             record.turns.contains { $0.name.localizedStandardContains(needle) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 10) {
                ScreenTitle(text: "Встречи")
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(p.faint)
                    TextField("Встреча или участник", text: $query).textFieldStyle(.plain).font(Kind.body(13.5))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(p.faint).help("Очистить поиск")
                    }
                }
                .padding(.horizontal, 10).frame(width: 260, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                trashMenu
            }

            if memory.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(memory.progress).font(Kind.body(12.5)).foregroundStyle(p.muted)
                }
            }
            if let failure = memory.failure {
                Text(failure).font(Kind.body(13)).foregroundStyle(p.warn).textSelection(.enabled)
            }
            if !memory.notice.isEmpty {
                Text(memory.notice).font(Kind.body(12.5)).foregroundStyle(p.muted)
            }

            if !library.unknown.isEmpty { unknownSection }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Все встречи").font(Kind.strong(14))
                    Text(summaryLine).font(Kind.body(12.5)).monospacedDigit().foregroundStyle(p.muted)
                    Spacer()
                    if !library.unknown.isEmpty {
                        Toggle("Только с голосами без имени", isOn: $onlyUnknown)
                            .toggleStyle(.checkbox).font(Kind.body(12.5))
                    }
                }
                if visibleRecords.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: library.records.isEmpty ? "waveform" : "magnifyingglass")
                            .font(.system(size: 24)).foregroundStyle(p.faint)
                        Text(library.records.isEmpty ? "Здесь появятся ваши встречи" : "Ничего не найдено")
                            .font(Kind.strong(14.5))
                        Text(library.records.isEmpty
                             ? "Запишите звонок или расшифруйте файл на экране «Запись»."
                             : "Попробуйте другое название или имя.")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                        if library.records.isEmpty {
                            Button("Перейти к записи") { screen = .capture }.buttonStyle(PrimaryButton()).padding(.top, 4)
                        } else {
                            Button("Сбросить поиск") { query = ""; onlyUnknown = false }
                                .buttonStyle(QuietButton()).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Rectangle().fill(p.line2).frame(height: 1).padding(.leading, 16) }
                            MeetingRowButton(record: record, library: library, status: AnyView(statusPill(for: record))) {
                                open(record)
                            }
                            .contextMenu {
                                Button("Открыть") { open(record) }
                                Button("Переименовать…") {
                                    MeetingActions.rename(record, library: library, memory: memory, pipeline: pipeline, player: player)
                                }
                                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.dir]) }
                                Divider()
                                Button("Удалить встречу…", role: .destructive) {
                                    MeetingActions.delete(record, library: library, memory: memory, pipeline: pipeline, player: player)
                                }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
                }
            }
        }
        .sheet(item: $asking) { record in
            ProjectSheet(record: record, library: library, pipeline: pipeline)
        }
        .onAppear { memory.loadCatalog(settings: library.settings) }
    }

    private func open(_ record: Record) { screen = .meeting(record.dir) }

    private var summaryLine: String {
        guard !library.records.isEmpty else { return "" }
        let total = library.records.reduce(0) { $0 + $1.length }
        let shown = visibleRecords.count == library.records.count ? "" : " · показано \(visibleRecords.count)"
        return plural(library.records.count, "встреча", "встречи", "встреч") + " · " + spokenLength(total) + shown
    }

    // голоса без имени — то, что ждёт человека после каждой встречи
    private var unknownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Голоса без имени").font(Kind.strong(14))
                Text("\(library.unknown.count)").font(Kind.body(12.5)).monospacedDigit().foregroundStyle(p.muted)
                Spacer()
                Button("Все голоса") { screen = .newVoices }.buttonStyle(LinkButton()).font(Kind.body(13))
            }
            VStack(spacing: 0) {
                ForEach(Array(library.unknown.prefix(3).enumerated()), id: \.element.id) { index, voice in
                    if index > 0 { Rectangle().fill(p.line2).frame(height: 1).padding(.leading, 56) }
                    RowBox {
                        PlayDot(size: 28) {
                            player.play(url: voice.url, label: library.label(for: voice),
                                        subtitle: "неопознанный голос", colour: library.color(for: voice))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(voice.guess.map { "Похоже, это \($0)" } ?? library.label(for: voice)).font(Kind.strong(13.5))
                            Text(voice.guess == nil ? "по имени к нему не обращались"
                                 : voice.guessedByVoice ? "похож по голосу, проверьте" : "имя определено по разговору")
                                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 8)
                        Button(voice.guess != nil ? "Подтвердить" : "Привязать") { screen = .newVoices }
                            .buttonStyle(QuietButton())
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
        }
    }

    // Корзина — место, куда изредка заглядывают: значок в углу не спорит
    // со списком.
    private var trashMenu: some View {
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
            Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(p.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
        .disabled(memory.busy || pipeline.isRunning)
        .help(memory.deleted.isEmpty ? "Корзина Славатора пуста" : "Корзина Славатора: \(memory.deleted.count)")
    }
}

/// Строка встречи: название, когда и сколько, маленькая лента голосов,
/// состояние. Нажатие открывает встречу.
struct MeetingRowButton: View {
    let record: Record
    var library: Library
    var status: AnyView? = nil
    let action: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetingTitle(record)).font(Kind.strong(14.5)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(meetingMeta(record)).font(Kind.body(12.5)).monospacedDigit()
                        .foregroundStyle(p.muted).lineLimit(1)
                }
                .help(record.title)
                Spacer(minLength: 12)
                if !record.turns.isEmpty {
                    Ribbon(turns: record.turns, height: 8, library: library, record: record)
                        .frame(width: 140).allowsHitTesting(false)
                }
                if let status { status }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.faint)
            }
            .padding(.horizontal, 16).frame(minHeight: 60)
            .background(hovering ? p.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Окно встречи

/// Действия над встречей, общие для списка и окна встречи.
enum MeetingActions {
    static func delete(_ record: Record, library: Library, memory: SpeakerMemory, pipeline: Pipeline, player: Player) {
        guard !pipeline.isRunning, !memory.busy else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить встречу «\(meetingTitle(record))»?"
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
    static func rename(_ record: Record, library: Library, memory: SpeakerMemory, pipeline: Pipeline, player: Player) {
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
    private static func retitle(_ folder: URL, to title: String) {
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

}

/// Встреча — открывается в том же окне, на месте списка; «Назад»
/// возвращает туда, откуда пришли.
struct MeetingPage: View {
    let dir: URL
    let backTitle: String
    let back: () -> Void
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var chat: Chat
    @Bindable var memory: SpeakerMemory
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    @State private var tab = "decisions"
    @State private var asking: Record?

    var body: some View {
        Panel {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(backTitle).font(Kind.body(13.5))
                }
                .foregroundStyle(p.accent2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Назад (⌘←)")
            .padding(.horizontal, 20).padding(.top, 16)

            if let record = library.records.first(where: { $0.dir == dir }) {
                MeetingDetail(record: record, library: library, player: player, pipeline: pipeline,
                              chat: chat, memory: memory, tab: $tab,
                              openVoices: { screen = .newVoices },
                              rename: { MeetingActions.rename(record, library: library, memory: memory, pipeline: pipeline, player: player) },
                              delete: { MeetingActions.delete(record, library: library, memory: memory, pipeline: pipeline, player: player) },
                              askProject: { asking = record })
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder").font(.system(size: 28)).foregroundStyle(p.faint)
                    Text("Встреча переименована или удалена").font(Kind.head(17))
                    Button("Ко всем встречам") { screen = .records }.buttonStyle(QuietButton())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $asking) { record in
            ProjectSheet(record: record, library: library, pipeline: pipeline)
        }
    }
}

// MARK: - Общие мелочи

/// Кнопка без своего оформления, только сжатие на нажатии.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(Pressable(pressed: configuration.isPressed))
    }
}
/// Название встречи для людей.
///
/// Запись из Яндекс Телемоста или Zoom приходит с именем вроде
/// «kuzina_2026-10-29T14_47_09.336Z»: так её и показывали, крупно и в две
/// строки. Время в таком имени — по Гринвичу (буква Z), поэтому переводим
/// его в местное. Настоящее имя файла не теряется: оно в подсказке и в
/// «Источниках». Переименованные вручную встречи показываются как есть.
func meetingTitle(_ record: Record) -> String {
    let title = record.title
    guard let match = title.range(of: #"(\d{4})-(\d{2})-(\d{2})[T _](\d{2})[_:.\-](\d{2})"#,
                                  options: .regularExpression) else { return title }
    let stamp = String(title[match])
    let digits = stamp.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    guard digits.count >= 5 else { return title }
    var parts = DateComponents()
    parts.year = digits[0]; parts.month = digits[1]; parts.day = digits[2]
    parts.hour = digits[3]; parts.minute = digits[4]
    let utc = title[match.upperBound...].contains("Z")
    var calendar = Calendar(identifier: .gregorian)
    if utc { calendar.timeZone = TimeZone(identifier: "UTC")! }
    guard let date = calendar.date(from: parts) else { return title }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "d MMMM, HH:mm"
    let when = formatter.string(from: date)
    let prefix = title[..<match.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "_- ."))
    return prefix.isEmpty ? "Встреча " + when : prefix + " — " + when
}


/// «Сегодня, 10:00», «Вчера, 16:00», «Пн, 13:00», «30 окт., 13:02».
func meetingDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let ru = Locale(identifier: "ru_RU")
    let time = DateFormatter(); time.locale = ru; time.dateFormat = "HH:mm"
    let clock = time.string(from: date)
    if calendar.isDateInToday(date) { return "Сегодня, " + clock }
    if calendar.isDateInYesterday(date) { return "Вчера, " + clock }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: Date())).day ?? 99
    let formatter = DateFormatter(); formatter.locale = ru
    if days > 0 && days < 7 {
        formatter.dateFormat = "EE"
        return formatter.string(from: date).capitalized + ", " + clock
    }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    formatter.dateFormat = sameYear ? "d MMM, HH:mm" : "d MMM yyyy, HH:mm"
    return formatter.string(from: date)
}

/// «Сегодня, 10:00 · 42 мин · 3 спикера». Если время записи уже стоит в
/// названии, дату обработки не добавляем: две разные даты рядом спорили.
func meetingMeta(_ record: Record) -> String {
    var parts = meetingTitle(record) == record.title ? [meetingDate(record.date)] : []
    if record.length > 0 { parts.append(spokenLength(record.length)) }
    if record.speakerCount > 0 {
        parts.append(plural(record.speakerCount, "спикер", "спикера", "спикеров"))
    }
    return parts.joined(separator: " · ")
}

