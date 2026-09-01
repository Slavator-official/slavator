import SwiftUI

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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            Shell(library: library, player: player,
                  pipeline: pipeline, capture: capture, dictation: dictation)
                .frame(minWidth: 1080, minHeight: 620)
                .onAppear {
                    library.reload()
                    // Диктовка придерживает разбор встречи: иначе она сама
                    // ползёт на загруженных ядрах.
                    dictation.onBusyChanged = { busy in pipeline.suspend(busy) }
                    dictation.refresh(settings: library.settings)
                    delegate.attach(dictation: dictation)
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
    case main, records, speakers, newVoices, settings
    case person(String)
}

/// Значок в строке меню. Сделан на AppKit намеренно: MenuBarExtra из SwiftUI
/// тянет символы, которых нет в macOS 14, а приложение обязано там работать.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private weak var dictation: Dictation?

    func attach(dictation: Dictation) {
        self.dictation = dictation
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Славатор")
        status.button?.image?.isTemplate = true
        status.menu = buildMenu()
        item = status
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "Держите правый ⌥ — говорите", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Открыть Славатор", action: #selector(openApp), keyEquivalent: "0"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.items.forEach { $0.target = $0.action == #selector(openApp) ? self : $0.target }
        return menu
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

struct Shell: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var dictation: Dictation
    @State private var screen: Screen = .main

    private var palette: Palette { library.palette }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, screen: $screen)
            Divider().overlay(palette.line2)

            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch screen {
                        case .main:      MainScreen(library: library, player: player,
                                                    pipeline: pipeline, capture: capture,
                                                    screen: $screen)
                        case .records:   RecordsScreen(library: library, player: player,
                                                      pipeline: pipeline, screen: $screen)
                        case .speakers:  SpeakersScreen(library: library, player: player, screen: $screen)
                        case .newVoices: NewVoicesScreen(library: library, player: player)
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

                if player.isActive {
                    PlayerBar(player: player)
                        .transition(.move(edge: .bottom))
                }
            }
            .background(palette.bg)
        }
        .environment(\.palette, palette)
        .animation(.easeOut(duration: 0.18), value: player.isActive)
        .background(palette.bg)
    }
}

struct Sidebar: View {
    @Bindable var library: Library
    @Binding var screen: Screen
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
            }
            .padding(.horizontal, 10).padding(.bottom, 22)

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
