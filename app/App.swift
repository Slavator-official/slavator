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
    /// Что установлено, а чего не хватает. На уровне приложения, чтобы ответ
    /// ядра не спрашивался заново при каждом переходе по вкладкам.
    @State private var doctor = Doctor()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            Shell(library: library, player: player,
                  pipeline: pipeline, capture: capture,
                  dictation: dictation, chat: chat, doctor: doctor)
                .frame(minWidth: 1080, minHeight: 620)
                .onAppear {
                    library.reload()
                    // Диктовка придерживает разбор встречи: иначе она сама
                    // ползёт на загруженных ядрах.
                    dictation.onBusyChanged = { busy in pipeline.suspend(busy) }
                    dictation.refresh(settings: library.settings)
                    delegate.attach(dictation: dictation, capture: capture,
                                    pipeline: pipeline, library: library)
                }
                // Переключатели быстрого доступа действуют сразу: значок и
                // наблюдение за встречей включаются без перезапуска.
                .onChange(of: library.settings.menubar_enabled) { _, _ in
                    delegate.apply(settings: library.settings)
                }
                .onChange(of: library.settings.meeting_watch_enabled) { _, _ in
                    delegate.apply(settings: library.settings)
                }
                .onChange(of: library.settings.widget_enabled) { _, _ in
                    delegate.apply(settings: library.settings)
                }
                .onChange(of: library.settings.widget_size) { _, _ in
                    delegate.apply(settings: library.settings)
                }
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

enum Screen: Hashable {
    case main, records, speakers, newVoices, settings, chat
    case person(String)
}

/// Остановить запись и отдать её в обработку.
///
/// Одна дорога для всех кнопок остановки — главного экрана, строки меню и
/// виджета. Свой вариант у каждой кнопки неминуемо разъехался бы в мелочах:
/// где-то забыли убрать слишком короткую запись, где-то не дождались
/// сведения дорожек.
@discardableResult
func stopAndProcess(capture: LiveCapture, pipeline: Pipeline, library: Library) -> URL? {
    guard let url = capture.stop() else { return nil }
    if capture.seconds < 3 {
        try? FileManager.default.removeItem(at: url)
        showAlert("Слишком короткая запись", "Записано меньше трёх секунд — обрабатывать нечего.")
        return nil
    }
    // Дорожки уже сведены в один файл при остановке. Отдельной дорожкой
    // микрофон больше не уходит: это стоило второго прохода распознавания —
    // на встрече в двадцать минут лишние полчаса ожидания.
    pipeline.run(input: url, library: library)
    return url
}

/// Значок в строке меню и предложение записать начавшуюся встречу.
///
/// Сделано на AppKit намеренно: MenuBarExtra из SwiftUI тянет символы,
/// которых нет в macOS 14, а приложение обязано там работать.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
    private var item: NSStatusItem?
    private weak var dictation: Dictation?
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
                pipeline: Pipeline, library: Library) {
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
        menu.addItem(note("Держите правый ⌥ — говорите"))
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
        guard let capture, let library, !capture.isRecording else { return }
        capture.start(source: .meeting,
                      folder: URL(fileURLWithPath: library.settings.recordingsFolder))
        openApp()
    }

    @objc private func stopListening() {
        guard let capture, let pipeline, let library else { return }
        stopAndProcess(capture: capture, pipeline: pipeline, library: library)
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
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
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
    var doctor: Doctor
    @State private var screen: Screen = .main
    /// Куда вернуться из чата.
    @State private var lastAppScreen: Screen = .main

    private var palette: Palette { library.palette }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, screen: $screen,
                    lastAppScreen: $lastAppScreen, chat: chat)
            Divider().overlay(palette.line2)

            VStack(spacing: 0) {
                // Чат живёт вне общей прокрутки: внутри неё высота не
                // задаётся, и экран обрывался на середине окна.
                if screen == .chat {
                    ChatScreen(library: library, chat: chat)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                } else {
                ScrollView {
                    Group {
                        switch screen {
                        case .main:      MainScreen(library: library, player: player,
                                                    pipeline: pipeline, capture: capture,
                                                    doctor: doctor, screen: $screen)
                        case .records:   RecordsScreen(library: library, player: player,
                                                      pipeline: pipeline, screen: $screen)
                        case .speakers:  SpeakersScreen(library: library, player: player, screen: $screen)
                        case .newVoices: NewVoicesScreen(library: library, player: player)
                        // Чат нарисован выше, вне прокрутки. Ветка нужна
                        // только чтобы перечисление было исчерпано.
                        case .chat:      EmptyView()
                        case .settings:  SettingsScreen(library: library, dictation: dictation)
                        case .person(let key): PersonScreen(library: library, player: player,
                                                            key: key, screen: $screen)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                }

                if player.isActive {
                    PlayerBar(player: player)
                        .transition(.move(edge: .bottom))
                }
            }
            .background(palette.bg)
        }
        .environment(\.palette, palette)
        // Тему держим в двух местах сразу: SwiftUI слушает эту строку, а
        // AppKit — NSApp.appearance. Иначе стандартные элементы остаются в
        // теме системы, а не приложения.
        .preferredColorScheme(library.settings.theme == "system"
                              ? nil : (palette == .dark ? .dark : .light))
        .onAppear { applyAppearance(library.settings.theme) }
        .onChange(of: library.settings.theme) { _, chosen in
            applyAppearance(chosen)
        }
        .animation(.easeOut(duration: 0.18), value: player.isActive)
        .background(palette.bg)
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
         (.records, "Записи", "clock"),
         (.speakers, "Спикеры", "person"),
         (.settings, "Настройки", "gearshape")]
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
                                  ? library.unknown.count : nil) {
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
