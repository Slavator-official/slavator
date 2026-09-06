import AppKit
import SwiftUI

/// Виджет на рабочем столе: начать запись, не открывая программу.
///
/// Это окно, а не расширение WidgetKit. Настоящий виджет живёт в песочнице и
/// делит состояние с программой через App Group, а тот требует Team ID от
/// Apple Developer — у самодельной подписи его нет, и живой таймер записи в
/// таком виджете показать невозможно. Окно на уровне рабочего стола ведёт
/// себя так же (лежит под окнами, видно на всех рабочих столах), но знает о
/// записи всё и работает без сертификата.
final class DeskWidget: NSPanel, NSWindowDelegate {

    private static let place = "ru.slavator.widget.origin"

    init(library: Library, capture: LiveCapture, pipeline: Pipeline) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 212, height: 86),
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

        let view = DeskWidgetView(library: library, capture: capture, pipeline: pipeline)
        contentView = NSHostingView(rootView: view)
        restorePlace()
    }

    /// Место виджета запоминается: перетащил один раз — и он там остаётся.
    private func restorePlace() {
        let saved = UserDefaults.standard.string(forKey: Self.place)
        let point = saved.map(NSPointFromString)
        if let point, NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
            setFrameOrigin(point)
        } else if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 28,
                                   y: screen.maxY - frame.height - 28))
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.place)
    }

    /// Безрамочная панель по умолчанию не становится ключевой, и кнопки в
    /// ней срабатывают только со второго щелчка. Главной она при этом не
    /// становится: nonactivatingPanel не выводит программу вперёд.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() { orderFrontRegardless() }
}

private struct DeskWidgetView: View {
    @Bindable var library: Library
    var capture: LiveCapture
    var pipeline: Pipeline
    @State private var source = "sys"
    @State private var pulse = false

    private var p: Palette { library.palette }

    var body: some View {
        // Ровно две строки: выбор источника и действие. Ни заголовка, ни
        // пояснения — на рабочем столе виджет соседствует с обоями и чужими
        // значками, и каждая лишняя строка там дороже, чем в окне. Что делает
        // кнопка, сказано на самой кнопке.
        VStack(spacing: 7) {
            if capture.isRecording { recording } else { idle }
        }
        .padding(9)
        .frame(width: 212, height: 86)
        .background(p.surface)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.palette, p)
    }

    @ViewBuilder private var idle: some View {
        // «Только микрофон» ужато до «Микрофона»: в две колонки такой ширины
        // длинная подпись сжимает соседнюю.
        Segmented(options: [("sys", "Звонок"), ("mic", "Микрофон")],
                  selection: $source, compact: true)
        Button(capture.failure == nil ? "Начать слушать" : "Повторить") {
            capture.start(source: source == "mic" ? .microphone : .meeting,
                          folder: URL(fileURLWithPath: library.settings.results_dir))
        }
        .buttonStyle(PrimaryButton(wide: true))
        // Причину отказа целиком показывает окно: здесь для неё нет места, а
        // обрезанная на полуслове ошибка хуже её отсутствия.
        .help(capture.failure ?? "")
    }

    @ViewBuilder private var recording: some View {
        HStack(spacing: 8) {
            Circle().fill(p.warn).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulse)
            Text(clock).font(.system(size: 17, weight: .semibold))
                .monospacedDigit().foregroundStyle(p.text)
            Spacer(minLength: 0)
            Text(source == "mic" ? "микрофон" : "звонок")
                .font(Kind.body(11)).foregroundStyle(p.muted)
        }
        .frame(height: 31)
        .onAppear { pulse = true }
        Button("Остановить") {
            stopAndProcess(capture: capture, pipeline: pipeline, library: library)
        }
        .buttonStyle(QuietButton(wide: true))
    }

    private var clock: String {
        let total = Int(capture.seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
