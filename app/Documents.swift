import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct LocalDocument: Codable, Equatable {
    struct Block: Codable, Identifiable, Equatable {
        var id: String
        var locator: String
        var text: String
        var separator: String? = nil
    }
    var title: String
    var format: String
    var blocks: [Block]
    var warnings: [String]
    var characters: Int
    var sourceHash: String? = nil
    var text: String { blocks.enumerated().map { index, block in
        (index == 0 ? "" : (block.separator ?? "\n\n")) + block.text
    }.joined() }
    var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
    static func reviewedCopy(_ text: String) -> LocalDocument {
        // Generic name and fresh provenance, never the original filename.
        let characters = Array(text)
        let blocks = stride(from: 0, to: characters.count, by: 3000).enumerated().map { number, start in
            Block(id: String(number + 1), locator: "Проверенная текстовая копия",
                  text: String(characters[start..<min(start + 3000, characters.count)]), separator: "")
        }
        return LocalDocument(title: "Обезличенная копия", format: "TXT", blocks: blocks,
                             warnings: ["Копия проверена пользователем. Это не гарантия полного обезличивания."], characters: text.count)
    }

    static func combining(_ documents: [LocalDocument]) throws -> LocalDocument {
        let count = documents.reduce(0) { $0 + $1.characters }
        guard !documents.isEmpty, count <= 2_000_000,
              documents.reduce(0, { $0 + $1.blocks.count }) <= 5000 else {
            throw NSError(domain: "Documents", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Общий объём вложений превышает 2 000 000 символов или 5000 фрагментов. Выберите меньше файлов."])
        }
        if documents.count == 1 { return documents[0] }
        var blocks: [Block] = []
        for document in documents {
            for (index, block) in document.blocks.enumerated() {
                blocks.append(Block(id: String(blocks.count + 1), locator: document.title + " · " + block.locator,
                                    text: block.text, separator: index == 0 ? "\n\n" : block.separator))
            }
        }
        return LocalDocument(title: documents.map(\.title).joined(separator: "; "), format: "FILES",
                             blocks: blocks, warnings: documents.flatMap { doc in doc.warnings.map { doc.title + ": " + $0 } },
                             characters: count)
    }
}

struct DocumentCitation: Codable, Identifiable, Equatable {
    let id: String
    let locator: String
    let text: String
    let block: String
    let shortened: Bool
}

struct PrivacyEntity: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var variants: [String]
    var replacement: String
    var enabled: Bool
    var origin: String
}

struct DocumentReply: Decodable {
    let event: String
    var message: String?
    var document: LocalDocument?
    var entities: [PrivacyEntity]?
    var text: String?
    var count: Int?
    var warnings: [String]?
    var citations: [DocumentCitation]?
    var notice: String?
    var data: String?
    var checked: Int?
    var total: Int?
    var model_complete: Bool?
}

/// Owns a single cancellable worker. Sensitive request bodies stay in pipes,
/// not command arguments, temporary request files, diagnostics or the clipboard.
@Observable
final class DocumentJob {
    private(set) var busy = false
    private(set) var progress = ""
    private(set) var failure: String?
    private var process: Process?
    private var timeout: DispatchWorkItem?
    private var token = UUID()

    func cancel() {
        token = UUID()
        timeout?.cancel(); timeout = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; busy = false; progress = ""
    }

    func run(_ request: [String: Any], settings: Settings,
             onEvent: @escaping (DocumentReply) -> Void = { _ in },
             completion: @escaping (DocumentReply?, String?) -> Void) {
        guard !busy else { return }
        cancel(); failure = nil
        let ownedToken = token
        let worker = Process(), input = Pipe(), output = Pipe()
        worker.executableURL = Paths.venvPython
        worker.arguments = ["-B", Paths.core.deletingLastPathComponent().appending(path: "document_tools.py").path]
        worker.environment = AppConfiguration.environment(settings: settings)
        worker.standardInput = input; worker.standardOutput = output
        worker.standardError = FileHandle.nullDevice
        var finalReply: DocumentReply?
        var reportedError: String?
        do {
            let payload = try JSONSerialization.data(withJSONObject: request) + Data([10])
            guard payload.count <= 128 * 1024 * 1024 else {
                completion(nil, "Документ слишком большой для обработки."); return
            }
            // Cancelling a process while its large stdin is being written must
            // produce an EPIPE error, not terminate the GUI with SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            try worker.run()
            process = worker; busy = true; progress = "Обрабатываю локально…"
            ProcessOutput.read(output, process: worker, onLine: { [weak self] line in
                guard let self, self.token == ownedToken, self.process === worker,
                      let data = line.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(DocumentReply.self, from: data) else { return }
                if reply.event == "progress" { self.progress = reply.message ?? "" }
                if reply.event == "error" { reportedError = reply.message ?? "Не удалось обработать документ." }
                if reply.event == "result" { finalReply = reply }
                onEvent(reply)
            }, onExit: { [weak self] status in
                guard let self, self.token == ownedToken, self.process === worker else { return }
                self.timeout?.cancel(); self.timeout = nil
                self.process = nil; self.busy = false; self.progress = ""
                let error = reportedError ?? (status == 0 && finalReply != nil ? nil : "Обработка документа завершилась без результата.")
                self.failure = error
                completion(finalReply, error)
            })
            DispatchQueue.global(qos: .utility).async {
                defer { try? input.fileHandleForWriting.close() }
                do { try input.fileHandleForWriting.write(contentsOf: payload) }
                catch { /* Exit handler reports an incomplete request. */ }
            }
            let action = request["action"] as? String
            let seconds: Double = (action == "detect" || action?.hasPrefix("privacy_") == true) ? 86_400 : (action == "read" ? 600 : 180)
            let limit = DispatchWorkItem { [weak self] in
                guard let self, self.token == ownedToken else { return }
                self.cancel()
                self.failure = "Превышено время обработки. Попробуйте документ меньшего размера."
                completion(nil, self.failure)
            }
            timeout = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: limit)
        } catch {
            if worker.isRunning { worker.terminate() }
            process = nil; busy = false; progress = ""; failure = error.localizedDescription
            completion(nil, failure)
        }
    }
}

@Observable
final class DocumentWorkspace {
    let job = DocumentJob()
    private(set) var document: LocalDocument?
    private(set) var originalURL: URL?
    var entities: [PrivacyEntity] = [] {
        didSet { if entities != oldValue { reviewed = false; replacementsChanged = true } }
    }
    var output = "" {
        didSet { if output != oldValue { reviewed = false } }
    }
    var warnings: [String] = []
    var error: String?
    var notice = ""
    var reviewed = false
    var hasResult = false
    var useModel = true
    var replacementsChanged = false
    var showOriginal = false
    var manualText = ""
    var manualReplacement = "[Данные пользователя]"
    var previewPage = 0
    var preserveFormat = false
    var entityPage = 0

    func reset() {
        job.cancel()
        document = nil; originalURL = nil; entities = []; output = ""
        warnings = []; error = nil; notice = ""; reviewed = false
        hasResult = false; replacementsChanged = false; showOriginal = false
        manualText = ""; manualReplacement = "[Данные пользователя]"; previewPage = 0; entityPage = 0
    }

    // Bound editor layout cost without truncating the stored/exported document.
    private var previewSource: String { showOriginal ? (document?.text ?? "") : output }
    var previewPages: Int { max(1, (previewSource.count + 9999) / 10000) }
    private func previewRange(in text: String) -> Range<String.Index> {
        let page = min(max(0, previewPage), max(0, (text.count - 1) / 10000))
        let start = text.index(text.startIndex, offsetBy: page * 10000, limitedBy: text.endIndex) ?? text.endIndex
        let end = text.index(start, offsetBy: 10000, limitedBy: text.endIndex) ?? text.endIndex
        return start..<end
    }
    var previewText: String {
        get { let text = previewSource; return String(text[previewRange(in: text)]) }
        set {
            guard !showOriginal else { return }
            let range = previewRange(in: output)
            output.replaceSubrange(range, with: newValue)
        }
    }

    func read(_ url: URL, settings: Settings) {
        guard !job.busy else { return }
        reset()
        job.run(["action": preserveFormat ? "privacy_read" : "read", "path": url.path], settings: settings) { [weak self] reply, error in
            guard let self else { return }
            self.error = error
            guard let document = reply?.document, error == nil else { return }
            self.document = document; self.originalURL = url.resolvingSymlinksInPath()
            self.entities = []; self.output = ""; self.hasResult = false
            self.reviewed = false; self.replacementsChanged = false
            self.warnings = document.warnings; self.showOriginal = true
        }
    }

    func read(_ urls: [URL], settings: Settings) {
        guard !job.busy, !urls.isEmpty else { return }
        reset()
        func next(_ index: Int, _ loaded: [LocalDocument]) {
            if index == urls.count {
                do {
                    document = try LocalDocument.combining(loaded)
                    warnings = document?.warnings ?? []; showOriginal = true
                } catch { self.error = error.localizedDescription }
                return
            }
            job.run(["action": "read", "path": urls[index].path], settings: settings) { reply, failure in
                guard let item = reply?.document, failure == nil else {
                    self.error = failure ?? "Не удалось прочитать вложение."; return
                }
                let items = loaded + [item]
                do { _ = try LocalDocument.combining(items) }
                catch { self.error = error.localizedDescription; return }
                next(index + 1, items)
            }
        }
        next(0, [])
    }

    func detect(settings: Settings) {
        guard let document, !job.busy else { return }
        error = nil; reviewed = false; hasResult = false; notice = ""
        var request: [String: Any] = ["action": "detect", "document": document.payload, "use_model": useModel]
        if preserveFormat {
            request = ["action": "privacy_detect", "path": originalURL?.path ?? "", "source_hash": document.sourceHash ?? "", "use_model": useModel]
        }
        job.run(request, settings: settings) { [weak self] reply, error in
            guard let self else { return }
            self.error = error
            guard let reply, error == nil, let text = reply.text else { return }
            self.entities = reply.entities ?? []; self.output = text
            self.hasResult = true; self.showOriginal = false; self.replacementsChanged = false
            self.previewPage = 0
            self.warnings = self.preserveFormat ? (reply.warnings ?? document.warnings) : document.warnings + (reply.warnings ?? [])
            self.entityPage = 0
            self.notice = self.preserveFormat
                ? "Найдено вхождений во всём файле: \(reply.count ?? 0). Предпросмотр — только начало; экспортируется весь файл."
                : "Заменено вхождений: \(reply.count ?? 0). Проверено моделью: \(reply.checked ?? 0) из \(reply.total ?? 0) фрагментов."
        }
    }

    func apply(settings: Settings) {
        guard let document, !job.busy,
              let data = try? JSONEncoder().encode(entities),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return }
        error = nil; reviewed = false
        var request: [String: Any] = ["action": "apply", "document": document.payload, "entities": raw]
        if preserveFormat {
            request = ["action": "privacy_apply", "path": originalURL?.path ?? "", "source_hash": document.sourceHash ?? "", "entities": raw]
        }
        job.run(request, settings: settings) { [weak self] reply, error in
            guard let self else { return }
            self.error = error
            guard let text = reply?.text, error == nil else { return }
            self.output = text; self.hasResult = true; self.showOriginal = false
            self.replacementsChanged = false
            self.notice = "Заменено вхождений: \(reply?.count ?? 0). Проверьте текст перед экспортом."
        }
    }

    func addManual() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 200, preserveFormat || document?.text.range(of: text, options: .caseInsensitive) != nil else {
            error = "Укажите точную фразу из исходника: от 2 до 200 символов."; return
        }
        entities.append(PrivacyEntity(id: UUID().uuidString, kind: "OTHER", variants: [text],
                                      replacement: manualReplacement, enabled: true, origin: "Вручную"))
        manualText = ""; reviewed = false; replacementsChanged = true; error = nil
    }

    var canExport: Bool { hasResult && reviewed && !replacementsChanged && !job.busy && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func export(to url: URL, word: Bool, settings: Settings) {
        guard canExport else { error = "Сначала примените замены и проверьте результат."; return }
        guard url.resolvingSymlinksInPath().standardizedFileURL != originalURL?.standardizedFileURL else {
            error = "Исходник нельзя перезаписывать. Выберите другое имя файла."; return
        }
        error = nil
        if preserveFormat {
            guard let document, let originalURL,
                  url.pathExtension.lowercased() == originalURL.pathExtension.lowercased(),
                  let data = try? JSONEncoder().encode(entities),
                  let raw = try? JSONSerialization.jsonObject(with: data) else {
                error = "Сохраните копию с тем же расширением, что исходник."; return
            }
            job.run(["action": "privacy_export", "path": originalURL.path, "source_hash": document.sourceHash ?? "", "entities": raw], settings: settings) { [weak self] reply, failure in
                guard let self else { return }
                self.error = failure
                guard failure == nil, let encoded = reply?.data, let data = Data(base64Encoded: encoded) else { return }
                self.write(data, to: url)
            }
        } else if word {
            job.run(["action": "export_docx", "text": output], settings: settings) { [weak self] reply, error in
                guard let self else { return }
                self.error = error
                guard error == nil, let encoded = reply?.data, let data = Data(base64Encoded: encoded) else { return }
                self.write(data, to: url)
            }
        } else { write(Data(output.utf8), to: url) }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            notice = "Сохранена копия: \(url.lastPathComponent). Исходник не изменён."
        } catch { self.error = "Не удалось сохранить копию: " + error.localizedDescription }
    }
}

#if !CHAT_TESTING
struct DocumentSheet: View {
    @Bindable var workspace: DocumentWorkspace
    var settings: Settings
    var attach: (LocalDocument) -> Void
    var standalone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(standalone ? "Обезличивание документов" : "Документы · только локально").font(Kind.head(22))
                    Text("Подготовка проверяемой копии без персональных данных. Исходник не изменяется.")
                        .font(Kind.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
                if !standalone { Button("Закрыть") { dismiss() }.buttonStyle(QuietButton()) }
            }
            HStack {
                Button(workspace.document == nil ? "Открыть файл…" : "Другой файл…", action: choose)
                    .buttonStyle(PrimaryButton()).disabled(workspace.job.busy)
                if let document = workspace.document {
                    Text(document.title).font(Kind.strong(13)).lineLimit(1)
                    Text("\(document.characters) символов").font(Kind.body(12)).foregroundStyle(p.muted)
                    Spacer()
                    Button("Убрать файл") { workspace.reset() }
                        .buttonStyle(QuietButton()).disabled(workspace.job.busy)
                    if !standalone { Button("Читать в чате") { attach(document); dismiss() }
                        .buttonStyle(QuietButton()).disabled(workspace.job.busy)
                    }
                }
            }
            if workspace.document != nil {
                HStack {
                    Button("Найти персональные данные") { workspace.detect(settings: settings) }
                        .buttonStyle(PrimaryButton()).disabled(workspace.job.busy)
                    Toggle(standalone ? "Дополнительно искать имена локальной NER" : "Имена и адреса — локальной моделью", isOn: $workspace.useModel)
                        .toggleStyle(.checkbox).font(Kind.body(12)).disabled(workspace.job.busy)
                    Spacer()
                }
                HStack(alignment: .top, spacing: 14) {
                    replacements.frame(width: 330)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Исходный текст") { workspace.showOriginal = true; workspace.previewPage = 0 }.buttonStyle(QuietButton())
                            Button("Копия для проверки") { workspace.showOriginal = false; workspace.previewPage = 0 }.buttonStyle(QuietButton())
                                .disabled(!workspace.hasResult)
                            Spacer()
                            Text(workspace.showOriginal ? "Исходник · только чтение" : (standalone ? "Копия · предпросмотр" : "Копия · можно исправить"))
                                .font(Kind.body(11)).foregroundStyle(p.muted)
                        }
                        if workspace.showOriginal {
                            ScrollView { Text(workspace.previewText).font(Kind.body(13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                                .background(p.raised)
                        } else if workspace.hasResult && !standalone {
                            TextEditor(text: $workspace.previewText).font(Kind.body(13))
                                .scrollContentBackground(.hidden).padding(8).background(p.raised)
                                .disabled(workspace.job.busy)
                        } else if workspace.hasResult {
                            ScrollView { Text(workspace.previewText).font(Kind.body(13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                                .background(p.raised)
                            Text("Начало файла. Изменяйте замены слева: они применяются ко всему оригиналу при экспорте.")
                                .font(Kind.body(11)).foregroundStyle(p.muted)
                        } else {
                            Text("Сначала запустите поиск данных или добавьте свои замены.")
                                .font(Kind.body(13)).foregroundStyle(p.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if workspace.previewPages > 1 {
                            HStack {
                                Button("Назад") { workspace.previewPage -= 1 }.disabled(workspace.previewPage <= 0)
                                Text("Часть \(min(workspace.previewPage + 1, workspace.previewPages)) из \(workspace.previewPages) · сохраняется весь текст")
                                    .font(Kind.body(11))
                                Button("Далее") { workspace.previewPage += 1 }
                                    .disabled(workspace.previewPage + 1 >= workspace.previewPages)
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
                ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(workspace.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(Kind.body(11)).foregroundStyle(p.warn)
                    }
                    Text(standalone ? "Экспорт — копия того же формата. Строки и таблицы сохраняются; служебные данные и вложения удаляются. PDF — только текстовый, без изображений; найденный текст удаляется. Проверьте весь результат перед передачей." : "Экспорт — новый текстовый TXT или Word: без картинок, вложений, авторов и скрытого содержимого исходника. Это не сохранение исходной вёрстки.")
                        .font(Kind.body(11)).foregroundStyle(p.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 85)
                Toggle("Я проверил(а) текст и замены перед передачей наружу", isOn: $workspace.reviewed)
                    .toggleStyle(.checkbox).font(Kind.body(12))
                    .disabled(!workspace.hasResult || workspace.replacementsChanged || workspace.job.busy)
                HStack {
                    Button(standalone ? "Сохранить копию в исходном формате…" : "Сохранить TXT…") { save(word: false) }.buttonStyle(PrimaryButton()).disabled(!workspace.canExport)
                    if !standalone { Button("Сохранить Word…") { save(word: true) }.buttonStyle(QuietButton()).disabled(!workspace.canExport) }
                    if !standalone { Button("Копию в локальный чат") { attach(.reviewedCopy(workspace.output)); dismiss() }
                        .buttonStyle(QuietButton()).disabled(!workspace.canExport)
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 38)).foregroundStyle(p.accent2)
                    Text("Excel XLSX · CSV / TSV · Word DOCX · текстовый PDF · TXT").font(Kind.strong(15))
                    Text("До 100 МБ и 25 млн символов, до 250 000 разных замен.\nПодходит для таблиц на 15 000+ строк. Проверяется весь файл, не только предпросмотр.\nИнтернет и Ollama для обезличивания не нужны. Сканы и PDF с изображениями не поддерживаются.")
                        .font(Kind.body(13)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if workspace.job.busy {
                HStack { ProgressView().controlSize(.small); Text(workspace.job.progress).font(Kind.body(12)); Spacer()
                    Button("Остановить") { workspace.job.cancel() }.buttonStyle(QuietButton()) }
            }
            if let error = workspace.error { Text(error).font(Kind.body(12)).foregroundStyle(p.warn) }
            if !workspace.notice.isEmpty { Text(workspace.notice).font(Kind.body(12)).foregroundStyle(p.muted) }
        }
        .padding(22).frame(width: standalone ? nil : 1030, height: standalone ? nil : 735)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(p.surface)
        .onAppear { workspace.preserveFormat = standalone }
        .onDisappear { workspace.reset() }
    }

    private var replacements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Замены (\(workspace.entities.count))").font(Kind.strong(14))
            Text("Одинаковые метки сохраняют связи. Проверьте, не объединены ли разные люди; подпись можно изменить.")
                .font(Kind.body(11)).foregroundStyle(p.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(workspace.entities.indices.dropFirst(workspace.entityPage * 100).prefix(100)), id: \.self) { index in
                        let entity = workspace.entities[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(entity.variants.joined(separator: " / "), isOn: $workspace.entities[index].enabled)
                                .toggleStyle(.checkbox).font(Kind.body(12)).textSelection(.enabled)
                            TextField("Заменить на", text: $workspace.entities[index].replacement).textFieldStyle(.roundedBorder)
                                .font(Kind.body(12))
                        }.padding(8).background(RoundedRectangle(cornerRadius: 7).fill(p.raised))
                    }
                }
            }
            if workspace.entities.count > 100 {
                HStack {
                    Button("Назад") { workspace.entityPage -= 1 }.disabled(workspace.entityPage == 0)
                    Text("\(workspace.entityPage + 1) / \((workspace.entities.count + 99) / 100)").font(Kind.body(11))
                    Button("Далее") { workspace.entityPage += 1 }.disabled((workspace.entityPage + 1) * 100 >= workspace.entities.count)
                }
            }
            TextField("Добавить точную фразу из исходника", text: $workspace.manualText).textFieldStyle(.roundedBorder)
            TextField("Заменить на", text: $workspace.manualReplacement).textFieldStyle(.roundedBorder)
            HStack {
                Button("Добавить") { workspace.addManual() }.buttonStyle(QuietButton())
                Button("Применить замены") { workspace.apply(settings: settings) }.buttonStyle(QuietButton())
            }
            if workspace.replacementsChanged {
                Text("Примените изменения, затем проверьте копию заново.").font(Kind.body(11)).foregroundStyle(p.warn)
            }
        }
        .disabled(workspace.job.busy)
    }

    private func choose() {
        let panel = NSOpenPanel()
        // AppKit may reuse panel state after another screen chose a folder.
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = (standalone ? ["xlsx", "csv", "tsv", "pdf", "docx", "txt", "md"] : ["pdf", "docx", "doc", "txt", "md"]).compactMap { UTType(filenameExtension: $0) }
        panel.message = "Документ будет прочитан на этом компьютере. Исходник не изменяется."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.read(url, settings: settings)
    }

    private func save(word: Bool) {
        let panel = NSSavePanel()
        let ext = standalone ? (workspace.originalURL?.pathExtension ?? "txt") : (word ? "docx" : "txt")
        panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
        panel.nameFieldStringValue = "Обезличенная копия." + ext
        panel.message = standalone ? "Сохраняется весь файл с заменами, а не только предпросмотр. Исходник не изменяется." : "Сохраняется только проверенный текст, без оригинала и таблицы соответствий."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.export(to: url, word: word, settings: settings)
    }
}

/// File context belongs to chat; privacy editing is a separate workspace.
struct ChatAttachmentSheet: View {
    @Bindable var workspace: DocumentWorkspace
    var settings: Settings
    var attach: (LocalDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Файлы для чата").font(Kind.head(22))
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(QuietButton())
            }
            Text("PDF, Word, TXT и MD. Можно выбрать несколько файлов. Модель ответит по их тексту с цитатами; обработка только локальная.")
                .font(Kind.body(13)).foregroundStyle(p.muted)
            Button("Выбрать файлы…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
                panel.allowedContentTypes = ["pdf", "docx", "doc", "txt", "md"].compactMap { UTType(filenameExtension: $0) }
                if panel.runModal() == .OK { workspace.read(panel.urls, settings: settings) }
            }.buttonStyle(PrimaryButton()).disabled(workspace.job.busy)
            if let document = workspace.document {
                Text(document.title).font(Kind.strong(13)).lineLimit(3)
                Text("\(document.characters) символов · \(document.blocks.count) фрагментов").font(Kind.body(12))
                ScrollView {
                    Text(String(document.text.prefix(3000))).font(Kind.body(13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if document.characters > 3000 {
                    Text("Здесь показано начало. В чат прикрепляется весь извлечённый текст; для длинных файлов ответы строятся по выбранным фрагментам.")
                        .font(Kind.body(11)).foregroundStyle(p.muted)
                }
                ScrollView { Text(document.warnings.joined(separator: "\n")).font(Kind.body(11)).foregroundStyle(p.warn) }
                    .frame(maxHeight: 85)
                Button("Прикрепить к чату") { attach(document); dismiss() }.buttonStyle(PrimaryButton())
            } else { Spacer() }
            if workspace.job.busy {
                HStack { ProgressView(); Text(workspace.job.progress).font(Kind.body(12))
                    Button("Остановить") { workspace.reset() } }
            }
            if let error = workspace.error { Text(error).font(Kind.body(12)).foregroundStyle(p.warn) }
        }.padding(24).frame(width: 760, height: 620).background(p.surface)
            .onDisappear { workspace.reset() }
    }
}
#endif
