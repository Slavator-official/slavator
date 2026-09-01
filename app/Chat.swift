import SwiftUI

/// Разговор с локальной языковой моделью.
///
/// Та же Ollama и та же модель, что собирает резюме встреч, — отдельной
/// установки не требуется. Ответ приходит потоком и печатается по мере
/// появления: ждать полминуты в пустое окно невыносимо.
@Observable
final class Chat {

    struct Message: Identifiable, Equatable {
        enum Role { case user, model }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isAnswering = false
    private(set) var failure: String?
    /// Размышления вслух: качественнее, но заметно дольше. Замер на короткой
    /// правке текста — 24,7 с против 2,2 с, поэтому по умолчанию выключены.
    var thinking = false

    private var task: Task<Void, Never>?

    var canSend: Bool { !isAnswering }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAnswering else { return }
        failure = nil
        messages.append(Message(role: .user, text: prompt))
        messages.append(Message(role: .model, text: ""))
        isAnswering = true

        let history = messages.dropLast().map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        task = Task { [weak self] in await self?.stream(history: Array(history)) }
    }

    func stop() {
        task?.cancel()
        task = nil
        isAnswering = false
    }

    func clear() {
        stop()
        messages.removeAll()
        failure = nil
    }

    // MARK: обмен с Ollama

    private func stream(history: [[String: String]]) async {
        let host = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBER_OLLAMA"]
            ?? "http://127.0.0.1:11434"
        let model = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBER_LLM"]
            ?? Settings.load().llm_model

        guard let url = URL(string: "\(host)/api/chat") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "think": thinking,
            "keep_alive": "10m",
            "messages": history,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await finish(error: "Ollama ответила кодом \(http.statusCode). "
                             + "Проверьте, что модель \(model) установлена: ollama pull \(model)")
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let data = line.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let piece = (raw["message"] as? [String: Any])?["content"] as? String,
                   !piece.isEmpty {
                    await append(piece)
                }
                if raw["done"] as? Bool == true { break }
            }
            await finish(error: nil)
        } catch {
            // Ollama может быть не установлена вовсе — у части людей так и есть.
            await finish(error: "Не удалось поговорить с моделью: \(error.localizedDescription)\n\n"
                         + "Ollama запущена? Она ставится вместе со Славатором и "
                         + "отвечает за резюме встреч и этот чат.")
        }
    }

    @MainActor
    private func append(_ piece: String) {
        guard var last = messages.last, last.role == .model else { return }
        last.text += piece
        messages[messages.count - 1] = last
    }

    @MainActor
    private func finish(error: String?) {
        isAnswering = false
        failure = error
        // Пустой ответ оставлять в переписке незачем: он выглядит как сбой,
        // о котором не сказали.
        if let last = messages.last, last.role == .model, last.text.isEmpty {
            messages.removeLast()
        }
    }
}

// MARK: - Экран

struct ChatScreen: View {
    @Bindable var library: Library
    var chat: Chat
    @Environment(\.palette) private var p
    @State private var draft = ""
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                ScreenTitle(text: "Чат")
                Spacer()
                if !chat.messages.isEmpty {
                    Button("Очистить") { chat.clear() }.buttonStyle(QuietButton())
                }
            }

            Card(fill: true) {
                if chat.messages.isEmpty {
                    empty
                } else {
                    conversation
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
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26)).foregroundStyle(p.faint)
            Text("Спросите что угодно").font(Kind.strong(14.5))
            Text("Модель работает на этом компьютере, переписка никуда не уходит")
                .font(Kind.body(12.5)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if chat.isAnswering {
                        Text("думает…").font(Kind.body(12.5)).foregroundStyle(p.faint)
                            .id("хвост")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    if chat.isAnswering {
                        proxy.scrollTo("хвост", anchor: .bottom)
                    } else if let id = chat.messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func bubble(_ message: Chat.Message) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "Вы" : "Модель")
                .font(Kind.eyebrow()).tracking(0.8)
                .foregroundStyle(message.role == .user ? p.accent2 : p.faint)
            Text(message.text)
                .font(Kind.body(14)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(message.role == .user ? p.accentSoft : p.raised))
    }

    private var composer: some View {
        Card {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Напишите сообщение…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Kind.body(14))
                    .lineLimit(1...6)
                    .focused($writing)
                    .onSubmit(send)

                if chat.isAnswering {
                    Button("Остановить") { chat.stop() }.buttonStyle(QuietButton())
                } else {
                    Button("Отправить", action: send)
                        .buttonStyle(PrimaryButton())
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Toggle("Размышлять перед ответом", isOn: Bindable(chat).thinking)
                    .toggleStyle(.checkbox)
                    .font(Kind.body(12))
                    .foregroundStyle(p.muted)
                Text("медленнее, но обдуманнее")
                    .font(Kind.body(12)).foregroundStyle(p.faint)
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        chat.send(text)
        writing = true
    }
}
