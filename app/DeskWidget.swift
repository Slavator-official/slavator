import AppKit
import SwiftUI

/// Размер виджета на рабочем столе.
///
/// Три ступени, а не плавная шкала: каждая — своя раскладка, а не то же
/// самое, растянутое мышью. Растягивание дало бы разъехавшиеся поля и
/// подписи, а выбор из трёх продуманных видов — предсказуемый результат.
enum WidgetSize: String {
    case small, medium, large

    static func named(_ value: String) -> WidgetSize {
        WidgetSize(rawValue: value) ?? .medium
    }

    var size: NSSize {
        switch self {
        case .small:  return NSSize(width: 196, height: 46)
        case .medium: return NSSize(width: 212, height: 86)
        case .large:  return NSSize(width: 326, height: 188)
        }
    }

    var padding: CGFloat {
        switch self {
        case .small:  return 8
        case .medium: return 9
        case .large:  return 16
        }
    }

    var corner: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 14
        case .large:  return 16
        }
    }
}

/// Виджет на рабочем столе: начать запись, не открывая программу.
///
/// Это окно, а не расширение WidgetKit. Настоящий виджет живёт в песочнице и
/// делит состояние с программой через App Group, а тот требует Team ID от
/// Apple Developer — у самодельной подписи его нет, и живой таймер записи в
/// таком виджете показать нечем. Окно на уровне рабочего стола ведёт себя так
/// же (лежит под окнами, видно на всех рабочих столах), но знает о записи всё
/// и работает без сертификата.
final class DeskWidget: NSPanel, NSWindowDelegate {

    private static let place = "ru.slavator.widget.origin"

    init(library: Library, capture: LiveCapture, pipeline: Pipeline) {
        let kind = WidgetSize.named(library.settings.widget_size)
        super.init(contentRect: NSRect(origin: .zero, size: kind.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Под окнами, но над значками рабочего стола — там же, где живут
        // системные виджеты. Поверх всего висело бы поперёк работы.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        delegate = self

        let view = DeskWidgetView(library: library, capture: capture,
                                  pipeline: pipeline, kind: kind)
        contentView = NSHostingView(rootView: view)
        restorePlace(size: kind.size)
    }

    /// Место виджета запоминается: перетащил один раз — и он там остаётся.
    /// При смене размера сохранённая точка — по-прежнему левый нижний угол,
    /// поэтому виджет растёт вверх и вправо, не убегая из-под курсора.
    private func restorePlace(size: NSSize) {
        let saved = UserDefaults.standard.string(forKey: Self.place).map(NSPointFromString)
        if let saved, NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
            setFrameOrigin(saved)
        } else if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - size.width - 28,
                                   y: screen.maxY - size.height - 28))
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.place)
    }

    /// Безрамочная панель по умолчанию не становится ключевой, и кнопки в ней
    /// срабатывают только со второго щелчка. Главной она при этом не
    /// становится: nonactivatingPanel не выводит программу вперёд.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() { orderFrontRegardless() }
}

private struct DeskWidgetView: View {
    @Bindable var library: Library
    var capture: LiveCapture
    var pipeline: Pipeline
    let kind: WidgetSize
    @State private var source = "sys"
    @State private var pulse = false

    private var p: Palette { library.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: kind == .large ? 0 : 7) {
            switch (kind, capture.isRecording) {
            case (.small, false):  smallIdle
            case (.small, true):   smallRecording
            case (.large, false):  largeIdle
            case (.large, true):   largeRecording
            case (_, false):       idle
            case (_, true):        recording
            }
        }
        .padding(kind.padding)
        .frame(width: kind.size.width, height: kind.size.height,
               alignment: kind == .large ? .topLeading : .center)
        .background(p.surface)
        .overlay(RoundedRectangle(cornerRadius: kind.corner).stroke(p.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: kind.corner))
        .environment(\.palette, p)
    }

    // MARK: маленький — одна кнопка

    /// Выбора источника здесь нет: на одну строку он не встаёт. Пишется
    /// звонок — то, ради чего виджет и заводят; «только микрофон» остаётся
    /// в размерах побольше и в самой программе.
    private var smallIdle: some View {
        Button("Начать слушать") { start(microphone: false) }
            .buttonStyle(PrimaryButton(wide: true))
    }

    private var smallRecording: some View {
        HStack(spacing: 8) {
            dot
            Text(clock).font(.system(size: 15, weight: .semibold))
                .monospacedDigit().foregroundStyle(p.text)
            Spacer(minLength: 0)
            Button("Стоп") { stop() }.buttonStyle(QuietButton())
        }
    }

    // MARK: средний — источник и действие

    @ViewBuilder private var idle: some View {
        // «Только микрофон» ужато до «Микрофона»: в две колонки такой ширины
        // длинная подпись сжимает соседнюю.
        Segmented(options: [("sys", "Звонок"), ("mic", "Микрофон")],
                  selection: $source, compact: true)
        Button(capture.failure == nil ? "Начать слушать" : "Повторить") {
            start(microphone: source == "mic")
        }
        .buttonStyle(PrimaryButton(wide: true))
        // Причину отказа целиком показывает окно: здесь для неё нет места, а
        // обрезанная на полуслове ошибка хуже её отсутствия.
        .help(capture.failure ?? "")
    }

    @ViewBuilder private var recording: some View {
        HStack(spacing: 8) {
            dot
            Text(clock).font(.system(size: 17, weight: .semibold))
                .monospacedDigit().foregroundStyle(p.text)
            Spacer(minLength: 0)
            Text(source == "mic" ? "микрофон" : "звонок")
                .font(Kind.body(11)).foregroundStyle(p.muted)
        }
        .frame(height: 31)
        Button("Остановить") { stop() }.buttonStyle(QuietButton(wide: true))
    }

    // MARK: большой — с заголовком и пояснением

    private var largeIdle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .font(.system(size: 19)).foregroundStyle(p.accent2).frame(width: 26)
                Text("Слушать встречу").font(Kind.strong(14.5)).foregroundStyle(p.text)
                Spacer()
            }
            Segmented(options: [("sys", "Звонок"), ("mic", "Только микрофон")],
                      selection: $source)
                .padding(.top, 12)
            Text(source == "sys"
                 ? "Собеседников из динамиков и вас с микрофона"
                 : "Только микрофон — для встречи в одной комнате")
                .font(Kind.body(12)).foregroundStyle(p.muted)
                .padding(.top, 6)
            Spacer(minLength: 0)
            Button("Начать слушать") { start(microphone: source == "mic") }
                .buttonStyle(PrimaryButton(wide: true))
            if let failure = capture.failure {
                Text(failure).font(Kind.body(11)).foregroundStyle(p.warn)
                    .lineLimit(2).padding(.top, 8)
            }
        }
    }

    private var largeRecording: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                dot
                Text("Идёт запись").font(Kind.strong(14.5)).foregroundStyle(p.text)
                Spacer()
            }
            Text(clock).font(Kind.title(30)).foregroundStyle(p.text)
                .monospacedDigit().padding(.top, 8)
            Text(source == "mic" ? "Только микрофон" : "Звонок")
                .font(Kind.body(12)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
            Button("Остановить и обработать") { stop() }
                .buttonStyle(QuietButton(wide: true))
        }
    }

    // MARK: общее

    private var dot: some View {
        Circle().fill(p.warn).frame(width: 8, height: 8)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }
    }

    private func start(microphone: Bool) {
        capture.start(source: microphone ? .microphone : .meeting,
                      folder: URL(fileURLWithPath: library.settings.results_dir))
    }

    private func stop() {
        stopAndProcess(capture: capture, pipeline: pipeline, library: library)
    }

    private var clock: String {
        let total = Int(capture.seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
