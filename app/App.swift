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
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 800)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

extension Edition {
    /// Тестовая уступает основной: пока та запущена, у тестовой нет ни
    /// диктовки, ни виджета, ни значка в меню, ни слежения за встречами.
    /// Иначе одно нажатие ⌥ поднимало две плашки и печатало текст дважды,
    /// а тестовая предлагала записать встречу, едва основная брала микрофон.
    /// Значение задаётся при первом обращении и дальше меняется AppDelegate
    /// по запуску и закрытию основной.
    static var yielding = isDev
        && !NSRunningApplication.runningApplications(withBundleIdentifier: stableID).isEmpty
}

enum Screen: Hashable {
    case main, memory, records, speakers, newVoices, settings, chat
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
        AppConfiguration.protectPrivateFolders()
        if Edition.isDev { followStable() }
        Task {
            if await OllamaServer.start() == .started {
                NotificationCenter.default.post(name: OllamaServer.started, object: nil)
            }
        }
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
        let own = !Edition.yielding
        if own && settings.menubar_enabled { addItem() } else { removeItem() }
        if own && settings.meeting_watch_enabled { watch.start() } else { watch.stop() }
        if own && settings.widget_enabled { addWidget(size: settings.widget_size) } else { removeWidget() }
    }

    /// Тестовая сборка следит за основной: та запустилась — всё фоновое
    /// выключается, закрылась — возвращается по настройкам.
    private func followStable() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Edition.stableID else { return }
                Edition.yielding = running
                guard let self, let library = self.library else { return }
                self.apply(settings: library.settings)
                self.dictation?.refresh(settings: library.settings)
            }
        }
    }

    // MARK: значок

    private func addItem() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "mic.fill",
                                       accessibilityDescription: "Славатор")
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

    private var inChat: Bool { screen == .chat }

    var body: some View {
        HStack(spacing: 3) {
            button(symbol: "waveform", active: !inChat, hint: "Славатор") {
                if inChat { screen = back }
            }
            button(symbol: "bubble.left.and.bubble.right", active: inChat, hint: "Чат с моделью") {
                if !inChat { back = screen; screen = .chat }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.line2, lineWidth: 1))
    }

    private func button(symbol: String, active: Bool, hint: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(hint == "Славатор" ? "Встречи" : "Чат", systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.white : p.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(active ? p.accent : Color.clear))
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
    @State private var screen: Screen = .main
    /// Куда вернуться из чата.
    @State private var lastAppScreen: Screen = .main
    @State private var picked: URL?
    @Environment(\.colorScheme) private var systemScheme

    private var palette: Palette {
        library.settings.theme == "system" ? (systemScheme == .dark ? .dark : .light) : library.palette
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, screen: $screen,
                    lastAppScreen: $lastAppScreen, chat: chat)
            Divider().overlay(palette.line2)

            VStack(spacing: 0) {
                // Чат живёт вне общей прокрутки: внутри неё высота не
                // задаётся, и экран обрывался на середине окна.
                if screen == .chat {
                    ChatScreen(library: library, chat: chat, memory: memory, player: player)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                } else {
                ScrollView {
                    Group {
                        switch screen {
                        case .main:      MainScreen(library: library, player: player,
                                                    pipeline: pipeline, capture: capture,
                                                    doctor: doctor, picked: $picked,
                                                    screen: $screen)
                        case .records:   RecordsScreen(library: library, player: player,
                                                      pipeline: pipeline, memory: memory, screen: $screen)
                        case .memory:    MemoryScreen(library: library, player: player, memory: memory)
                        case .speakers:  SpeakerProfilesScreen(library: library, player: player,
                                                               screen: $screen)
                        case .newVoices: NewVoicesScreen(library: library, player: player)
                        // Чат нарисован выше, вне прокрутки. Ветка нужна
                        // только чтобы перечисление было исчерпано.
                        case .chat:      EmptyView()
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

                if capture.isRecording || pipeline.isRunning {
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
        .onAppear { applyAppearance(library.settings.theme) }
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
                    Image(systemName: "record.circle.fill").foregroundStyle(Color.hex(0xE0705F))
                    Text("Идёт запись").font(Kind.strong())
                    Text(hms(capture.seconds)).font(Kind.mono()).foregroundStyle(palette.muted)
                    if capture.micSilent {
                        Label("микрофон молчит", systemImage: "mic.slash")
                            .font(Kind.body(12.5)).foregroundStyle(palette.warn)
                    }
                    Spacer()
                    Button("Остановить и обработать") {
                        picked = finishMeeting(capture: capture, pipeline: pipeline, library: library)
                    }.buttonStyle(QuietButton())
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
                    Text("\(Int(pipeline.percent))% ").font(Kind.mono())
                    Button(pipeline.isCancelling ? "Останавливаю…" : "Прервать") { pipeline.cancel() }
                        .buttonStyle(QuietButton()).disabled(pipeline.isCancelling)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(palette.line2).frame(height: 1) }
    }
}

struct Sidebar: View {
    @Bindable var library: Library
    @Binding var screen: Screen
    @Binding var lastAppScreen: Screen
    var chat: Chat
    @Environment(\.palette) private var p

    private var items: [(Screen, String, String)] {
        [(.main, "Главная", "house"),
         (.memory, "Память встреч", "brain"),
         (.records, "Записи", "clock"),
         (.speakers, "Спикеры", "person"),
         (.settings, "Настройки", "gearshape")]
            .filter { $0.0 != .memory || Edition.hasMemory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NSImage(named: "AppIcon") ?? bundledIcon() {
                    Image(nsImage: icon)
                        .resizable().frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                Text("Славатор").font(Kind.title(19))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.bottom, 12)

            // Переключатель режимов стоит здесь, у названия: это выбор
            // «чем сейчас занимаемся», а не действие внутри экрана, и в
            // правом верхнем углу он читался как случайная кнопка.
            ModeSwitch(screen: $screen, back: $lastAppScreen)
                .padding(.horizontal, 10).padding(.bottom, 18)

            if screen == .chat {
                // В режиме чата «Главная» и «Записи» не нужны, а список
                // переписок нужен постоянно — он и занимает их место.
                ChatHistory(chat: chat)
            } else {
            VStack(spacing: 2) {
                ForEach(items, id: \.1) { item in
                    NavButton(title: item.1, symbol: item.2,
                              active: isActive(item.0),
                              badge: item.0 == .speakers && !library.unknown.isEmpty
                                  ? library.unknown.count : nil,
                              // Число — это новые голоса, и нажатие на него ведёт
                              // прямо к ним, минуя список спикеров.
                              badgeAction: { screen = .newVoices }) {
                        screen = item.0
                    }
                }
            }
            }
            Spacer()
        }
        .padding(.vertical, 22).padding(.horizontal, 12)
        .frame(width: 224, alignment: .leading)
        .background(p.sidebar)
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

private struct NavButton: View {
    @Environment(\.palette) private var p
    let title: String
    let symbol: String
    let active: Bool
    var badge: Int? = nil
    var badgeAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18)
                Text(title).font(.system(size: 14, weight: active ? .semibold : .regular))
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p == .dark ? Color.hex(0x241A02) : .white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(p.warn))
                        .contentShape(Capsule())
                        .highPriorityGesture(TapGesture().onEnded { (badgeAction ?? action)() })
                        .help("Открыть новые голоса")
                }
            }
            .foregroundStyle(active ? p.text : p.muted)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? p.accentSoft : (hovering ? p.raised : .clear)))
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
        Text(text).font(Kind.title(24)).foregroundStyle(p.text)
            .padding(.bottom, 18)
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
            ZStack {
                Circle().fill(p.accent).frame(width: size, height: size)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
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
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? p.raised : p.row)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(hovering ? p.line : p.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
