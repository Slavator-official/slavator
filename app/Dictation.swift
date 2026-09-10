import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// Диктовка в любое текстовое поле.
///
/// Устройство: удержание клавиши включает микрофон, накопленный звук раз в
/// полторы секунды уходит в постоянный питоновский процесс с загруженной
/// моделью, а устоявшаяся часть расшифровки печатается синтезированными
/// нажатиями прямо туда, где стоит курсор.
///
/// Ключевое правило: **напечатанное не переписывается**. Модель уточняет
/// только хвост последней фразы; всё, что перед ним, зафиксировано. Иначе
/// пришлось бы слать Backspace вслепую в чужой редактор.
@Observable
final class Dictation {
    static var assigningHotkey = false

    enum Mode { case raw, tidy }

    enum State: Equatable {
        case off              // выключена в настройках
        case needsAccess      // нет разрешения на управление вводом
        case starting         // поднимается модель
        case idle             // готова
        case listening        // идёт диктовка
        case finishing        // клавишу отпустили, дописываем
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var level: Double = 0
    private(set) var seconds: Double = 0
    /// Что уже напечатано за эту диктовку — для индикатора.
    private(set) var typed = ""
    /// Один раз за сеанс сообщаем, что обработка недоступна.
    private(set) var tidyUnavailableShown = false

    var onBusyChanged: ((Bool) -> Void)?

    private let worker = Worker()
    private let typer = Typer()
    private var recorder: Recorder?
    private var hotkey: Hotkey?
    private var indicator: Indicator?

    private var mode: Mode = .raw
    private var lastText = ""
    /// Уже закрытые паузами фразы — нужны режиму обработки целиком.
    private var spoken = ""
    private var pending = false
    /// Клавишу отпустили, пока предыдущий запрос не вернулся.
    private var finalPending = false
    private var watchdog: Timer?
    private var ticker: Timer?
    private var clock: Timer?
    private var settings = Settings.load()
    /// Громкость до приглушения. nil — не приглушали: выключено в настройках
    /// или устройство громкостью не управляет.
    private var volumeBefore: Float?

    // MARK: жизненный цикл

    func refresh(settings: Settings) {
        self.settings = settings
        guard settings.dictation_enabled else { stopEverything(); state = .off; return }
        // Разрешение могли выдать только что, в Системных настройках. Верить
        // прошлой проверке нельзя: карточка так и висела «нужен доступ»,
        // хотя доступ уже был.
        let allowed = Typer.hasAccess(prompt: false)
        Dictation.logHotkey("доступ к вводу: \(allowed ? "есть" : "нет")")
        guard allowed else {
            stopEverything()
            state = .needsAccess
            return
        }
        if case .needsAccess = state { state = .off }
        startWorker()
        installHotkey()
    }

    private var workerStarted = false

    private func startWorker() {
        guard !workerStarted else { return }
        workerStarted = true
        state = .starting
        worker.start(model: settings.dictation_model,
                     onReady: { [weak self] in
                         DispatchQueue.main.async { self?.state = .idle }
                     },
                     onFail: { [weak self] message in
                         DispatchQueue.main.async { self?.state = .failed(message) }
                     })
    }

    private var installedCombo = ""

    private func installHotkey() {
        // Слежение переставляем, когда сочетание сменили: старое иначе
        // осталось бы работать, и диктовка отзывалась бы на обе клавиши.
        let combo = settings.dictation_hotkey + "|" + settings.dictation_tidy_hotkey
        if hotkey != nil, combo == installedCombo { return }
        hotkey?.stop()
        hotkey = Hotkey(dictate: settings.dictation_hotkey,
                        tidy: settings.dictation_tidy_hotkey) { [weak self] down, wantsTidy in
            DispatchQueue.main.async {
                guard let self else { return }
                guard down else { self.end(); return }
                if case .listening = self.state {
                    // Обработку выбирают той же клавишей плюс ⇧, а нажать их
                    // одновременно нельзя: fn всегда успевает первой, и
                    // диктовка начиналась обычной. Пока ничего не напечатано,
                    // разрешаем передумать — обработка всё равно печатает
                    // только в конце, так что терять нечего.
                    if self.typed.isEmpty { self.mode = wantsTidy ? .tidy : .raw }
                } else {
                    self.begin(mode: wantsTidy ? .tidy : .raw)
                }
            }
        }
        if hotkey?.start() != true {
            state = .needsAccess
            hotkey = nil
            installedCombo = ""
            return
        }
        installedCombo = combo
    }

    private func stopEverything() {
        hotkey?.stop(); hotkey = nil; installedCombo = ""
        worker.stop()
        workerStarted = false
        recorder?.stop(); recorder = nil
        indicator?.hide(); indicator = nil
    }

    /// Разрешение спрашиваем в момент первой диктовки, а не при установке:
    /// macOS называет его «управление компьютером», и просить такое авансом —
    /// верный способ получить отказ.
    func requestAccess() {
        _ = Typer.hasAccess(prompt: true)
    }

    // MARK: диктовка

    private func begin(mode: Mode) {
        guard case .idle = state else { return }
        // Греем прямо сейчас: модель поднимается секунды, и человек как раз
        // эти секунды говорит. К концу фразы она уже в памяти, а ждать её
        // с готовым текстом на руках — та самая заминка, из-за которой
        // обработка выглядела сломанной.
        if mode == .tidy { worker.warm() }
        self.mode = mode
        lastText = ""; typed = ""; spoken = ""; seconds = 0
        state = .listening
        onBusyChanged?(true)

        let rec = Recorder()
        guard rec.start(onLevel: { [weak self] value in
            DispatchQueue.main.async { self?.level = value }
        }) else {
            state = .failed("Микрофон недоступен")
            onBusyChanged?(false)
            return
        }
        recorder = rec

        duck()
        indicator = indicator ?? Indicator()
        indicator?.show(self)

        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.seconds += 0.1
        }
        // Сырой режим печатает на ходу; режим обработки молчит до конца —
        // причесать уже напечатанное нельзя, не стирая его.
        if mode == .raw {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.poll(final: false)
            }
        }
    }

    private func end() {
        guard case .listening = state else { return }
        unduck()
        ticker?.invalidate(); ticker = nil
        clock?.invalidate(); clock = nil
        state = .finishing
        level = 0
        recorder?.stop()
        // Сторож на случай, если процесс распознавания промолчит: висеть
        // с плашкой «Дописываю…» бесконечно нельзя.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, case .finishing = self.state else { return }
            self.pending = false
            self.finalPending = false
            self.state = .failed("Распознавание не ответило")
            self.onBusyChanged?(false)
            self.indicator?.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.state = .idle }
        }
        poll(final: true)
    }

    private func poll(final: Bool) {
        // Запрос уже в полёте. Раньше здесь просто выходили, и если клавишу
        // отпускали именно в этот момент, финальный запрос терялся: диктовка
        // навсегда застревала на «Дописываю…», а текст оставался ненапечатанным.
        // Теперь запоминаем долг и отдаём его, как только ответ придёт.
        if pending {
            if final { finalPending = true }
            return
        }
        guard let rec = recorder else {
            if final { finish() }
            return
        }
        // Тишину не распознаём. Это первый рубеж против выдумок: на пустом
        // звуке Whisper уверенно печатает титры фильмов, которых никто не
        // произносил. Второй рубеж — фильтр в самом рабочем процессе.
        guard rec.heardSpeech else {
            rec.reset()
            if final { finish(raw: spoken) }
            return
        }
        guard let wav = rec.snapshot() else {
            if final { finish(raw: spoken) }
            return
        }
        pending = true
        worker.transcribe(path: wav) { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending = false
                if final {
                    self.commit(text)
                    self.finish(raw: self.spoken + text)
                    return
                }

                // Пауза в речи закрывает фразу: дописываем её целиком и
                // начинаем запись заново. Это чинит сразу две беды —
                // перераспознавание всей записи (чем дольше говоришь, тем
                // медленнее) и накопление правок в уже напечатанном.
                if !text.isEmpty, rec.silentTail() > 1.1 {
                    self.commit(text + " ")
                    self.spoken += text + " "
                    rec.reset()
                    self.typed = ""
                    self.lastText = ""
                } else {
                    // Внутри фразы фиксируем только устоявшуюся часть.
                    self.commit(Self.stablePrefix(self.lastText, text))
                    self.lastText = text
                }
                if self.finalPending {
                    self.finalPending = false
                    self.poll(final: true)
                }
            }
        }
    }

    /// Общее начало двух расшифровок, обрезанное по границе слова.
    static func stablePrefix(_ a: String, _ b: String) -> String {
        if a.isEmpty { return "" }
        let x = Array(a), y = Array(b)
        var i = 0
        while i < x.count && i < y.count && x[i] == y[i] { i += 1 }
        var prefix = String(x[0..<i])
        if i < y.count, let space = prefix.lastIndex(of: " ") {
            prefix = String(prefix[prefix.startIndex...space])
        }
        return prefix
    }

    /// Допечатать то, чего ещё нет в поле.
    ///
    /// Сравнения «начинается ровно с напечатанного» здесь БЫТЬ НЕ ДОЛЖНО:
    /// получив продолжение фразы, модель правит знаки в её начале, совпадение
    /// ломается — и диктовка замолкала навсегда. Напечатанное всё равно
    /// неприкосновенно, поэтому просто дописываем хвост.
    private func commit(_ target: String) {
        guard mode == .raw, target.count > typed.count else { return }
        let delta = String(target.dropFirst(typed.count))
        typer.type(delta)
        typed = target
    }

    /// Приглушить системный звук на время диктовки.
    ///
    /// Тысячная доля прежней громкости — на слух тишина. Ровно нуля всё же
    /// не ставим: у части устройств ноль включает системный «без звука» со
    /// своим значком и перечёркнутым динамиком, а это уже не приглушение на
    /// секунду, а выключенный звук, который человек пойдёт чинить руками.
    ///
    /// Запоминаем то, что было ровно перед нажатием: вернуть надо своё
    /// значение, а не то, что система считает обычным.
    private func duck() {
        guard settings.dictation_duck, volumeBefore == nil,
              let current = OutputVolume.read(), current > 0.05 else { return }
        guard OutputVolume.set(current * 0.001) else { return }
        volumeBefore = current
    }

    private func unduck() {
        guard let before = volumeBefore else { return }
        volumeBefore = nil
        OutputVolume.set(before)
    }

    private func finish(raw: String = "") {
        recorder = nil
        if mode == .tidy, !raw.isEmpty {
            worker.tidy(text: raw, level: settings.dictation_level) { [weak self] text, ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.typer.type(text)
                    self.typed = text
                    if !ok && !self.tidyUnavailableShown {
                        self.tidyUnavailableShown = true
                        self.warnNoTidy()
                    }
                    self.done()
                }
            }
        } else {
            done()
        }
    }

    private func done() {
        watchdog?.invalidate(); watchdog = nil
        finalPending = false
        state = .idle
        level = 0
        onBusyChanged?(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if case .idle = self?.state { self?.indicator?.hide() }
        }
    }

    private func warnNoTidy() {
        let box = NSAlert()
        box.messageText = "Обработка недоступна"
        box.informativeText = "Языковая модель не отвечает, поэтому вставлен текст как есть, "
            + "без чистки. Расшифровка от этого не страдает.\n\n"
            + "Проверьте, запущена ли Ollama."
        box.addButton(withTitle: "Понятно")
        box.runModal()
    }
}

// MARK: - Постоянный процесс распознавания

/// Модель грузится секунды, поэтому процесс живёт всё время работы программы.
private final class Worker {
    private var task: Process?
    private var input: FileHandle?
    private var replies: [Int: (String, Bool) -> Void] = [:]
    private var nextID = 1
    private let lock = NSLock()
    private var buffer = Data()

    func start(model: String, onReady: @escaping () -> Void,
               onFail: @escaping (String) -> Void) {
        guard task == nil else { return }
        let script = Paths.core.deletingLastPathComponent().appending(path: "dictation_worker.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            onFail("Не найден dictation_worker.py"); return
        }

        let process = Process()
        process.executableURL = Paths.venvPython
        // -B и PYTHONDONTWRITEBYTECODE обязательны: ядро лежит ВНУТРИ
        // подписанного бандла, и Python, импортируя оттуда модуль, кладёт
        // рядом __pycache__. Это ломает подпись приложения, а вместе с ней
        // слетают выданные разрешения — микрофон и управление вводом.
        process.arguments = ["-B", script.path]
        var env = AppConfiguration.environment()
        env["SLAVATOR_DICTATION_MODEL"] = model
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env

        let toWorker = Pipe(), fromWorker = Pipe()
        process.standardInput = toWorker
        process.standardOutput = fromWorker
        // Непрочитанный stderr заполнял pipe и останавливал worker.
        process.standardError = FileHandle.standardError

        fromWorker.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.buffer.append(chunk)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                if raw["ready"] as? Bool == true { onReady(); continue }
                if let error = raw["error"] as? String, raw["id"] == nil {
                    onFail(error); continue
                }
                guard let id = raw["id"] as? Int else { continue }
                self.lock.lock()
                let reply = self.replies.removeValue(forKey: id)
                self.lock.unlock()
                reply?(raw["text"] as? String ?? "", raw["ok"] as? Bool ?? true)
            }
        }

        do {
            try process.run()
            task = process
            input = toWorker.fileHandleForWriting
        } catch {
            onFail(error.localizedDescription)
        }
    }

    func stop() {
        send(["cmd": "quit"], reply: nil)
        task?.terminate(); task = nil; input = nil
    }

    func transcribe(path: URL, done: @escaping (String) -> Void) {
        send(["cmd": "transcribe", "path": path.path]) { text, _ in done(text) }
    }

    /// Поднять языковую модель в память, не дожидаясь ответа.
    func warm() {
        send(["cmd": "warm"], reply: nil)
    }

    func tidy(text: String, level: String, done: @escaping (String, Bool) -> Void) {
        send(["cmd": "tidy", "text": text, "level": level], reply: done)
    }

    private func send(_ command: [String: Any], reply: ((String, Bool) -> Void)?) {
        guard let input else { reply?("", false); return }
        lock.lock()
        let id = nextID; nextID += 1
        if let reply { replies[id] = reply }
        lock.unlock()

        var payload = command
        payload["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            reply?("", false); return
        }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { reply?("", false) }
    }
}

// MARK: - Запись микрофона

/// Пишет микрофон в память и по требованию отдаёт готовый WAV.
private final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Int16] = []
    /// Сколько отсчётов ушло в последний снимок: ровно их и забываем, когда
    /// фраза закрыта. Всё, что записалось позже, ещё не напечатано.
    private var taken = 0
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var file: URL?
    /// Когда микрофон последний раз слышал речь. По этому определяется пауза,
    /// а пауза закрывает фразу.
    private var lastLoud = Date()
    /// Была ли речь после последнего сброса. На тишине Whisper выдумывает
    /// титры фильмов, поэтому отправлять её на распознавание нельзя.
    private var heard = false

    private static let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start(onLevel: @escaping (Double) -> Void) -> Bool {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0 else { return false }
        converter = AVAudioConverter(from: source, to: Self.target)

        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = Self.target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity)
            else { return }
            var supplied = false
            var failure: NSError?
            converter.convert(to: out, error: &failure) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard failure == nil, out.frameLength > 0,
                  let channel = out.int16ChannelData?[0] else { return }

            var peak = 0
            var slice: [Int16] = []
            slice.reserveCapacity(Int(out.frameLength))
            for i in 0..<Int(out.frameLength) {
                slice.append(channel[i])
                peak = max(peak, abs(Int(channel[i])))
            }
            self.lock.lock()
            self.samples.append(contentsOf: slice)
            // Порог низкий: шёпот и тихая речь паузой считаться не должны.
            if peak > 500 { self.lastLoud = Date(); self.heard = true }
            self.lock.unlock()
            onLevel(Double(peak) / 32768.0)
        }

        do { try engine.start() } catch { return false }
        return true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Звучала ли речь с начала текущей фразы.
    var heardSpeech: Bool {
        lock.lock(); let value = heard; lock.unlock()
        return value
    }

    /// Сколько времени прошло с последнего звука.
    func silentTail() -> TimeInterval {
        lock.lock(); let mark = lastLoud; lock.unlock()
        return Date().timeIntervalSince(mark)
    }

    /// Начать фразу заново: прошлая уже напечатана целиком.
    ///
    /// Выбрасываем ровно то, что ушло в снимок, а не всё подряд. Распознавание
    /// занимает доли секунды, и человек в это время продолжает говорить —
    /// прежний сброс стирал эти слова вместе с уже напечатанными, и фраза
    /// теряла начало. Со стороны это выглядело как «иногда обрезает».
    func reset() {
        lock.lock()
        // Перед срезом оставляем тишину — но только настоящую тишину.
        //
        // Заход, начинающийся ровно на звуке, стоил распознавателю первого
        // слова. Запас вслепую стоил дороже: если в него попадал хвост
        // предыдущей фразы, она распознавалась второй раз и «Привет»
        // печатался дважды. Поэтому отступаем от среза назад, пока идёт
        // молчание, и останавливаемся на первом же звуке.
        if taken > 0, taken <= samples.count {
            let limit = max(0, taken - 5600)          // не дальше 0,35 с
            var cut = taken
            while cut > limit, abs(Int(samples[cut - 1])) <= 500 { cut -= 1 }
            samples.removeFirst(cut)
        } else {
            samples.removeAll(keepingCapacity: true)
        }
        taken = 0
        lastLoud = Date()
        // Хвост мог остаться со речью — тогда фраза уже началась.
        heard = samples.contains { abs(Int($0)) > 500 }
        lock.unlock()
    }

    /// Полный WAV со всем, что записано на этот момент.
    func snapshot() -> URL? {
        lock.lock(); let data = samples; taken = data.count; lock.unlock()
        guard data.count > 1600 else { return nil }        // меньше 0,1 с — нечего слать

        let url = file ?? FileManager.default.temporaryDirectory
            .appending(path: "slavator-dictation-\(UUID().uuidString).wav")
        file = url

        var wav = Data()
        let bytes = data.count * 2
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(le32(UInt32(36 + bytes)))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        wav.append(le32(16)); wav.append(le16(1)); wav.append(le16(1))
        wav.append(le32(16000)); wav.append(le32(32000))
        wav.append(le16(2)); wav.append(le16(16))
        wav.append("data".data(using: .ascii)!)
        wav.append(le32(UInt32(bytes)))
        data.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }

        do { try wav.write(to: url) } catch { return nil }
        return url
    }
}

// MARK: - Синтез ввода

/// Печатает текст туда, где стоит курсор.
private final class Typer {
    static func hasAccess(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Порциями: за одно событие система принимает ограниченную строку.
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(16)
            rest = rest.dropFirst(piece.count)
            let utf16 = Array(String(piece).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            utf16.withUnsafeBufferPointer { pointer in
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: pointer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: pointer.baseAddress)
            }
            // Клавишу диктовки человек всё это время держит, и её флаг
            // уезжал вместе с буквой. Одни программы такое проглатывали,
            // другие — нет: в браузере текст появлялся, в приложениях на
            // Electron исчезал молча. Событию модификаторы не нужны.
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1200)
        }
    }
}

// MARK: - Горячая клавиша

/// Сочетание модификаторов, которое нужно удерживать.
///
/// Только модификаторы: обычную клавишу удерживать нельзя — она печаталась бы
/// в то же поле, куда потом идёт надиктованное.
///
/// Сторона (левый/правый) сохраняется только у одиночной клавиши: правый ⌥
/// сам по себе почти не нажимают, в этом и был смысл значения по умолчанию.
/// У сочетания из двух и более сторона не важна — держать ⌘⌥ левой рукой или
/// правой человек решает по месту, и запоминать за него не надо.
enum HotCombo {
    /// Маски отдельных клавиш. Их различает только CGEvent: NSEvent отдаёт
    /// общие флаги, по которым левый ⌥ не отличить от правого.
    private static let sided: [(token: String, bit: UInt64, sign: String, side: String)] = [
        ("lctrl",  0x0000_0001, "⌃", "левый"),
        ("rctrl",  0x0000_2000, "⌃", "правый"),
        ("lshift", 0x0000_0002, "⇧", "левый"),
        ("rshift", 0x0000_0004, "⇧", "правый"),
        ("lcmd",   0x0000_0008, "⌘", "левый"),
        ("rcmd",   0x0000_0010, "⌘", "правый"),
        ("lopt",   0x0000_0020, "⌥", "левый"),
        ("ropt",   0x0000_0040, "⌥", "правый"),
    ]

    /// Те же клавиши, когда сторона не важна. Порядок — как на клавиатуре.
    ///
    /// fn стоит особняком: стороны у неё нет, и системная диктовка Apple
    /// висит на ней же. Мы её всё равно разрешаем — человек вправе занять
    /// её собой, раз системную диктовку не использует.
    private static let plain: [(token: String, mask: CGEventFlags, sign: String)] = [
        ("fn", .maskSecondaryFn, "fn"),
        ("ctrl", .maskControl, "⌃"), ("opt", .maskAlternate, "⌥"),
        ("shift", .maskShift, "⇧"), ("cmd", .maskCommand, "⌘"),
    ]

    static let allBits: UInt64 = sided.reduce(0) { $0 | $1.bit }

    /// Во что превратить нажатое: одна клавиша — со стороной, несколько — без.
    static func tokens(from raw: UInt64) -> String {
        let held = sided.filter { raw & $0.bit != 0 }
        if held.isEmpty { return "" }
        if held.count == 1 { return held[0].token }
        return plain.filter { item in held.contains { $0.sign == item.sign } }
                    .map(\.token).joined(separator: "+")
    }

    /// Подпись для человека: «правый ⌥», «⌥⇧».
    ///
    /// Сторону называем только у одиночной клавиши: в сочетании она и так не
    /// проверяется, а «правый ⌥ и любой ⇧» — подпись, которую не прочесть
    /// с одного взгляда.
    static func label(_ combo: String) -> String {
        let parts = combo.split(separator: "+").map(String.init)
        if parts.count == 1, let one = sided.first(where: { $0.token == parts[0] }) {
            return "\(one.side) \(one.sign)"
        }
        let signs = plain.compactMap { item -> String? in
            let mine = parts.contains(item.token)
                || sided.contains { $0.sign == item.sign && parts.contains($0.token) }
            return mine ? item.sign : nil
        }.joined()
        return signs.isEmpty ? "не задано" : signs
    }

    /// Сочетание по кодам физических клавиш: их сообщает NSEvent, когда
    /// меняются модификаторы, и по ним сторона видна без лишних догадок.
    static func tokens(fromKeyCodes codes: Set<UInt16>) -> String {
        let byCode: [UInt16: String] = [
            59: "lctrl", 62: "rctrl", 56: "lshift", 60: "rshift",
            55: "lcmd",  54: "rcmd",  58: "lopt",   61: "ropt",
            63: "fn",
        ]
        let held = codes.compactMap { byCode[$0] }
        if held.isEmpty { return "" }
        if held.count == 1 { return held[0] }
        // В сочетании сторона не проверяется — обобщаем до знака клавиши,
        // а порядок берём с клавиатуры, чтобы подпись не прыгала.
        return plain.filter { item in
            held.contains(item.token)
                || sided.contains { $0.token != item.token && held.contains($0.token)
                                    && $0.sign == item.sign }
        }.map(\.token).joined(separator: "+")
    }

    /// Держат ли сейчас всё, что нужно. Лишние модификаторы не мешают: ими
    /// как раз переключается обработка.
    static func held(_ combo: String, flags: CGEventFlags) -> Bool {
        let parts = combo.split(separator: "+").map(String.init)
        if parts.isEmpty { return false }
        for token in parts {
            if let one = sided.first(where: { $0.token == token }) {
                if flags.rawValue & one.bit == 0 { return false }
            } else if let any = plain.first(where: { $0.token == token }) {
                if !flags.contains(any.mask) { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Занят ли ⇧ самим сочетанием.
    static func usesShift(_ combo: String) -> Bool {
        combo.split(separator: "+").contains { $0.hasSuffix("shift") }
    }
}

/// Следит за удержанием выбранного сочетания. Fn и двойной Control занимает
/// системная диктовка Apple, поэтому по умолчанию взят правый ⌥: в одиночку
/// его почти не жмут.
private final class Hotkey {
    private var tap: CFMachPort?
    private var loop: CFRunLoopSource?
    private let dictate: String
    private let tidy: String
    private let onChange: (Bool, Bool) -> Void
    private var down = false
    private var tidyNow = false

    init(dictate: String, tidy: String, onChange: @escaping (Bool, Bool) -> Void) {
        self.dictate = dictate
        self.tidy = tidy
        self.onChange = onChange
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, _, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
                owner.handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else { return false }

        tap = port
        loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loop, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), loop, .commonModes) }
        tap = nil; loop = nil
    }

    private func handle(_ event: CGEvent) {
        guard !Dictation.assigningHotkey else { return }
        // Код клавиши не смотрим: у сочетания их несколько, и важно состояние
        // целиком, а не то, какая из них шевельнулась последней.
        //
        // Обработку проверяем первой: её сочетание обычно содержит в себе
        // сочетание диктовки (⌥ и ⌥⇧), и при обратном порядке до неё бы
        // никогда не дошло.
        let wantsTidy = HotCombo.held(self.tidy, flags: event.flags)
        let pressed = wantsTidy || HotCombo.held(dictate, flags: event.flags)
        if pressed == down {
            // Клавишу держат, но набор модификаторов изменился: добавили ⇧
            // к уже нажатой fn. Это выбор обработки, и о нём надо сказать.
            if down, wantsTidy != tidyNow {
                tidyNow = wantsTidy
                onChange(true, wantsTidy)
            }
            return
        }
        down = pressed
        tidyNow = wantsTidy
        onChange(pressed, wantsTidy)
    }
}

// MARK: - Плашка поверх окон

/// Показывает, что микрофон слышит и что уже напечатано.
private final class Indicator {
    private var panel: NSPanel?

    func show(_ dictation: Dictation) {
        if panel == nil {
            let view = NSHostingView(rootView: IndicatorView(dictation: dictation))
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 46),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.contentView = view
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .statusBar
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = window
        }
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.minY + 82))
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct IndicatorView: View {
    @Bindable var dictation: Dictation

    private var label: String {
        switch dictation.state {
        case .listening:  return "Слушаю"
        case .finishing:  return "Дописываю…"
        case .idle:       return "Готово"
        default:          return "Диктовка"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(dictation.state == .listening ? Color(hex: 0xE0705F) : Color(hex: 0x19C37D))
                .frame(width: 9, height: 9)
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: 0x5590FF))
                        .frame(width: 3, height: barHeight(i))
                }
            }
            .frame(height: 17)
            Text(label).font(.system(size: 13, weight: .medium))
            if dictation.state == .listening {
                Text(String(format: "%d:%02d", Int(dictation.seconds) / 60, Int(dictation.seconds) % 60))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 23)
                .fill(Color(hex: 0x0C1826))
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color(hex: 0x1E3350), lineWidth: 1))
        )
        .foregroundStyle(Color(hex: 0xF2F6FC))
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base = dictation.level * 17
        let wobble = [0.55, 0.9, 1.0, 0.75, 0.95, 0.6][index % 6]
        return max(3, min(17, base * wobble + 3))
    }
}

extension Color {
    init(hex value: UInt32) {
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Журнал назначения клавиши

extension Dictation {
    /// Короткая запись о том, что происходит при назначении сочетания.
    ///
    /// Заведена не от любви к логам: поломку записи нельзя было увидеть со
    /// стороны — кнопка молчала одинаково и когда события не приходят, и
    /// когда приходят, но не опознаются.
    static func logHotkey(_ line: String) {
        let dir = Paths.support.appending(path: "logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "hotkey.log")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        guard let data = "\(stamp)  \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}
