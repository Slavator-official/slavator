import SwiftUI

/// Память встреч: поиск по сохранённым расшифровкам и граф участников.
///
/// Отдельный экран, а не вкладка у спикеров. Спикеры — это люди и их голоса,
/// список, который правят руками. Память — то, что программа насчитала по
/// расшифровкам. Общего у них только слово «голос», и сведённые в один экран
/// они мешали друг другу: за списком людей нужно было идти через поиск.
///
/// Шапка — одна строка: заголовок, переключатель «Поиск / Граф» и цифры под
/// ними. Раньше до содержимого было пять слоёв: подзаголовок, плашки-счётчики,
/// подпись о хранении и широкий переключатель.
struct MemoryScreen: View {
    @Bindable var library: Library
    var player: Player
    @Bindable var memory: SpeakerMemory
    @Environment(\.palette) private var p
    @State private var detail: MemoryQuote?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    ScreenTitle(text: "Память встреч")
                    Spacer()
                    Segmented(options: [("search", "Поиск"), ("graph", "Граф")],
                              selection: $memory.tab)
                        .frame(width: 190)
                    IconButton(symbol: "arrow.clockwise", hint: "Перечитать расшифровки и обновить память") {
                        memory.refresh(settings: library.settings)
                    }
                    .disabled(memory.busy)
                }
                Text(statsLine).font(Kind.body(12.5)).monospacedDigit().foregroundStyle(p.muted)
            }

            if memory.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(memory.progress).font(Kind.body(12)).foregroundStyle(p.muted)
                    Spacer()
                    Button("Остановить") { memory.cancel() }.buttonStyle(QuietButton()).disabled(memory.isMutating)
                }
            }
            if let failure = memory.failure {
                Text(failure).font(Kind.body(13)).foregroundStyle(p.warn).textSelection(.enabled)
            }
            if !memory.notice.isEmpty {
                Text(memory.notice).font(Kind.body(12)).foregroundStyle(p.muted).textSelection(.enabled)
            }
            if !memory.warnings.isEmpty {
                DisclosureGroup("Не прочитано файлов: \(memory.warnings.count). Сохранена последняя доступная версия.") {
                    Text(memory.warnings.joined(separator: "\n")).font(Kind.body(12)).textSelection(.enabled)
                }.font(Kind.body(12)).foregroundStyle(p.warn)
            }

            if memory.tab == "graph" {
                if library.settings.memory_graph_enabled {
                    MemoryGraph(memory: memory, library: library)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Граф выключен").font(Kind.strong(14))
                        Text("Поиск, история реплик и чат по памяти встреч работают и без него.")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                        Button("Включить граф") { setGraph(true) }.buttonStyle(PrimaryButton())
                            .disabled(memory.isMutating)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
                }
            } else {
                searchBar
                results
            }
        }
        .onAppear { memory.activate(settings: library.settings) }
        .onChange(of: library.settings.results_dir) { _, _ in memory.activate(settings: library.settings) }
        .onChange(of: library.speakers) { _, _ in memory.invalidate(settings: library.settings) }
        .onChange(of: memory.tab) { _, tab in
            if tab == "search" { memory.search(settings: library.settings) }
        }
        .sheet(item: $detail) { quote in
            QuoteContext(quote: quote, memory: memory, library: library, player: player)
        }
    }

    private var statsLine: String {
        let o = memory.overview
        return [plural(o.meetings.count, "встреча", "встречи", "встреч"),
                plural(o.people.count, "голос", "голоса", "голосов"),
                plural(o.quotes, "реплика", "реплики", "реплик"),
                "хранится только на этом Mac"].joined(separator: " · ")
    }

    private func setGraph(_ on: Bool) {
        library.settings.memory_graph_enabled = on
        library.settings.save()
        memory.invalidate(settings: library.settings)
    }

    // MARK: поиск

    /// Одно поле, как Spotlight: вопрос пишут сюда и жмут Enter. Режим и
    /// фильтры — рядом и мельче, они меняются реже, чем вопрос.
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(p.faint)
                TextField(memory.mode == "semantic" ? "О чём договаривались? Кто обещал прислать отчёт?"
                                                   : "Точная фраза, например «перенесём релиз»",
                          text: $memory.query)
                    .textFieldStyle(.plain).font(Kind.body(15))
                    .disabled(memory.busy)
                    .onSubmit { memory.search(settings: library.settings) }
                Segmented(options: [("semantic", "По смыслу"), ("phrase", "Точно")], selection: $memory.mode)
                    // Ширина числом: fixedSize() тянет _FixedSizeLayout из
                    // SwiftUICore, которого в macOS 14 нет.
                    .frame(width: 190)
                    .onChange(of: memory.mode) { _, _ in memory.search(settings: library.settings) }
                Button("Найти") { memory.search(settings: library.settings) }
                    .buttonStyle(PrimaryButton()).disabled(memory.busy)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))

            HStack(spacing: 8) {
                FilterMenu(symbol: "person",
                           title: memory.overview.people.first(where: { $0.id == memory.person }).map { voiceName($0.name) } ?? "Все голоса",
                           active: !memory.person.isEmpty) {
                    Button("Все голоса") { filter(person: "") }
                    ForEach(memory.overview.people) { person in
                        Button(voiceName(person.name) + person.mark + " · \(person.meetings) встр.") { filter(person: person.id) }
                    }
                }
                FilterMenu(symbol: "calendar",
                           title: memory.overview.meetings.first(where: { $0.id == memory.meeting })?.title ?? "Все встречи",
                           active: !memory.meeting.isEmpty) {
                    Button("Все встречи") { filter(meeting: "") }
                    ForEach(memory.overview.meetings) { meeting in
                        Button(meeting.title + " · " + String(meeting.date.prefix(10))) { filter(meeting: meeting.id) }
                    }
                }
                if !memory.person.isEmpty || !memory.meeting.isEmpty || !memory.query.isEmpty {
                    Button("Сбросить") {
                        memory.person = ""; memory.meeting = ""; memory.query = ""
                        memory.search(settings: library.settings)
                    }.buttonStyle(LinkButton()).font(Kind.body(12.5)).padding(.leading, 4)
                }
                Spacer(minLength: 8)
                Text(memory.mode == "semantic"
                     ? "Ищет близкое по смыслу — сверяйтесь с контекстом"
                     : "Слова подряд, без учёта регистра")
                    .font(Kind.body(11.5)).foregroundStyle(p.faint).lineLimit(1)
            }
            .disabled(memory.busy)
        }
    }

    private func filter(person: String? = nil, meeting: String? = nil) {
        if let person { memory.person = person }
        if let meeting { memory.meeting = meeting }
        memory.search(settings: library.settings)
    }

    // MARK: реплики

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(memory.query.isEmpty ? "Хронология реплик" : "Найденные реплики").font(Kind.strong(13.5))
                Text("\(memory.total)").font(Kind.body(12)).monospacedDigit().foregroundStyle(p.muted)
                Spacer()
                if let hidden = memory.overview.hidden_fragments, hidden > 0 {
                    Text("обрывки вроде «ну вот» скрыты: \(hidden)")
                        .font(Kind.body(11.5)).foregroundStyle(p.faint)
                        .help("Служебные обрывки не показаны отдельными строками. Они сохранены в контексте и исходной расшифровке.")
                }
            }
            if memory.hits.isEmpty && !memory.busy {
                VStack(spacing: 8) {
                    Image(systemName: memory.overview.quotes == 0 ? "waveform" : "magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(p.faint)
                    Text(memory.overview.quotes == 0 ? "В памяти пока нет расшифровок" : "Подходящих реплик нет")
                        .font(Kind.strong(14))
                    Text(memory.overview.quotes == 0
                         ? "Обработайте встречу в «Записях» — её реплики появятся здесь."
                         : "Попробуйте короче, другими словами или без фильтров.")
                        .font(Kind.body(12.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34)
                .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
            } else {
                let labels = memoryLabels(memory.overview.people)
                // Встреча под каждой репликой нужна, только когда их несколько
                // и выдача не сужена до одной.
                let showMeeting = memory.overview.meetings.count > 1 && memory.meeting.isEmpty
                LazyVStack(spacing: 0) {
                    ForEach(Array(memory.hits.enumerated()), id: \.element.id) { index, quote in
                        let colour = memoryColour(id: quote.person, name: quote.name, library: library, palette: p)
                        if index > 0 { Rectangle().fill(p.line2).frame(height: 0.5).padding(.leading, 72) }
                        QuoteRow(quote: quote, label: labels[quote.person] ?? voiceName(quote.name),
                                 colour: colour, showMeeting: showMeeting, busy: memory.busy,
                                 play: { playMemoryQuote(quote, player: player, colour: colour) },
                                 context: { detail = quote; memory.loadContext(quote, settings: library.settings) })
                    }
                }
                .background(p.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
            }
            if memory.hits.count < memory.total {
                Button("Показать ещё \(min(30, memory.total - memory.hits.count))") {
                    memory.search(settings: library.settings, more: true)
                }
                .buttonStyle(QuietButton()).disabled(memory.busy)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }
}

/// Строка реплики: время, кто сказал, что сказал. Действия — тихими
/// значками справа, а не тремя кнопками под каждой репликой: реплик
/// на экране десятки, и кнопки забивали текст, ради которого сюда пришли.
private struct QuoteRow: View {
    let quote: MemoryQuote
    let label: String
    let colour: Color
    let showMeeting: Bool
    let busy: Bool
    let play: () -> Void
    let context: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(quote.time).font(Kind.body(12.5)).monospacedDigit().foregroundStyle(p.muted)
                .frame(width: 44, alignment: .leading).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(colour).frame(width: 7, height: 7)
                    // Откуда взялось имя — подсказкой: в каждой строке одна и
                    // та же фраза забивала текст реплик.
                    Text(label).font(Kind.strong(13)).help(quote.attribution)
                }
                Text(quote.text).font(Kind.body(13.5)).lineSpacing(2).textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                if showMeeting {
                    Text(quote.title + " · " + memoryDate(quote.date))
                        .font(Kind.body(11.5)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(symbol: "play.fill", hint: quote.audio == nil ? "Исходное аудио недоступно" : "Послушать этот отрывок",
                           action: play)
                    .disabled(quote.audio == nil)
                IconButton(symbol: "text.alignleft", hint: "Что говорили до и после", action: context)
                    .disabled(busy)
                IconButton(symbol: "folder", hint: "Папка встречи") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: quote.meeting))
                }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hovering ? p.selection.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Значок-кнопка: нейтральный, с подложкой при наведении и сжатием при
/// нажатии.
struct IconButton: View {
    let symbol: String
    let hint: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
        }
        .buttonStyle(IconStyle())
        .help(hint)
        .accessibilityLabel(hint)
    }
}

private struct IconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconLabel(configuration: configuration) }
}

private struct IconLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? p.text : p.faint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && enabled ? p.selection.opacity(1.5) : .clear))
            .contentShape(Rectangle())
            .modifier(Pressable(pressed: configuration.isPressed && enabled))
            .onHover { hovering = $0 }
    }
}

/// Фильтр-кнопка: значок, текущее значение, стрелка. Выбранный фильтр
/// подсвечен — видно, что выдача сужена.
private struct FilterMenu<Items: View>: View {
    let symbol: String
    let title: String
    let active: Bool
    @ViewBuilder let items: Items
    @Environment(\.palette) private var p

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).lineLimit(1)
            }
            .font(Kind.body(12.5))
        }
        .menuStyle(.borderlessButton)
        // Ширина по длине подписи. fixedSize() дал бы то же самое, но тянет
        // _FixedSizeLayout из SwiftUICore, которого нет в macOS 14.
        .frame(width: min(240, CGFloat(title.count) * 7.6 + 44))
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? p.accentSoft : p.selection))
        .foregroundStyle(active ? p.accent2 : p.text)
    }
}

/// Имя голоса для людей. «SPEAKER_05» — внутренний ярлык разделения голосов,
/// ему не место в интерфейсе: на ленте встречи тот же голос зовётся
/// «Голос 6», и здесь он должен называться так же.
func voiceName(_ raw: String) -> String {
    guard raw.hasPrefix("SPEAKER_"), let number = Int(raw.dropFirst("SPEAKER_".count)) else { return raw }
    return "Голос \(number + 1)"
}

/// Цвет голоса — тот же, что на ленте встречи: у названного человека его
/// постоянный цвет, у безымянного — цвет по номеру голоса. Иначе граф из
/// одних безымянных голосов был бы сплошь серым.
func voiceColour(_ raw: String, library: Library, palette: Palette) -> Color {
    if raw.hasPrefix("SPEAKER_"), let number = Int(raw.dropFirst("SPEAKER_".count)) {
        return palette.speakers[number % palette.speakers.count]
    }
    return library.color(forName: raw)
}

/// Цвет голоса в памяти по его идентификатору. Названный — свой постоянный,
/// «Голос N» — как на ленте, голос с угаданным именем — свой цвет по
/// идентификатору, одинаковый от запуска к запуску. Одно правило для
/// реплик и графа: человек не должен менять цвет при переходе между ними.
func memoryColour(id: String, name: String, library: Library, palette: Palette) -> Color {
    if id.hasPrefix("profile:") || name.hasPrefix("SPEAKER_") {
        return voiceColour(name, library: library, palette: palette)
    }
    let hash = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return palette.speakers[Int(hash % UInt32(palette.speakers.count))]
}

/// Подписи голосов памяти. Имя, угаданное по разговору, — с вопросом: это
/// ещё не человек, а догадка. Одна догадка часто достаётся нескольким
/// голосам встречи, и три одинаковых «Валерия» читались как один человек
/// трижды — такие получают номер.
func memoryLabels(_ people: [MemoryPerson]) -> [String: String] {
    var labels: [String: String] = [:]
    for person in people {
        var label = voiceName(person.name)
        if !person.confirmed && !person.name.hasPrefix("SPEAKER_") { label += "?" }
        labels[person.id] = label
    }
    let repeated = Dictionary(grouping: people.map(\.id), by: { labels[$0] ?? "" }).filter { $0.value.count > 1 }
    for (_, ids) in repeated {
        for (index, id) in ids.sorted().enumerated() { labels[id] = (labels[id] ?? "") + " \(index + 1)" }
    }
    return labels
}

/// «2026-10-30…» → «30 октября».
func memoryDate(_ raw: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: String(raw.prefix(10))) else { return String(raw.prefix(10)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "d MMMM"
    return formatter.string(from: date)
}

func playMemoryQuote(_ quote: MemoryQuote, player: Player, colour: Color) {
    guard let source = quote.audio else {
        showAlert("Аудиозапись недоступна", "Текст сохранён, но исходный аудиофайл перемещён или удалён.")
        return
    }
    player.play(url: source, label: voiceName(quote.name), subtitle: quote.title + " · " + quote.time,
                colour: colour, from: quote.start, to: quote.end)
}

struct QuoteContext: View {
    let quote: MemoryQuote
    @Bindable var memory: SpeakerMemory
    var library: Library
    var player: Player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(quote.title).font(Kind.title(19)).kerning(-0.3).lineLimit(2)
                    Text("Что говорили вокруг \(quote.time) · время от начала записи")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
            }
            if memory.busy { ProgressView().controlSize(.small) }
            if let failure = memory.failure { Text(failure).foregroundStyle(p.warn) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(memory.context) { item in
                        let current = item.id == quote.id
                        HStack(alignment: .top, spacing: 12) {
                            // Найденная реплика отмечена полосой слева: красной
                            // подложки не нужно, это не ошибка, а «вот она».
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(current ? p.accent : Color.clear).frame(width: 3)
                            Text(item.time).font(Kind.body(12.5)).monospacedDigit().foregroundStyle(p.muted)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Circle().fill(voiceColour(item.name, library: library, palette: p)).frame(width: 7, height: 7)
                                    Text(voiceName(item.name)).font(Kind.strong(13))
                                }
                                Text(item.text).font(Kind.body(13.5)).lineSpacing(2).textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            IconButton(symbol: "play.fill", hint: "Послушать") {
                                playMemoryQuote(item, player: player, colour: voiceColour(item.name, library: library, palette: p))
                            }
                            .disabled(item.audio == nil)
                        }
                        .padding(.vertical, 10).padding(.trailing, 8)
                        .background(current ? p.selection : Color.clear)
                    }
                }
            }
            HStack(spacing: 10) {
                Text(quote.attribution).font(Kind.body(12)).foregroundStyle(p.muted)
                Spacer()
                if !library.speakers.isEmpty {
                    Menu("Уточнить, кто говорит…") {
                        ForEach(library.speakers) { person in
                            Button(person.name) {
                                memory.link(quote, profile: person.key, settings: library.settings)
                                dismiss()
                            }
                        }
                    }
                    .frame(maxWidth: 220)
                    .disabled(memory.busy)
                }
            }
            Text("Привязка исправит все реплики этого голоса в этой встрече. Имя, угаданное по разговору, не объединяет людей автоматически.")
                .font(Kind.body(11.5)).foregroundStyle(p.faint)
            HStack {
                Button("Папка встречи") { NSWorkspace.shared.open(URL(fileURLWithPath: quote.meeting)) }
                    .buttonStyle(QuietButton())
                if let transcript = quote.record.transcript {
                    Button("Стенограмма") { NSWorkspace.shared.open(transcript) }.buttonStyle(QuietButton())
                }
                Spacer()
                if quote.audio == nil { Text("Исходное аудио недоступно").font(Kind.body(12)).foregroundStyle(p.muted) }
            }
        }.padding(24).frame(width: 760, height: 640).background(p.surface)
    }
}

// MARK: - Граф

/// Граф «кто с кем встречался».
///
/// Люди — кружки своего цвета, того же, что на ленте голосов: человек
/// узнаётся одинаково везде. Размер кружка — сколько встреч у человека.
/// В центре тот, кого выбрали, а пока никого не выбрали — самый частый
/// участник: вокруг него граф и читается. Линия — общая встреча, толще —
/// чаще.
///
/// Наведение подсвечивает связи человека и приглушает остальных: «с кем он»
/// видно без щелчка. Справа — панель с тем, что из графа не прочитать: на
/// каких именно встречах пересеклись и что человек говорил.
struct MemoryGraph: View {
    @Bindable var memory: SpeakerMemory
    var library: Library
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var openEdge: String?
    @State private var showUnconfirmed = false

    private var people: [MemoryPerson] { memory.overview.people }
    private var unconfirmed: [MemoryPerson] { people.filter { !$0.confirmed } }
    /// Названных людей ещё нет — показываем голоса как есть: иначе у
    /// каждого нового пользователя граф начинался бы с пустоты.
    private var nobodyNamed: Bool { !people.contains(where: \.confirmed) }
    private var eligible: [MemoryPerson] {
        people.filter { showUnconfirmed || nobodyNamed || $0.confirmed || $0.id == memory.person }
    }
    private var chosen: MemoryPerson? { people.first(where: { $0.id == memory.person }) }

    /// Центр графа: выбранный человек, иначе самый частый участник.
    private var centre: MemoryPerson? {
        if let chosen, eligible.contains(where: { $0.id == chosen.id }) { return chosen }
        return eligible.max(by: { ($0.meetings, $0.quotes) < ($1.meetings, $1.quotes) })
    }
    /// Кольцо вокруг центра. Когда человек выбран — только те, с кем он
    /// встречался: остальные к вопросу «с кем он» отношения не имеют.
    private var ring: [MemoryPerson] {
        guard let centre else { return [] }
        var others = eligible.filter { $0.id != centre.id }
        if !memory.person.isEmpty {
            let near = neighbours(of: centre.id)
            others = others.filter { near.contains($0.id) }
        }
        return Array(others.sorted { ($0.meetings, $0.quotes) > ($1.meetings, $1.quotes) }.prefix(11))
    }
    private var nodes: [MemoryPerson] { (centre.map { [$0] } ?? []) + ring }
    private var edges: [MemoryEdge] {
        let ids = Set(nodes.map(\.id))
        return memory.overview.edges.filter { ids.contains($0.a) && ids.contains($0.b) }
    }
    /// На кого смотрим: под курсором, иначе выбранный.
    private var focus: String? { hovered ?? (memory.person.isEmpty ? nil : memory.person) }

    private func neighbours(of id: String) -> Set<String> {
        Set(memory.overview.edges.filter { $0.a == id || $0.b == id }.flatMap { [$0.a, $0.b] })
            .subtracting([id])
    }
    private func point(_ id: String, in size: CGSize) -> CGPoint {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard id != centre?.id, let index = ring.firstIndex(where: { $0.id == id }) else { return middle }
        let angle = Double(index) / Double(max(ring.count, 1)) * .pi * 2 - .pi / 2
        let rx = max(70, size.width / 2 - 80), ry = max(70, size.height / 2 - 62)
        return CGPoint(x: middle.x + cos(angle) * rx, y: middle.y + sin(angle) * ry)
    }
    private func diameter(_ person: MemoryPerson) -> CGFloat { 30 + CGFloat(min(person.meetings, 8)) * 3.5 }
    private func colour(_ person: MemoryPerson) -> Color {
        memoryColour(id: person.id, name: person.name, library: library, palette: p)
    }
    private var labels: [String: String] { memoryLabels(people) }
    private func name(_ id: String) -> String { labels[id] ?? voiceName(id) }
    private func label(_ person: MemoryPerson) -> String { labels[person.id] ?? voiceName(person.name) }
    private func person(_ id: String) -> MemoryPerson? { people.first(where: { $0.id == id }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                canvas
                panel.frame(width: 290)
            }
            HStack(spacing: 8) {
                Text("Граф строится по всем обработанным встречам.")
                    .font(Kind.body(11.5)).foregroundStyle(p.faint)
                Spacer()
                Button("Выключить граф") {
                    library.settings.memory_graph_enabled = false
                    library.settings.save()
                    memory.invalidate(settings: library.settings)
                }
                .buttonStyle(.plain).font(Kind.body(11.5)).foregroundStyle(p.muted)
                .disabled(memory.isMutating)
                .help("Поиск и чат по памяти продолжат работать — граф просто перестанет пересчитываться")
            }
        }
    }

    // холст с людьми и связями
    private var canvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Кто с кем встречался").font(Kind.strong(13.5))
                Spacer()
                if !unconfirmed.isEmpty && !nobodyNamed {
                    Toggle("Голоса без имени (\(unconfirmed.count))", isOn: $showUnconfirmed)
                        .toggleStyle(.checkbox).font(Kind.body(12))
                }
            }
            .padding(.horizontal, 16).padding(.top, 14)

            if nodes.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26)).foregroundStyle(p.faint)
                    Text(people.isEmpty ? "Граф появится после первых встреч"
                         : unconfirmed.isEmpty ? "Пока не с кем связать"
                         : "Пока нет названных людей")
                        .font(Kind.strong(14))
                    Text(people.isEmpty ? "Нужны встречи, разобранные по голосам."
                         : unconfirmed.isEmpty ? "Нужны хотя бы двое, которые встречались вместе."
                         : "Назовите голоса в «Спикерах» или отметьте «Голоса без имени» выше.")
                        .font(Kind.body(12.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 440)
            } else {
                GeometryReader { geo in
                    ZStack {
                        Canvas { context, size in
                            for link in edges {
                                var path = Path()
                                path.move(to: point(link.a, in: size))
                                path.addLine(to: point(link.b, in: size))
                                let lit = focus != nil && (link.a == focus || link.b == focus)
                                let colour = lit ? p.accent2.opacity(0.9)
                                                 : p.muted.opacity(focus == nil ? 0.3 : 0.1)
                                context.stroke(path, with: .color(colour),
                                               style: StrokeStyle(lineWidth: 1 + CGFloat(min(link.meetings.count, 5)),
                                                                  lineCap: .round))
                            }
                        }
                        .accessibilityHidden(true)
                        ForEach(nodes) { person in
                            node(person).position(point(person.id, in: geo.size))
                        }
                    }
                }
                .frame(height: 440)
                .clipped()
                Text("Линия — общая встреча, толще — чаще. Наведите на человека, чтобы увидеть его связи; нажмите — он встанет в центр.")
                    .font(Kind.body(11.5)).foregroundStyle(p.faint)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
    }

    private func node(_ person: MemoryPerson) -> some View {
        let size = diameter(person)
        let selected = person.id == memory.person
        let dimmed = focus != nil && person.id != focus && !neighbours(of: focus ?? "").contains(person.id)
        return Button { select(person) } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(colour(person)).frame(width: size, height: size)
                    Text(initials(label(person)))
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().stroke(p.accent2, lineWidth: 2).padding(-4).opacity(selected ? 1 : 0))
                VStack(spacing: 1) {
                    Text(label(person)).font(Kind.strong(12)).lineLimit(1)
                    Text(plural(person.meetings, "встреча", "встречи", "встреч"))
                        .font(Kind.body(10.5)).foregroundStyle(p.muted)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                // Подложка под подписью: линии не должны перечёркивать имя.
                .background(RoundedRectangle(cornerRadius: 5).fill(p.surface.opacity(0.9)))
            }
            .frame(width: 130)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.3 : 1)
        // Подсветка — изменение цвета и прозрачности, быстро и без движения.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focus)
        .onHover { inside in
            if inside { hovered = person.id } else if hovered == person.id { hovered = nil }
        }
        .help(person.confirmed ? label(person)
              : label(person) + " — имя угадано по разговору, проверьте его в «Спикерах»")
    }

    private func initials(_ name: String) -> String {
        if name.hasPrefix("Голос") { return String(name.dropFirst(5)).trimmingCharacters(in: .whitespaces).prefix(2).description }
        if name == "Вы" { return "Я" }
        return name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init)
            .joined().replacingOccurrences(of: "?", with: "").uppercased()
    }

    private func select(_ person: MemoryPerson) {
        memory.person = memory.person == person.id ? "" : person.id
        openEdge = nil
    }

    // панель справа: что из графа не прочитать
    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let chosen {
                HStack(spacing: 11) {
                    Circle().fill(colour(chosen)).frame(width: 38, height: 38)
                        .overlay(Text(initials(label(chosen))).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(chosen)).font(Kind.strong(15)).lineLimit(1)
                        Text(plural(chosen.meetings, "встреча", "встречи", "встреч") + " · "
                             + plural(chosen.quotes, "реплика", "реплики", "реплик"))
                            .font(Kind.body(12)).monospacedDigit().foregroundStyle(p.muted)
                    }
                }
                if !chosen.confirmed {
                    Text(chosen.name.hasPrefix("SPEAKER_")
                         ? "Голос без имени: известен только внутри своей встречи. Назовите его в «Спикерах», и он свяжется с другими встречами."
                         : "Имя угадано по разговору. Пока его не подтвердили в «Спикерах», голос известен только внутри своей встречи.")
                        .font(Kind.body(11.5)).foregroundStyle(p.faint)
                }
                Button("Все реплики") { history(chosen) }
                    .buttonStyle(PrimaryButton(wide: true)).disabled(memory.busy)
                let links = memory.overview.edges
                    .filter { $0.a == chosen.id || $0.b == chosen.id }
                    .sorted { $0.meetings.count > $1.meetings.count }
                section(links.isEmpty ? "Общих встреч пока нет" : "Встречался с") {
                    ForEach(links.prefix(12)) { link in
                        edgeRow(link, single: link.a == chosen.id ? link.b : link.a)
                    }
                }
                Button("Снять выбор") { memory.person = ""; openEdge = nil }
                    .buttonStyle(LinkButton()).font(Kind.body(12.5))
            } else {
                let top = edges.sorted { $0.meetings.count > $1.meetings.count }
                section("Чаще всего вместе") {
                    if top.isEmpty {
                        Text("Общих встреч пока нет.").font(Kind.body(12.5)).foregroundStyle(p.muted)
                    }
                    ForEach(top.prefix(8)) { link in edgeRow(link, single: nil) }
                }
                Text("Нажмите на человека в графе — здесь появятся его встречи и реплики.")
                    .font(Kind.body(12)).foregroundStyle(p.faint)
                if !unconfirmed.isEmpty && !nobodyNamed {
                    section("Голоса без имени · \(unconfirmed.count)") {
                        ForEach(unconfirmed.prefix(4)) { voice in
                            HStack(spacing: 8) {
                                Circle().fill(p.unknown).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(label(voice)).font(Kind.body(12.5)).lineLimit(1)
                                    if let title = voice.title {
                                        Text(title).font(Kind.body(11)).foregroundStyle(p.faint).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 6)
                                Button("Реплики") { history(voice) }
                                    .buttonStyle(LinkButton()).font(Kind.body(12)).disabled(memory.busy)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 0.5))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.faint)
            content()
        }
    }

    /// Связь: двое (или один — собеседник выбранного) и сколько встреч.
    /// Раскрывается в список самих встреч: по нажатию — их реплики.
    @ViewBuilder
    private func edgeRow(_ link: MemoryEdge, single: String?) -> some View {
        let open = openEdge == link.id
        Button { openEdge = open ? nil : link.id } label: {
            HStack(spacing: 7) {
                if let single, let other = person(single) {
                    Circle().fill(colour(other)).frame(width: 7, height: 7)
                    Text(label(other)).lineLimit(1)
                } else {
                    HStack(spacing: -2) {
                        Circle().fill(person(link.a).map(colour) ?? p.unknown).frame(width: 7, height: 7)
                        Circle().fill(person(link.b).map(colour) ?? p.unknown).frame(width: 7, height: 7)
                    }
                    Text(name(link.a) + " и " + name(link.b)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(link.meetings.count)").monospacedDigit().foregroundStyle(p.muted)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(p.faint).rotationEffect(.degrees(open ? 90 : 0))
            }
            .font(Kind.body(12.5))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // Наведение на связь подсвечивает её на графе.
            if inside { hovered = single ?? link.a } else if hovered == (single ?? link.a) { hovered = nil }
        }
        if open {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(link.meetings, id: \.self) { mid in
                    Button {
                        memory.meeting = mid; memory.person = ""; memory.query = ""
                        memory.tab = "search"; memory.search(settings: library.settings)
                    } label: {
                        Label(memory.overview.meetings.first(where: { $0.id == mid })?.title ?? "Встреча",
                              systemImage: "text.bubble")
                            .lineLimit(1)
                    }
                    .buttonStyle(LinkButton()).font(Kind.body(12)).disabled(memory.busy)
                }
            }
            .padding(.leading, 14).padding(.bottom, 4)
        }
    }

    private func history(_ person: MemoryPerson) {
        memory.person = person.id; memory.query = ""; memory.meeting = ""
        memory.tab = "search"; memory.search(settings: library.settings)
    }
}
