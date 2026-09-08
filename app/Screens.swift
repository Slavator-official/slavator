import AppKit
import SwiftUI

// MARK: - Главная

/// «Обзор» и «Живая встреча» сведены на один экран: и то и другое — способ
/// начать работу, разводить их по вкладкам незачем.
struct MainScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    var capture: LiveCapture
    var doctor: Doctor
    @Binding var screen: Screen
    @Environment(\.palette) private var p
    @State private var picked: URL?
    @State private var source = "sys"
    @State private var pulse = false
    @State private var ready = Paths.isReady
    /// Сколько человек на встрече. 0 — пусть определит сама.
    @State private var speakers = 0
    @State private var setupStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: "Главная")

            if !ready {
                setupCard
            } else if let report = doctor.report, !report.ok {
                updateCard(report)
            }

            // Обе карточки одной высоты: разъехавшиеся по высоте блоки
            // сразу читаются как небрежность.
            // Высоту выравнивает сам Card(fill:): стек берёт высоту большей
            // карточки, а обе растягиваются до неё.
            HStack(spacing: 14) {
                pickCard
                liveCard
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.45)

            if pipeline.isRunning { progressCard }
            lastMeeting

            if !library.unknown.isEmpty { unknownCard }
        }
        // Установка идёт в Терминале, отдельным процессом. Возвращение в
        // приложение - самый надёжный момент, чтобы проверить, чем кончилось.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = Paths.isReady
            doctor.refresh()
        }
        .onAppear { doctor.refresh() }
        // Дозагрузка кончилась — спрашиваем ядро заново, а не верим на слово.
        .onChange(of: pipeline.isRunning) { _, running in
            if !running { doctor.refresh() }
        }
    }

    // первый запуск: окружения ещё нет
    private var setupCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19)).foregroundStyle(p.accent).frame(width: 26)
                Text(setupStarted ? "Идёт установка" : "Славатор ещё не настроен")
                    .font(Kind.strong(14.5))
                Spacer()
            }
            Text(setupStarted
                 ? "Установка идёт в окне Терминала. Когда там появится «Готово», вернитесь сюда — программа сама подхватит окружение."
                 : "Нужно один раз развернуть распознавание речи и языковую модель: около 6 ГБ загрузки и 20–40 минут. Всё останется на этом компьютере.")
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            if !setupStarted {
                Button("Установить") {
                    setupStarted = true
                    Paths.runSetup()
                }
                .buttonStyle(PrimaryButton(wide: true))
                .padding(.top, 10)
            }
        }
    }

    // окружение стоит, но чего-то не хватает
    //
    // Отдельная карточка, а не строчка в углу: без языковой модели не будет
    // резюме, без моделей разделения — голосов. Человек должен узнать об этом
    // до того, как отдаст программе часовую запись и подождёт полчаса.
    @ViewBuilder
    private func updateCard(_ report: Readiness) -> some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.system(size: 19)).foregroundStyle(p.warn).frame(width: 26)
                Text("Требуется дозагрузка").font(Kind.strong(14.5))
                Spacer()
                if let weight = report.weight {
                    Pill(text: weight, fg: p.warn, bg: p.warnBg)
                }
            }
            Text(report.listing)
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            if report.needs_setup {
                // Библиотеки ставит установщик: ему нужны интернет, компилятор
                // и права, которых у окна программы нет.
                Text("Это доставляет установщик — он пропустит то, что уже стоит.")
                    .font(Kind.body(12)).foregroundStyle(p.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Button(setupStarted ? "Установка идёт в Терминале" : "Установить") {
                    setupStarted = true
                    Paths.runSetup()
                }
                .buttonStyle(PrimaryButton(wide: true))
                .disabled(setupStarted)
                .padding(.top, 10)
            } else {
                Button(pipeline.isRunning ? "Идёт дозагрузка" : "Дозагрузить") {
                    pipeline.repair(library: library)
                }
                .buttonStyle(PrimaryButton(wide: true))
                .disabled(pipeline.isRunning)
                .padding(.top, 10)
            }
        }
    }

    // выбрать запись
    private var pickCard: some View {
        Card(fill: true) {
            if let picked {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 21)).foregroundStyle(p.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(picked.lastPathComponent)
                            .font(Kind.strong(14)).lineLimit(1).truncationMode(.middle)
                        Text(fileInfo(picked)).font(Kind.body(12)).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 8)
                    // Выбрали не тот файл - должно быть видно, как отменить.
                    // «Другой файл» открывает диалог заново и требует что-то
                    // выбрать; отказаться было нельзя.
                    Button { self.picked = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(p.faint)
                    }
                    .buttonStyle(.plain)
                    .disabled(pipeline.isRunning)
                    .help("Убрать файл")
                }
                // Кнопки прижаты к низу, как в соседней карточке: действие
                // всегда на одной высоте, а не гуляет вслед за содержимым.
                Spacer(minLength: 14)
                // Оба ряда в общем стеке с явным зазором. На отступах они
                // налезали друг на друга: у кнопок своя внутренняя высота,
                // и складывать её с padding на глаз бесполезно.
                VStack(alignment: .leading, spacing: 14) {
                    // Число участников снимает главную причину дробления
                    // голосов: без него движок гадает и выдаёт десятки «людей».
                    HStack(spacing: 10) {
                        Text("Участников").font(Kind.body(12.5)).foregroundStyle(p.muted)
                        HStack(spacing: 0) {
                            stepButton("−") { speakers = max(0, speakers - 1) }
                            Text(speakers == 0 ? "—" : String(speakers))
                                .font(Kind.mono(13)).frame(width: 30)
                            stepButton("+") { speakers = min(12, speakers + 1) }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                        Text(speakers == 0 ? "определю сама" : "разложу ровно на \(speakers)")
                            .font(Kind.body(12)).foregroundStyle(p.faint)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Button("Начать транскрибацию") {
                            pipeline.run(input: picked, library: library, speakers: speakers)
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(pipeline.isRunning)
                        Button("Другой файл") { pick() }.buttonStyle(QuietButton())
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Button(action: pick) {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 21)).foregroundStyle(p.faint).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Выбрать запись").font(Kind.strong(14.5)).foregroundStyle(p.text)
                            Text("или перетащите файл сюда")
                                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { picked = url } }
            }
            return true
        }
    }

    /// Кнопка счётчика: тихая, без собственной рамки — рамка общая на группе.
    private func stepButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(Kind.strong(15)).foregroundStyle(p.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // слушать встречу
    private var liveCard: some View {
        Card(fill: true) {
            if capture.isRecording {
                HStack(spacing: 12) {
                    Circle().fill(Color.hex(0xE0705F)).frame(width: 10, height: 10)
                        .opacity(pulse ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                    Text(hms(capture.seconds))
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                    LevelMeter(level: capture.level)
                    Button("Остановить") { finishRecording() }.buttonStyle(QuietButton())
                }
                .onAppear { pulse = true }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "mic")
                        .font(.system(size: 19)).foregroundStyle(p.accent2).frame(width: 26)
                    Text("Слушать встречу").font(Kind.strong(14.5))
                    Spacer()
                }
                // Как в прототипе: сначала выбор источника во всю ширину,
                // под ним — кнопка запуска. Так решение и действие разнесены
                // по строкам, а не толкаются в одной.
                Segmented(options: [("sys", "Звонок"), ("mic", "Только микрофон")],
                          selection: $source)
                    .padding(.top, 12)
                Text(source == "sys"
                     ? "Собеседников из динамиков и вас с микрофона"
                     : "Только микрофон — для встречи в одной комнате")
                    .font(Kind.body(12)).foregroundStyle(p.muted)
                    .padding(.top, 6)
                Button("Начать слушать") { startRecording() }
                    .buttonStyle(PrimaryButton(wide: true))
                    .padding(.top, 8)
                if let failure = capture.failure {
                    Text(failure).font(Kind.body(12)).foregroundStyle(p.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            }
        }
    }

    private func startRecording() {
        let folder = URL(fileURLWithPath: library.settings.results_dir)
        capture.start(source: source == "mic" ? .microphone : .meeting, folder: folder)
    }

    /// Остановка сразу отправляет запись в обычную обработку: живой режим и
    /// файл сходятся в один пайплайн, иначе качество разъедется.
    private func finishRecording() {
        picked = stopAndProcess(capture: capture, pipeline: pipeline, library: library)
    }

    /// Обработка идёт долго — час записи считается десятки минут. Без
    /// внятного прогресса это неотличимо от зависшего приложения.
    private var progressCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Обработка")
                    Text(pipeline.stage).font(Kind.head(17)).foregroundStyle(p.text).padding(.top, 2)
                    if !pipeline.detail.isEmpty {
                        Text(pipeline.detail).font(Kind.body(13)).foregroundStyle(p.muted)
                    }
                }
                Spacer()
                Text("\(Int(pipeline.percent))%")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.text)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.raised).frame(height: 8)
                    Capsule().fill(p.accent)
                        .frame(width: max(0, geo.size.width * pipeline.percent / 100), height: 8)
                        .animation(.easeOut(duration: 0.3), value: pipeline.percent)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 8)
            .padding(.top, 14)

            HStack(spacing: 10) {
                ForEach(pipeline.stageOrder, id: \.self) { key in
                    Circle()
                        .fill(pipeline.reached(key) ? p.accent : p.line)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Button("Прервать") { pipeline.cancel() }.buttonStyle(QuietButton())
            }
            .padding(.top, 14)
        }
    }

    // последняя встреча с лентой
    @ViewBuilder private var lastMeeting: some View {
        if let record = library.records.first {
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Последняя встреча")
                        Text(record.title).font(Kind.head(17)).foregroundStyle(p.text).lineLimit(1)
                    }
                    Spacer()
                    Button("Все записи") { screen = .records }
                        .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
                }
                Text(meta(record)).font(Kind.body(13)).foregroundStyle(p.muted)
                    .padding(.top, 2).padding(.bottom, 16)

                Ribbon(turns: record.turns, height: 46, library: library, record: record) { turn in
                    playTurn(turn, in: record)
                }
                Ruler(length: record.length).padding(.top, 7)
                Legend(turns: record.turns, library: library, record: record)
                    .padding(.top, 14)
            }
        } else {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 26)).foregroundStyle(p.faint)
                    Text("Пока нет обработанных встреч")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                    Text("Выберите запись выше и нажмите «Начать транскрибацию»")
                        .font(Kind.body(12.5)).foregroundStyle(p.faint)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 26)
            }
        }
    }

    private var unknownCard: some View {
        Card {
            HStack {
                Text(unknownTitle).font(Kind.head(16)).foregroundStyle(p.text)
                Spacer()
                Button("Открыть") { screen = .newVoices }
                    .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.accent2)
            }
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(library.unknown.prefix(2)) { voice in
                    RowBox {
                        PlayDot(size: 28) {
                            player.play(url: voice.url, label: library.label(for: voice),
                                        subtitle: "неопознанный голос",
                                        colour: library.color(for: voice))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(voice.guess.map { "Похоже, это \($0)" }
                                 ?? library.label(for: voice))
                                .font(Kind.strong(14))
                            Text(voice.guess != nil ? "имя определено по разговору"
                                                    : "по имени к нему не обращались")
                                .font(Kind.body(12.5)).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 8)
                        Button(voice.guess != nil ? "Подтвердить" : "Выбрать человека") {
                            screen = .newVoices
                        }
                        .buttonStyle(voice.guess != nil ? AnyButtonStyle(PrimaryButton())
                                                        : AnyButtonStyle(QuietButton()))
                    }
                }
            }
        }
    }

    private var unknownTitle: String {
        let n = library.unknown.count
        let tail = n % 10, hundred = n % 100
        if hundred >= 11 && hundred <= 14 { return "\(n) голосов не узнано" }
        if tail == 1 { return "\(n) голос не узнан" }
        if tail >= 2 && tail <= 4 { return "\(n) голоса не узнаны" }
        return "\(n) голосов не узнано"
    }

    private func meta(_ record: Record) -> String {
        var parts = [humanDate(record.date)]
        if record.length > 0 { parts.append(hms(record.length)) }
        if record.speakerCount > 0 { parts.append("\(record.speakerCount) участников") }
        return parts.joined(separator: " · ")
    }

    private func playTurn(_ turn: Turn, in record: Record) {
        // Свои реплики лежат на отдельной дорожке — системная их не слышала.
        let wav = turn.speaker == "OWN" ? (record.ownTrack ?? record.source) : record.source
        guard let wav else {
            showAlert("Фрагмент недоступен",
                      "Исходная запись встречи не найдена рядом с результатом — возможно, её перенесли или удалили.")
            return
        }
        player.play(url: wav,
                    label: Legend.label(for: turn, in: record),
                    subtitle: "\(record.title) · \(hms(turn.start))",
                    colour: library.color(for: turn, in: record),
                    from: turn.start, to: turn.end)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK { picked = panel.url }
    }

    private func fileInfo(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(url.pathExtension.uppercased()) · \(formatter.string(fromByteCount: Int64(size)))"
    }
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

struct RecordsScreen: View {
    @Bindable var library: Library
    var player: Player
    var pipeline: Pipeline
    @Binding var screen: Screen
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(text: "Записи")
            Card {
                if library.records.isEmpty {
                    Text("Пока нет обработанных встреч")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    // Ширины подобраны так, чтобы ленте осталось место. С
                    // прежними колонка «Кто говорил» получала нулевую ширину:
                    // лента схлопывалась в штрих, а заголовок переносился по
                    // букве в строку и выглядел пустотой. Дата и длительность
                    // сведены в одну колонку - вместе они читаются лучше.
                    HStack(spacing: 12) {
                        Text("Встреча").frame(width: 150, alignment: .leading)
                        Text("Кто говорил")
                            .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                        Text("Когда").frame(width: 150, alignment: .leading)
                        Text("Статус").frame(width: 112, alignment: .trailing)
                        Text("Стенограмма").frame(width: 88, alignment: .trailing)
                        Text("Саммари").frame(width: 88, alignment: .trailing)
                    }
                    .font(Kind.eyebrow()).tracking(0.8).foregroundStyle(p.faint)
                    .lineLimit(1)
                    .padding(.bottom, 9)

                    ForEach(library.records) { record in
                        Divider().overlay(p.line2)
                        HStack(spacing: 12) {
                            Text(record.title).font(Kind.strong(13.5))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 150, alignment: .leading)
                            Ribbon(turns: record.turns, height: 12,
                                   library: library, record: record)
                                .frame(minWidth: 110, maxWidth: .infinity)
                            Text("\(humanDate(record.date)) · \(hms(record.length))")
                                .font(Kind.mono(12)).lineLimit(1)
                                .foregroundStyle(p.muted).frame(width: 150, alignment: .leading)
                            statusPill(for: record).frame(width: 112, alignment: .trailing)
                            fileButton(record.transcript, hint: "Открыть стенограмму")
                                .frame(width: 88, alignment: .trailing)
                            summaryButton(for: record)
                                .frame(width: 88, alignment: .trailing)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .onTapGesture { NSWorkspace.shared.open(record.dir) }
                    }
                }
            }
        }
    }
}

// MARK: - Спикеры

extension RecordsScreen {
    /// Кнопка открытия документа встречи. Пока обработка не дошла до этого
    /// шага, файла нет — и честнее показать это, чем неработающую кнопку.
    @ViewBuilder func fileButton(_ url: URL?, hint: String) -> some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 12))
                    Text("Открыть").font(Kind.body(12.5))
                }
                .foregroundStyle(library.palette.accent2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hint)
        } else {
            Text("нет").font(Kind.body(12.5)).foregroundStyle(library.palette.faint)
        }
    }

    /// Резюме собирается отдельно, по запросу: это самый долгий шаг и
    /// единственный, которому нужна языковая модель. Пока его не просили,
    /// в колонке стоит кнопка, а не прочерк.
    @ViewBuilder func summaryButton(for record: Record) -> some View {
        // Резюме выключено в настройках — кнопки нет. Уже собранное резюме
        // при этом остаётся доступным: выключатель про будущую работу, а не
        // про то, чтобы прятать сделанное.
        if !library.settings.make_summary && record.summary == nil {
            EmptyView()
        } else if record.summary != nil {
            fileButton(record.summary, hint: "Открыть саммари встречи")
        } else if pipeline.isRunning {
            Text("занято").font(Kind.body(12.5)).foregroundStyle(library.palette.faint)
        } else {
            Button { pipeline.summarize(record: record, library: library) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 12))
                    Text("Собрать").font(Kind.body(12.5))
                }
                .foregroundStyle(library.palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Собрать саммари: решения, поручения и заметки")
        }
    }

    /// Статус встречи: важно не «готово», а есть ли неразобранные голоса.
    @ViewBuilder func statusPill(for record: Record) -> some View {
        let unknown = Library.readUnknown(in: record).count
        if unknown > 0 {
            Pill(text: unknown == 1 ? "1 новый голос" : "\(unknown) новых голоса",
                 fg: library.palette.warn, bg: library.palette.warnBg)
        } else {
            Pill(text: "Готово", fg: library.palette.ok, bg: library.palette.okBg)
        }
    }
}

struct SpeakersScreen: View {
    @Bindable var library: Library
    var player: Player
    @Binding var screen: Screen
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(text: "Спикеры")
            Card {
                HStack {
                    Text("Все люди").font(Kind.head(16)).foregroundStyle(p.text)
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
                    VStack(spacing: 8) {
                        ForEach(library.speakers) { person in
                            RowBox {
                                PlayDot(size: 28) { playSample(person) }
                                Avatar(text: person.initials, colour: library.color(for: person))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name).font(Kind.strong(14.5))
                                    // Должность и компания - два разных факта,
                                    // и точка между ними их только склеивала.
                                    // Тегами видно, что это признаки человека,
                                    // а не продолжение имени.
                                    if !person.tags.isEmpty {
                                        HStack(spacing: 5) {
                                            ForEach(person.tags, id: \.self) { tag in
                                                Tag(text: tag)
                                            }
                                        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(text: "Новые голоса")

            if library.unknown.isEmpty {
                Card {
                    Text("Все голоса определены")
                        .font(Kind.body(14)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 26)
                }
            } else {
                Card {
                    Text("Один человек часто распадается на несколько голосов — отметьте их вместе.")
                        .font(Kind.body(13)).foregroundStyle(p.muted)
                        .padding(.bottom, 14)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                              spacing: 12) {
                        ForEach(library.unknown) { voice in
                            VoiceCard(voice: voice, library: library, player: player,
                                      selected: selected.contains(voice.url)) {
                                if selected.contains(voice.url) { selected.remove(voice.url) }
                                else { selected.insert(voice.url) }
                            } assign: {
                                selected = [voice.url]
                                enrolling = true
                            }
                        }
                    }
                }

                if !selected.isEmpty {
                    HStack(spacing: 12) {
                        Text(selectionTitle).font(Kind.strong(14))
                        Spacer()
                        Button("Снять выбор") { selected.removeAll() }
                            .buttonStyle(.plain).font(Kind.body(13)).foregroundStyle(p.muted)
                        Button(selected.count == 1 ? "Это человек…" : "Это один человек…") {
                            enrolling = true
                        }
                        .buttonStyle(PrimaryButton())
                    }
                    .padding(14)
                    .background(p.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .padding(.top, 12)
                }
            }
        }
        .sheet(isPresented: $enrolling) {
            EnrollSheet(library: library, samples: Array(selected)) {
                selected.removeAll()
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
    var toggle: () -> Void = {}
    var assign: () -> Void = {}

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
                Text(voice.guess.map { "Похоже, это \($0) — определено по разговору" }
                     ?? "По разговору имя определить не удалось: по имени к нему не обращались.")
                    .font(Kind.body(13)).foregroundStyle(p.text)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(voice.guess != nil ? p.accentSoft : p.warnBg))
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Button(voice.guess.map { "Это \($0)" } ?? "Выбрать человека") { assign() }
                    .buttonStyle(PrimaryButton())
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
    @Environment(\.palette) private var p

    @State private var name = ""
    @State private var position = ""
    @State private var company = ""
    @State private var problem = ""
    @State private var saved = false
    @State private var editing = false

    private var person: Speaker? { library.speakers.first { $0.key == key } }

    private var changed: Bool {
        guard let person else { return false }
        return name != person.name || position != person.position || company != person.company
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackButton(title: "Спикеры") { screen = .speakers }
            if let person {
                HStack(spacing: 14) {
                    Avatar(text: person.initials, colour: library.color(for: person), size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(person.name).font(Kind.title(20)).foregroundStyle(p.text)
                        if !person.tags.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(person.tags, id: \.self) { tag in Tag(text: tag) }
                            }
                        }
                    }
                    Spacer()
                    Button(editing ? "Отмена" : "Редактировать") {
                        if editing {
                            fill()          // вернуть как было
                            problem = ""
                        }
                        editing.toggle()
                        saved = false
                    }
                    .buttonStyle(QuietButton())
                }
                if editing {
                Card {
                    Text("Кто это").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 6)
                    SettingRow(title: "Имя") { field($name, "Имя и фамилия") }
                    Divider().overlay(p.line2)
                    SettingRow(title: "Должность") { field($position, "например, CTO") }
                    Divider().overlay(p.line2)
                    SettingRow(title: "Компания") { field($company, "например, РТЛабс") }
                    if !problem.isEmpty {
                        Text(problem).font(Kind.body(12.5)).foregroundStyle(p.warn)
                            .padding(.top, 10)
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        if saved, !changed {
                            Text("Сохранено").font(Kind.body(12.5)).foregroundStyle(p.muted)
                        }
                        Button("Сохранить") {
                            problem = library.saveSpeaker(key: key, name: name,
                                                          position: position,
                                                          company: company) ?? ""
                            saved = problem.isEmpty
                            if saved { editing = false }
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(!changed)
                        .opacity(changed ? 1 : 0.45)
                    }
                    .padding(.top, 12)
                }
                }

                Card {
                    Text("Образцы голоса").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 14)
                    let samples = sampleFiles(person)
                    if samples.isEmpty {
                        Text("Образцов пока нет").font(Kind.body(13.5)).foregroundStyle(p.muted)
                    } else {
                        VStack(spacing: 8) {
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
        .onAppear { fill() }
        // Переход к другому человеку — то же окно, другие данные.
        .onChange(of: key) { _, _ in
            problem = ""
            saved = false
            editing = false
            fill()
        }
    }

    private func field(_ value: Binding<String>, _ hint: String) -> some View {
        TextField(hint, text: value)
            .textFieldStyle(.roundedBorder)
            .frame(width: 260)
            .onChange(of: value.wrappedValue) { _, _ in
                // Прошлая ошибка относилась к прошлому тексту.
                problem = ""
                saved = false
            }
    }

    /// Подставить то, что уже записано о человеке.
    private func fill() {
        guard let person else { return }
        name = person.name
        position = person.position
        company = person.company
    }

    private func sampleFiles(_ person: Speaker) -> [URL] {
        // Два места: образцы, добавленные в приложении, и образцы прежнего
        // конвейера. Смотрим в оба - иначе у человека, заведённого до
        // переписывания, страница пуста при непустом счётчике.
        let folders = [Paths.profiles.appending(path: "samples/\(person.key)"),
                       Paths.legacySamples.appending(path: person.key)]
        let items = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: nil)) ?? []
        }
        return items.filter { $0.pathExtension.lowercased() == "wav" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

// MARK: - Настройки

struct SettingsScreen: View {
    @Bindable var library: Library
    var dictation: Dictation
    @Environment(\.palette) private var p
    /// Разделов двенадцать: развёрнутыми они заслоняют собой всю страницу
    /// настроек, а меняют их редко.
    @State private var blocksOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: "Настройки")

            dictationCard

            Card {
                Text("Общее").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 12)
                SettingRow(title: "Ваше имя",
                           subtitle: "Так подписываются ваши реплики при записи звонка") {
                    TextField("Вы", text: Binding(
                        get: { library.settings.my_name },
                        set: { library.settings.my_name = $0; library.settings.save() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Тема") {
                    Segmented(options: [("dark", "Тёмная"), ("light", "Светлая"), ("system", "Авто")],
                              selection: Binding(
                                get: { library.settings.theme },
                                set: { library.settings.theme = $0; library.settings.save(); library.reload() }))
                        .frame(width: 260)
                }
            }

            Card {
                Text("Быстрый доступ").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 12)
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
                Text("Артефакты").font(Kind.head(16)).foregroundStyle(p.text)
                Text("Что появится в папке встречи. Чем больше разделов, тем дольше счёт")
                    .font(Kind.body(12.5)).foregroundStyle(p.muted).padding(.bottom, 12)
                // Резюме здесь главное, а не первое по алфавиту: майндкарта
                // рисуется из того же разбора и без него не существует.
                // Поставить её выше значило бы обещать карту без резюме.
                SettingRow(title: "Саммари встречи",
                           subtitle: "Разбор языковой моделью — самая долгая часть обработки") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.make_summary },
                        set: { library.settings.make_summary = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if library.settings.make_summary {
                    Divider().overlay(p.line2)
                    SettingRow(title: "Майндкарта встречи",
                               subtitle: "Файл 03_mindmap.md из того же разбора — открывается майндмап-программами") {
                        Toggle("", isOn: Binding(
                            get: { library.settings.make_mindmap },
                            set: { library.settings.make_mindmap = $0; library.settings.save() }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider().overlay(p.line2)
                    blocksDisclosure
                }
            }

            Card {
                Text("Хранение данных").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 12)
                SettingRow(title: "Папка для результатов", subtitle: library.settings.results_dir) {
                    Button("Изменить") { chooseFolder() }.buttonStyle(QuietButton())
                }
                Divider().overlay(p.line2)
                SettingRow(title: "Хранить диагностические данные",
                           subtitle: "Нужны, чтобы слушать фрагменты встреч после обработки") {
                    Toggle("", isOn: Binding(
                        get: { library.settings.keep_diagnostics },
                        set: { library.settings.keep_diagnostics = $0; library.settings.save() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Card {
                Text("Термины команды").font(Kind.head(16)).foregroundStyle(p.text).padding(.bottom, 12)
                SettingRow(title: "Словарь", subtitle: "\(glossaryCount) терминов") {
                    Button("Открыть") { NSWorkspace.shared.open(Paths.glossary) }
                        .buttonStyle(QuietButton())
                }
            }
        }
    }

    /// Разделы протокола: свёрнуты по умолчанию.
    ///
    /// Стрелка и подпись «включено N из 12» говорят состояние словами, а не
    /// одним цветом, и вся строка целиком - зона нажатия.
    private var blocksDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { blocksOpen.toggle() } label: {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Настройка разделов саммари").font(Kind.body(14))
                        Text("Под себя, выбирая нужное")
                            .font(Kind.body(12.5)).foregroundStyle(p.muted)
                    }
                    Spacer()
                    // Счётчик переехал из подписи сюда: подпись теперь про
                    // смысл, а состояние всё равно надо видеть свёрнутым - и
                    // видеть словами, а не одним цветом.
                    Text("\(library.settings.chosenBlocks.count) из \(SummaryBlock.all.count)")
                        .font(Kind.body(12.5)).foregroundStyle(p.faint)
                    Image(systemName: blocksOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.muted)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if blocksOpen {
                ForEach(SummaryBlock.all) { block in
                    SettingRow(title: block.title, subtitle: block.hint) {
                        Toggle("", isOn: Binding(
                            get: { library.settings.hasBlock(block.id) },
                            set: { library.settings.setBlock(block.id, $0)
                                   library.settings.save() }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
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
}

extension SettingsScreen {
    var dictationCard: some View {
        Card {
            HStack(spacing: 10) {
                Text("Диктовка").font(Kind.head(16)).foregroundStyle(p.text)
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
                Toggle("", isOn: Binding(
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
private struct KeyCatcher: NSViewRepresentable {
    var onFlags: (UInt16, NSEvent.ModifierFlags) -> Void

    final class Catcher: NSView {
        var onFlags: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func flagsChanged(with event: NSEvent) {
            onFlags?(event.keyCode, event.modifierFlags)
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onFlags = onFlags
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onFlags = onFlags
        if view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
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
        .background {
            if recording {
                KeyCatcher(onFlags: { code, mods in take(code: code, mods: mods) })
                    .frame(width: 1, height: 1)
            }
        }
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
        Dictation.logHotkey("запись начата")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            take(code: event.keyCode, mods: event.modifierFlags)
            return event
        }
    }

    private func finish(save: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        guard save else { return }
        let chosen = HotCombo.tokens(fromKeyCodes: pressed)
        Dictation.logHotkey("записано: \(chosen.isEmpty ? "ничего" : chosen)")
        if !chosen.isEmpty { combo = chosen }
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
                Text(title).font(Kind.body(14)).foregroundStyle(p.text)
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
