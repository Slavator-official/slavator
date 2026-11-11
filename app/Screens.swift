import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «1 встреча», «2 встречи», «5 встреч».
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let tail = n % 10, hundred = n % 100
    if tail == 1 && hundred != 11 { return "\(n) \(one)" }
    if (2...4).contains(tail) && !(12...14).contains(hundred) { return "\(n) \(few)" }
    return "\(n) \(many)"
}

/// Длительность словами для сводок: «6 ч 20 мин», «45 мин».
func spokenLength(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours) ч \(minutes) мин" : "\(max(minutes, total > 0 ? 1 : 0)) мин"
}

/// Одинаковая остановка в панели новой встречи и в постоянной нижней полосе.
@discardableResult
func finishMeeting(capture: LiveCapture, pipeline: Pipeline, library: Library) -> URL? {
    guard let url = capture.stop() else { return nil }
    if let warning = capture.failure { showAlert("Запись сохранена с ограничением", warning) }
    guard capture.seconds >= 3 else {
        showAlert("Слишком короткая запись", "Записано меньше трёх секунд. Аудиофайл сохранён в папке результатов.")
        return url
    }
    guard !pipeline.isRunning else {
        showAlert("Запись сохранена", "Другая встреча ещё обрабатывается. Новая запись выбрана в «Записях» — запустите её, когда обработка завершится.")
        return url
    }
    // Дорожки сведены в один файл ещё при остановке, отдельной микрофонной
    // больше нет: второй проход распознавания по ней стоил на встрече в
    // двадцать минут лишние полчаса ожидания.
    pipeline.run(input: url, library: library)
    return url
}

func showAlert(_ title: String, _ text: String) {
    let box = NSAlert()
    box.messageText = title
    box.informativeText = text
    box.addButton(withTitle: "Понятно")
    box.runModal()
}

/// Обёртка, чтобы стиль кнопки можно было выбирать по условию.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Записи

/// Разговор о том, к какому проекту отнести встречу.
///
/// Спрашиваем здесь, а не окном сразу после обработки: разбор заканчивается
/// когда придётся, и перебивать человека вопросом о папке — плохая цена за
/// аккуратность. Встреча ждёт в списке столько, сколько нужно.
struct ProjectSheet: View {
    let record: Record
    @Bindable var library: Library
    var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var answers = ""
    @State private var chosen = ""

    private var card: MeetingCard { record.meeting ?? MeetingCard() }
    private var known: [String] { Library.projectNames() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("К какому проекту отнести встречу").font(Kind.head(16))
            Text(record.title).font(Kind.body(13)).foregroundStyle(p.muted)

            if !card.project.isEmpty {
                Card {
                    Text("Ядро предполагает: «\(card.project)»").font(Kind.strong(13.5))
                    if !card.why.isEmpty {
                        Text(card.why).font(Kind.body(12.5)).foregroundStyle(p.muted)
                            .padding(.top, 4)
                    }
                }
            }

            if !card.questions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Вопросы к вам").font(Kind.eyebrow()).foregroundStyle(p.faint)
                    ForEach(card.questions, id: \.self) { question in
                        Text("— \(question)").font(Kind.body(13))
                    }
                }
                TextEditor(text: $answers)
                    .font(Kind.body(13)).frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                Button("Ответить и переспросить") {
                    pipeline.clarify(record: record, answers: answers, library: library)
                    dismiss()
                }
                .buttonStyle(QuietButton(wide: true))
                .disabled(answers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider().overlay(p.line2)

            Text("Или выберите сами").font(Kind.eyebrow()).foregroundStyle(p.faint)
            HStack(spacing: 10) {
                Picker("", selection: $chosen) {
                    // Идентификатор ForEach задаёт выбор без .tag(), который
                    // в новом SDK добавляет зависимость от macOS 15.
                    ForEach([""] + known.filter { !$0.isEmpty } +
                            (!card.project.isEmpty && !known.contains(card.project) ? [card.project] : []), id: \.self) { project in
                        Text(project.isEmpty ? "не выбран" :
                                (known.contains(project) ? project : "Добавить «\(project)»"))
                    }
                }
                .labelsHidden().frame(width: 260)

                Button("Сохранить") {
                    pipeline.assign(record: record, project: chosen,
                                    remember: !known.contains(chosen), library: library)
                    dismiss()
                }
                .buttonStyle(PrimaryButton())
                .disabled(chosen.isEmpty)
            }

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton())
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(p.surface)
    }
}

// MARK: - Спикеры

struct SpeakerProfilesScreen: View {
    @Bindable var library: Library
    var player: Player
    @Binding var screen: Screen
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(text: "Спикеры")
            Card {
                HStack {
                    Text("Все люди").font(Kind.head(16))
                    Spacer()
                    if !library.unknown.isEmpty {
                        Button("Новые голоса · \(library.unknown.count)") { screen = .newVoices }
                            .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
                    }
                }
                .padding(.bottom, 14)

                if library.speakers.isEmpty {
                    Text("Пока никого нет. Люди появятся, когда вы назовёте голоса со встреч.")
                        .font(Kind.body(13.5)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    VStack(spacing: 2) {
                        ForEach(library.speakers) { person in
                            RowBox {
                                PlayDot(size: 28) { playSample(person) }
                                Avatar(text: person.initials, colour: library.color(for: person))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).font(Kind.strong(14.5))
                                    if !person.subtitle.isEmpty {
                                        Text(person.subtitle).font(Kind.body(12.5))
                                            .foregroundStyle(p.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("\(person.samples)").font(Kind.mono(13)).foregroundStyle(p.text)
                                    Text("образцов").font(Kind.body(11)).foregroundStyle(p.muted)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { screen = .person(person.key) }
                        }
                    }
                }
            }
        }
    }

    private func playSample(_ person: Speaker) {
        let folder = Paths.profiles.appending(path: "samples/\(person.key)")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        guard let first = items.first(where: { $0.pathExtension.lowercased() == "wav" }) else {
            showAlert("Нет образцов", "Для этого человека пока нет записей голоса.")
            return
        }
        player.play(url: first, label: person.name, subtitle: person.subtitle,
                    colour: library.color(for: person))
    }
}

// MARK: - Новые голоса

struct NewVoicesScreen: View {
    @Bindable var library: Library
    var player: Player
    @Environment(\.palette) private var p
    @State private var selected: Set<URL> = []
    @State private var enrolling = false
    /// Имя, с которым открыть окно привязки: подсказка «по разговору» или
    /// ничего, если человек выбрал «Другой человек…».
    @State private var suggested: String?

    private var dismissed: [UnknownVoice] { library.dismissed }
    @State private var split = VoiceSplit()

    /// Отмеченные голоса. Порядок — как в списке.
    private var chosen: [UnknownVoice] { library.unknown.filter { selected.contains($0.url) } }

    /// Встречи с неразобранными голосами, свежие сверху.
    private var meetings: [URL] {
        var seen: [URL] = []
        for record in library.records where library.unknown.contains(where: { $0.record == record.dir }) {
            seen.append(record.dir)
        }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(text: "Новые голоса")
                Spacer()
                // Отложенные голоса не исчезают навсегда: имя может
                // вспомниться через неделю, а голос к тому времени должен
                // где-то лежать.
                Menu {
                    if dismissed.isEmpty { Text("Здесь пусто") }
                    ForEach(dismissed) { voice in
                        Button("Вернуть: \(library.label(for: voice)) · \(voice.record.lastPathComponent.replacingOccurrences(of: "_result", with: ""))") {
                            library.restoreUnknown(voice)
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.fill.xmark")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(p.muted)
                            .frame(width: 28, height: 24)
                        if !dismissed.isEmpty {
                            Text("\(dismissed.count)")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(p.accent))
                                .offset(x: 7, y: -2)
                        }
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 36)
                .help(dismissed.isEmpty ? "Отложенных голосов нет"
                      : "Отложено голосов: \(dismissed.count)")
            }

            if library.unknown.isEmpty {
                Card {
                    Text(dismissed.isEmpty ? "Все голоса определены"
                         : "Все голоса разобраны. Отложенные лежат под значком справа сверху.")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 26)
                }
            } else {
                if let failure = split.failure {
                    Text(failure).font(Kind.body(12)).foregroundStyle(p.warn)
                        .textSelection(.enabled).padding(.bottom, 10)
                }
                // Голоса разложены по встречам: SPEAKER_02 из разных встреч —
                // разные люди, и в общей куче их легко было отметить вместе
                // как одного.
                ForEach(meetings, id: \.self) { record in
                    Card {
                        Text(record.lastPathComponent.replacingOccurrences(of: "_result", with: ""))
                            .font(Kind.head(15))
                        Text("Один человек часто распадается на несколько голосов — отметьте их вместе. Голоса из разных встреч объединяйте, только если это точно один человек.")
                            .font(Kind.body(12.5)).foregroundStyle(p.muted)
                            .padding(.top, 3).padding(.bottom, 14)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                                  spacing: 12) {
                            ForEach(library.unknown.filter { $0.record == record }) { voice in
                                VoiceCard(voice: voice, library: library, player: player,
                                          selected: selected.contains(voice.url),
                                          busy: split.isRunning) {
                                    if selected.contains(voice.url) { selected.remove(voice.url) }
                                    else { selected.insert(voice.url) }
                                } assign: { suggestion in
                                    selected = [voice.url]
                                    suggested = suggestion
                                    enrolling = true
                                } dismiss: {
                                    selected.remove(voice.url)
                                    library.dismissUnknown(voice)
                                } split: { count in
                                    selected.remove(voice.url)
                                    split.split(voice: voice, into: count, library: library) { }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }

                if !selected.isEmpty {
                    HStack(spacing: 12) {
                        Text(selectionTitle).font(Kind.strong(14))
                        Spacer()
                        Button("Снять выбор") { selected.removeAll() }
                            .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.muted)
                        // Те же пункты, что и на карточке: кнопка называется
                        // так же, и открывать она должна то же самое.
                        // Разделение — только для одного голоса: делить
                        // отмеченную пачку сразу означало бы делить каждый на
                        // одно и то же число, чего никто не имеет в виду.
                        Menu {
                            Button("Выбрать человека…") {
                                suggested = nil
                                enrolling = true
                            }
                            // Делить можно только один голос: у отмеченной
                            // пачки это означало бы разделить каждый на одно и
                            // то же число, чего никто не имеет в виду. Пункт
                            // не гасим, а убираем — погашенный заставляет
                            // гадать, чего ему не хватает.
                            if let voice = chosen.first, chosen.count == 1 {
                                Divider()
                                Menu("Здесь несколько человек") {
                                    ForEach(2...6, id: \.self) { count in
                                        Button("Разделить на \(count) " + (count < 5 ? "человека" : "человек")) {
                                            selected.removeAll()
                                            split.split(voice: voice, into: count, library: library) { }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button(chosen.count == 1 ? "Не определяется" : "Не определяются") {
                                let voices = chosen
                                selected.removeAll()
                                for voice in voices { library.dismissUnknown(voice) }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Text("Привязать").font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 15).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(split.isRunning ? p.raised : p.accent))
                            .contentShape(Rectangle())
                        }
                        // Ширина числом: fixedSize() тянет _FixedSizeLayout из
                        // SwiftUICore, которого в macOS 14 нет.
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: 124).disabled(split.isRunning)
                    }
                    .padding(14)
                    .background(p.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .padding(.top, 12)
                }
            }
        }
        .sheet(isPresented: $enrolling) {
            EnrollSheet(library: library, samples: Array(selected), suggestion: suggested) {
                selected.removeAll()
                suggested = nil
            }
        }
    }

    private var selectionTitle: String {
        let n = selected.count
        let tail = n % 10, hundred = n % 100
        if hundred >= 11 && hundred <= 14 { return "Выбрано \(n) голосов" }
        if tail == 1 { return "Выбран \(n) голос" }
        if tail >= 2 && tail <= 4 { return "Выбрано \(n) голоса" }
        return "Выбрано \(n) голосов"
    }
}

private struct VoiceCard: View {
    @Environment(\.palette) private var p
    let voice: UnknownVoice
    var library: Library
    var player: Player
    var selected: Bool = false
    var busy = false
    var toggle: () -> Void = {}
    /// Привязать голос. Аргумент — имя, которым заполнить окно: подсказка
    /// по разговору, или nil, чтобы выбрать человека самому.
    var assign: (String?) -> Void = { _ in }
    var dismiss: (() -> Void)? = nil
    var split: ((Int) -> Void)? = nil

    /// Реплики встречи, из которой взят голос.
    private var turns: [Turn] {
        library.records.first { $0.dir == voice.record }?.turns ?? []
    }

    /// Свои отрезки в цвете, чужие — приглушённой заливкой: сразу видно,
    /// в каких местах встречи звучит именно этот голос.
    private var highlighted: [Turn] {
        let mine = voice.label
        return turns.map {
            $0.speaker == mine ? $0
                : Turn(start: $0.start, end: $0.end, speaker: "", name: "")
        }
    }

    var body: some View {
        Card(padding: 15) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selected ? p.accent : p.faint)
                }
                .buttonStyle(.plain)
                PlayDot { player.play(url: voice.url, label: library.label(for: voice),
                                      subtitle: "неопознанный голос",
                                      colour: library.color(for: voice)) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(library.color(for: voice)).frame(width: 9, height: 9)
                        Text(library.label(for: voice)).font(Kind.strong(14))
                    }
                    Text(voice.record.lastPathComponent
                        .replacingOccurrences(of: "_result", with: ""))
                        .font(Kind.body(12.5)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            if !turns.isEmpty {
                Eyebrow(text: "Где звучит на встрече").padding(.bottom, 6)
                Ribbon(turns: highlighted, height: 26, library: library,
                       record: library.records.first { $0.dir == voice.record })
                    .padding(.bottom, 12)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: voice.guess != nil ? "sparkles" : "questionmark.circle")
                    .font(.system(size: 13)).foregroundStyle(voice.guess != nil ? p.accent2 : p.warn)
                Text(voice.guess.map {
                    voice.guessedByVoice
                        // Честно про степень доверия: сходство голоса с
                        // карточкой из одного образца уже ошибалось.
                        ? "Голосом похож на \($0), но образцов у карточки мало — послушайте и проверьте"
                        : "Похоже, это \($0) — определено по разговору"
                } ?? "По разговору имя определить не удалось: по имени к нему не обращались.")
                    .font(Kind.body(13)).foregroundStyle(p.text)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(voice.guess != nil ? p.selection : p.warnBg))
            .padding(.bottom, 12)

            // Всё, что можно сделать с голосом, — под одной кнопкой.
            // Разделение и «не определяется» стояли рядом с ней тремя
            // равноправными действиями и на узкой карточке переносились по
            // слогам, хотя выбирают из них раз в жизни.
            HStack(spacing: 8) {
                Menu {
                    if let guess = voice.guess {
                        Button("Это \(guess)") { assign(guess) }
                        // Подсказка по разговору ошибается: человека зовут по
                        // имени, а говорит в этот момент другой. Выбрать
                        // иначе раньше было некуда — пункт вёл в то же окно.
                        Button("Другой человек…") { assign(nil) }
                    } else {
                        Button("Выбрать человека…") { assign(nil) }
                    }
                    if let split {
                        Divider()
                        // Сколько человек — говорит человек, а не подбор:
                        // подбор на реальной записи перескакивает нужное
                        // число, ради этого пункт и нужен.
                        Menu("Здесь несколько человек") {
                            ForEach(2...6, id: \.self) { count in
                                Button("Разделить на \(count) " + (count < 5 ? "человека" : "человек")) {
                                    split(count)
                                }
                            }
                        }
                    }
                    if let dismiss {
                        Divider()
                        Button("Не определяется") { dismiss() }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text("Привязать").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(busy ? p.raised : p.accent))
                    .contentShape(Rectangle())
                }
                // Ширина задана числом: fixedSize() тянет за собой
                // _FixedSizeLayout из SwiftUICore, которого в macOS 14 нет, и
                // сборка такой бинарник не пропускает.
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 124).disabled(busy)
                .help("Назвать человека, разделить голос на нескольких или убрать из списка")
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(selected ? p.accent : .clear, lineWidth: 2))
    }
}

// MARK: - Карточка человека

struct PersonScreen: View {
    @Bindable var library: Library
    var player: Player
    let key: String
    @Binding var screen: Screen
    var memory: SpeakerMemory
    @Environment(\.palette) private var p

    private var person: Speaker? { library.speakers.first { $0.key == key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackButton(title: "Спикеры") { screen = .speakers }
            if let person {
                HStack(spacing: 14) {
                    Avatar(text: person.initials, colour: library.color(for: person), size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(Kind.title(20))
                        if !person.subtitle.isEmpty {
                            Text(person.subtitle).font(Kind.body(13.5)).foregroundStyle(p.muted)
                        }
                    }
                    Spacer()
                }
                Card {
                    Text("Память о человеке").font(Kind.head(16)).padding(.bottom, 8)
                    if let info = memory.overview.people.first(where: { $0.id == "profile:" + key }) {
                        Text("\(info.meetings) встреч · \(info.quotes) фрагментов · последняя обработка \(info.last_seen.prefix(10))")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                    } else {
                        Text("История появится, когда голос будет связан с репликами сохранённых встреч.")
                            .font(Kind.body(13)).foregroundStyle(p.muted)
                    }
                    Button("Открыть высказывания и поиск") {
                        memory.person = "profile:" + key; memory.query = ""; memory.meeting = ""
                        memory.tab = "search"; screen = .memory
                        memory.search(settings: library.settings)
                    }.buttonStyle(PrimaryButton()).disabled(memory.busy).padding(.top, 12)
                }
                Card {
                    Text("Образцы голоса").font(Kind.head(16)).padding(.bottom, 14)
                    let samples = sampleFiles(person)
                    if samples.isEmpty {
                        Text("Образцов пока нет").font(Kind.body(13.5)).foregroundStyle(p.muted)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(samples, id: \.self) { url in
                                RowBox {
                                    PlayDot(size: 28) {
                                        player.play(url: url, label: person.name,
                                                    subtitle: "образец голоса",
                                                    colour: library.color(for: person))
                                    }
                                    Text(url.lastPathComponent).font(Kind.body(13))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Человек не найден").font(Kind.body()).foregroundStyle(p.muted)
            }
        }
        // Память живёт на своём экране, и раньше её считывал он же. Карточка
        // человека без этого встречала пустым «история появится»: посчитано
        // всё, но только для того, кто по дороге заглянул в «Память встреч».
        .onAppear { memory.activate(settings: library.settings) }
    }

    private func sampleFiles(_ person: Speaker) -> [URL] {
        let folder = Paths.profiles.appending(path: "samples/\(person.key)")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "wav" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

// MARK: - Настройки

struct SettingsScreen: View {
    @Bindable var library: Library
    var dictation: Dictation
    var pipeline: Pipeline
    @Environment(\.palette) private var p
    /// Дополнительные настройки раскрыты. Не сохраняется: это не настройка,
    /// а состояние разговора — вернулся в настройки, значит пришёл за другим.
    @State private var modelExtras = false

    /// Что уже скачано. Считается при открытии настроек и после каждой
    /// загрузки: строка «скачана» врёт хуже, чем её отсутствие.
    /// У языковых `nil` — Ollama не ответила, это отдельный разговор.
    @State private var installedASR: Set<String> = []
    @State private var installedLLM: Set<String>? = nil

    private var threshold: Double { library.settings.voice_threshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: "Настройки")

            dictationCard

            Card {
                Text("О себе").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Ваше имя",
                           subtitle: "Так подписываются ваши реплики при записи звонка") {
                    TextField("Вы", text: Binding(
                        get: { library.settings.my_name },
                        set: { library.settings.my_name = $0; library.settings.save() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Должность") {
                    TextField("", text: Binding(
                        get: { library.settings.my_position },
                        set: { library.settings.my_position = $0; library.saveMyCard() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Компания") {
                    TextField("", text: Binding(
                        get: { library.settings.my_company },
                        set: { library.settings.my_company = $0; library.saveMyCard() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if library.mySpeaker != nil {
                    Text("То же самое стоит в вашей карточке в «Спикерах».")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }

            Card {
                Text("Распознавание речи").font(Kind.head(16)).padding(.bottom, 12)
                // Выборов было два: переключатель «что важнее» на виду и
                // список «другая модель» под кнопкой. Поле у них одно, спорить
                // не о чем — а человек ни по одному из них не видел ни того,
                // что уже скачано, ни того, что потянет его машина. Теперь
                // выбор один и в нём всё это написано.
                ModelPicker(options: ModelCatalog.asr,
                            installed: installedASR,
                            recommended: ModelCatalog.recommendedASR(),
                            selection: Binding(
                                get: { library.settings.asr_model },
                                set: { library.settings.asr_model = $0; library.settings.save() }))
                Text("Ненайденная модель скачается сама перед первой встречей. Старые расшифровки не меняются: выбор применяется к следующей. Для GigaAM настройка Whisper не используется.")
                    .font(Kind.body(12)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Divider().overlay(p.line2).padding(.top, 6)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { modelExtras.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Дополнительно").font(Kind.body(14))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(modelExtras ? 90 : 0))
                        Spacer()
                    }
                    .foregroundStyle(p.accent2)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if modelExtras {
                    // Единственно верного порога нет: у одного человека
                    // близость голоса лежит в 0,83–0,98, у разных доходит до
                    // 0,91 — зоны перекрываются, и где резать, зависит от
                    // микрофона и от того, что дороже: лишний вопрос или
                    // склеенные люди.
                    SettingRow(title: "Порог узнавания голоса",
                               subtitle: threshold == 0.90 ? "Измеренное значение — 0,90"
                                   : (threshold < 0.90 ? "Ниже измеренного: узнаёт чаще, но склеит похожих"
                                                       : "Выше измеренного: спросит лишний раз, но не перепутает")) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(
                                get: { threshold },
                                set: { library.settings.voice_threshold = (($0 * 100).rounded()) / 100
                                       library.settings.save() }),
                                in: 0.70...0.98, step: 0.01)
                                .frame(width: 170)
                            Text(String(format: "%.2f", threshold))
                                .font(Kind.mono(13)).frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }

            // Языковая модель — своя карточка, а не строка под кнопкой в
            // распознавании речи: это другая работа и другая загрузка, и
            // рядом с моделью распознавания её каждый раз принимали за неё же.
            Card {
                Text("Резюме и чат").font(Kind.head(16))
                Text("Языковая модель Ollama: пишет резюме встречи, находит решения и отвечает в чате")
                    .font(Kind.body(12.5)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3).padding(.bottom, 12)
                ModelPicker(options: ModelCatalog.llm,
                            installed: installedLLM ?? [],
                            recommended: ModelCatalog.recommendedLLM(),
                            download: { pipeline.pullModel($0, library: library) },
                            busy: pipeline.isRunning,
                            selection: Binding(
                                get: { library.settings.llm_model },
                                set: { library.settings.llm_model = $0; library.settings.save() }))
                if installedLLM == nil {
                    // «Ничего не установлено» и «некому ответить» — разные
                    // вещи: во втором случае кнопка «Скачать» тоже не сработает.
                    Text("Ollama не отвечает, поэтому не видно, что установлено. Она ставится вместе со Славатором и должна быть запущена.")
                        .font(Kind.body(12)).foregroundStyle(p.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            }

            Card {
                Text("Оформление").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Тема") {
                    Segmented(options: [("dark", "Тёмная"), ("light", "Светлая"), ("system", "Авто")],
                              selection: Binding(
                                get: { library.settings.theme },
                                set: { library.settings.theme = $0; library.settings.save(); library.reload() }))
                        .frame(width: 260)
                }
            }

            Card {
                Text("Быстрый доступ").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Значок в строке меню",
                           subtitle: "Начать запись, не открывая окно") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.menubar_enabled },
                        set: { library.settings.menubar_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Виджет на рабочем столе",
                           subtitle: "Кнопка записи поверх обоев, под окнами — как системные виджеты") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.widget_enabled },
                        set: { library.settings.widget_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if library.settings.widget_enabled {
                    Divider().overlay(p.line2)
                    SettingRow(title: "Размер виджета") {
                        // «Значок», а не «маленький»: это не уменьшенная копия
                        // остальных, а другой вид — одна кнопка без подписей.
                        Segmented(options: [("small", "Значок"), ("medium", "Средний"),
                                            ("large", "Большой")],
                                  selection: Binding(
                                    get: { library.settings.widget_size },
                                    set: { library.settings.widget_size = $0; library.settings.save() }))
                            .frame(width: 280)
                    }
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Предлагать запись, когда начинается встреча",
                           subtitle: "Славатор заметит, что микрофон занят звонком, и спросит одним уведомлением") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.meeting_watch_enabled },
                        set: { library.settings.meeting_watch_enabled = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Card {
                Text("Хранение данных").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Папка для результатов", subtitle: library.settings.results_dir) {
                    Button("Изменить") { chooseFolder() }.buttonStyle(QuietButton())
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Папка для записей",
                           subtitle: library.settings.recordings_dir.isEmpty
                               ? "Там же, где результаты: \(library.settings.results_dir)"
                               : library.settings.recordings_dir) {
                    HStack(spacing: 8) {
                        if !library.settings.recordings_dir.isEmpty {
                            Button("Сбросить") {
                                library.settings.recordings_dir = ""
                                library.settings.save()
                            }.buttonStyle(QuietButton())
                        }
                        Button("Изменить") { chooseRecordingsFolder() }.buttonStyle(QuietButton())
                    }
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Автоопределение проекта и группировка",
                           subtitle: "После резюме встреча относится к проекту и ложится в его папку. Нужна Ollama") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.project_grouping },
                        set: { library.settings.project_grouping = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Список проектов",
                           subtitle: "\(projectCount) проектов. Название и то, как его называют в речи") {
                    Button("Открыть") { openProjects() }.buttonStyle(QuietButton())
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Хранить диагностические данные",
                           subtitle: "Сохранять рабочий WAV для диагностики; занимает дополнительное место") {
                    Toggle("Хранить диагностические данные", isOn: Binding(
                        get: { library.settings.keep_diagnostics },
                        set: { library.settings.keep_diagnostics = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Card {
                Text("Термины команды").font(Kind.head(16)).padding(.bottom, 12)
                SettingRow(title: "Словарь", subtitle: "Терминов: \(glossaryCount)") {
                    Button("Открыть") { NSWorkspace.shared.open(Paths.glossary) }
                        .buttonStyle(QuietButton())
                }
            }
        }
        .task { await refreshInstalled() }
        // Загрузка кончилась — модель либо приехала, либо нет. Пересчитываем:
        // иначе только что скачанная так и стоит в списке ненайденной.
        .onChange(of: pipeline.isRunning) { _, running in
            if !running { Task { await refreshInstalled() } }
        }
    }

    /// Спросить диск и Ollama, что из списка уже стоит.
    private func refreshInstalled() async {
        let cached = await Task.detached(priority: .utility) { ModelCatalog.installedASR() }.value
        let ollama = await ModelCatalog.installedLLM()
        installedASR = cached
        installedLLM = ollama
    }

    /// Сколько проектов в списке. Считаем по файлу: его правят руками, и
    /// показывать надо то, что там сейчас, а не то, что мы помним.
    private var projectCount: Int {
        guard let data = try? Data(contentsOf: Paths.projects),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = raw["projects"] as? [Any] else { return 0 }
        return items.count
    }

    private func openProjects() {
        if !FileManager.default.fileExists(atPath: Paths.projects.path) {
            // Пустой список с примером: пустой файл человек закроет, не поняв,
            // что от него хотят.
            let sample = """
            {
              "projects": [
                {"name": "Название проекта", "aliases": ["как его зовут в речи"]}
              ]
            }
            """
            try? FileManager.default.createDirectory(
                at: Paths.projects.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? sample.write(to: Paths.projects, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.projects)
    }

    private var glossaryCount: Int {
        guard let text = try? String(contentsOf: Paths.glossary, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                   && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.results_dir = url.path
            library.settings.save()
            library.reload()
        }
    }

    /// Куда складывать сами записи встреч.
    ///
    /// Отдельно от результатов: запись — это исходник на десятки мегабайт, и
    /// держать его хочется не там, где лежат стенограммы, а иногда и не на
    /// системном диске.
    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.recordings_dir = url.path
            library.settings.save()
        }
    }
}

extension SettingsScreen {
    var dictationCard: some View {
        Card {
            HStack(spacing: 10) {
                Text("Диктовка").font(Kind.head(16))
                Spacer()
                // Когда не хватает доступа, надпись — кнопка: искать нужный
                // раздел в Системных настройках человек не обязан.
                if case .needsAccess = dictation.state {
                    Button(dictationState) { openAccessibility() }
                        .buttonStyle(.plain)
                        .font(Kind.body(12.5)).foregroundStyle(dictationColour)
                        .underline()
                } else {
                    Text(dictationState).font(Kind.body(12.5)).foregroundStyle(dictationColour)
                }
            }
            .padding(.bottom, 12)

            SettingRow(title: "Диктовать в любое поле",
                       subtitle: "Держите \(hotkeyLabel) и говорите — текст появится там, где курсор") {
                Toggle("Диктовать в любое поле", isOn: Binding(
                    get: { library.settings.dictation_enabled },
                    set: { value in
                        library.settings.dictation_enabled = value
                        library.settings.save()
                        if value { dictation.requestAccess() }
                        dictation.refresh(settings: library.settings)
                    }))
                    .labelsHidden()
            }
            SettingRow(title: "Клавиша диктовки",
                       subtitle: "Нажмите и подержите своё сочетание: ⌘, ⌥, ⌃, ⇧, fn или несколько сразу") {
                HotkeyField(combo: Binding(
                    get: { library.settings.dictation_hotkey },
                    set: { chosen in
                        library.settings.dictation_hotkey = chosen
                        library.settings.save()
                        dictation.refresh(settings: library.settings)
                    }))
            }
            SettingRow(title: "Клавиша обработки",
                       subtitle: "Диктовка сразу с обработкой. Обычно это клавиша диктовки плюс ⇧") {
                HotkeyField(combo: Binding(
                    get: { library.settings.dictation_tidy_hotkey },
                    set: { chosen in
                        library.settings.dictation_tidy_hotkey = chosen
                        library.settings.save()
                        dictation.refresh(settings: library.settings)
                    }))
            }
            SettingRow(title: "Приглушать звук на время диктовки",
                       subtitle: "Пока держите клавишу, музыка и видео почти умолкают; отпустили — звучат как раньше") {
                Toggle("Приглушать звук на время диктовки", isOn: Binding(
                    get: { library.settings.dictation_duck },
                    set: { library.settings.dictation_duck = $0; library.settings.save() }))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingRow(title: "Модель",
                       subtitle: "«Быстро» пишет на ходу, «точно» вставляет целиком через 3 секунды") {
                Segmented(options: [("small", "Быстро"), ("large-v3-turbo", "Точно")],
                          selection: Binding(
                            get: { library.settings.dictation_model },
                            set: { library.settings.dictation_model = $0; library.settings.save() }))
                    .frame(width: 210)
            }
            SettingRow(title: "Что делает обработка",
                       subtitle: library.settings.dictation_tidy_hotkey == library.settings.dictation_hotkey
                           ? "Сочетания совпали — обработка забирает и обычную диктовку"
                           : "Убрать «ну» и «вот», согласовать окончания, сократить лишнее. Нужна Ollama") {
                Segmented(options: [("clean", "Чистка"), ("structure", "Структура"), ("shrink", "Сжатие")],
                          selection: Binding(
                            get: { library.settings.dictation_level },
                            set: { library.settings.dictation_level = $0; library.settings.save() }))
                    .frame(width: 280)
            }
        }
    }

    private var hotkeyLabel: String { HotCombo.label(library.settings.dictation_hotkey) }

    private func openAccessibility() {
        dictation.requestAccess()
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    private var dictationState: String {
        switch dictation.state {
        case .off:           return "выключена"
        case .needsAccess:   return "нужен доступ к вводу"
        case .starting:      return "готовится…"
        case .idle:          return "готова"
        case .listening:     return "слушаю"
        case .finishing:     return "дописываю"
        case .failed(let m): return m
        }
    }

    private var dictationColour: Color {
        switch dictation.state {
        case .idle, .listening, .finishing: return p.ok
        case .needsAccess, .failed:         return p.warn
        default:                            return p.muted
        }
    }
}

/// Ловушка модификаторов: обычный NSView, которому система сама шлёт
/// flagsChanged, когда он первый откликающийся.
///
/// Прямая доставка надёжнее слежки за чужими событиями: NSEvent-монитор
/// молчал, и понять почему со стороны было нельзя. Монитор оставлен рядом
/// вторым путём — лишним он не будет, повторы отсекаются множеством.
private final class KeyCatcher: NSView {
    var onFlags: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func flagsChanged(with event: NSEvent) { onFlags?(event.keyCode, event.modifierFlags) }
}

/// Назначение сочетания: нажали кнопку, подержали клавиши, отпустили.
///
/// Ловим отпускание, а не нажатие: пока клавиши держат, человек ещё набирает
/// сочетание, и «⌘» стало бы ответом раньше, чем он дошёл до «⌘⌥». Пока он
/// держит, набранное показывается прямо на кнопке — видно, что нажатие
/// дошло.
private struct HotkeyField: View {
    @Binding var combo: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var catcher: KeyCatcher?
    @State private var previousResponder: NSResponder?
    @State private var pressed: Set<UInt16> = []

    var body: some View {
        Button(caption) {
            if recording { finish(save: false) } else { begin() }
        }
        // Ширина и правый край — как у соседних переключателей: строки
        // настроек должны стоять по одной линии, иначе список выглядит
        // собранным на скорую руку.
        .buttonStyle(QuietButton(wide: true))
        .frame(width: 210)
        .onDisappear { finish(save: false) }
    }

    private var caption: String {
        guard recording else { return HotCombo.label(combo) }
        let now = HotCombo.tokens(fromKeyCodes: pressed)
        return now.isEmpty ? "Держите клавиши" : HotCombo.label(now)
    }

    private func take(code: UInt16, mods: NSEvent.ModifierFlags) {
        Dictation.logHotkey("код \(code), модификаторы \(mods.rawValue)")
        // Код клавиши в flagsChanged называет саму клавишу — по нему видна и
        // сторона. Через CGEvent это делать нельзя: у NSEvent его может не
        // оказаться вовсе, и запись молча ничего не ловила.
        if !mods.intersection([.command, .option, .control, .shift, .function]).isEmpty {
            pressed.insert(code)
        } else if !pressed.isEmpty {
            finish(save: true)              // отпустили всё — сочетание набрано
        }
    }

    private func begin() {
        pressed = []
        recording = true
        Dictation.assigningHotkey = true
        if let window = NSApp.keyWindow, let content = window.contentView {
            previousResponder = window.firstResponder
            let view = KeyCatcher(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            view.onFlags = { code, mods in take(code: code, mods: mods) }
            content.addSubview(view)
            window.makeFirstResponder(view)
            catcher = view
        }
        Dictation.logHotkey("запись начата")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            take(code: event.keyCode, mods: event.modifierFlags)
            return event
        }
    }

    private func finish(save: Bool) {
        Dictation.assigningHotkey = false
        if let catcher {
            catcher.window?.makeFirstResponder(previousResponder)
            catcher.removeFromSuperview()
        }
        catcher = nil; previousResponder = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        guard save else { return }
        let chosen = HotCombo.tokens(fromKeyCodes: pressed)
        Dictation.logHotkey("записано: \(chosen.isEmpty ? "ничего" : chosen)")
        if !chosen.isEmpty { combo = chosen }
    }
}

/// Выбор модели списком.
///
/// Переключателем такое не показать: у каждой строки своё состояние — скачана
/// она или нет, сколько качать и какую мы советуем этой машине. Ровно об этом
/// человек и спрашивает, открывая настройки моделей, а имя модели он набирать
/// не должен: набранного руками «qwen3:1.7b» с опечаткой не существует, и
/// узнаётся это уже посреди встречи.
private struct ModelPicker: View {
    @Environment(\.palette) private var p
    let options: [ModelCatalog.Choice]
    let installed: Set<String>
    let recommended: String
    /// Есть — рядом с ненайденной моделью появляется кнопка. Нет — модель
    /// приезжает сама, и кнопка соврала бы, что без неё не обойтись.
    var download: ((String) -> Void)? = nil
    var busy = false
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 6) { ForEach(rows) { row($0) } }
    }

    /// Выбранное имя, которого нет в списке: его вписали в config.env или
    /// оставила прежняя версия. Показать его надо — иначе список выглядит
    /// так, будто не выбрано ничего.
    private var rows: [ModelCatalog.Choice] {
        guard !selection.isEmpty, !options.contains(where: { $0.name == selection })
        else { return options }
        return options + [ModelCatalog.Choice(name: selection, title: "Своя модель",
                                              note: "Задана вручную — в config.env или прежней версией",
                                              weight: "")]
    }

    /// Строка — кнопка, а не картинка с нажатием: иначе на неё не попасть ни
    /// клавишей, ни голосом, и весь выбор модели остаётся только для мыши.
    ///
    /// «Скачать» стоит рядом с кнопкой строки, а не внутри неё: вложенная
    /// кнопка спорит за тот же щелчок, и какая из двух его получит — вопрос
    /// без надёжного ответа.
    private func row(_ option: ModelCatalog.Choice) -> some View {
        let chosen = option.name == selection
        let pull = download != nil && !installed.contains(option.name) && !option.weight.isEmpty
        return HStack(spacing: 12) {
            Button {
                selection = option.name
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(chosen ? p.accent : p.line)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(option.title).font(Kind.strong(13.5))
                            Text(option.name).font(Kind.mono(11.5)).foregroundStyle(p.faint)
                            if option.name == recommended {
                                Pill(text: "рекомендуем", fg: p.accent2, bg: p.accentSoft)
                            }
                        }
                        Text(option.note).font(Kind.body(12.5)).foregroundStyle(p.muted)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 8)
                    if !pull { state(option) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(option.title), \(option.name)")
            .accessibilityValue(installed.contains(option.name) ? "скачана"
                                : option.weight.isEmpty ? "" : "не скачана, \(option.weight)")
            if pull { state(option) }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(chosen ? p.accentSoft : p.row)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(chosen ? p.accent : p.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func state(_ option: ModelCatalog.Choice) -> some View {
        if installed.contains(option.name) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                Text("скачана").font(Kind.body(12.5))
            }
            .foregroundStyle(p.ok)
        } else if option.weight.isEmpty {
            EmptyView()
        } else if let download {
            HStack(spacing: 9) {
                Text(option.weight).font(Kind.body(12.5)).foregroundStyle(p.muted)
                Button("Скачать") { download(option.name) }
                    .buttonStyle(QuietButton())
                    .disabled(busy)
                    .help("Скачать через Ollama. Уже установленную не качает заново")
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle").font(.system(size: 12))
                Text(option.weight).font(Kind.body(12.5))
            }
            .foregroundStyle(p.muted)
            .help("Ещё не скачана — приедет сама перед первой встречей")
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    @Environment(\.palette) private var p
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Kind.body(14))
                if let subtitle {
                    Text(subtitle).font(Kind.body(12.5)).foregroundStyle(p.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 11)
    }
}
