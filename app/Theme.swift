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
    var bg: Color        { color("bg", 0x0D1420, 0xF3F5F9) }
    var sidebar: Color   { color("sidebar", 0x101A29, 0xFFFFFF) }
    var surface: Color   { color("surface", 0x141F30, 0xFFFFFF) }
    var raised: Color    { color("raised", 0x1B293D, 0xEDF1F7) }
    var row: Color       { color("row", 0x172438, 0xF7F9FC) }

    // MARK: границы
    var line: Color      { color("line", 0x32445C, 0xCAD4E2) }
    var line2: Color     { color("line2", 0x26364C, 0xDFE5EE) }

    // MARK: текст
    var text: Color      { color("text", 0xF2F5FA, 0x17263B) }
    var muted: Color     { color("muted", 0xA7B4C7, 0x53647A) }
    var faint: Color     { color("faint", 0x899BB2, 0x63748B) }

    // MARK: акцент и состояния
    var accent: Color    { color("accent", 0x2F6FF5, 0x2F6FF5) }
    var accent2: Color   { color("accent2", 0x7AABFF, 0x245CCD) }
    var accentSoft: Color { color("accentSoft", 0x20385C, 0xE8EFFF) }
    var ok: Color        { color("ok", 0x62D6AA, 0x187552) }
    var okBg: Color      { color("okBg", 0x183B32, 0xE2F3EB) }
    var warn: Color      { color("warn", 0xF4C770, 0x815C0E) }
    var warnBg: Color    { color("warnBg", 0x3B3120, 0xFCF0D8) }

    /// Неопознанный голос намеренно бесцветный: он не человек, пока его не назвали.
    var unknown: Color   { color("unknown", 0x667D9B, 0x778AA4) }

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
    static func title(_ size: CGFloat = 25) -> Font { .system(size: size, weight: .bold, design: .default) }
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
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(p.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 13))
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

struct PrimaryButton: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : p.faint)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(enabled ? (configuration.isPressed ? p.accent.opacity(0.85) : p.accent) : p.raised))
            .contentShape(Rectangle())
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? p.text : p.faint)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 9).fill(p.raised))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(configuration.isPressed ? p.accent : p.line, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Сегментированный переключатель: тема, источник звука, движок.
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
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).layoutPriority(1)
                        .foregroundStyle(selection == value ? .white : p.muted)
                        .padding(.horizontal, compact ? 7 : 9).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == value ? p.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.raised))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.line, lineWidth: 1))
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
