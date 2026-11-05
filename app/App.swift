import SwiftUI
import UserNotifications

@main
struct SlavatorApp: App {
    @State private var library = Library()
    @State private var player = Player()
    // Обработка и запись живут на уровне приложения. Внутри экрана они
    // умирали при переходе на другую вкладку: процесс продолжал считать,
    // а прогресс и результат терялись.
    @State private var pipeline = Pipeline()
    @State private var capture = LiveCapture()
    @State private var dictation = Dictation()
    @State private var chat = Chat()
    @State private var memory = SpeakerMemory()
    @State private var doctor = Doctor()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            Shell(library: library, player: player,
                  pipeline: pipeline, capture: capture,
                  dictation: dictation, chat: chat, memory: memory, doctor: doctor)
                .frame(minWidth: 1080, minHeight: 620)
                .onAppear {
                    library.reload()
                    // Диктовка придерживает разбор встречи: иначе она сама
                    // ползёт на загруженных ядрах.
                    dictation.onBusyChanged = { busy in pipeline.suspend(busy) }
                    dictation.refresh(settings: library.settings)
                    delegate.attach(dictation: dictation, capture: capture, pipeline: pipeline, library: library, memory: memory, chat: chat)
                }
                .onChange(of: library.settings.menubar_enabled) { _, _ in delegate.apply(settings: library.settings) }
                .onChange(of: library.settings.meeting_watch_enabled) { _, _ in delegate.apply(settings: library.settings) }
                .onChange(of: library.settings.widget_enabled) { _, _ in delegate.apply(settings: library.settings) }
                .onChange(of: library.settings.widget_size) { _, _ in delegate.apply(settings: library.settings) }
                // Возвращение в программу — момент, когда стоит перечитать
                // разрешения: их выдают в Системных настройках, снаружи.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    dictation.refresh(settings: library.settings)
                }
        }
        // Без отдельной полосы заголовка: боковая панель поднимается под
        // кнопки окна, как в Finder и Почте. Название окна и так написано
        // в боковой панели, полоса над ней дублировала его.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

/// «Главной» больше нет: она повторяла «Записи» — та же последняя встреча и
/// те же кнопки. Новая встреча начинается прямо в «Записях», над списком
/// (apple-design: экран называют по тому, что в нём лежит, а не «Главная»).
enum Screen: Hashable {
    case memory, records, speakers, newVoices, settings, chat, privacy
    case person(String)
}

/// Значок в строке меню. Сделан на AppKit намеренно: MenuBarExtra из SwiftUI
/// тянет символы, которых нет в macOS 14, а приложение обязано там работать.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
    private var item: NSStatusItem?
    private weak var dictation: Dictation?
    private weak var memory: SpeakerMemory?
    private weak var chat: Chat?
    private weak var capture: LiveCapture?
    private weak var library: Library?
    private weak var pipeline: Pipeline?
    private var widget: DeskWidget?
    /// Каким размером виджет собран сейчас: панель задаёт его при создании,
    /// поэтому смена размера — это пересборка окна, а не правка на лету.
    private var widgetSize = ""
    private let watch = MeetingWatch()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Делегата ставят до первого уведомления, иначе нажатие кнопки в нём
        // некому обработать.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(dictation: Dictation, capture: LiveCapture,
                pipeline: Pipeline, library: Library, memory: SpeakerMemory, chat: Chat) {
        self.memory = memory
        self.chat = chat
        self.dictation = dictation
        self.capture = capture
        self.pipeline = pipeline
        self.library = library
        watch.isRecording = { [weak capture] in capture?.isRecording ?? false }
        watch.onRecord = { [weak self] in self?.startListening() }
        apply(settings: library.settings)
    }

    /// Что из быстрого доступа включено. Вызывается и при запуске, и на
    /// каждое переключение в настройках.
    func apply(settings: Settings) {
        if settings.menubar_enabled { addItem() } else { removeItem() }
        if settings.meeting_watch_enabled { watch.start() } else { watch.stop() }
        if settings.widget_enabled { addWidget(size: settings.widget_size) } else { removeWidget() }
    }

    // MARK: значок

    private func addItem() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "mic.fill",
                                       accessibilityDescription: AppConfiguration.displayName)
        status.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        item = status
    }

    private func removeItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Меню собирается в момент открытия: запись могла начаться или кончиться
    /// после того, как значок появился.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if capture?.isRecording == true {
            let seconds = Int(capture?.seconds ?? 0)
            menu.addItem(note(String(format: "Идёт запись — %d:%02d",
                                     seconds / 60, seconds % 60)))
            menu.addItem(entry("Остановить и обработать", #selector(stopListening)))
        } else {
            if let holder = watch.holder {
                menu.addItem(note("Микрофон занял \(holder)"))
            }
            menu.addItem(entry("Записать встречу", #selector(startFromMenu)))
        }
        menu.addItem(.separator())
        menu.addItem(note("Держите " + HotCombo.label(library?.settings.dictation_hotkey ?? "ropt") + " — говорите"))
        menu.addItem(.separator())
        menu.addItem(entry("Открыть Славатор", #selector(openApp)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func note(_ title: String) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        line.isEnabled = false
        return line
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: action, keyEquivalent: "")
        line.target = self
        return line
    }

    // MARK: запись

    @objc private func startFromMenu() { startListening() }

    /// Звонок, а не только микрофон: предложение возникает ровно тогда, когда
    /// собеседники звучат из динамиков, и записывать одну свою половину
    /// разговора бессмысленно.
    private func startListening() {
        guard let capture, let library, let pipeline, !capture.isRecording, !pipeline.isRunning else { return }
        capture.start(source: .meeting,
                      folder: URL(fileURLWithPath: library.settings.recordingsFolder))
        openApp()
    }

    @objc private func stopListening() {
        guard let capture, let pipeline, let library else { return }
        finishMeeting(capture: capture, pipeline: pipeline, library: library)
        openApp()
    }

    // MARK: виджет

    private func addWidget(size: String) {
        if widget != nil, size == widgetSize { return }
        removeWidget()
        guard let capture, let pipeline, let library else { return }
        widgetSize = size
        widget = DeskWidget(library: library, capture: capture, pipeline: pipeline)
        widget?.show()
    }

    private func removeWidget() {
        widget?.close()
        widget = nil
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    // MARK: уведомления

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        // Запись начинает только кнопка. Нажатие на само уведомление
        // открывает программу: соглашаться за человека нельзя.
        if response.actionIdentifier == MeetingWatch.action {
            DispatchQueue.main.async { [weak self] in self?.watch.recordTapped() }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in self?.openApp() }
        }
        done()
    }

    /// Показывать, даже когда Славатор впереди: человек в это время смотрит
    /// в окно встречи, а не сюда.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
    func applicationWillTerminate(_ notification: Notification) {
        memory?.cancel()
        chat?.stop()
        watch.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture, capture.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Сейчас идёт запись встречи"
        alert.informativeText = "При выходе запись остановится. Аудиофайл сохранится в папке результатов."
        alert.addButton(withTitle: "Остановить и выйти")
        alert.addButton(withTitle: "Продолжить запись")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        capture.stop()
        return .terminateNow
    }
}

/// Два значка: слева Славатор, справа разговор с моделью.
struct ModeSwitch: View {
    @Binding var screen: Screen
    @Binding var back: Screen
    @Environment(\.palette) private var p

    private var inChat: Bool { screen == .chat || screen == .privacy }

    var body: some View {
        HStack(spacing: 2) {
            button(symbol: "waveform", active: !inChat, hint: "Славатор") {
                if inChat { screen = (back == .chat || back == .privacy) ? .records : back }
            }
            button(symbol: "bubble.left.and.bubble.right", active: inChat, hint: "Чат с моделью") {
                if !inChat { back = screen }
                screen = .chat
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.selection))
    }

    private func button(symbol: String, active: Bool, hint: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(hint == "Славатор" ? "Встречи" : "Чат", systemImage: symbol)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? p.text : p.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(active ? p.segment : Color.clear)
                    .shadow(color: .black.opacity(active ? 0.12 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}

struct Shell: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var dictation: Dictation
    var chat: Chat
    var memory: SpeakerMemory
    var doctor: Doctor
    @State private var screen: Screen = .records
    /// Куда вернуться из чата.
    @State private var lastAppScreen: Screen = .records
    @State private var picked: URL?
    @State private var privacyWorkspace = DocumentWorkspace()
    @Environment(\.colorScheme) private var systemScheme

    private var palette: Palette {
        library.settings.theme == "system" ? (systemScheme == .dark ? .dark : .light) : library.palette
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, screen: $screen,
                    lastAppScreen: $lastAppScreen, chat: chat)
            Rectangle().fill(palette.line).frame(width: 0.5)

            VStack(spacing: 0) {
                // Чат живёт вне общей прокрутки: внутри неё высота не
                // задаётся, и экран обрывался на середине окна.
                if screen == .chat {
                    ChatScreen(library: library, chat: chat, memory: memory, player: player)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                } else if screen == .privacy {
                    DocumentSheet(workspace: privacyWorkspace, settings: library.settings, attach: { _ in }, standalone: true)
                } else {
                ScrollView {
                    Group {
                        switch screen {
                        case .records:   RecordsScreen(library: library, player: player,
                                                      pipeline: pipeline, capture: capture,
                                                      doctor: doctor, memory: memory,
                                                      picked: $picked, screen: $screen)
                        case .memory:    MemoryScreen(library: library, player: player, memory: memory)
                        case .speakers:  SpeakerProfilesScreen(library: library, player: player,
                                                               screen: $screen)
                        case .newVoices: NewVoicesScreen(library: library, player: player)
                        // Чат нарисован выше, вне прокрутки. Ветка нужна
                        // только чтобы перечисление было исчерпано.
                        case .chat, .privacy: EmptyView()
                        case .settings:  SettingsScreen(library: library, dictation: dictation,
                                                        pipeline: pipeline)
                        case .person(let key): PersonScreen(library: library, player: player,
                                                            key: key, screen: $screen, memory: memory)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                }

                // В «Записях» запись и расшифровка видны в панели новой
                // встречи; нижняя полоса там повторяла бы её слово в слово.
                if (capture.isRecording || pipeline.isRunning) && screen != .records {
                    activityBar
                }
                if player.isActive {
                    PlayerBar(player: player)
                        .transition(.move(edge: .bottom))
                }
            }
            .background(palette.bg)
        }
        .environment(\.palette, palette)
        .foregroundStyle(palette.text)
        .onAppear {
            applyAppearance(library.settings.theme)
        }
        .onChange(of: library.settings.theme) { _, value in applyAppearance(value) }
        .onChange(of: pipeline.isRunning) { _, running in if running { chat.stop() } }
        .preferredColorScheme(library.settings.theme == "system" ? nil : (palette == .dark ? .dark : .light))
        .animation(.easeOut(duration: 0.18), value: player.isActive)
        .background(palette.bg)
        .onReceive(NotificationCenter.default.publisher(for: .settingsSaveFailed)) { message in
            showAlert("Не удалось сохранить настройки", message.object as? String ?? "Проверьте доступ к папке приложения.")
        }
    }

    private var activityBar: some View {
        VStack(spacing: 10) {
            if capture.isRecording {
                HStack(spacing: 12) {
                    Circle().fill(palette.accent).frame(width: 9, height: 9)
                    Text("Идёт запись").font(Kind.strong())
                    Text(hms(capture.seconds)).font(Kind.body(13)).monospacedDigit().foregroundStyle(palette.muted)
                    Spacer()
                    Button("Остановить и расшифровать") {
                        picked = finishMeeting(capture: capture, pipeline: pipeline, library: library)
                    }.buttonStyle(PrimaryButton())
                }
            }
            if pipeline.isRunning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pipeline.isSuspended ? "Пауза на время диктовки" : pipeline.stage).font(Kind.strong())
                        Text(pipeline.detail).font(Kind.body(12)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                    Spacer()
                    if let left = pipeline.remainingText, !pipeline.isSuspended {
                        Text(left).font(Kind.body(12)).foregroundStyle(palette.muted)
                    }
                    Text("\(Int(pipeline.percent))%").font(Kind.body(13)).monospacedDigit()
                    Button(pipeline.isCancelling ? "Останавливаю…" : "Прервать") { pipeline.cancel() }
                        .buttonStyle(QuietButton()).disabled(pipeline.isCancelling)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 0.5) }
    }
}

struct Sidebar: View {
    @Bindable var library: Library
    @Binding var screen: Screen
    @Binding var lastAppScreen: Screen
    var chat: Chat
    @Environment(\.palette) private var p

    /// Пункты названы по содержимому: «Записи» открываются первыми и
    /// начинают новую встречу, «Главной» больше нет.
    private var items: [(Screen, String, String)] {
        [(.records, "Записи", "waveform"),
         (.memory, "Память встреч", "point.3.connected.trianglepath.dotted"),
         (.speakers, "Спикеры", "person.2"),
         (.settings, "Настройки", "gearshape")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon = bundledIcon() ?? NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppConfiguration.displayName)
                        .font(.system(size: 15, weight: .semibold)).kerning(-0.15)
                    Text("Всё на этом Mac").font(Kind.body(11.5)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.bottom, 14)

            // Переключатель режимов стоит здесь, у названия: это выбор
            // «чем сейчас занимаемся», а не действие внутри экрана, и в
            // правом верхнем углу он читался как случайная кнопка.
            ModeSwitch(screen: $screen, back: $lastAppScreen)
                .padding(.horizontal, 4).padding(.bottom, 16)

            if screen == .chat || screen == .privacy {
                NavButton(title: "Обезличивание", symbol: "lock.shield",
                          active: screen == .privacy, badge: nil) { screen = .privacy }
                    .padding(.bottom, 14)
                // В режиме чата «Записи» не нужны, а список переписок нужен
                // постоянно — он и занимает их место.
                ChatHistory(chat: chat, showsSelection: screen == .chat, onOpen: { screen = .chat })
            } else {
                VStack(spacing: 1) {
                    ForEach(items, id: \.1) { item in
                        NavButton(title: item.1, symbol: item.2,
                                  active: isActive(item.0),
                                  badge: item.0 == .speakers && !library.unknown.isEmpty
                                      ? library.unknown.count : nil) {
                            screen = item.0
                        }
                    }
                }
            }
            Spacer()
            // Главное обещание программы — видно всегда: записи и модели не
            // уходят с компьютера, а если чего-то не хватает, это тоже видно.
            HStack(spacing: 7) {
                Circle().fill(Paths.isReady ? p.ok : p.warn).frame(width: 7, height: 7)
                Text(Paths.isReady ? "Работает без интернета" : "Нужна установка")
                    .font(Kind.body(11.5)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10)
        }
        // Сверху — место под кнопки окна: полосы заголовка больше нет.
        .padding(.top, 44).padding(.bottom, 16).padding(.horizontal, 10)
        .frame(width: 224, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Стекло тонировано тёплым графитом. Чистый системный материал брал
        // цвет обоев: на синих обоях боковая панель становилась синей и
        // спорила с красной гаммой «Славатора 2». Сквозь тонировку обои
        // только угадываются, а при «Уменьшить прозрачность» система сама
        // делает стекло глухим.
        .background(ZStack {
            SidebarMaterial()
            p.sidebar.opacity(0.84)
        }.ignoresSafeArea())
    }

    private func isActive(_ target: Screen) -> Bool {
        if case .person = screen, target == .speakers { return true }
        if screen == .newVoices, target == .speakers { return true }
        return screen == target
    }

    private func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appending(path: "app_icon.png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Строка боковой панели по образцу системных: значок в цвете акцента,
/// текст обычного цвета, выбранная строка — серая подложка. Переход между
/// экранами мгновенный: его делают десятки раз в день.
private struct NavButton: View {
    @Environment(\.palette) private var p
    let title: String
    let symbol: String
    let active: Bool
    var badge: Int? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(p.accent2)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(p.text)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(p.muted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(active ? p.selection.opacity(1.4) : (hovering ? p.selection : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Общие мелочи экранов

struct ScreenTitle: View {
    @Environment(\.palette) private var p
    let text: String
    var body: some View {
        // Крупный кегль — плотнее трекинг: так буквы не рассыпаются.
        Text(text).font(Kind.title(26)).kerning(-0.5).foregroundStyle(p.text)
            .padding(.bottom, 4)
    }
}

struct Eyebrow: View {
    @Environment(\.palette) private var p
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Kind.eyebrow()).tracking(0.9)
            .foregroundStyle(p.faint)
    }
}

struct BackButton: View {
    @Environment(\.palette) private var p
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(Kind.body(13))
            }
            .foregroundStyle(p.muted)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

/// Круглая кнопка воспроизведения.
struct PlayDot: View {
    @Environment(\.palette) private var p
    var size: CGFloat = 34
    var playing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Нейтральная: красный оставлен записи и главному действию, а
            // кнопок «послушать» на экране бывает десяток.
            ZStack {
                Circle().fill(p.selection.opacity(1.5)).frame(width: size, height: size)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(p.text)
                    .offset(x: playing ? 0 : size * 0.03)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Приостановить воспроизведение" : "Воспроизвести образец")
    }
}

struct Avatar: View {
    let text: String
    let colour: Color
    var size: CGFloat = 38
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29)
            .fill(colour)
            .frame(width: size, height: size)
            .overlay(Text(text)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white))
    }
}

struct RowBox<Content: View>: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 13) { content }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? p.selection : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
