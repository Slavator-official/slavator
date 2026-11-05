import SwiftUI

func applyAppearance(_ theme: String) {
    NSApp.appearance = theme == "system" ? nil : NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
}

/// Основные роли приходят из общего desktop_contract.json для Mac и Windows.
/// Локальные значения — запасной вариант при отсутствии ресурса в сборке.
enum Palette {
    case dark, light

    private var tokens: [String: Any] { DesktopContract.theme(self == .dark ? "dark" : "light") }
    private func color(_ key: String, _ dark: UInt32, _ light: UInt32) -> Color {
        .hex((tokens[key] as? String).flatMap { UInt32($0, radix: 16) } ?? (self == .dark ? dark : light))
    }

    // MARK: поверхности
    var bg: Color        { color("bg", 0x1D1A1A, 0xFBFAF9) }
    var sidebar: Color   { color("sidebar", 0x1A1717, 0xF4EFED) }
    var surface: Color   { color("surface", 0x262222, 0xFFFFFF) }
    var raised: Color    { color("raised", 0x312B2A, 0xF2EEEC) }
    var row: Color       { color("row", 0x231F1F, 0xFFFFFF) }

    // MARK: границы
    var line: Color      { color("line", 0x3D3533, 0xE2DAD7) }
    var line2: Color     { color("line2", 0x2E2827, 0xEEE8E6) }

    // MARK: текст
    var text: Color      { color("text", 0xF3EEED, 0x1F1A19) }
    var muted: Color     { color("muted", 0xACA19E, 0x6C6361) }
    var faint: Color     { color("faint", 0x857B78, 0x8A817E) }

    // MARK: акцент и состояния
    var accent: Color    { color("accent", 0xE5483C, 0xD23A2F) }
    var accent2: Color   { color("accent2", 0xFF7A6E, 0xBF3329) }
    var accentSoft: Color { color("accentSoft", 0x3B2422, 0xFBE8E6) }
    var ok: Color        { color("ok", 0x62D6AA, 0x187552) }
    var okBg: Color      { color("okBg", 0x183B32, 0xE2F3EB) }
    var warn: Color      { color("warn", 0xF4C770, 0x815C0E) }
    var warnBg: Color    { color("warnBg", 0x3B3120, 0xFCF0D8) }

    /// Подложка выбранного: строка в боковой панели, сегмент переключателя.
    /// Полупрозрачная, как у системных списков Mac, поэтому одинаково ложится
    /// и на стекло боковой панели, и на фон окна.
    var selection: Color { self == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    /// Выбранный сегмент: в светлой теме — белая плашка, в тёмной — светлее фона.
    var segment: Color { self == .dark ? Color.white.opacity(0.16) : Color.white }

    /// Неопознанный голос намеренно бесцветный: он не человек, пока его не назвали.
    var unknown: Color   { color("unknown", 0x7A7270, 0x8E8A88) }

    /// Цвет как идентичность человека, а не украшение: по нему он узнаётся
    /// на голосовой ленте встречи.
    /// Цвета говорящих. Раздаются по порядку, поэтому первыми идут самые
    /// несхожие: на большинстве встреч дальше четвёртого-пятого не доходит.
    ///
    /// Шести не хватало: на восьми голосах седьмой получал цвет первого, и на
    /// ленте два разных человека выглядели одинаково.
    var speakers: [Color] {
        if let values = tokens["speakers"] as? [String], !values.isEmpty {
            let colors = values.compactMap { UInt32($0, radix: 16).map(Color.hex) }
            if !colors.isEmpty { return colors }
        }
        return self == .dark
            ? [.hex(0xE0A33C), .hex(0x35A9A0), .hex(0x8E7DE8),
               .hex(0xE0705F), .hex(0x56B37F), .hex(0x7B96C4),
               .hex(0xD97BA8), .hex(0x9AAF3E), .hex(0x4FA3D9), .hex(0xBE9A6E)]
            : [.hex(0xC7862A), .hex(0x1E8F87), .hex(0x6F5FD0),
               .hex(0xCB5647), .hex(0x3E9866), .hex(0x5C7CAC),
               .hex(0xB85C8A), .hex(0x74872A), .hex(0x2E82B5), .hex(0x8F6E45)]
    }
}

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue:  Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Типографика

/// Прототип набран Unbounded и Golos Text. В macOS их нет, а тащить
/// веб-шрифты в нативное приложение неправильно: системная гарнитура здесь
/// уместнее и выглядит лучше. Иерархия размеров и насыщенностей сохранена.
enum Kind {
    /// Заголовки полужирные, а не жирные: так набирает сама macOS. Плотный
    /// трекинг крупным кеглям даёт ScreenTitle (.kerning) — у Font его нет.
    static func title(_ size: CGFloat = 25) -> Font { .system(size: size, weight: .semibold, design: .default) }
    static func head(_ size: CGFloat = 16) -> Font  { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 13.5) -> Font { .system(size: size, weight: .regular) }
    static func strong(_ size: CGFloat = 13.5) -> Font { .system(size: size, weight: .semibold) }
    /// Тайм-коды и длительности: цифры обязаны стоять в колонку.
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
    static func eyebrow() -> Font { .system(size: 10.5, weight: .semibold) }
}

// MARK: - Общие элементы

/// Карточка — основной контейнер интерфейса.
struct Card<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 18
    /// Растянуть по высоте до соседей в ряду. Карточки разной высоты рядом
    /// читаются как небрежность, а высоту задаёт та, где содержимого больше.
    var fill = false
    @ViewBuilder var content: Content

    var body: some View {
        // Содержимое обязательно в стеке: без него несколько элементов из
        // ViewBuilder раскладывает родитель, и одна карточка распадается на
        // несколько.
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil,
                   alignment: fill ? .topLeading : .leading)
            .background(p.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Плашка состояния: «Готово», «2 новых голоса».
struct Pill: View {
    let text: String
    var fg: Color
    var bg: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }
}

/// Отклик на нажатие: кнопка чуть сжимается, пока её держат.
///
/// Отвечать нужно на нажатие, а не на отпускание: так интерфейс слышит
/// человека сразу. 0,97 и 120 мс с быстрым началом — мера из навыка
/// emil-design-eng: заметно пальцам, незаметно глазу. При «Уменьшить
/// движение» в Универсальном доступе сжатия нет.
struct Pressable: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduce ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// Главное действие экрана. Красное — цвет записи и аватарки «Славатора 2»;
/// на экране такая кнопка одна.
struct PrimaryButton: ButtonStyle {
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(configuration: configuration, wide: wide)
    }
}

private struct PrimaryLabel: View {
    let configuration: ButtonStyleConfiguration
    let wide: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : p.faint)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(enabled ? p.accent : p.raised))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(enabled && hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .modifier(Pressable(pressed: configuration.isPressed && enabled))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Второстепенное действие: нейтральная плашка без рамки, как у системных
/// кнопок Mac. Рамка у каждой кнопки дробила экран на мелкие коробочки.
struct QuietButton: ButtonStyle {
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, wide: wide)
    }
}

private struct QuietLabel: View {
    let configuration: ButtonStyleConfiguration
    let wide: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? p.text : p.faint)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hovering && enabled ? p.selection.opacity(1.6) : p.selection))
            .contentShape(Rectangle())
            .modifier(Pressable(pressed: configuration.isPressed && enabled))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Ссылка внутри текста: красная, без подложки.
struct LinkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }
}

private struct LinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? p.accent2 : p.faint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Сегментированный переключатель: тема, источник звука, движок.
///
/// Выбранный сегмент — светлая плашка на сером, как у системного
/// переключателя Mac. Переключают его часто, поэтому плашка не ездит:
/// по правилу частоты из emil-design-eng такое не анимируют.
struct Segmented<T: Hashable>: View {
    @Environment(\.palette) private var p
    let options: [(T, String)]
    @Binding var selection: T
    /// Ужатые поля по бокам — для виджета, где ширина считана по пикселям и
    /// обычные отступы съедают подпись до многоточия.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(.system(size: 12.5, weight: selection == value ? .semibold : .medium))
                        .lineLimit(1).layoutPriority(1)
                        .foregroundStyle(selection == value ? p.text : p.muted)
                        .padding(.horizontal, compact ? 7 : 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == value ? p.segment : .clear)
                            .shadow(color: .black.opacity(selection == value ? 0.12 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.selection))
    }
}

/// Материал боковой панели — настоящее стекло Mac, через которое просвечивают
/// обои. Так боковая панель читается отдельным, более тяжёлым слоем, как
/// в Finder и Почте, а не ещё одним прямоугольником того же цвета
/// (apple-design: материалы задают иерархию).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Палитра через окружение

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
