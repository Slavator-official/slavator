import Foundation

enum Paths {
    static var support: URL { AppConfiguration.support }
    static var core: URL { support.appendingPathComponent("core.py") }
    static var profiles: URL { support }
    static var venvPython: URL { URL(fileURLWithPath: "/usr/bin/python3") }
}
struct Record {
    let dir: URL; let title: String; let date: Date
    var source: URL? { nil }
    var ownTrack: URL? { nil }
}

@main struct ChatChecks {
    static func spin(until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Chat worker timeout")
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slavator-chat-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("MEETING_TRANSCRIBER_APP_SUPPORT", dir.path, 1)
        let worker = """
        import json,sys,time
        r=json.loads(sys.stdin.readline())
        print(json.dumps({'event':'progress','message':'ready'}),flush=True)
        if r['question']=='slow': time.sleep(.5)
        q=dict(id='quote',meeting='/meeting',title='Встреча',date='2026-09-07',source='',voice='OWN',person='profile:one',name='Анна',identity='manual',start=62,end=65,text='Точная цитата')
        print(json.dumps(dict(event='result',text=r['question'],sources=[q])),flush=True)
        """
        try worker.write(to: dir.appendingPathComponent("meeting_chat.py"), atomically: true, encoding: .utf8)
        var settings = Settings(); settings.chat_memory_enabled = true
        let chat = Chat()
        chat.send("first", settings: settings)
        spin { !chat.isAnswering }
        precondition(chat.messages.last?.text == "first")
        precondition(chat.messages.last?.sources?.first?.time == "01:02")
        let firstID = chat.currentID!
        chat.send("slow", settings: settings)
        spin { chat.progress == "ready" }
        chat.startNew()
        chat.send("second", settings: settings)
        spin { !chat.isAnswering }
        precondition(chat.messages.last?.text == "second")
        chat.open(firstID)
        precondition(chat.messages.last?.text != "second")
        let restored = Chat()
        precondition(restored.conversations.contains { $0.messages.contains { $0.sources?.first?.id == "quote" } })
        let old = Data("{\"role\":\"user\",\"id\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"old\"}".utf8)
        let message = try JSONDecoder().decode(Chat.Message.self, from: old)
        precondition(message.sources == nil && message.fromMemory == nil)
        print("PASS: чат — источники, сохранение, старый формат, отмена и изоляция переписок")
    }
}
