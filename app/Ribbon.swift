import SwiftUI

/// Голосовая лента: горизонтальная полоса встречи, где каждый отрезок —
/// реплика, ширина — её длительность, цвет — человек.
///
/// Это главный элемент интерфейса. Данные для него ядро складывало в
/// diarization.json с самого начала, но пользователю они не показывались —
/// пересчитывались только в число участников.
struct Ribbon: View {
    @Environment(\.palette) private var p
    let turns: [Turn]
    var height: CGFloat = 46
    var library: Library
    var record: Record? = nil
    var onPick: ((Turn) -> Void)? = nil

    private var span: Double { max(turns.map(\.end).max() ?? 1, 0.001) }

    var body: some View {
        GeometryReader { geo in
            if turns.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(p.raised)
                    .overlay(
                        Text("Нет данных о говорящих")
                            .font(Kind.body(11)).foregroundStyle(p.faint)
                    )
            } else {
                ZStack(alignment: .leading) {
                    ForEach(turns) { turn in
                        let x = geo.size.width * turn.start / span
                        // Минимальная ширина: короткая реплика должна остаться
                        // видимой, иначе лента теряет участников с репликами
                        // в пару слов.
                        let w = max(2, geo.size.width * turn.duration / span - 2)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(library.color(for: turn, in: record))
                            .frame(width: w, height: geo.size.height)
                            .offset(x: x)
                            .onTapGesture { onPick?(turn) }
                            .help(turn.name.isEmpty ? Legend.label(for: turn, in: record) : turn.name)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Шкала времени под лентой.
struct Ruler: View {
    @Environment(\.palette) private var p
    let length: Double
    var body: some View {
        HStack {
            Text("0:00")
            Spacer()
            Text(hms(length))
        }
        .font(Kind.mono(11))
        .foregroundStyle(p.faint)
    }
}

/// Кто сколько говорил. Считается по той же ленте, что и рисуется.
struct Legend: View {
    @Environment(\.palette) private var p
    let turns: [Turn]
    let library: Library
    var record: Record? = nil
    var onPick: ((String) -> Void)? = nil

    /// Безымянный голос всё равно должен различаться: «Голос 1», «Голос 2».
    static func label(for turn: Turn, in record: Record?) -> String {
        if !turn.name.isEmpty { return turn.name }
        if turn.speaker == "OWN" { return "Вы" }
        guard let record else { return "Неизвестный голос" }
        let ids = Set(record.turns.map(\.speaker)).sorted()
        guard let index = ids.firstIndex(of: turn.speaker) else { return "Неизвестный голос" }
        return "Голос \(index + 1)"
    }

    private struct Share: Identifiable {
        let id = UUID()
        let name: String
        let seconds: Double
        let colour: Color
    }

    private var shares: [Share] {
        let total = max(turns.reduce(0) { $0 + $1.duration }, 0.001)
        // Опознанного человека собираем в одну строку, даже если диаризация
        // разложила его на несколько голосов — иначе он повторяется в легенде
        // по разу на каждый голос, и объединение выглядит так, будто не
        // сработало. Безымянные остаются раздельными: это разные люди.
        var sums: [String: Double] = [:]
        var sample: [String: Turn] = [:]
        for turn in turns {
            let key = turn.name.isEmpty ? turn.speaker : turn.name
            sums[key, default: 0] += turn.duration
            if sample[key] == nil { sample[key] = turn }
        }
        return sums.sorted { $0.value > $1.value }.compactMap { key, seconds in
            guard let turn = sample[key] else { return nil }
            return Share(name: Self.label(for: turn, in: record),
                         seconds: seconds / total * 100,
                         colour: library.color(for: turn, in: record))
        }
    }

    var body: some View {
        // Сетка с подстраиваемыми колонками вместо собственной раскладки.
        // Своя требовала протокол Layout, а его реализация по умолчанию
        // живёт в SwiftUICore - фреймворке, которого нет в macOS 14. Из-за
        // одной этой зависимости приложение не запускалось на Sonoma вовсе.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16)],
                  alignment: .leading, spacing: 6) {
            ForEach(shares) { share in
                Button { onPick?(share.name) } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(share.colour).frame(width: 10, height: 10)
                        Text(share.name).font(Kind.body(13)).foregroundStyle(p.muted)
                        Text("\(Int(share.seconds.rounded()))%")
                            .font(Kind.mono(11.5)).foregroundStyle(p.faint)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Индикатор уровня входящего звука: показывает, что запись действительно
/// что-то слышит, а не пишет тишину.
struct LevelMeter: View {
    @Environment(\.palette) private var p
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { i in
                let threshold = Double(i) / 24
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? p.accent : p.line)
                    .frame(height: 6 + CGFloat(i % 5) * 4)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.08), value: level)
    }
}
