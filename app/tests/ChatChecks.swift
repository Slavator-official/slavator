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
        precondition(message.sources == nil && message.fromMemory == nil && message.documentNotice == nil)
        let legacyText = "Ответ [1].\n\nОтвет локальной модели — проверьте по источникам.\n\nИспользовано фрагментов: 6 из 8. Это выборка, не полный разбор всего документа."
        let legacyDocument = Chat.Message(role: .model, text: legacyText, fromDocument: true)
        precondition(legacyDocument.documentPresentation.text == "Ответ [1].")
        precondition(legacyDocument.documentPresentation.notice?.contains("выборка") == true)
        precondition(legacyDocument.text == legacyText)
        precondition(Chat.Message(role: .user, text: legacyText).documentPresentation.text == legacyText)
        print("PASS: чат — источники, сохранение, старый формат, отмена и изоляция переписок")

        let documentWorker = """
        import json,sys,time
        time.sleep(.1)
        r=json.loads(sys.stdin.readline())
        print(json.dumps({'event':'progress','message':'ready'}),flush=True)
        if r.get('question')=='slow': time.sleep(.5)
        action=r['action']
        if action in ('read','privacy_read'):
            result={'document':dict(title='source.docx',format='DOCX',blocks=[dict(id='1',locator='Текст',text='Иван и бюджет 500')],warnings=[],characters=18,sourceHash='a'*64)}
        elif action in ('detect','privacy_detect'):
            result=dict(text='[Человек 1] и бюджет 500',entities=[dict(id='1',kind='PERSON',variants=['Иван'],replacement='[Человек 1]',enabled=True,origin='Модель')],count=1,checked=1,total=1,model_complete=True)
        elif action=='apply': result={'text':r['entities'][0]['replacement']+' и бюджет 500','count':1}
        elif action=='answer':
            citations=[dict(id='1',locator='Страница 1',text='Точная цитата из файла',block='1',shortened=False)]
            print(json.dumps(dict(event='sources',citations=citations)),flush=True)
            result=dict(text=r['question'],citations=citations,notice='Выбрана часть документа')
        elif action=='conversation': result=dict(text='Локальное продолжение')
        elif action=='export_docx': result={'data':'Y2xlYW4='}
        elif action=='privacy_export':
            assert r['source_hash']=='a'*64 and r['path'].endswith('source.docx')
            result={'data':'d2hvbGVfZmlsZQ=='}
        print(json.dumps(dict(event='result',**result)),flush=True)
        """
        try documentWorker.write(to: dir.appendingPathComponent("document_tools.py"), atomically: true, encoding: .utf8)
        let source = dir.appendingPathComponent("source.docx")
        try Data("original".utf8).write(to: source)
        let documents = chat.documents
        documents.read(source, settings: settings)
        spin { !documents.job.busy }
        precondition(documents.document?.title == "source.docx")
        documents.detect(settings: settings)
        spin { !documents.job.busy }
        precondition(documents.hasResult && !documents.canExport && !documents.replacementsChanged)
        documents.reviewed = true
        precondition(documents.canExport)
        documents.output += " Правка"
        precondition(!documents.reviewed && !documents.canExport)
        documents.reviewed = true
        documents.entities[0].replacement = "[Покупатель]"
        precondition(!documents.reviewed && documents.replacementsChanged && !documents.canExport)
        documents.apply(settings: settings)
        spin { !documents.job.busy }
        documents.reviewed = true
        precondition(documents.canExport)
        documents.export(to: source, word: false, settings: settings)
        precondition(documents.error != nil && (try! String(contentsOf: source)) == "original")
        let alias = dir.appendingPathComponent("alias.docx")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        documents.export(to: alias, word: true, settings: settings)
        precondition(documents.error != nil && !documents.job.busy)
        let exported = dir.appendingPathComponent("reviewed.txt")
        documents.export(to: exported, word: false, settings: settings)
        precondition((try! String(contentsOf: exported)) == "[Покупатель] и бюджет 500")
        let copy = LocalDocument.reviewedCopy(String(repeating: "смысл и условие ", count: 400))
        precondition(copy.text == String(repeating: "смысл и условие ", count: 400))

        var doc = documents.document!
        var secondDoc = doc
        secondDoc.title = "second.pdf"
        let combined = try LocalDocument.combining([doc, secondDoc])
        precondition(combined.blocks.count == 2 && Set(combined.blocks.map(\.id)).count == 2)
        precondition(combined.blocks[1].locator.contains("second.pdf"))
        precondition(combined.text == doc.text + "\n\n" + secondDoc.text)
        secondDoc.characters = 2_000_001
        precondition((try? LocalDocument.combining([doc, secondDoc])) == nil)
        documents.output = String(repeating: "я", count: 10000) + "ХВОСТ"
        documents.showOriginal = false; documents.previewPage = 1
        precondition(documents.previewPages == 2 && documents.previewText == "ХВОСТ")
        documents.reviewed = true
        documents.previewText = "НОВЫЙ ХВОСТ"
        precondition(documents.output == String(repeating: "я", count: 10000) + "НОВЫЙ ХВОСТ")
        precondition(!documents.reviewed)
        chat.startNew()
        precondition(documents.document == nil && documents.output.isEmpty && documents.entities.isEmpty)
        precondition(!documents.hasResult && !documents.canExport && documents.originalURL == nil)
        doc.blocks[0].text = "RAW_DOCUMENT_NOT_IN_HISTORY"
        chat.attachDocument(doc)
        chat.send("По файлу", settings: settings)
        spin { !chat.isAnswering }
        precondition(chat.messages.last?.text == "По файлу" && chat.messages.last?.fromDocument == true)
        precondition(chat.messages.last?.documentSources?.first?.locator == "Страница 1")
        precondition(chat.messages.last?.text == "По файлу")
        precondition(chat.messages.last?.documentNotice == "Выбрана часть документа")
        precondition(Chat().conversations.contains { $0.messages.contains { $0.documentNotice == "Выбрана часть документа" } })
        precondition(!(try! String(contentsOf: dir.appendingPathComponent("chats.json"))).contains("RAW_DOCUMENT_NOT_IN_HISTORY"))
        chat.detachDocument()
        precondition(chat.containsDocumentData)
        chat.send("Продолжи", settings: settings) // Memory preference must not reroute this conversation.
        spin { !chat.isAnswering }
        precondition(chat.messages.last?.text == "Локальное продолжение")
        precondition(Chat().conversations.contains { $0.messages.contains { $0.documentSources?.first?.id == "1" } })
        chat.attachDocument(doc)
        chat.send("slow", settings: settings)
        spin { chat.progress == "ready" }
        chat.open(firstID)
        precondition(chat.attachedDocument == nil)
        chat.send("after document", settings: settings)
        spin { !chat.isAnswering }
        precondition(chat.messages.last?.text == "after document")
        precondition(message.fromDocument == nil && message.documentSources == nil)

        let native = DocumentWorkspace(); native.preserveFormat = true
        native.read(source, settings: settings)
        spin { !native.job.busy }
        precondition(native.document?.sourceHash == String(repeating: "a", count: 64))
        native.detect(settings: settings)
        spin { !native.job.busy }
        native.reviewed = true
        let nativeCopy = dir.appendingPathComponent("native-copy.docx")
        native.export(to: nativeCopy, word: false, settings: settings)
        spin { !native.job.busy }
        precondition((try! String(contentsOf: nativeCopy)) == "whole_file")
        native.export(to: source, word: false, settings: settings)
        precondition(native.error != nil && (try! String(contentsOf: source)) == "original")
        native.export(to: dir.appendingPathComponent("wrong.txt"), word: false, settings: settings)
        precondition(native.error != nil && !native.job.busy)
        print("PASS: исходный формат — хеш, полный экспорт вместо предпросмотра, защита оригинала и расширения")

        // A cancelled, back-pressured stdin writer must not crash the app or
        // deliver its late result into the next request.
        let job = DocumentJob()
        var gotCancelledReply = false
        job.run(["action":"answer", "question":String(repeating:"x", count:800_000)], settings:settings) { _, _ in gotCancelledReply = true }
        job.cancel()
        var gotNewReply = false
        job.run(["action":"answer", "question":"new"], settings:settings) { reply, error in
            precondition(error == nil && reply?.text == "new"); gotNewReply = true
        }
        spin { gotNewReply }
        precondition(!gotCancelledReply)
        let attachments = DocumentWorkspace()
        attachments.read([source, source], settings: settings)
        spin { !attachments.job.busy }
        precondition(attachments.error == nil && attachments.document?.blocks.count == 2)
        precondition(attachments.document?.characters == 36)
        attachments.reset()
        precondition(attachments.document == nil)
        print("PASS: документы — согласие на экспорт, изменение копии, защита оригинала, большие запросы и отмена, локальная переписка и цитаты")
    }
}
