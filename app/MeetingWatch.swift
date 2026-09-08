import AppKit
import CoreAudio
import Foundation
import UserNotifications

/// Замечает начало встречи и предлагает её записать.
///
/// Признак встречи — чужая программа, которая держит микрофон. Списка «вот
/// это считаем звонками» здесь намеренно нет: у каждой команды свой набор —
/// Zoom, Телемост, Контур.Толк, звонок прямо во вкладке браузера, — и
/// перечислить их все невозможно, а незнакомое приложение молчаливо выпало бы
/// из наблюдения. Кто именно занял микрофон, названо в самом предложении, так
/// что случайное срабатывание на диктофоне видно сразу и стоит одного отказа.
@Observable
final class MeetingWatch {

    /// Кто сейчас держит микрофон. nil — никто, встречи нет.
    private(set) var holder: String?

    /// Нажали «Записать встречу».
    var onRecord: (() -> Void)?
    /// Идёт ли запись прямо сейчас: во время неё предлагать нечего.
    var isRecording: () -> Bool = { false }

    static let category = "ru.slavator.meeting"
    static let action = "ru.slavator.meeting.record"

    private var timer: Timer?
    private var holdingSince: Date?
    /// Кому уже предложили. Пока микрофон занят та же программа, второй раз
    /// не спрашиваем: одно предложение на встречу, иначе это травля.
    private var offered: String?
    private var prompt: MeetingPrompt?
    private var authorized = false
    private var asked = false

    /// Сколько микрофон должен быть занят, прежде чем предлагать запись.
    /// Меньше — и предложение прилетает на каждую проверку связи перед
    /// звонком, когда встречи ещё нет.
    private static let hold: TimeInterval = 8
    private static let period: TimeInterval = 4

    // MARK: наблюдение

    func start() {
        guard timer == nil else { return }
        askPermission()
        // .common — иначе опрос замирает, пока открыто меню или тянут окно.
        let ticker = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        holdingSince = nil
        offered = nil
        holder = nil
        dismissPrompt()
    }

    private func tick() {
        let app = meetingApp()
        let name = app?.localizedName ?? app?.bundleIdentifier

        if name != holder {                     // микрофон сменил владельца
            holder = name
            holdingSince = name == nil ? nil : Date()
            // Микрофон отпустили — встреча кончилась, следующая будет новой.
            if name == nil { offered = nil }
            return
        }
        guard let name, let since = holdingSince,
              Date().timeIntervalSince(since) >= Self.hold,
              offered != name, !isRecording()
        else { return }
        offered = name
        offer(name)
    }

    // MARK: кто держит микрофон

    private func meetingApp() -> NSRunningApplication? {
        for object in processObjects() where running(input: object) {
            guard let app = owner(of: object),
                  // Обычная программа с окном, а не служба. Так из наблюдения
                  // сами собой выпадают Siri, диктовка системы и прочие
                  // фоновые слушатели, которых пришлось бы перечислять руками.
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { continue }
            return app
        }
        return nil
    }

    /// Программа, которой принадлежит процесс со звуком.
    ///
    /// Микрофон на звонке в браузере держит не сам браузер, а его служебный
    /// процесс — Google Chrome Helper. Человеку надо назвать программу, а не
    /// её потроха, поэтому от идентификатора отрезается хвост `.helper`.
    private func owner(of object: AudioObjectID) -> NSRunningApplication? {
        let bundle = bundleID(of: object)
        if let bundle, let cut = bundle.range(of: ".helper", options: .caseInsensitive) {
            let root = String(bundle[bundle.startIndex..<cut.lowerBound])
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: root).first {
                return app
            }
        }
        let owner = pid(of: object)
        return owner > 0 ? NSRunningApplication(processIdentifier: owner) : nil
    }

    // MARK: предложение

    private func offer(_ name: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Кажется, идёт встреча"
        content.body = "Микрофон занял \(name). Записать и расшифровать?"
        content.categoryIdentifier = Self.category
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            // Уведомление не ушло по технической причине — предложить всё
            // равно надо, иначе наблюдение просто молчит и выглядит сломанным.
            DispatchQueue.main.async { self?.showPrompt(name) }
        }
    }

    private func askPermission() {
        // Вне бандла центра уведомлений нет, и обращение к нему валит процесс.
        guard Bundle.main.bundleIdentifier != nil, !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        let record = UNNotificationAction(
            identifier: Self.action, title: "Записать встречу", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [record],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.authorized = granted
                // Отказ человека — это ответ, его уважаем. А вот техническая
                // осечка (у неподписанного приложения такое бывает) не должна
                // выключать возможность целиком: остаётся подсказка окном.
                if !granted, error != nil { self?.authorized = true }
            }
        }
    }

    func recordTapped() {
        dismissPrompt()
        onRecord?()
    }

    private func showPrompt(_ name: String) {
        dismissPrompt()
        prompt = MeetingPrompt(app: name,
                               onRecord: { [weak self] in self?.recordTapped() },
                               onClose: { [weak self] in self?.dismissPrompt() })
        prompt?.show()
    }

    private func dismissPrompt() {
        prompt?.close()
        prompt = nil
    }

    // MARK: Core Audio

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func running(input object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private func pid(of object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return -1 }
        return value
    }

    private func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Core Audio отдаёт сюда ссылку на строку, а не саму строку — как и в
        // SystemAudio с UID устройства.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() as String?, !text.isEmpty
        else { return nil }
        return text
    }
}

/// Запасная подсказка: маленькое окно поверх остальных.
///
/// Нужна там, где системное уведомление не доходит — например, у сборки без
/// сертификата разработчика. Отказ человека от уведомлений сюда не приводит:
/// «нет» означает «нет».
final class MeetingPrompt: NSPanel {

    private let onRecord: () -> Void
    private let onClose: () -> Void
    private var timer: Timer?

    init(app: String, onRecord: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 116),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = body(app: app)
    }

    private func body(app: String) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 116))

        let title = NSTextField(labelWithString: "Кажется, идёт встреча")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 18, y: 68, width: 300, height: 20)

        let detail = NSTextField(labelWithString: "Микрофон занял \(app)")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 18, y: 48, width: 300, height: 18)

        let record = NSButton(title: "Записать", target: self, action: #selector(record))
        record.bezelStyle = .rounded
        record.keyEquivalent = "\r"
        record.frame = NSRect(x: 214, y: 12, width: 108, height: 28)

        let later = NSButton(title: "Не сейчас", target: self, action: #selector(dismiss))
        later.bezelStyle = .rounded
        later.frame = NSRect(x: 112, y: 12, width: 96, height: 28)

        [title, detail, record, later].forEach(root.addSubview)
        return root
    }

    func show() {
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 22,
                                   y: screen.maxY - frame.height - 22))
        }
        orderFrontRegardless()
        // Предложение живёт полминуты: встреча уже идёт, и окно, висящее
        // поверх работы бесконечно, — само по себе помеха.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    @objc private func record() { onRecord() }
    @objc private func dismiss() { onClose() }
}
