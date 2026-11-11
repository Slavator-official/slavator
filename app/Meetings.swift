import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «Встречи» — главный экран: список слева, открытая встреча справа.
///
/// Так устроен «Светлый кабинет»: меню, список, инспектор. Запись и импорт
/// стоят над списком, потому что новая встреча появляется именно в нём;
/// идущая запись и расшифровка видны там же, первой строкой, — без
/// отдельного экрана и без полосы внизу.
struct MeetingsScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var doctor: Doctor
    @Bindable var memory: SpeakerMemory
    var chat: Chat
    @Binding var picked: URL?
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: URL?
    @State private var query = ""
    @State private var onlyUnknown = false
    @State private var inputError: String?
    @State private var dropTargeted = false
    @State private var source = "sys"
    @State private var ready = Paths.isReady
    @State private var setupStarted = false
    /// Сколько человек на встрече. 0 — пусть определит сама.
    @State private var speakers = 0
    @State private var pulse = false
    @State private var asking: Record?
    @State private var detailTab = "decisions"

    private var visibleRecords: [Record] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.records.filter { record in
            (!onlyUnknown || library.unknown.contains { $0.record == record.dir }) &&
            (needle.isEmpty || record.title.localizedStandardContains(needle) ||
             meetingTitle(record).localizedStandardContains(needle) ||
             record.turns.contains { $0.name.localizedStandardContains(needle) })
        }
    }

    /// Открытая встреча. Пока человек ничего не выбирал — самая свежая.
    private var current: Record? {
        let list = visibleRecords
        if let selected, let record = list.first(where: { $0.dir == selected }) { return record }
        return list.first
    }

    var body: some View {
        GeometryReader { geo in
            // Список — от 360 pt (спецификация), встреча забирает остальное.
            let listWidth = min(460, max(360, geo.size.width * 0.4))
            HStack(spacing: 12) {
                Panel { listColumn }.frame(width: listWidth)
                Panel { detailColumn }
            }
        }
        // Запись можно бросить в любое место экрана, а не целиться в зону.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard ready, !pipeline.isRunning, !capture.isRecording,
                  let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { selectFile(url) } }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(p.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.bg.opacity(0.85)))
                    .overlay(Label("Отпустите — расшифрую запись", systemImage: "arrow.down.doc")
                        .font(Kind.strong(16)).foregroundStyle(p.accent2))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $asking) { record in
            ProjectSheet(record: record, library: library, pipeline: pipeline)
        }
        .onAppear {
            memory.loadCatalog(settings: library.settings)
            doctor.refresh()
        }
        // Установка идёт в Терминале, отдельным процессом. Возвращение в
        // приложение — самый надёжный момент, чтобы проверить, чем кончилось.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = Paths.isReady
            doctor.refresh()
        }
        .onChange(of: pipeline.isRunning) { _, running in
            guard !running else { return }
            doctor.refresh()
            // Расшифровка кончилась: открываем свежую встречу, а выбранный
            // файл больше не предлагаем — он уже разобран.
            selected = nil
            picked = nil
        }
    }

    // MARK: список

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Уступает место заголовок, а не кнопки: подпись действия,
                // разорванная на «Запи / сать», читается как поломка.
                Text("Встречи").font(Kind.title(26)).kerning(-0.5).lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 8)
                Button(action: pick) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(IconFrameStyle())
                .disabled(!ready || pipeline.isRunning || capture.isRecording)
                .help("Импорт: выбрать файл записи — WAV, MP3, M4A, MP4, WEBM и другие")
                .accessibilityLabel("Импорт файла записи")
                recordButton.layoutPriority(1)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            statusArea

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(p.faint)
                    TextField("Поиск по встречам", text: $query)
                        .textFieldStyle(.plain).font(Kind.body(14))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(p.faint).help("Очистить поиск")
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                filterMenu
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            meetingList
        }
    }

    /// Единая кнопка записи с текстовым статусом: «Записать» — пока тихо,
    /// «Стоп · 12:34» — пока идёт запись. Стрелка рядом выбирает источник.
    @ViewBuilder private var recordButton: some View {
        if capture.isRecording {
            Button { picked = finishMeeting(capture: capture, pipeline: pipeline, library: library) } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                    Text("Стоп · " + hms(capture.seconds)).monospacedDigit().lineLimit(1)
                }
            }
            .buttonStyle(PrimaryButton(destructive: true))
            .help("Остановить запись — расшифровка начнётся сразу")
        } else {
            let enabled = ready && !pipeline.isRunning
            HStack(spacing: 0) {
                Button(action: startRecording) {
                    HStack(spacing: 7) {
                        Image(systemName: "record.circle").font(.system(size: 14, weight: .semibold))
                        Text("Записать").lineLimit(1)
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : p.faint)
                    .padding(.leading, 12).padding(.trailing, 9).frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                Rectangle().fill(Color.white.opacity(enabled ? 0.3 : 0)).frame(width: 1, height: 18)
                Menu {
                    Toggle("Звонок — собеседники и вы", isOn: Binding(
                        get: { source == "sys" }, set: { if $0 { source = "sys" } }))
                    Toggle("Только микрофон", isOn: Binding(
                        get: { source == "mic" }, set: { if $0 { source = "mic" } }))
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(enabled ? Color.white : p.faint)
                        .frame(width: 26, height: 34).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 34)
                .help("Что записывать")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? p.accent : p.raised))
            .disabled(!enabled)
            .help(source == "sys" ? "Запишу звонок: собеседников из звука компьютера и вас с микрофона"
                                  : "Запишу только микрофон — для встречи в одной комнате")
        }
    }

    /// Фильтры и корзина: меняются редко, поэтому спрятаны под одну кнопку.
    private var filterMenu: some View {
        Menu {
            Toggle("Только с голосами без имени", isOn: $onlyUnknown)
            Divider()
            if memory.deleted.isEmpty {
                Text("Корзина пуста")
            } else {
                Text("Корзина Славатора")
                ForEach(memory.deleted) { entry in
                    Button("Восстановить: \(entry.title) · \(entry.date.prefix(10))") {
                        guard !pipeline.isRunning, !memory.busy else { return }
                        memory.restoreMeeting(entry, settings: library.settings) { library.reload() }
                    }
                }
            }
            Button("Показать папку корзины") {
                NSWorkspace.shared.open(URL(fileURLWithPath: library.settings.results_dir).appending(path: ".slavator-trash"))
            }.disabled(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: library.settings.results_dir).appending(path: ".slavator-trash").path))
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                .foregroundStyle(onlyUnknown ? p.accent2 : p.text)
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(onlyUnknown ? p.accentSoft : p.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
        .disabled(memory.busy)
        .help("Фильтр и корзина")
    }

    // Состояния над списком: установка, запись, расшифровка, выбранный файл.
    @ViewBuilder private var statusArea: some View {
        let showSetup = !ready || (doctor.report.map { !$0.ok } ?? false)
        if showSetup || capture.isRecording || pipeline.isRunning || picked != nil || inputError != nil || capture.failure != nil || memory.busy {
            VStack(alignment: .leading, spacing: 8) {
                if !ready {
                    setupCard
                } else if let report = doctor.report, !report.ok {
                    updateCard(report)
                }
                if capture.isRecording {
                    recordingCard
                } else if pipeline.isRunning {
                    progressCard
                } else if let picked {
                    chosenCard(picked)
                }
                if let inputError {
                    Label(inputError, systemImage: "exclamationmark.circle")
                        .font(Kind.body(12.5)).foregroundStyle(p.error)
                }
                if let failure = capture.failure, !capture.isRecording {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(Kind.body(12.5)).foregroundStyle(p.warn)
                }
                if memory.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(memory.progress).font(Kind.body(12)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func statusBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.raised))
    }

    private var recordingCard: some View {
        statusBox {
            HStack(spacing: 10) {
                Circle().fill(p.error).frame(width: 9, height: 9)
                    .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    // Огонёк записи мигает раз в секунду, как на диктофоне;
                    // при «Уменьшить движение» горит ровно.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: pulse)
                Text("Идёт запись · " + (source == "sys" ? "звонок" : "микрофон")).font(Kind.strong(13.5))
                Spacer(minLength: 8)
                LevelMeter(level: capture.level)
            }
            Text("Расшифровка начнётся сразу после остановки.").font(Kind.body(12.5)).foregroundStyle(p.muted)
        }
        .onAppear { pulse = true }
    }

    /// Расшифровка идёт долго — час записи считается десятки минут. Без
    /// внятного прогресса это неотличимо от зависшего приложения, поэтому
    /// шаг назван словами, а не только процентом.
    private var progressCard: some View {
        statusBox {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pipeline.isSuspended ? "Пауза на время диктовки" : pipeline.stage)
                    .font(Kind.strong(13.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int(pipeline.percent))%").font(Kind.strong(13.5)).monospacedDigit()
            }
            if !pipeline.detail.isEmpty {
                Text(pipeline.detail).font(Kind.body(12.5)).foregroundStyle(p.muted).lineLimit(2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.line)
                    Capsule().fill(p.accent)
                        .frame(width: max(0, geo.size.width * pipeline.percent / 100))
                        // Постоянное движение — равномерно, без разгона.
                        .animation(.linear(duration: 0.3), value: pipeline.percent)
                }
            }
            .frame(height: 4)
            HStack {
                if let left = pipeline.remainingText, !pipeline.isSuspended {
                    Text(left).font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button(pipeline.isCancelling ? "Останавливаю…" : "Прервать") { pipeline.cancel() }
                    .buttonStyle(LinkButton()).font(Kind.body(12.5)).disabled(pipeline.isCancelling)
            }
        }
    }

    private func chosenCard(_ file: URL) -> some View {
        statusBox {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(p.accent2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.lastPathComponent).font(Kind.strong(13.5)).lineLimit(1).truncationMode(.middle)
                    Text(fileInfo(file)).font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 6)
                Button { picked = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(p.faint).help("Убрать файл")
            }
            HStack(spacing: 8) {
                // Число участников снимает главную причину дробления голосов:
                // без него движок гадает и выдаёт десятки «людей».
                Text("Участников").font(Kind.body(12.5)).foregroundStyle(p.muted)
                HStack(spacing: 0) {
                    stepButton("−") { speakers = max(0, speakers - 1) }
                    Text(speakers == 0 ? "авто" : String(speakers))
                        .font(Kind.body(12.5)).monospacedDigit().frame(width: 38)
                    stepButton("+") { speakers = min(12, speakers + 1) }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.line, lineWidth: 1))
                Spacer(minLength: 6)
                Button("Расшифровать") { pipeline.run(input: file, library: library, speakers: speakers) }
                    .buttonStyle(PrimaryButton())
                    .disabled(pipeline.isRunning || capture.isRecording)
            }
        }
    }

    private func stepButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(Kind.strong(14)).foregroundStyle(p.muted)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // первый запуск: окружения ещё нет
    private var setupCard: some View {
        statusBox {
            Label(setupStarted ? "Идёт установка" : "\(AppConfiguration.displayName) ещё не настроен",
                  systemImage: "arrow.down.circle")
                .font(Kind.strong(13.5))
            Text(setupStarted
                 ? "Установка идёт в окне Терминала. Когда там появится «Готово», вернитесь сюда — программа сама подхватит окружение."
                 : "Один раз развернуть распознавание речи и языковую модель: около 6 ГБ загрузки и 20–40 минут. Всё останется на этом Mac.")
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
            if !setupStarted {
                Button("Установить") { setupStarted = true; Paths.runSetup() }
                    .buttonStyle(PrimaryButton())
            }
        }
    }

    // окружение стоит, но чего-то не хватает: узнать об этом нужно до того,
    // как отдать программе часовую запись и подождать полчаса.
    private func updateCard(_ report: Readiness) -> some View {
        statusBox {
            HStack(spacing: 8) {
                Label(report.needs_setup ? "Нужно восстановить окружение"
                      : (report.needsDownload ? "Не хватает моделей" : "Локальные службы ещё не готовы"),
                      systemImage: "arrow.down.circle.dotted")
                    .font(Kind.strong(13.5)).foregroundStyle(p.text)
                Spacer(minLength: 6)
                if let weight = report.weight { Pill(text: weight, fg: p.warn, bg: p.warnBg) }
            }
            Text(report.listing).font(Kind.body(12.5)).foregroundStyle(p.muted)
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
    }

    private var meetingList: some View {
        Group {
            if visibleRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: library.records.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(p.faint)
                    Text(library.records.isEmpty ? "Пока нет встреч" : "Ничего не найдено").font(Kind.strong(14))
                    Text(library.records.isEmpty
                         ? "Нажмите «Записать» во время звонка или перетащите файл записи в окно."
                         : "Попробуйте другое название или имя.")
                        .font(Kind.body(12.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    if !library.records.isEmpty {
                        Button("Сбросить поиск") { query = ""; onlyUnknown = false }
                            .buttonStyle(QuietButton()).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let list = visibleRecords
                    LazyVStack(spacing: 0) {
                        let currentDir = current?.dir
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, record in
                            let isSelected = record.dir == currentDir
                            // Разделитель — только между двумя невыбранными
                            // строками: у выбранной своя подложка.
                            if index > 0 && !isSelected && list[index - 1].dir != currentDir {
                                Rectangle().fill(p.line2).frame(height: 1).padding(.horizontal, 12)
                            }
                            MeetingRow(record: record, selected: isSelected,
                                       unknown: library.unknown.filter { $0.record == record.dir }.count) {
                                selected = record.dir
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                    if list.count < 4 {
                        Label("Перетащите файл записи в окно — расшифрую его здесь же.", systemImage: "arrow.down.doc")
                            .font(Kind.body(12.5)).foregroundStyle(p.faint)
                            .padding(.horizontal, 20).padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: встреча

    @ViewBuilder private var detailColumn: some View {
        if let record = current {
            MeetingDetail(record: record, library: library, player: player, pipeline: pipeline,
                          chat: chat, memory: memory, screen: $screen, tab: $detailTab,
                          rename: { renameMeeting(record) },
                          delete: { confirmDeletion(record) },
                          askProject: { asking = record })
                .id(record.dir)
        } else {
            VStack(spacing: 12) {
                if let url = Bundle.main.resourceURL?.appending(path: "app_icon.png"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 56, height: 56)
                }
                Text(library.records.isEmpty ? "Здесь откроется встреча" : "Выберите встречу слева")
                    .font(Kind.title(20)).kerning(-0.3)
                Text("Решения, кто сколько говорил, расшифровка и чат по встрече — всё в одном месте.")
                    .font(Kind.body(13.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                LocalBadge().padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: действия

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

    private func confirmDeletion(_ record: Record) {
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

}

/// Квадратная кнопка-значок в рамке: импорт, «ещё».
struct IconFrameStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconFrameLabel(configuration: configuration) }
}

private struct IconFrameLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? p.text : p.faint)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && enabled ? p.raised : p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
            .modifier(Pressable(pressed: configuration.isPressed && enabled))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
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

/// Кнопка без своего оформления, только сжатие на нажатии.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(Pressable(pressed: configuration.isPressed))
    }
}

/// Компактная строка встречи: название, когда и сколько, состояние.
private struct MeetingRow: View {
    let record: Record
    let selected: Bool
    let unknown: Int
    let action: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetingTitle(record)).font(Kind.strong(14.5)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                        .help(record.title)
                    Text(meetingMeta(record)).font(Kind.body(12.5)).monospacedDigit()
                        .foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if unknown > 0 {
                    // Состояние — значком и числом, не одним цветом.
                    HStack(spacing: 3) {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 11.5))
                        Text("\(unknown)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(p.warn)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Capsule().fill(p.warnBg))
                    .help(plural(unknown, "голос без имени", "голоса без имени", "голосов без имени"))
                }
                Image(systemName: "waveform").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? p.accent2 : p.faint)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.faint)
            }
            .padding(.horizontal, 12).frame(minHeight: 62)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? p.accentSoft : (hovering ? p.selection : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
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
