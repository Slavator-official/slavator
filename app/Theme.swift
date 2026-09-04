import AppKit
import SwiftUI

/// Токены оформления. Значения перенесены один в один из веб-прототипа,
/// чтобы приложение и прототип были одним и тем же продуктом, а не
/// «похожими» вещами.
///
/// Светлая палитра пришла из дизайн-кита Cardbox; брендовые цвета Госуслуг
/// не используются. Тёмная — производная в тех же ролях.
enum Palette {
    case dark, light

    // MARK: поверхности
    var bg: Color        { self == .dark ? .hex(0x0A1420) : .hex(0xF4F6FA) }
    var sidebar: Color   { self == .dark ? .hex(0x0C1826) : .hex(0xFFFFFF) }
    var surface: Color   { self == .dark ? .hex(0x101E2E) : .hex(0xFFFFFF) }
    var raised: Color    { self == .dark ? .hex(0x16263A) : .hex(0xF8FAFD) }
    var row: Color       { self == .dark ? .hex(0x132339) : .hex(0xF8FAFD) }

    // MARK: границы
    var line: Color      { self == .dark ? .hex(0x1E3350) : .hex(0xE2E8F2) }
    var line2: Color     { self == .dark ? .hex(0x182A42) : .hex(0xEDF1F7) }

    // MARK: текст
    var text: Color      { self == .dark ? .hex(0xF2F6FC) : .hex(0x0B1F33) }
    var muted: Color     { self == .dark ? .hex(0x90A0B5) : .hex(0x63707F) }
    var faint: Color     { self == .dark ? .hex(0x63758C) : .hex(0x8794A3) }

    // MARK: акцент и состояния
    var accent: Color    { .hex(0x2F6FF5) }
    var accent2: Color   { self == .dark ? .hex(0x5590FF) : .hex(0x1D5DEB) }
    var accentSoft: Color { self == .dark ? .hex(0x16305A) : .hex(0xE3ECFD) }
    var ok: Color        { self == .dark ? .hex(0x19C37D) : .hex(0x12A06A) }
    var okBg: Color      { self == .dark ? .hex(0x10362A) : .hex(0xDCF4E6) }
    var warn: Color      { self == .dark ? .hex(0xF0B429) : .hex(0xA87200) }
    var warnBg: Color    { self == .dark ? .hex(0x382C10) : .hex(0xFDEFC9) }

    /// Неопознанный голос намеренно бесцветный: он не человек, пока его не назвали.
    var unknown: Color   { self == .dark ? .hex(0x4A5D75) : .hex(0xA9B6C6) }

    /// Цвет как идентичность человека, а не украшение: по нему он узнаётся
    /// на голосовой ленте встречи.
    /// Цвета говорящих. Раздаются по порядку, поэтому первыми идут самые
    /// несхожие: на большинстве встреч дальше четвёртого-пятого не доходит.
    ///
    /// Шести не хватало: на восьми голосах седьмой получал цвет первого, и на
    /// ленте два разных человека выглядели одинаково.
    var speakers: [Color] {
        self == .dark
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
    static func title(_ size: CGFloat = 25) -> Font { .system(size: size, weight: .heavy, design: .default) }
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
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(configuration.isPressed ? p.accent2 : p.accent))
            .contentShape(Rectangle())
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.palette) private var p
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(p.text)
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
                        .padding(.horizontal, 13).padding(.vertical, 5)
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

/// Сообщить системе, в какой теме мы рисуем.
///
/// Палитру приложение задаёт само, но цвет заголовков, полей ввода и кнопок
/// берётся из оформления системы — своего у них нет. Пока мы о выбранной теме
/// молчали, на светлой macOS тёмное окно получало чёрный текст на тёмном фоне
/// и белые поля посреди тёмных карточек.
func applyAppearance(_ theme: String) {
    switch theme {
    case "light":  NSApp.appearance = NSAppearance(named: .aqua)
    // «Авто» — это и есть «как в системе»: своего мнения у нас тут нет.
    case "system": NSApp.appearance = nil
    default:       NSApp.appearance = NSAppearance(named: .darkAqua)
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
