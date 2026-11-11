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
    var bg: Color        { color("bg", 0x12161D, 0xF6F7F9) }
    var sidebar: Color   { color("sidebar", 0x12161D, 0xF6F7F9) }
    var surface: Color   { color("surface", 0x1B2029, 0xFFFFFF) }
    var raised: Color    { color("raised", 0x252B36, 0xF1F3F6) }
    var row: Color       { color("row", 0x1B2029, 0xFFFFFF) }

    // MARK: границы
    var line: Color      { color("line", 0x323A46, 0xDCE1E8) }
    var line2: Color     { color("line2", 0x262D38, 0xE9ECF1) }

    // MARK: текст
    var text: Color      { color("text", 0xE8ECF2, 0x17212B) }
    var muted: Color     { color("muted", 0x9AA5B4, 0x586474) }
    var faint: Color     { color("faint", 0x8590A0, 0x6A7584) }

    // MARK: акцент и состояния
    var accent: Color    { color("accent", 0x3B6FE0, 0x2459D3) }
    var accent2: Color   { color("accent2", 0x8AABFF, 0x2459D3) }
    var accentSoft: Color { color("accentSoft", 0x1E2B45, 0xE9EFFC) }
    var ok: Color        { color("ok", 0x62D6AA, 0x187552) }
    var okBg: Color      { color("okBg", 0x183B32, 0xE2F3EB) }
    var warn: Color      { color("warn", 0xF4C770, 0x815C0E) }
    var warnBg: Color    { color("warnBg", 0x3B3120, 0xFCF0D8) }
    /// Ошибка и остановка записи: единственное место, где появляется красный.
    var error: Color     { color("error", 0xFF7A82, 0xB42B35) }

    /// Подложка выбранного: строка в боковой панели, сегмент переключателя.
    /// Полупрозрачная, как у системных списков Mac, поэтому одинаково ложится
    /// и на стекло боковой панели, и на фон окна.
    var selection: Color { self == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04) }

    /// Неопознанный голос намеренно бесцветный: он не человек, пока его не назвали.
    var unknown: Color   { color("unknown", 0x6D7787, 0x98A2B0) }

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
    /// Обычный текст «Светлого кабинета» — 14/20.
    static func body(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular) }
    static func strong(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .semibold) }
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
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
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
/// человека сразу. 0,97 и 100 мс с быстрым началом — мера из навыка
/// emil-design-eng: заметно пальцам, незаметно глазу. При «Уменьшить
/// движение» в Универсальном доступе сжатия нет.
struct Pressable: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduce ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// Главное действие экрана: белый текст на синем. Высота 34 pt — кнопку
/// легко попасть, и рядом с полем поиска она стоит вровень.
struct PrimaryButton: ButtonStyle {
    var wide = false
    /// Остановка записи и удаление — тот же вид, но цвета ошибки.
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(configuration: configuration, wide: wide, destructive: destructive)
    }
}

private struct PrimaryLabel: View {
    let configuration: ButtonStyleConfiguration
    let wide: Bool
    let destructive: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : p.faint)
            .padding(.horizontal, 14)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(enabled ? (destructive ? p.error : p.accent) : p.raised))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(enabled && hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .modifier(Pressable(pressed: configuration.isPressed && enabled))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Второстепенное действие: нейтральная поверхность, тёмный текст и
/// разделительная рамка — как «Импорт» в макете.
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
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(enabled ? p.text : p.faint)
            .padding(.horizontal, 13)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hovering && enabled ? p.raised : p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
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

/// Сегментированный выбор режима: выбранный сегмент — белая плашка с лёгкой
/// тенью и синим текстом на сером треке. Сплошная синяя заливка во всю
/// ширину спорила с главной кнопкой экрана: синего должно быть мало, тогда
/// оно и значит «действие».
/// Переключают его часто, поэтому заливка не ездит: по правилу частоты из
/// emil-design-eng такое не анимируют.
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
                        .font(.system(size: 13, weight: selection == value ? .semibold : .medium))
                        .lineLimit(1).layoutPriority(1)
                        .foregroundStyle(selection == value ? p.accent2 : p.muted)
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == value ? p.surface : .clear)
                            .shadow(color: .black.opacity(selection == value ? 0.10 : 0), radius: 1.5, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
    }
}

/// Белая панель на сером фоне окна: список встреч, встреча, переписки.
struct Panel<Content: View>: View {
    @Environment(\.palette) private var p
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(p == .dark ? 0 : 0.03), radius: 3, y: 1)
    }
}

/// Плашка «Локально и конфиденциально»: обещание программы, видимое там,
/// где речь о записях и ответах модели.
struct LocalBadge: View {
    @Environment(\.palette) private var p
    var text = "Локально и конфиденциально"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield").font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(p.ok)
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(p.okBg))
        .overlay(Capsule().stroke(p.ok.opacity(0.35), lineWidth: 1))
    }
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
