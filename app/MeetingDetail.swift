import AppKit
import SwiftUI

/// Открытая встреча — правая панель «Встреч».
///
/// Сверху то, что нужно всегда: название, когда и сколько, плеер. Ниже три
/// вкладки: «Решения» — что договорились и кто сколько говорил,
/// «Источники» — файлы встречи, «Чат» — вопросы именно по этой встрече.
struct MeetingDetail: View {
    let record: Record
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var chat: Chat
    @Bindable var memory: SpeakerMemory
    @Binding var screen: Screen
    @Binding var tab: String
    let rename: () -> Void
    let delete: () -> Void
    let askProject: () -> Void
    @Environment(\.palette) private var p
    @State private var analysis: MeetingAnalysis?
    @State private var opening: [BriefLine] = []
    @State private var done: Set<String> = []

    private var unknown: [UnknownVoice] { library.unknown.filter { $0.record == record.dir } }
    private var doneKey: String { "Сделано: " + record.dir.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            playerBar
            Segmented(options: [("decisions", "Решения"), ("sources", "Источники"), ("chat", "Чат")],
                      selection: $tab)
                .frame(maxWidth: 360)
            switch tab {
            case "chat":
                ChatScreen(library: library, chat: chat, memory: memory, player: player, embedded: true)
                    .onAppear { chat.openMeeting(record.dir, title: meetingTitle(record)) }
            case "sources":
                ScrollView { sources.frame(maxWidth: .infinity, alignment: .leading) }
            default:
                ScrollView { decisions.frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        // Резюме собирается в фоне: когда оно готово, решения появляются сами.
        .onChange(of: pipeline.isRunning) { _, running in if !running { load() } }
    }

    private func load() {
        analysis = record.analysis
        opening = record.opening()
        done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
    }

    // MARK: заголовок

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meetingTitle(record)).font(Kind.title(24)).kerning(-0.4).lineLimit(2)
                    .textSelection(.enabled)
                    .help(record.title)
                Text(meetingMeta(record)).font(Kind.body(14)).monospacedDigit().foregroundStyle(p.muted)
                statusChips
            }
            Spacer(minLength: 8)
            Menu {
                Button("Переименовать…", action: rename).disabled(pipeline.isRunning || memory.busy)
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.dir]) }
                if let transcript = record.transcript {
                    Button("Открыть стенограмму") { NSWorkspace.shared.open(transcript) }
                }
                Divider()
                Button("Удалить встречу…", role: .destructive, action: delete)
                    .disabled(pipeline.isRunning || memory.busy)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text).frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
            .help("Ещё: переименовать, показать в Finder, удалить")
        }
    }

    /// Состояние встречи — значком и словами: голоса без имени, проект.
    @ViewBuilder private var statusChips: some View {
        let card = record.meeting
        if !unknown.isEmpty || card?.needs_review == true || !(card?.project ?? "").isEmpty {
            HStack(spacing: 6) {
                if !unknown.isEmpty {
                    Button { screen = .newVoices } label: {
                        chip("person.crop.circle.badge.questionmark",
                             plural(unknown.count, "голос без имени", "голоса без имени", "голосов без имени"),
                             fg: p.warn, bg: p.warnBg)
                    }
                    .buttonStyle(.plain).help("Назвать голоса в «Новых голосах»")
                }
                if let card, card.needs_review {
                    Button(action: askProject) {
                        chip("questionmark.folder", "Уточнить проект", fg: p.warn, bg: p.warnBg)
                    }
                    .buttonStyle(.plain).help("Ядро не смогло определить проект — ответьте на вопросы или выберите сами")
                } else if let card, !card.project.isEmpty {
                    Button(action: askProject) { chip("folder", card.project, fg: p.ok, bg: p.okBg) }
                        .buttonStyle(.plain).help("Проект встречи — нажмите, чтобы изменить")
                }
            }
            .padding(.top, 2)
        }
    }

    private func chip(_ symbol: String, _ text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 9).frame(height: 24)
        .background(Capsule().fill(bg))
    }

    // MARK: плеер

    private var playerBar: some View {
        let mine = player.recordingID == record.dir
        let length = mine && player.length > 0 ? player.length : record.length
        let position = mine ? player.position : 0
        let audio = record.source ?? record.ownTrack
        let playing = mine && player.isPlaying
        return HStack(spacing: 12) {
            Button {
                if mine { player.toggle() } else { player.playMeeting(record, colour: p.accent) }
            } label: {
                ZStack {
                    Circle().fill(audio == nil ? p.raised : p.accent).frame(width: 34, height: 34)
                    if mine && player.isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(audio == nil ? p.faint : Color.white)
                            .offset(x: playing ? 0 : 1)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(audio == nil)
            .help(audio == nil ? "Исходное аудио не найдено: возможно, файл перенесли или удалили."
                               : (playing ? "Пауза" : "Слушать встречу"))
            .accessibilityLabel(playing ? "Пауза" : "Слушать встречу")

            Text("\(hms(position)) / \(hms(length))")
                .font(Kind.body(13)).monospacedDigit().foregroundStyle(p.muted)

            PlayerTrack(record: record, library: library,
                        progress: length > 0 ? min(1, position / length) : 0) { fraction in
                if mine, player.canSeek { player.seek(to: fraction) }
            }

            Button {
                let speeds = Player.speeds
                let index = speeds.firstIndex(of: player.rate) ?? 0
                player.setRate(speeds[(index + 1) % speeds.count])
            } label: {
                Text(player.rateLabel).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(p.text)
                    .frame(minWidth: 38).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Скорость воспроизведения")
        }
        .padding(.horizontal, 12).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.line, lineWidth: 1))
    }

    // MARK: решения

    private var decisions: some View {
        VStack(alignment: .leading, spacing: 18) {
            let items = analysis?.decisions ?? []
            let todos = analysis?.todos ?? []
            if analysis == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Решения ещё не собраны").font(Kind.strong(14))
                    Text("Локальная модель прочитает расшифровку и выпишет решения и поручения. Это займёт несколько минут; в интернет ничего не уходит.")
                        .font(Kind.body(13)).foregroundStyle(p.muted)
                    Button(pipeline.isRunning ? "Идёт обработка…" : "Собрать решения") {
                        pipeline.summarize(record: record, library: library)
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(pipeline.isRunning)
                    .padding(.top, 2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.raised))
            } else if items.isEmpty && todos.isEmpty {
                Text("В резюме нет решений и поручений.").font(Kind.body(13.5)).foregroundStyle(p.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in check(item, detail: nil) }
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        let who = [todo.owner, todo.due].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                        check(todo.task, detail: who.isEmpty ? nil : who)
                    }
                }
            }

            Rectangle().fill(p.line2).frame(height: 1)

            HStack(alignment: .top, spacing: 20) {
                speakersBlock.frame(width: 220, alignment: .leading)
                Rectangle().fill(p.line2).frame(width: 1)
                briefBlock.frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(.top, 2)
    }

    /// Пункт-галочка. Отметки хранятся на этом Mac и переживают перезапуск.
    private func check(_ text: String, detail: String?) -> some View {
        let isDone = done.contains(text)
        return Button {
            if isDone { done.remove(text) } else { done.insert(text) }
            UserDefaults.standard.set(Array(done), forKey: doneKey)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16)).foregroundStyle(isDone ? p.accent2 : p.faint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(Kind.body(14))
                        .foregroundStyle(isDone ? p.muted : p.text)
                        .strikethrough(isDone, color: p.muted)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail).font(Kind.body(12.5)).foregroundStyle(p.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Share: Identifiable {
        let id: String
        let name: String
        /// Номер голоса, когда имя совпадает с чужим: «Валерий · голос 3».
        let note: String?
        let colour: Color
        let share: Double
        /// «39 %», а не «0 %» для голоса, сказавшего пару слов.
        var percentText: String {
            let value = share * 100
            if value > 0 && value < 1 { return "<1\u{00A0}%" }
            return "\(Int(value.rounded()))\u{00A0}%"
        }
    }

    private var shares: [Share] {
        let total = record.turns.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }
        let groups = Dictionary(grouping: record.turns, by: \.speaker)
        let order = groups.keys.sorted()
        let names = groups.mapValues { Legend.label(for: $0[0], in: record) }
        // Имя, угаданное по разговору, часто достаётся нескольким голосам:
        // три одинаковых «Валерия» читались как один человек трижды.
        let repeated = Set(Dictionary(grouping: names.values, by: { $0 }).filter { $0.value.count > 1 }.keys)
        return groups.compactMap { speaker, turns -> Share? in
            guard let first = turns.first, let name = names[speaker] else { return nil }
            let spoken = turns.reduce(0) { $0 + $1.duration }
            let number = (order.firstIndex(of: speaker) ?? 0) + 1
            return Share(id: speaker, name: name,
                         note: repeated.contains(name) ? "голос \(number)" : nil,
                         colour: library.color(for: first, in: record),
                         share: spoken / total)
        }
        .sorted { $0.share > $1.share }
    }

    private var speakersBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Спикеры").font(Kind.strong(14))
            let list = shares
            if list.isEmpty {
                Text("Голоса не разделены").font(Kind.body(13)).foregroundStyle(p.muted)
            }
            ForEach(list.prefix(6)) { share in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3).fill(share.colour).frame(width: 12, height: 12)
                    Text(share.name).font(Kind.body(13.5)).lineLimit(1).layoutPriority(1)
                    if let note = share.note {
                        Text(note).font(Kind.body(12)).foregroundStyle(p.faint).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(share.percentText).font(Kind.body(13)).monospacedDigit().foregroundStyle(p.muted)
                }
            }
            if list.count > 6 {
                Text("и ещё \(plural(list.count - 6, "голос", "голоса", "голосов"))")
                    .font(Kind.body(12.5)).foregroundStyle(p.muted)
            }
        }
    }

    /// Кратко — пересказ из резюме. Пока его нет, показываем начало
    /// разговора и честно так и подписываем.
    private var briefBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = analysis?.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text("Кратко").font(Kind.strong(14))
                Text(summary).font(Kind.body(13.5)).lineSpacing(3).textSelection(.enabled)
            } else if !opening.isEmpty {
                Text("Начало разговора").font(Kind.strong(14))
                ForEach(opening) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Text(hms(line.start)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(p.accent2)
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(p.accentSoft))
                        Text(line.text).font(Kind.body(13.5)).lineLimit(3)
                            .help(voiceName(line.name))
                    }
                }
            } else {
                Text("Кратко").font(Kind.strong(14))
                Text("Расшифровка пуста.").font(Kind.body(13)).foregroundStyle(p.muted)
            }
        }
    }

    // MARK: источники

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            let audio = record.source ?? record.ownTrack
            VStack(spacing: 0) {
                sourceRow("waveform", "Исходная запись", audio?.lastPathComponent ?? "файл не найден — его перенесли или удалили",
                          button: audio.map { url in ("Показать", { NSWorkspace.shared.activateFileViewerSelecting([url]) }) })
                divider
                sourceRow("doc.text", "Стенограмма", record.transcript == nil ? "ещё не готова" : "Word: кто, когда и что сказал",
                          button: record.transcript.map { url in ("Открыть", { NSWorkspace.shared.open(url) }) })
                divider
                if let summary = record.summary {
                    sourceRow("checklist", "Резюме и поручения", "Word: решения, задачи и ответственные",
                              button: ("Открыть", { NSWorkspace.shared.open(summary) }))
                } else {
                    sourceRow("checklist", "Резюме и поручения", "ещё не собрано",
                              button: pipeline.isRunning ? nil : ("Собрать", { pipeline.summarize(record: record, library: library) }))
                }
                divider
                sourceRow("folder", "Папка встречи", record.dir.lastPathComponent,
                          button: ("Показать", { NSWorkspace.shared.activateFileViewerSelecting([record.dir]) }))
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.line, lineWidth: 1))

            if let card = record.meeting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проект").font(Kind.strong(14))
                    if !card.project.isEmpty {
                        Text(card.project).font(Kind.body(14))
                    }
                    if !card.why.isEmpty {
                        Text(card.why).font(Kind.body(12.5)).foregroundStyle(p.muted)
                    }
                    Button(card.needs_review ? "Уточнить проект" : "Изменить проект", action: askProject)
                        .buttonStyle(card.needs_review ? AnyButtonStyle(PrimaryButton()) : AnyButtonStyle(QuietButton()))
                        .padding(.top, 4)
                }
            }
        }
        .padding(.top, 2)
    }

    private var divider: some View {
        Rectangle().fill(p.line2).frame(height: 1).padding(.leading, 54)
    }

    private func sourceRow(_ symbol: String, _ title: String, _ subtitle: String,
                           button: (String, () -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.accent2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(Kind.body(12.5)).foregroundStyle(p.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let button {
                Button(button.0, action: button.1).buttonStyle(QuietButton())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Лента голосов вместо условной «волны»: цвет — кто говорит, яркая часть —
/// уже прослушано. Нажатие переносит к месту, если запись уже играет.
private struct PlayerTrack: View {
    let record: Record
    var library: Library
    let progress: Double
    let seek: (Double) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            let span = max(record.length, 0.001)
            ZStack(alignment: .leading) {
                if record.turns.isEmpty {
                    Capsule().fill(p.raised).frame(height: 6)
                } else {
                    Canvas { context, size in
                        let bar: CGFloat = 18
                        for turn in record.turns {
                            let x = size.width * turn.start / span
                            let width = max(1.5, size.width * turn.duration / span - 1)
                            let played = turn.start / span < progress
                            let rect = CGRect(x: x, y: (size.height - bar) / 2, width: width, height: bar)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                         with: .color(library.color(for: turn, in: record).opacity(played ? 1 : 0.38)))
                        }
                    }
                }
                if progress > 0 {
                    Rectangle().fill(p.text).frame(width: 2, height: geo.size.height)
                        .offset(x: max(0, geo.size.width * progress - 1))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                seek(min(max(value.location.x / max(geo.size.width, 1), 0), 1))
            })
        }
        .frame(height: 28)
        .help("Лента голосов: цвет — кто говорит. Нажмите, чтобы перейти к месту.")
    }
}
