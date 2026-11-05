import SwiftUI

struct MemoryPerson: Decodable, Identifiable {
    let id: String
    let name: String
    let meetings: Int
    let quotes: Int
    let last_seen: String
    let identity: String
    /// Встреча, в которой голос звучал. У человека с карточкой встреч много,
    /// и название здесь — просто последняя из них.
    let title: String?
    /// Голос связан с карточкой человека. Всё остальное — голос, известный
    /// внутри одной встречи: имя ему дала догадка по разговору или сама
    /// диаризация, и за пределами этой встречи оно ничего не значит.
    var confirmed: Bool { id.hasPrefix("profile:") }
    /// Чем подписать голос без карточки, чтобы строки не были одинаковыми.
    var mark: String {
        confirmed ? "" : " · голос без карточки" + (title.map { " · \($0)" } ?? "")
    }
}

struct MemoryMeeting: Decodable, Identifiable {
    let id: String
    let title: String
    let date: String
}

struct MemoryEdge: Decodable, Identifiable {
    let a: String
    let b: String
    let meetings: [String]
    var id: String { a + b }
}

struct MemoryOverview: Decodable {
    var people: [MemoryPerson] = []
    var meetings: [MemoryMeeting] = []
    var edges: [MemoryEdge] = []
    var quotes = 0
    var hidden_fragments: Int?
}

struct DeletedMeeting: Decodable, Identifiable {
    let id: String
    let title: String
    let date: String
    let count: Int
}

struct MemoryQuote: Codable, Identifiable, Equatable {
    let id: String
    let meeting: String
    let title: String
    let date: String
    let source: String
    let voice: String
    let person: String
    let name: String
    let identity: String
    let start: Double
    let end: Double
    let text: String
    /// Откуда взялось имя над репликой. «Не подтверждена» ничего не
    /// объясняло: человек не знает, что он должен был подтвердить и где.
    var attribution: String {
        switch identity {
        case "manual": return "Голос назван вами"
        case "voice": return "Узнан по голосовому профилю"
        default: return "Имя не сохранено: голос известен только в этой встрече"
        }
    }
    var record: Record {
        Record(dir: URL(fileURLWithPath: meeting), title: title, date: Date())
    }
    var audio: URL? {
        let fm = FileManager.default
        if !source.isEmpty {
            let original = URL(fileURLWithPath: source)
            if voice == "OWN" {
                let own = original.deletingLastPathComponent().appending(path: "\(title) — мой голос.wav")
                if fm.fileExists(atPath: own.path) { return own }
            } else if fm.fileExists(atPath: original.path) { return original }
        }
        return voice == "OWN" ? record.ownTrack : record.source
    }
    var time: String { String(format: "%02d:%02d", Int(start)/60, Int(start)%60) }
}

/// One cancellable worker owns the index at a time. UI state lives across tabs.
@Observable final class SpeakerMemory {
    var query = ""
    var mode = "semantic"
    var person = ""
    var meeting = ""
    var tab = "search"
    private(set) var overview = MemoryOverview()
    private(set) var hits: [MemoryQuote] = []
    private(set) var context: [MemoryQuote] = []
    private(set) var total = 0
    private(set) var busy = false
    private(set) var isMutating = false
    private(set) var deleted: [DeletedMeeting] = []
    private(set) var progress = ""
    private(set) var notice = ""
    private(set) var failure: String?
    private(set) var warnings: [String] = []
    private var process: Process?
    /// Запрос, пришедший, пока память была занята. Раньше такой запрос
    /// молча выбрасывался: «Записи» при запуске просят каталог, человек
    /// переходит в «Память», её запрос на синхронизацию и хронологию
    /// натыкается на занятость — и экран навсегда показывал «0 реплик».
    /// Храним только последний: он и отражает то, чего человек ждёт сейчас.
    private var queued: (() -> Void)?
    private var root = ""

    private struct Reply: Decodable {
        let event: String
        var message: String?
        var overview: MemoryOverview?
        var hits: [MemoryQuote]?
        var context: [MemoryQuote]?
        var total: Int?
        var notice: String?
        var warnings: [String]?
        var deleted: [DeletedMeeting]?
    }

    func activate(settings: Settings) {
        guard !isMutating else { return }
        if root != settings.results_dir {
            if busy { cancel() }
            root = settings.results_dir
            overview = MemoryOverview(); hits = []; context = []; total = 0; deleted = []
            person = ""; meeting = ""
            refresh(settings: settings)
        } else {
            // A user may have just named voices in another screen. Never
            // retain an old graph merely because a minute has not passed.
            refresh(settings: settings)
        }
    }

    func invalidate(settings: Settings) {
        guard !isMutating else { return }
        if busy { cancel() }
        refresh(settings: settings)
    }

    func loadCatalog(settings: Settings) {
        guard !isMutating else { return }
        if root != settings.results_dir {
            if busy { cancel() }
            root = settings.results_dir
            overview = MemoryOverview(); hits = []; context = []; total = 0; deleted = []
            person = ""; meeting = ""
        }
        run(["action": "catalog"], settings: settings)
    }

    func deleteMeeting(_ record: Record, settings: Settings, done: @escaping () -> Void) {
        mutate(["action": "delete_meeting", "meeting": record.dir.path], settings: settings, done: done)
    }

    func restoreMeeting(_ entry: DeletedMeeting, settings: Settings, done: @escaping () -> Void) {
        mutate(["action": "restore_meeting", "token": entry.id], settings: settings, done: done)
    }

    private func mutate(_ request: [String: Any], settings: Settings, done: @escaping () -> Void) {
        run(request, settings: settings) { [weak self] in
            guard let self else { return }
            self.person = ""; self.meeting = ""; self.hits = []; self.context = []; self.total = 0
            done()
            self.search(settings: settings, keepNotice: true)
        }
    }

    func refresh(settings: Settings) {
        run(["action": "sync"], settings: settings) { [weak self] in
            self?.search(settings: settings, keepNotice: true)
        }
    }

    func search(settings: Settings, more: Bool = false, keepNotice: Bool = false) {
        guard !busy else {
            queued = { [weak self] in self?.search(settings: settings, more: more, keepNotice: keepNotice) }
            return
        }
        if !more { hits = []; total = 0 }
        let offset = more ? hits.count : 0
        run(["action": "search", "query": query, "mode": mode,
             "person": person, "meeting": meeting, "offset": offset],
            settings: settings, append: more, keepNotice: keepNotice)
    }

    func loadContext(_ quote: MemoryQuote, settings: Settings) {
        context = []
        run(["action": "context", "id": quote.id], settings: settings)
    }

    func link(_ quote: MemoryQuote, profile: String, settings: Settings) {
        run(["action": "link", "meeting": quote.meeting, "voice": quote.voice,
             "profile": profile], settings: settings) { [weak self] in
            self?.person = "profile:" + profile
            self?.search(settings: settings)
        }
    }

    func cancel() {
        // File moves are brief and journalled, but interrupting one is not a
        // normal cancellation path. A crash is recoverable through the bin.
        guard !isMutating else { return }
        // Invalidate callbacks immediately; SQLite rolls back an unfinished write.
        if let process, process.isRunning { process.terminate() }
        process = nil; busy = false; queued = nil
        progress = ""
        notice = "Остановлено. Уже сохранённая память останется на диске."
    }

    private func run(_ request: [String: Any], settings: Settings,
                     append: Bool = false, keepNotice: Bool = false,
                     done: (() -> Void)? = nil) {
        guard !busy else {
            queued = { [weak self] in
                self?.run(request, settings: settings, append: append, keepNotice: keepNotice, done: done)
            }
            return
        }
        let worker = Process()
        worker.executableURL = Paths.venvPython
        worker.arguments = ["-B", Paths.core.deletingLastPathComponent().appending(path: "speaker_memory.py").path,
                            "--root", settings.results_dir, "--profiles", Paths.profiles.path]
        worker.environment = AppConfiguration.environment(settings: settings)
        let input = Pipe(), output = Pipe()
        worker.standardInput = input; worker.standardOutput = output
        worker.standardError = FileHandle.standardError
        busy = true; failure = nil; progress = "Читаю память встреч…"
        isMutating = ["delete_meeting", "restore_meeting"].contains(request["action"] as? String ?? "")
        if !keepNotice { notice = "" }
        process = worker
        var received = false
        do {
            var request = request
            request["build_graph"] = settings.memory_graph_enabled
            let payload = try JSONSerialization.data(withJSONObject: request)
            try worker.run()
            try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
            try input.fileHandleForWriting.close()
            ProcessOutput.read(output, process: worker, onLine: { [weak self] line in
                guard let self, self.process === worker,
                      let data = line.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
                if reply.event == "progress" { self.progress = reply.message ?? "" }
                if reply.event == "error" { self.failure = reply.message }
                if reply.event == "result" {
                    received = true
                    if let overview = reply.overview {
                        self.overview = overview
                        if !self.person.isEmpty && !overview.people.contains(where: { $0.id == self.person }) { self.person = "" }
                        if !self.meeting.isEmpty && !overview.meetings.contains(where: { $0.id == self.meeting }) { self.meeting = "" }
                    }
                    if let hits = reply.hits { self.hits = append ? self.hits + hits : hits }
                    if let context = reply.context { self.context = context }
                    if let total = reply.total { self.total = total }
                    if let deleted = reply.deleted { self.deleted = deleted }
                    if let notice = reply.notice, !notice.isEmpty || !keepNotice { self.notice = notice }
                    self.warnings = reply.warnings ?? []
                }
            }, onExit: { [weak self] status in
                guard let self, self.process === worker else { return }
                self.process = nil; self.busy = false; self.isMutating = false; self.progress = ""
                if status != 0 || !received {
                    self.failure = self.failure ?? "Не удалось прочитать память встреч. Проверьте окружение и доступ к папке результатов."
                } else { done?() }
                // Отложенный запрос — после своего продолжения: если done
                // уже запустил следующий шаг, очередь дождётся и его.
                if !self.busy, let next = self.queued { self.queued = nil; next() }
            })
        } catch {
            if worker.isRunning { worker.terminate() }
            process = nil; busy = false; isMutating = false; failure = error.localizedDescription
        }
    }
}
