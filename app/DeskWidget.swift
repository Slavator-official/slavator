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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 326, height: 188),
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
        VStack(alignment: .leading, spacing: 0) {
            if capture.isRecording { recording } else { idle }
        }
        .padding(16)
        .frame(width: 326, height: 188, alignment: .topLeading)
        .background(p.surface)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.palette, p)
    }

    private var idle: some View {
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
            Button("Начать слушать") {
                capture.start(source: source == "mic" ? .microphone : .meeting,
                              folder: URL(fileURLWithPath: library.settings.results_dir))
            }
            .buttonStyle(PrimaryButton(wide: true))
            if let failure = capture.failure {
                Text(failure).font(Kind.body(11)).foregroundStyle(p.warn)
                    .lineLimit(2).padding(.top, 8)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(p.warn).frame(width: 9, height: 9)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: pulse)
                Text("Идёт запись").font(Kind.strong(14.5)).foregroundStyle(p.text)
                Spacer()
            }
            Text(clock).font(Kind.title(30)).foregroundStyle(p.text)
                .monospacedDigit().padding(.top, 8)
            Text(source == "mic" ? "Только микрофон" : "Звонок")
                .font(Kind.body(12)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
            Button("Остановить и обработать") {
                stopAndProcess(capture: capture, pipeline: pipeline, library: library)
            }
            .buttonStyle(QuietButton(wide: true))
        }
        .onAppear { pulse = true }
    }

    private var clock: String {
        let total = Int(capture.seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
