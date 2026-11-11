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
        var fromDocument: Bool? = nil
        var documentSources: [DocumentCitation]? = nil
        var documentName: String? = nil
        var documentNotice: String? = nil

        // Older conversations stored this generated footer in the answer.
        // Separate it only for display; never rewrite the saved message.
        var documentPresentation: (text: String, notice: String?) {
            guard role == .model, fromDocument == true else { return (text, documentNotice) }
            var answer = text
            var notice = documentNotice
            if notice == nil, let range = answer.range(of: "\n\nИспользовано фрагментов:", options: .backwards) {
                notice = String(answer[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                answer = String(answer[..<range.lowerBound])
            }
            let disclaimer = "\n\nОтвет локальной модели — проверьте по источникам."
            if answer.hasSuffix(disclaimer) {
                answer.removeLast(disclaimer.count)
                notice = "Ответ локальной модели — проверьте по источникам." +
                    ((notice ?? "").isEmpty ? "" : "\n" + (notice ?? ""))
            }
            return (answer, notice)
        }
    }

    struct Conversation: Identifiable, Codable, Equatable {
        var id = UUID()
        var title: String
        var updated: Date
        var messages: [Message]
        /// Переписка о конкретной встрече: путь к её папке и название.
        /// Ответы ищутся только в этой встрече. У старых переписок полей нет —
        /// необязательные поля читаются как пустые.
        var meeting: String? = nil
        var meetingTitle: String? = nil

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
    let documents = DocumentWorkspace()
    private let documentJob = DocumentJob()
    private(set) var attachedDocument: LocalDocument?
    var containsDocumentData: Bool { messages.contains { $0.fromDocument == true || $0.documentSources != nil } }

    func attachDocument(_ document: LocalDocument) {
        guard !isAnswering else { return }
        if currentID == nil { startNew() }
        attachedDocument = document
    }

    func detachDocument() { guard !isAnswering else { return }; attachedDocument = nil; documents.reset() }

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var messages: [Message] { current?.messages ?? [] }

    init() { load() }

    // MARK: список переписок

    func startNew() {
        stop()
        documents.reset()
        attachedDocument = nil
        failure = nil
        // Пустой черновик не плодим: если текущая переписка ещё без единого
        // сообщения, «новый чат» — это она и есть.
        if let current, current.messages.isEmpty, current.meeting == nil { return }
        let fresh = Conversation(title: "Новый чат", updated: Date(), messages: [])
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        save()
    }

    /// Открыть переписку о встрече; если её ещё нет — завести.
    func openMeeting(_ dir: URL, title: String) {
        let key = dir.resolvingSymlinksInPath().path
        if let existing = conversations.first(where: { $0.meeting == key }) {
            open(existing.id)
            return
        }
        stop()
        documents.reset()
        attachedDocument = nil
        failure = nil
        let fresh = Conversation(title: "Встреча: " + title, updated: Date(), messages: [],
                                 meeting: key, meetingTitle: title)
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        save()
    }

    func open(_ id: UUID) {
        guard id != currentID else { return }
        stop()
        documents.reset()
        attachedDocument = nil
        failure = nil
        currentID = id
    }

    func delete(_ id: UUID) {
        if id == currentID { stop(); attachedDocument = nil }
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
        let readingDocument = attachedDocument != nil
        let scope = conversations[index].meeting
        let fromMemory = (settings.chat_memory_enabled || scope != nil) && !readingDocument
        conversations[index].messages.append(Message(role: .user, text: prompt, fromMemory: fromMemory,
                                                     fromDocument: readingDocument, documentName: attachedDocument?.title))
        conversations[index].messages.append(Message(role: .model, text: "", fromMemory: fromMemory,
                                                     fromDocument: readingDocument, documentName: attachedDocument?.title))
        conversations[index].updated = Date()
        isAnswering = true
        save()

        if let document = attachedDocument {
            askDocument(["action": "answer", "document": document.payload, "question": prompt], settings: settings,
                        token: token, conversationID: conversationID)
            return
        }
        // Once private document content is in a conversation, its later turns
        // also use the verified-local worker even after removing the attachment.
        if containsDocumentData {
            let history = conversations[index].messages.dropLast().map {
                ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
            }
            askDocument(["action": "conversation", "history": history], settings: settings,
                        token: token, conversationID: conversationID)
            return
        }
        // Вопрос о встрече всегда ищется в её расшифровке: свободный разговор
        // с моделью здесь отвечал бы выдумкой, а не тем, что было сказано.
        if let scope {
            recall(prompt, settings: settings, token: token, conversationID: conversationID, meeting: scope)
            return
        }
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
        documentJob.cancel(); documents.job.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil
        progress = ""
        task?.cancel()
        task = nil
        isAnswering = false
        if let index = conversations.firstIndex(where: { $0.id == currentID }),
           let last = conversations[index].messages.indices.last,
           ["Найдены возможные совпадения. Готовлю ответ…", "Фрагменты документа найдены. Готовлю ответ…"].contains(conversations[index].messages[last].text) {
            conversations[index].messages[last].text = "Ответ остановлен. Найденные цитаты сохранены."
        }
        if let index = conversations.firstIndex(where: { $0.id == currentID }),
           let last = conversations[index].messages.last, last.role == .model,
           last.text.isEmpty && (last.sources ?? []).isEmpty && (last.documentSources ?? []).isEmpty {
            conversations[index].messages.removeLast()
        }
        save()
    }

    private func askDocument(_ payload: [String: Any], settings: Settings, token: UUID, conversationID: UUID) {
        progress = "Читаю документ локально…"
        documentJob.run(payload, settings: settings, onEvent: { [weak self] reply in
            guard let self, self.requestID == token else { return }
            if reply.event == "progress" { self.progress = reply.message ?? "" }
            if reply.event == "sources", let index = self.conversations.firstIndex(where: { $0.id == conversationID }),
               let last = self.conversations[index].messages.indices.last {
                self.conversations[index].messages[last].documentSources = reply.citations
                self.conversations[index].messages[last].text = "Фрагменты документа найдены. Готовлю ответ…"
                self.save()
            }
        }, completion: { [weak self] reply, error in
            guard let self, self.requestID == token else { return }
            if let reply, let index = self.conversations.firstIndex(where: { $0.id == conversationID }),
               let last = self.conversations[index].messages.indices.last {
                self.conversations[index].messages[last].text = reply.text ?? ""
                self.conversations[index].messages[last].documentNotice = reply.notice
                self.conversations[index].messages[last].documentSources = reply.citations
            }
            Task { @MainActor in self.finish(error: error, token: token, conversationID: conversationID) }
        })
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
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config, delegate: LocalChatTransport(), delegateQueue: nil)
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

    private func recall(_ question: String, settings: Settings, token: UUID, conversationID: UUID,
                        meeting: String = "") {
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
            let payload = try JSONSerialization.data(withJSONObject: ["question": question, "profile": settings.my_profile_key,
                                                                      "meeting": meeting])
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

/// A local reply must never redirect private conversation history elsewhere.
private final class LocalChatTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Экран

#if !CHAT_TESTING

struct ChatScreen: View {
    @Bindable var library: Library
    var chat: Chat
    var memory: SpeakerMemory
    var player: Player
    /// Встроен во вкладку встречи: без своих рамок, без вложений и без
    /// переключателя памяти — вопросы и так ищутся в этой встрече.
    var embedded = false
    @State private var detail: MemoryQuote?
    @Environment(\.palette) private var p
    @State private var draft = ""
    @State private var search = ""
    @State private var showDocuments = false
    @FocusState private var writing: Bool

    /// Переписка о конкретной встрече: ищем только в ней.
    private var scoped: Bool { chat.current?.meeting != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.current?.title ?? "Чат").font(Kind.title(22)).kerning(-0.3).lineLimit(1)
                        if let title = chat.current?.meetingTitle {
                            Label("Ответы только по встрече «\(title)»", systemImage: "calendar")
                                .font(Kind.body(12.5)).foregroundStyle(p.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    LocalBadge()
                }
                .padding(.top, 4)
            }
            if embedded {
                Group { if chat.messages.isEmpty { empty } else { conversation } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Card(fill: true) {
                    if chat.messages.isEmpty { empty } else { conversation }
                }
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
        .sheet(isPresented: $showDocuments) {
            ChatAttachmentSheet(workspace: chat.documents, settings: library.settings) { document in
                chat.attachDocument(document)
            }
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
            Text(scoped ? "Что узнать об этой встрече?" : chat.attachedDocument != nil ? "Что узнать из документа?" : (library.settings.chat_memory_enabled ? "Что вспомнить из встреч?" : "Спросите что угодно")).font(Kind.strong(14.5))
            Text(scoped ? "Например: «Какие сроки назвали?» или «Кто отвечает за презентацию?»" : chat.attachedDocument != nil ? "Например: «Какие сроки и обязательства указаны?»" : (library.settings.chat_memory_enabled ? "Например: «Когда я говорил про перенос сроков?»" : (AppConfiguration.usesLocalModel ? "Ответит локальная модель" : "Используется настроенный адрес модели")))
                .font(Kind.body(12.5)).foregroundStyle(p.muted).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, embedded ? 16 : 40)
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
            Text(Self.rendered(message.documentPresentation.text))
                .font(Kind.body(14)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if let name = message.documentName {
                Text("Документ: " + name + " · локально").font(Kind.body(11)).foregroundStyle(p.muted)
                    .lineLimit(1).truncationMode(.middle).help(name)
            }
            if !(message.documentSources ?? []).isEmpty || !(message.documentPresentation.notice ?? "").isEmpty {
                DocumentSourcesView(sources: message.documentSources ?? [], notice: message.documentPresentation.notice)
            }
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

    @ViewBuilder private var composer: some View {
        if embedded { composerBody } else { Card { composerBody } }
    }

    private var composerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = chat.attachedDocument {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(p.accent2)
                    Text(document.title).font(Kind.body(12)).lineLimit(1).truncationMode(.middle)
                        .help(document.title)
                    Spacer(minLength: 8)
                    Button { chat.detachDocument() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(chat.isAnswering)
                        .accessibilityLabel("Убрать прикреплённые файлы").help("Убрать файлы из контекста")
                }.padding(9).background(RoundedRectangle(cornerRadius: 8).fill(p.raised))
                    .padding(.bottom, 8)
            }
            if chat.attachedDocument != nil || chat.containsDocumentData {
                HStack(spacing: 6) {
                    Label(chat.attachedDocument != nil ? "Контекст: прикреплённые файлы" : "Контекст: история и цитаты", systemImage: "lock")
                    Spacer()
                    Image(systemName: "info.circle")
                        .help("Обработка локальная. В истории остаются вопросы, ответы и цитаты, не весь исходник. Для поиска по встречам начните новую переписку; для чтения всего файла прикрепите его снова.")
                }.font(Kind.body(11)).foregroundStyle(p.muted).padding(.bottom, 8)
            }
            if scoped && !embedded {
                Label("Ищу только в этой встрече", systemImage: "calendar")
                    .font(Kind.body(12)).foregroundStyle(p.muted).padding(.bottom, 8)
            }
            if chat.attachedDocument == nil && !chat.containsDocumentData && !scoped {
            HStack {
                Toggle("Искать во встречах", isOn: Binding(
                    get: { library.settings.chat_memory_enabled },
                    set: { library.settings.chat_memory_enabled = $0; library.settings.save() }))
                    .toggleStyle(.switch).controlSize(.small).font(Kind.body(12)).disabled(chat.isAnswering)
                Spacer(minLength: 12)
                if library.settings.chat_memory_enabled {
                    Menu("Ваш голос: " + (library.speakers.first(where: { $0.key == library.settings.my_profile_key })?.name ?? "не выбран")) {
                        Button("Не указывать свой голос") {
                            library.settings.my_profile_key = Settings.noVoice; library.settings.save()
                        }
                        ForEach(library.speakers) { person in
                            Button(person.name) { library.settings.my_profile_key = person.key; library.settings.save() }
                        }
                    }.frame(maxWidth: 220).controlSize(.small).font(Kind.body(12)).disabled(chat.isAnswering)
                        .help("Выберите себя среди участников, чтобы искать свои реплики по вопросу «когда я говорил».")
                } else {
                    Toggle("Обдумать ответ", isOn: Bindable(chat).thinking)
                        .toggleStyle(.checkbox).font(Kind.body(12)).foregroundStyle(p.muted)
                        .disabled(chat.isAnswering).help("Ответ может быть медленнее, но подробнее обдуман.")
                }
            }.padding(.bottom, 9)
            if needsOwnProfile {
                Text("Чтобы найти ваши слова, выберите себя в меню «Ваш голос».")
                    .font(Kind.body(12)).foregroundStyle(p.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !scoped {
                    Button { showDocuments = true } label: {
                        Image(systemName: "paperclip").font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.line, lineWidth: 1))
                    }.buttonStyle(PressStyle()).foregroundStyle(p.muted).disabled(chat.isAnswering)
                        .accessibilityLabel("Прикрепить файлы").help("Прикрепить PDF, Word или текстовые файлы")
                }
                // Поле по макету: значок сообщения слева, отправка — внутри
                // поля справа, а не отдельной синей плиткой.
                HStack(alignment: .bottom, spacing: 9) {
                    Image(systemName: "bubble.left").font(.system(size: 14))
                        .foregroundStyle(p.faint).padding(.bottom, 12)
                    TextField(scoped ? "Задайте вопрос по встрече…" : "Напишите сообщение…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Kind.body(14))
                        .lineLimit(1...6)
                        .focused($writing)
                        .onSubmit(send)
                        .padding(.vertical, 10)
                    if chat.isAnswering {
                        Button { chat.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 18))
                                .foregroundStyle(p.muted).frame(width: 28, height: 28)
                        }.buttonStyle(PressStyle()).padding(.bottom, 6)
                            .accessibilityLabel("Остановить ответ").help("Остановить ответ")
                    } else {
                        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button(action: send) {
                            Image(systemName: "paperplane").font(.system(size: 16, weight: .medium))
                                .foregroundStyle(empty || needsOwnProfile ? p.faint : p.accent2)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).padding(.bottom, 6)
                            .accessibilityLabel("Отправить сообщение").help("Отправить сообщение")
                            .disabled(empty || needsOwnProfile)
                    }
                }
                .padding(.leading, 12).padding(.trailing, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(writing ? p.accent : p.line, lineWidth: writing ? 1.5 : 1))
            }
        }
    }

    private var needsOwnProfile: Bool {
        chat.attachedDocument == nil && !chat.containsDocumentData && library.settings.chat_memory_enabled &&
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
private struct DocumentSourcesView: View {
    let sources: [DocumentCitation]
    let notice: String?
    @State private var expanded = false
    @Environment(\.palette) private var p

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let notice, !notice.isEmpty {
                    Text(notice).font(Kind.body(11)).foregroundStyle(p.muted)
                        .layoutPriority(1)
                }
                ForEach(sources) { source in
                    DisclosureGroup {
                        Text(source.text + (source.shortened ? "\n[Показана часть фрагмента]" : ""))
                            .font(Kind.body(12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            .padding(.vertical, 6)
                    } label: {
                        Text("[\(source.id)] \(source.locator) · фрагмент \(source.block)")
                            .font(Kind.strong(12)).lineLimit(2).help(source.locator)
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                }
            }.padding(.top, 6)
        } label: {
            Text(sources.isEmpty ? "О контексте ответа" :
                    ((notice?.contains("выборка") == true ? "Выборочный контекст · " : "") + "Источники · \(sources.count)"))
                .font(Kind.body(12)).foregroundStyle(p.accent2)
        }
        .padding(.top, 5)
    }
}

struct ChatHistory: View {
    var chat: Chat
    var showsSelection = true
    var onOpen: () -> Void = {}
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
                Text("Переписки").font(Kind.title(20)).kerning(-0.3)
                Spacer()
                Button { chat.startNew(); onOpen() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(p.accent2).frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .help("Новая переписка")
            }
            .padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(p.faint)
                TextField("Поиск по перепискам", text: $search).textFieldStyle(.plain).font(Kind.body(13.5))
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.line, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { item in row(item) }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
        }
    }

    private func row(_ item: Chat.Conversation) -> some View {
        let active = showsSelection && item.id == chat.currentID
        return Button { chat.open(item.id); onOpen() } label: {
            HStack(alignment: .top, spacing: 9) {
                // Переписка о встрече отмечена календарём: её ответы — только
                // по одной встрече.
                Image(systemName: item.meeting == nil ? "bubble.left" : "calendar")
                    .font(.system(size: 12.5)).foregroundStyle(active ? p.accent2 : p.faint)
                    .frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Kind.body(13.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(p.text)
                    Text(meetingDate(item.updated)).font(Kind.body(11.5)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? p.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Удалить переписку", role: .destructive) { chat.delete(item.id) }
        }
    }
}
#endif
