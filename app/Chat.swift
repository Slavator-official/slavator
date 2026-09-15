import SwiftUI

/// Разговор с локальной языковой моделью.
///
/// Та же Ollama и та же модель, что собирает резюме встреч, — отдельной
/// установки не требуется. Ответ приходит потоком и печатается по мере
/// появления: ждать полминуты в пустое окно невыносимо.
///
/// Переписки хранятся на диске рядом с настройками. Без этого чат бесполезен:
/// закрыл окно — и всё, что выяснил у модели, пропало.
@Observable
final class Chat {

    struct Message: Identifiable, Codable, Equatable {
        enum Role: String, Codable { case user, model }
        var id = UUID()
        let role: Role
        var text: String
        var sources: [MemoryQuote]? = nil
        var fromMemory: Bool? = nil
    }

    struct Conversation: Identifiable, Codable, Equatable {
        var id = UUID()
        var title: String
        var updated: Date
        var messages: [Message]

        /// Заголовок из первого вопроса: списку нужны разные названия, а не
        /// десять строк «Новый чат».
        static func name(from text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if flat.isEmpty { return "Новый чат" }
            return flat.count <= 42 ? flat : String(flat.prefix(41)) + "…"
        }
    }

    private(set) var conversations: [Conversation] = []
    private(set) var currentID: UUID?
    private(set) var isAnswering = false
    private(set) var failure: String?
    /// Размышления вслух: качественнее, но заметно дольше. Замер на короткой
    /// правке текста — 24,7 с против 2,2 с, поэтому по умолчанию выключены.
    var thinking = false

    private var task: Task<Void, Never>?
    private var process: Process?
    private var requestID = UUID()
    private(set) var progress = ""

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var messages: [Message] { current?.messages ?? [] }

    init() { load() }

    // MARK: список переписок

    func startNew() {
        stop()
        failure = nil
        // Пустой черновик не плодим: если текущая переписка ещё без единого
        // сообщения, «новый чат» — это она и есть.
        if let current, current.messages.isEmpty { return }
        let fresh = Conversation(title: "Новый чат", updated: Date(), messages: [])
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        save()
    }

    func open(_ id: UUID) {
        guard id != currentID else { return }
        stop()
        failure = nil
        currentID = id
    }

    func delete(_ id: UUID) {
        if id == currentID { stop() }
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        if conversations.isEmpty { startNew() } else { save() }
    }

    // MARK: отправка

    func send(_ text: String, settings: Settings = Settings.load()) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAnswering else { return }
        if currentID == nil { startNew() }
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }

        failure = nil
        let token = UUID()
        requestID = token
        let conversationID = conversations[index].id
        if conversations[index].messages.isEmpty {
            conversations[index].title = Conversation.name(from: prompt)
        }
        conversations[index].messages.append(Message(role: .user, text: prompt, fromMemory: settings.chat_memory_enabled))
        conversations[index].messages.append(Message(role: .model, text: "", fromMemory: settings.chat_memory_enabled))
        conversations[index].updated = Date()
        isAnswering = true
        save()

        if settings.chat_memory_enabled {
            recall(prompt, settings: settings, token: token, conversationID: conversationID)
            return
        }
        let localOnly = conversations[index].messages.contains { $0.fromMemory == true || $0.sources != nil }
        let history = conversations[index].messages.dropLast().map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        task = Task { [weak self] in await self?.stream(history: Array(history), token: token, conversationID: conversationID, localOnly: localOnly) }
    }

    func stop() {
        requestID = UUID()
        if let process, process.isRunning { process.terminate() }
        process = nil
        progress = ""
        task?.cancel()
        task = nil
        isAnswering = false
        if let index = conversations.firstIndex(where: { $0.id == currentID }),
           let last = conversations[index].messages.indices.last,
           conversations[index].messages[last].text == "Найдены возможные совпадения. Готовлю ответ…" {
            conversations[index].messages[last].text = "Ответ остановлен. Найденные цитаты сохранены."
        }
        if let index = conversations.firstIndex(where: { $0.id == currentID }),
           let last = conversations[index].messages.last, last.role == .model,
           last.text.isEmpty && (last.sources ?? []).isEmpty {
            conversations[index].messages.removeLast()
        }
        save()
    }

    // MARK: обмен с Ollama

    private func stream(history: [[String: String]], token: UUID, conversationID: UUID, localOnly: Bool) async {
        let env = AppConfiguration.environment()
        let host = localOnly ? "http://127.0.0.1:11434" : (env["MEETING_TRANSCRIBER_OLLAMA_HOST"] ?? "http://127.0.0.1:11434")
        // Не `Settings()`: там умолчание контракта, а оно тяжелее того, что
        // советуют настройки этой машине, — чат просил бы у Ollama модель,
        // которой на ней нет.
        let model = env["MEETING_TRANSCRIBER_LLM"] ?? Settings.load().llm_model

        guard let url = URL(string: "\(host)/api/chat") else {
            await finish(error: "Неверный адрес модели", token: token, conversationID: conversationID); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "think": thinking,
            "keep_alive": "10m",
            "messages": history,
        ])

        do {
            let session = ModelTransport.session()
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await finish(error: "Ollama ответила кодом \(http.statusCode). "
                             + "Проверьте, что модель \(model) установлена: ollama pull \(model)", token: token, conversationID: conversationID)
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let data = line.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let piece = (raw["message"] as? [String: Any])?["content"] as? String,
                   !piece.isEmpty {
                    await append(piece, token: token, conversationID: conversationID)
                }
                if raw["done"] as? Bool == true { break }
            }
            await finish(error: nil, token: token, conversationID: conversationID)
        } catch {
            guard !Task.isCancelled else { return }
            // Ollama может быть не установлена вовсе — у части людей так и есть.
            await finish(error: "Не удалось поговорить с моделью: \(error.localizedDescription)\n\n"
                         + "Ollama запущена? Она ставится вместе со Славатором и "
                         + "отвечает за резюме встреч и этот чат.", token: token, conversationID: conversationID)
        }
    }

    @MainActor
    private func append(_ piece: String, token: UUID, conversationID: UUID) {
        guard requestID == token, let index = conversations.firstIndex(where: { $0.id == conversationID }),
              var last = conversations[index].messages.last, last.role == .model
        else { return }
        last.text += piece
        conversations[index].messages[conversations[index].messages.count - 1] = last
    }

    @MainActor
    private func finish(error: String?, token: UUID, conversationID: UUID) {
        guard requestID == token else { return }
        progress = ""
        isAnswering = false
        failure = error
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            // Пустой ответ в переписке выглядит как сбой, о котором умолчали.
            if let last = conversations[index].messages.last,
               last.role == .model, last.text.isEmpty {
                conversations[index].messages.removeLast()
            }
            conversations[index].updated = Date()
        }
        save()
    }

    private struct RecallReply: Decodable {
        let event: String
        var message: String?
        var text: String?
        var sources: [MemoryQuote]?
        var notice: String?
        var warnings: [String]?
    }

    private func recall(_ question: String, settings: Settings, token: UUID, conversationID: UUID) {
        let worker = Process(), input = Pipe(), output = Pipe()
        worker.executableURL = Paths.venvPython
        worker.arguments = ["-B", Paths.core.deletingLastPathComponent().appending(path: "meeting_chat.py").path,
                            "--root", settings.results_dir, "--profiles", Paths.profiles.path]
        worker.environment = AppConfiguration.environment(settings: settings)
        worker.standardInput = input; worker.standardOutput = output
        worker.standardError = FileHandle.standardError
        process = worker
        progress = "Ищу в памяти встреч…"
        var received = false
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["question": question, "profile": settings.my_profile_key])
            try worker.run()
            try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
            try input.fileHandleForWriting.close()
            ProcessOutput.read(output, process: worker, onLine: { [weak self] line in
                guard let self, self.requestID == token, self.process === worker,
                      let data = line.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(RecallReply.self, from: data) else { return }
                if reply.event == "progress" { self.progress = reply.message ?? "" }
                if reply.event == "error" { self.failure = reply.message }
                if reply.event == "sources", let index = self.conversations.firstIndex(where: { $0.id == conversationID }),
                   let last = self.conversations[index].messages.indices.last {
                    self.conversations[index].messages[last].sources = reply.sources
                    self.conversations[index].messages[last].text = "Найдены возможные совпадения. Готовлю ответ…"
                    self.save()
                }
                if reply.event == "result", let index = self.conversations.firstIndex(where: { $0.id == conversationID }),
                   let last = self.conversations[index].messages.indices.last {
                    received = true
                    self.conversations[index].messages[last].text = (reply.text ?? "")
                        + ((reply.notice ?? "").isEmpty ? "" : "\n\n" + (reply.notice ?? ""))
                    self.conversations[index].messages[last].sources = reply.sources
                    if let warnings = reply.warnings, !warnings.isEmpty {
                        self.failure = "Часть встреч не прочитана: " + warnings.joined(separator: "; ")
                    }
                    self.save()
                }
            }, onExit: { [weak self] status in
                guard let self, self.requestID == token, self.process === worker else { return }
                self.process = nil
                Task { @MainActor in
                    self.finish(error: self.failure ?? (status == 0 && received ? nil : "Не удалось прочитать память встреч."),
                                token: token, conversationID: conversationID)
                }
            })
        } catch {
            if worker.isRunning { worker.terminate() }
            process = nil; isAnswering = false; progress = ""; failure = error.localizedDescription
        }
    }

    // MARK: хранение

    private var file: URL { Paths.support.appending(path: "chats.json") }

    private func load() {
        defer { if conversations.isEmpty { startNew() } else { currentID = conversations.first?.id } }
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return }
        conversations = saved.sorted { $0.updated > $1.updated }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Экран

#if !CHAT_TESTING

struct ChatScreen: View {
    @Bindable var library: Library
    var chat: Chat
    var memory: SpeakerMemory
    var player: Player
    @State private var detail: MemoryQuote?
    @Environment(\.palette) private var p
    @State private var draft = ""
    @State private var search = ""
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(fill: true) {
                if chat.messages.isEmpty { empty } else { conversation }
            }
            if let failure = chat.failure {
                Card {
                    Text(failure).font(Kind.body(13)).foregroundStyle(p.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            composer
        }
        .sheet(item: $detail) { quote in
            QuoteContext(quote: quote, memory: memory, library: library, player: player)
        }
        // Чат занимает всю высоту окна: переписка сверху, поле ввода внизу.
        // Внутри общей прокрутки высота не задавалась вовсе, и экран
        // обрывался на середине, оставляя полокна пустыми.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: fillMyVoice)
        // Голоса подгружаются не мгновенно: к первому появлению чата списка
        // может ещё не быть, и подставлять тогда нечего.
        .onChange(of: library.speakers) { _, _ in fillMyVoice() }
    }

    /// Подставить свой голос, не спрашивая.
    ///
    /// Кто вы — уже сказано в настройках, именем. Спрашивать то же самое
    /// второй раз, да ещё в чате, незачем: без выбора вопросы «когда я
    /// говорил» упираются в предупреждение, и человек не понимает, чего от
    /// него хотят. Явный отказ пишется отдельным значением и переживает
    /// возвращение в чат — иначе выбор «не указывать» стирался бы сразу.
    private func fillMyVoice() {
        guard library.settings.my_profile_key.isEmpty,
              let mine = library.mySpeaker else { return }
        library.settings.my_profile_key = mine.key
        library.settings.save()
    }

    // MARK: переписка

    private var empty: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26)).foregroundStyle(p.faint)
            Text(library.settings.chat_memory_enabled ? "Что вспомнить из встреч?" : "Спросите что угодно").font(Kind.strong(14.5))
            Text(library.settings.chat_memory_enabled ? "Например: «Когда я говорил про перенос сроков?»" : (AppConfiguration.usesLocalModel ? "Ответит локальная модель" : "Используется настроенный адрес модели"))
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if chat.isAnswering {
                        Text(chat.progress.isEmpty ? "думает…" : chat.progress).font(Kind.body(12.5)).foregroundStyle(p.faint).id("хвост")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    if chat.isAnswering { proxy.scrollTo("хвост", anchor: .bottom) }
                    else if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(_ message: Chat.Message) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "Вы" : "Модель")
                .font(Kind.eyebrow()).tracking(0.8)
                .foregroundStyle(message.role == .user ? p.accent2 : p.faint)
            Text(Self.rendered(message.text))
                .font(Kind.body(14)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sources = message.sources {
                ForEach(Array(sources.enumerated()), id: \.element.id) { number, quote in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("[\(number + 1)] \(quote.name) · \(quote.time)")
                            .font(Kind.strong(12))
                        Text(quote.title + " · обработано: " + quote.date).font(Kind.body(11)).foregroundStyle(p.muted)
                        Text(quote.text).font(Kind.body(12)).textSelection(.enabled)
                        HStack {
                            Button("Прослушать") { playMemoryQuote(quote, player: player, colour: p.accent2) }
                                .disabled(quote.audio == nil)
                            Button("Контекст") { memory.loadContext(quote, settings: library.settings); detail = quote }
                                .disabled(memory.busy)
                        }.buttonStyle(QuietButton())
                    }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(message.role == .user ? p.accentSoft : p.raised))
    }

    /// Разобрать разметку модели: **жирный**, *курсив*, `код`.
    ///
    /// Режим inlineOnlyPreservingWhitespace выбран намеренно: он разбирает
    /// оформление внутри строк, но не трогает переносы. Полный разбор
    /// склеил бы абзацы в сплошной текст, а модель отвечает списками.
    ///
    /// Пока ответ печатается, незакрытые звёздочки видны как есть — это
    /// нормально: закроются, когда придёт вторая пара.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    private var composer: some View {
        Card {
            HStack {
                Toggle("Искать в памяти встреч", isOn: Binding(
                    get: { library.settings.chat_memory_enabled },
                    set: { library.settings.chat_memory_enabled = $0; library.settings.save() }))
                    .toggleStyle(.switch).disabled(chat.isAnswering)
                Spacer()
                if library.settings.chat_memory_enabled {
                    Menu("Ваш голос: " + (library.speakers.first(where: { $0.key == library.settings.my_profile_key })?.name ?? "не выбран")) {
                        Button("Не указывать свой голос") {
                            library.settings.my_profile_key = Settings.noVoice; library.settings.save()
                        }
                        ForEach(library.speakers) { person in
                            Button(person.name) { library.settings.my_profile_key = person.key; library.settings.save() }
                        }
                    }.frame(width: 250).disabled(chat.isAnswering)
                        .help("Выберите себя среди участников, чтобы искать свои реплики по вопросу «когда я говорил».")
                }
            }.padding(.bottom, 10)
            if library.settings.chat_memory_enabled {
                Text(needsOwnProfile
                     ? "Кого считать вами? Выберите свой голос выше, чтобы найти именно ваши слова."
                     : "Для вопросов «я говорил» выберите свой голос. В остальных вопросах поиск идёт по всем участникам.")
                    .font(Kind.body(12)).foregroundStyle(needsOwnProfile ? p.warn : p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            }
            HStack(alignment: .bottom, spacing: 10) {
                // Полю нужны собственные отступы и подложка: без них оно
                // прилипало к верху, а кнопка со своими отступами оказывалась
                // выше — строка выглядела разъехавшейся.
                TextField("Напишите сообщение…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Kind.body(14))
                    .lineLimit(1...6)
                    .focused($writing)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(p.raised))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(writing ? p.accent2 : p.line, lineWidth: 1))
                if chat.isAnswering {
                    Button("Остановить") { chat.stop() }.buttonStyle(QuietButton())
                } else {
                    Button("Отправить", action: send)
                        .buttonStyle(PrimaryButton())
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || needsOwnProfile)
                }
            }
            if !library.settings.chat_memory_enabled {
            HStack(spacing: 8) {
                Toggle("Размышлять перед ответом", isOn: Bindable(chat).thinking)
                    .toggleStyle(.checkbox)
                    .font(Kind.body(12)).foregroundStyle(p.muted)
                Text("медленнее, но обдуманнее").font(Kind.body(12)).foregroundStyle(p.faint)
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
            }
        }
    }

    private var needsOwnProfile: Bool {
        library.settings.chat_memory_enabled &&
        !library.speakers.contains(where: { $0.key == library.settings.my_profile_key }) &&
        draft.range(of: #"\b(я|мне|мной|мною|мои|моих|мою|мой|моя|моё|мое)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func send() {
        guard !needsOwnProfile else { return }
        let text = draft
        draft = ""
        chat.send(text, settings: library.settings)
        writing = true
    }
}


/// Список переписок в боковом меню. В режиме чата он занимает место
/// обычной навигации: «Главная» и «Записи» там всё равно не нужны.
struct ChatHistory: View {
    var chat: Chat
    @Environment(\.palette) private var p
    @State private var search = ""

    private var shown: [Chat.Conversation] {
        let probe = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !probe.isEmpty else { return chat.conversations }
        return chat.conversations.filter {
            $0.title.lowercased().contains(probe)
                || $0.messages.contains { $0.text.lowercased().contains(probe) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Переписки").font(Kind.eyebrow()).tracking(0.8).foregroundStyle(p.faint)
                Spacer()
                Button { chat.startNew() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13))
                        .foregroundStyle(p.accent2)
                }
                .buttonStyle(.plain)
                .help("Новая переписка")
            }
            .padding(.horizontal, 10).padding(.bottom, 9)

            TextField("Поиск", text: $search)
                .textFieldStyle(.plain)
                .font(Kind.body(12.5))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(p.raised))
                .padding(.horizontal, 10).padding(.bottom, 9)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { item in row(item) }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func row(_ item: Chat.Conversation) -> some View {
        let active = item.id == chat.currentID
        return Button { chat.open(item.id) } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(active ? p.accent2 : p.faint.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(item.title)
                    .font(Kind.body(13)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(active ? p.text : p.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(active ? p.raised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Удалить переписку", role: .destructive) { chat.delete(item.id) }
        }
    }
}
#endif
