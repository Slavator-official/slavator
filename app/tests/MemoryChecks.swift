import Foundation

enum Paths {
    static var core: URL { AppConfiguration.support.appendingPathComponent("core.py") }
    static var profiles: URL { AppConfiguration.support }
    static var venvPython: URL { URL(fileURLWithPath: "/usr/bin/python3") }
}
struct Record {
    let dir: URL; let title: String; let date: Date
    var source: URL? { nil }
    var ownTrack: URL? { nil }
}

@main struct MemoryChecks {
    static func spin(until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Memory worker timeout")
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slavator-memory-check-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("MEETING_TRANSCRIBER_APP_SUPPORT", dir.path, 1)
        let worker = """
        import json,sys,time,pathlib
        r=json.loads(sys.stdin.readline())
        print(json.dumps({'event':'progress','message':'ready'}),flush=True)
        if r.get('query')=='slow': time.sleep(30)
        q=dict(id='quote',meeting='/meeting',title='Встреча',date='2026-09-07',source='',voice='OWN',person='profile:one',name='Анна',identity='manual',start=62,end=65,text='Точная цитата')
        identity=pathlib.Path(__file__).with_name('identity.txt')
        if identity.exists(): q['name']=identity.read_text()
        v=dict(event='result',overview=dict(people=[],meetings=[],edges=[],quotes=1),notice='',warnings=[])
        if r['action']=='delete_meeting':
            time.sleep(.25)
            v['deleted']=[dict(id='token',title='Удалённая встреча',date='2026-09-08',count=2)]
        if r['action']=='restore_meeting': v['deleted']=[]
        if r['action']=='search': v.update(hits=[q],total=1)
        if r['action']=='context': v.update(context=[q])
        print(json.dumps(v),flush=True)
        """
        try worker.write(to: dir.appendingPathComponent("speaker_memory.py"),atomically:true,encoding:.utf8)
        var settings = Settings(); settings.results_dir = dir.path
        let memory = SpeakerMemory()
        memory.activate(settings: settings)
        spin { !memory.busy }
        precondition(memory.hits.count == 1 && memory.total == 1 && memory.failure == nil)
        let hit = memory.hits[0]
        precondition(hit.name == "Анна" && hit.time == "01:02" && hit.audio == nil)
        memory.loadContext(hit,settings:settings)
        spin { !memory.busy }
        precondition(memory.context.first?.id == hit.id)
        try "Новое имя".write(to: dir.appendingPathComponent("identity.txt"),atomically:true,encoding:.utf8)
        memory.activate(settings:settings)
        spin { !memory.busy }
        precondition(memory.hits.first?.name == "Новое имя", "Назначенное имя должно обновляться без минутной задержки")
        var changed = false
        memory.deleteMeeting(hit.record,settings:settings) { changed = true }
        precondition(memory.isMutating && memory.busy)
        memory.cancel()
        precondition(memory.busy, "Нельзя прерывать перемещение файлов обычной отменой")
        spin { !memory.busy }
        precondition(changed && memory.deleted.first?.count == 2)
        memory.restoreMeeting(memory.deleted[0],settings:settings) { changed = false }
        spin { !memory.busy }
        precondition(!changed && memory.deleted.isEmpty)
        memory.query = "slow"; memory.search(settings:settings)
        spin { memory.progress == "ready" }
        memory.cancel()
        memory.query = "быстро"; memory.search(settings:settings)
        spin { !memory.busy }
        precondition(memory.hits.first?.text == "Точная цитата" && memory.failure == nil)
        print("PASS: память — поиск, контекст, немедленное обновление имён, корзина/восстановление, отмена и новый запрос")
    }
}
