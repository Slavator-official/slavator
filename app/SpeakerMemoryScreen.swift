import SwiftUI

/// Память встреч: поиск по сохранённым расшифровкам и граф участников.
///
/// Отдельный экран, а не вкладка у спикеров. Спикеры — это люди и их голоса,
/// список, который правят руками. Память — то, что программа насчитала по
/// расшифровкам. Общего у них только слово «голос», и сведённые в один экран
/// они мешали друг другу: за списком людей нужно было идти через поиск.
struct MemoryScreen: View {
    @Bindable var library: Library
    var player: Player
    @Bindable var memory: SpeakerMemory
    @Environment(\.palette) private var p
    @State private var detail: MemoryQuote?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Память встреч").font(Kind.title(24))
                    Text("Кто, что и когда говорил — с опорой на сохранённые расшифровки.")
                        .font(Kind.body(13)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Обновить память") { memory.refresh(settings: library.settings) }
                    .buttonStyle(QuietButton()).disabled(memory.busy)
            }
            HStack(spacing: 10) {
                metric("встреч", memory.overview.meetings.count)
                metric("голосов", memory.overview.people.count)
                metric("фрагментов", memory.overview.quotes)
                Spacer()
                Label("Хранится на этом устройстве", systemImage: "lock.shield")
                    .font(Kind.body(12)).foregroundStyle(p.muted)
            }
            Segmented(options: [("search", "Поиск и история"), ("graph", "Граф встреч")],
                      selection: $memory.tab)
                .frame(width: 380)
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
                Toggle("Строить граф встреч", isOn: Binding(
                    get: { library.settings.memory_graph_enabled },
                    set: { library.settings.memory_graph_enabled = $0; library.settings.save()
                        memory.invalidate(settings: library.settings) }))
                    .toggleStyle(.switch).disabled(memory.isMutating)
                if library.settings.memory_graph_enabled {
                    MemoryGraph(memory: memory, settings: library.settings)
                } else {
                    Card {
                        Text("Построение графа выключено. Поиск, история реплик и чат по памяти встреч продолжают работать.")
                            .font(Kind.body(14)).foregroundStyle(p.muted)
                    }
                }
            } else {
                searchControls
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

    private func metric(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(value)").font(Kind.mono(16))
            Text(title).font(Kind.body(12)).foregroundStyle(p.muted)
        }.padding(.horizontal, 13).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
    }

    private var searchControls: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.accent2)
                TextField("Фраза или контекст: о чём договаривались?", text: $memory.query)
                    .textFieldStyle(.plain).font(Kind.body(15))
                    .disabled(memory.busy)
                    .onSubmit { memory.search(settings: library.settings) }
                Button("Найти") { memory.search(settings: library.settings) }
                    .buttonStyle(PrimaryButton()).disabled(memory.busy)
            }
            Divider().overlay(p.line2).padding(.vertical, 12)
            HStack(spacing: 12) {
                Segmented(options: [("semantic", "По смыслу"), ("phrase", "Точная фраза")], selection: $memory.mode)
                    // Explicit width avoids the new SDK's _FixedSizeLayout
                    // witness being linked directly from macOS 15 SwiftUICore.
                    .frame(width: 260)
                    .onChange(of: memory.mode) { _, _ in memory.search(settings: library.settings) }
                Spacer(minLength: 4)
                Menu {
                    Button("Все голоса") { filter(person: "") }
                    ForEach(memory.overview.people) { person in
                        Button(person.name + person.mark + " · \(person.meetings) встр.") { filter(person: person.id) }
                    }
                } label: {
                    Label(memory.overview.people.first(where: { $0.id == memory.person })?.name ?? "Все голоса", systemImage: "person")
                        .lineLimit(1).frame(maxWidth: 160)
                }
                Menu {
                    Button("Все встречи") { filter(meeting: "") }
                    ForEach(memory.overview.meetings) { meeting in
                        Button(meeting.title + " · " + String(meeting.date.prefix(10))) { filter(meeting: meeting.id) }
                    }
                } label: {
                    Label(memory.overview.meetings.first(where: { $0.id == memory.meeting })?.title ?? "Все встречи", systemImage: "calendar")
                        .lineLimit(1).frame(maxWidth: 180)
                }
            }.disabled(memory.busy)
            Text(memory.mode == "semantic"
                 ? "Смысловой поиск находит близкие высказывания, но не гарантирует, что они отвечают на вопрос. Проверяйте контекст."
                 : "Ищем слова фразы подряд, без учёта регистра и пунктуации. Пустой запрос показывает хронологию.")
                .font(Kind.body(11.5)).foregroundStyle(p.muted).padding(.top, 10)
        }
    }

    private func filter(person: String? = nil, meeting: String? = nil) {
        if let person { memory.person = person }
        if let meeting { memory.meeting = meeting }
        memory.search(settings: library.settings)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(memory.query.isEmpty ? "История высказываний" : "Найденные высказывания").font(Kind.head(16))
                Text("\(memory.total)").font(Kind.mono(13)).foregroundStyle(p.muted)
                Spacer()
                if !memory.person.isEmpty || !memory.meeting.isEmpty || !memory.query.isEmpty {
                    Button("Сбросить") {
                        memory.person = ""; memory.meeting = ""; memory.query = ""
                        memory.search(settings: library.settings)
                    }.buttonStyle(QuietButton()).disabled(memory.busy)
                }
            }
            if let hidden = memory.overview.hidden_fragments, hidden > 0 {
                Text("Служебные обрывки вроде «как» и «ну вот» не показаны отдельными карточками (\(hidden)). Они сохранены в контексте и исходной расшифровке.")
                    .font(Kind.body(11)).foregroundStyle(p.muted)
            }
            if memory.hits.isEmpty && !memory.busy {
                Card {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble").font(.system(size: 26)).foregroundStyle(p.muted)
                        Text(memory.overview.quotes == 0 ? "В памяти пока нет расшифровок" : "Подходящих реплик не найдено").font(Kind.head(15))
                        Text(memory.overview.quotes == 0
                             ? "Обработайте встречу или выберите папку с результатами в настройках. Здесь появятся настоящие реплики."
                             : "Попробуйте более короткую фразу, другой контекст или уберите фильтры.")
                            .font(Kind.body(13)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
            LazyVStack(spacing: 10) {
                ForEach(memory.hits) { quote in
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            Text(quote.time).font(Kind.mono(13)).foregroundStyle(p.accent2)
                                .padding(.vertical, 7).padding(.horizontal, 9)
                                .background(RoundedRectangle(cornerRadius: 8).fill(p.bg))
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(quote.name).font(Kind.strong(14))
                                    Text(quote.attribution).font(Kind.body(11)).foregroundStyle(p.muted)
                                    Spacer(minLength: 0)
                                }
                                Text(quote.text).font(Kind.body(14)).textSelection(.enabled)
                                Text(quote.title + "  ·  обработано " + String(quote.date.prefix(10)))
                                    .font(Kind.body(12)).foregroundStyle(p.muted).lineLimit(2)
                                HStack(spacing: 12) {
                                    Button("Открыть контекст") {
                                        detail = quote
                                        memory.loadContext(quote, settings: library.settings)
                                    }.buttonStyle(QuietButton()).disabled(memory.busy)
                                    Button { playMemoryQuote(quote, player: player, colour: p.accent2) } label: {
                                        Label("Слушать", systemImage: "play.fill")
                                    }.buttonStyle(QuietButton()).disabled(quote.audio == nil)
                                    Button("Папка встречи") { NSWorkspace.shared.open(URL(fileURLWithPath: quote.meeting)) }
                                        .buttonStyle(QuietButton())
                                }
                            }
                        }
                    }
                }
            }
            if memory.hits.count < memory.total {
                Button("Ещё 30 высказываний") { memory.search(settings: library.settings, more: true) }
                    .buttonStyle(QuietButton()).disabled(memory.busy)
            }
        }
    }
}

func playMemoryQuote(_ quote: MemoryQuote, player: Player, colour: Color) {
    guard let source = quote.audio else {
        showAlert("Аудиозапись недоступна", "Текст сохранён, но исходный аудиофайл перемещён или удалён.")
        return
    }
    player.play(url: source, label: quote.name, subtitle: quote.title + " · " + quote.time,
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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(quote.title).font(Kind.head(18)).lineLimit(2)
                    Text("Контекст вокруг \(quote.time) · время от начала записи")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton())
            }
            if memory.busy { ProgressView() }
            if let failure = memory.failure { Text(failure).foregroundStyle(p.warn) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(memory.context) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(item.time + " · " + item.name).font(Kind.strong(13))
                                Spacer()
                                Button("Слушать") { playMemoryQuote(item, player: player, colour: p.accent2) }
                                    .buttonStyle(QuietButton()).disabled(item.audio == nil)
                            }
                            Text(item.text).font(Kind.body(14)).textSelection(.enabled)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(item.id == quote.id ? p.accent.opacity(0.13) : p.bg))
                    }
                }
            }
            HStack {
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
                    }.disabled(memory.busy)
                }
            }
            Text("Привязка исправит все реплики этого голоса в этой встрече. Имя, угаданное по разговору, не объединяет людей автоматически.")
                .font(Kind.body(11)).foregroundStyle(p.muted)
            HStack {
                Button("Папка встречи") { NSWorkspace.shared.open(URL(fileURLWithPath: quote.meeting)) }
                    .buttonStyle(QuietButton())
                if let transcript = quote.record.transcript {
                    Button("Документ расшифровки") { NSWorkspace.shared.open(transcript) }.buttonStyle(QuietButton())
                }
                Spacer()
                if quote.audio == nil { Text("Исходное аудио недоступно").font(Kind.body(12)).foregroundStyle(p.muted) }
            }
        }.padding(24).frame(width: 740, height: 630).background(p.surface)
    }
}

struct MemoryGraph: View {
    @Bindable var memory: SpeakerMemory
    let settings: Settings
    @Environment(\.palette) private var p
    @State private var edge: MemoryEdge?
    @State private var showUnconfirmed = false

    private var unconfirmed: [MemoryPerson] { memory.overview.people.filter { !$0.confirmed } }
    private var eligible: [MemoryPerson] {
        memory.overview.people.filter { showUnconfirmed || $0.confirmed || $0.id == memory.person }
    }

    private var nodes: [MemoryPerson] {
        let all = eligible
        guard !memory.person.isEmpty else { return Array(all.prefix(12)) }
        let adjacent = Set(memory.overview.edges.filter { $0.a == memory.person || $0.b == memory.person }.flatMap { [$0.a,$0.b] })
        let centre = all.filter { $0.id == memory.person }
        return centre + all.filter { $0.id != memory.person && adjacent.contains($0.id) }.prefix(11)
    }
    private var edges: [MemoryEdge] {
        let ids = Set(nodes.map(\.id))
        return memory.overview.edges.filter { ids.contains($0.a) && ids.contains($0.b) }
    }
    private func position(_ index: Int, size: CGSize) -> CGPoint {
        let angle = Double(index) / Double(max(nodes.count, 1)) * .pi * 2 - .pi/2
        return CGPoint(x: size.width/2 + cos(angle) * max(40, size.width/2 - 90),
                       y: size.height/2 + sin(angle) * (size.height/2 - 45))
    }

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Кто встречался вместе").font(Kind.head(17))
                    Text("Линия — общая встреча, толщина — число встреч. Нажмите на человека или связь ниже.")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
                if !memory.person.isEmpty {
                    Button("Все участники") { memory.person = ""; edge = nil }.buttonStyle(QuietButton())
                }
            }
            HStack {
                Toggle("Показать голоса без карточек (\(unconfirmed.count))", isOn: $showUnconfirmed)
                    .toggleStyle(.checkbox).font(Kind.body(12))
                Spacer()
                Menu("Выбрать участника") {
                    ForEach(memory.overview.people) { person in
                        Button(person.name + person.mark) {
                            memory.person = person.id; edge = nil
                        }
                    }
                }
            }.padding(.top, 12)
            if nodes.isEmpty {
                Text(unconfirmed.isEmpty ? "Граф появится после обработки встреч с разделением по голосам."
                     : "Пока нет подтверждённых людей. Назовите голоса в списке ниже или включите их показ на графе.")
                    .font(Kind.body(14)).foregroundStyle(p.muted).padding(.vertical, 40)
            } else {
                GeometryReader { geometry in
                    ZStack {
                        Canvas { context, size in
                            for link in edges {
                                guard let a = nodes.firstIndex(where: { $0.id == link.a }),
                                      let b = nodes.firstIndex(where: { $0.id == link.b }) else { continue }
                                var path = Path()
                                path.move(to: position(a, size: size))
                                path.addLine(to: position(b, size: size))
                                context.stroke(path, with: .color(p.accent2.opacity(edge?.id == link.id ? 0.9 : 0.25)),
                                               lineWidth: CGFloat(min(6, 1 + link.meetings.count)))
                            }
                        }.accessibilityHidden(true)
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, person in
                            Button {
                                memory.person = person.id; edge = nil
                            } label: {
                                VStack(spacing: 4) {
                                    Text(person.name).font(Kind.strong(12)).lineLimit(2).multilineTextAlignment(.center)
                                    Text("\(person.meetings) встр. · \(person.quotes) фр.").font(Kind.body(10)).foregroundStyle(p.muted)
                                    if !person.confirmed { Text("без карточки").font(Kind.body(9)).foregroundStyle(p.muted) }
                                }.padding(10).frame(width: 142)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(person.id == memory.person ? p.accent2 : p.line2, lineWidth: 1.5))
                            }.buttonStyle(.plain).position(position(index, size: geometry.size))
                        }
                    }
                }.frame(height: 410).padding(.vertical, 12)
                Text("Показано \(nodes.count) из \(eligible.count) выбранных участников. По умолчанию — только подтверждённые люди из актуальных версий встреч. Остальные доступны через «Выбрать участника» и список ниже.")
                    .font(Kind.body(11)).foregroundStyle(p.muted)
                if !memory.person.isEmpty {
                    Button("Показать историю выбранного человека") {
                        memory.query = ""; memory.meeting = ""; memory.tab = "search"
                        memory.search(settings: settings)
                    }.buttonStyle(PrimaryButton()).disabled(memory.busy).padding(.top, 10)
                }
                Divider().overlay(p.line2).padding(.vertical, 12)
                Text("Связи и встречи-основания").font(Kind.strong(14))
                if edges.isEmpty { Text("Для этих голосов общих встреч пока нет.").foregroundStyle(p.muted) }
                ForEach(edges.prefix(36)) { link in
                    Button {
                        edge = edge?.id == link.id ? nil : link
                    } label: {
                        HStack {
                            Text(name(link.a) + " ↔ " + name(link.b)).lineLimit(1)
                            Spacer()
                            Text("\(link.meetings.count) встр.")
                        }.font(Kind.body(12)).padding(.vertical, 5)
                    }.buttonStyle(.plain).foregroundStyle(edge?.id == link.id ? p.accent2 : p.text)
                    if edge?.id == link.id {
                        ForEach(link.meetings, id: \.self) { mid in
                            Button {
                                memory.meeting = mid; memory.person = ""; memory.query = ""
                                memory.tab = "search"; memory.search(settings: settings)
                            } label: {
                                Label(memory.overview.meetings.first(where: { $0.id == mid })?.title ?? "Встреча", systemImage: "text.bubble")
                            }.buttonStyle(QuietButton()).disabled(memory.busy)
                        }
                    }
                }
                if edges.count > 36 { Text("Выберите человека, чтобы сузить список связей.").font(Kind.body(12)).foregroundStyle(p.muted) }
            }
            if !unconfirmed.isEmpty {
                Divider().overlay(p.line2).padding(.vertical, 12)
                DisclosureGroup("Голосов без карточки: \(unconfirmed.count) — это голоса, известные только внутри своей встречи") {
                    Text("Для этих голосов нет сохранённой привязки к человеку. Даже если короткого образца нет в «Новых голосах», откройте реплики и выберите «Уточнить, кто говорит…» в контексте.")
                        .font(Kind.body(12)).foregroundStyle(p.muted).padding(.vertical, 8)
                    ForEach(unconfirmed) { person in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name).font(Kind.strong(12))
                                Text("\(person.quotes) фр." + (person.title.map { " · \($0)" } ?? ""))
                                    .font(Kind.body(11)).foregroundStyle(p.muted)
                            }
                            Spacer()
                            Button("Разобрать реплики") {
                                memory.person = person.id; memory.query = ""; memory.meeting = ""
                                memory.tab = "search"; memory.search(settings: settings)
                            }.buttonStyle(QuietButton()).disabled(memory.busy)
                        }.padding(.vertical, 5)
                    }
                }.font(Kind.body(13))
            }
        }
    }
    private func name(_ id: String) -> String { memory.overview.people.first(where: { $0.id == id })?.name ?? id }
}
