import AVFoundation
import SwiftUI

/// Захват звука идущей встречи.
///
/// Звук компьютера берётся через Core Audio process tap — профильный API
/// Apple для записи того, что играет на машине. Разрешение на запись экрана
/// не нужно, виртуальные устройства вроде BlackHole ставить не надо.
///
/// Запись идёт сразу в WAV 16 кГц mono — ровно в том формате, который ждёт
/// ядро обработки, так что после остановки файл уходит в обычный пайплайн
/// без единого преобразования.
@Observable
final class LiveCapture: NSObject {

    /// Что писать.
    ///
    /// `.meeting` — звук компьютера И микрофон одновременно, сведённые в один
    /// файл. Только так в записи оказываются все: собеседники приходят из
    /// динамиков, а собственный голос — только с микрофона, в динамики он не
    /// возвращается. Записывать что-то одно значит потерять половину встречи.
    enum Source: String { case meeting = "sys", microphone = "mic" }

    private(set) var isRecording = false
    private(set) var seconds: Double = 0
    private(set) var level: Double = 0          // 0…1, для индикатора
    private(set) var failure: String?
    private(set) var lastFile: URL?

    private let tap = SystemAudioTap()
    private var engine: AVAudioEngine?
    private var ticker: Timer?
    private let queue = DispatchQueue(label: "ru.slavator.capture")

    // Источники пишутся в отдельные файлы и сводятся при остановке. Смешивать
    // на лету нельзя: у микрофона и системного звука разные часы, и кадры
    // приходят вразнобой — свести их построчно можно только имея оба целиком.
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var systemURL: URL?
    private var micURL: URL?
    /// Куда ляжет готовая запись. Известно с самого начала: в режиме
    /// микрофона туда пишут сразу, в режиме встречи — после сведения.
    private var result: URL?
    /// Сколько кадров реально пришло с системного захвата. Разрешение может
    /// быть выдано, а поток при этом молчать — тогда честнее сказать об этом,
    /// чем отдать в обработку пустой файл.
    private var systemFrames = 0

    /// Запись заведена: защищает от повторного запуска, пока идёт ожидание
    /// первого кадра и `isRecording` ещё не выставлен.
    private var active = false

    /// Общее начало записи в системных часах.
    ///
    /// Дорожки заводятся не одновременно: микрофон поднимается почти сразу,
    /// а отвод системного звука — только после создания агрегатного
    /// устройства, это сотни миллисекунд. Файл же начинается с первого
    /// пришедшего кадра, поэтому без общей точки отсчёта нулевая секунда у
    /// двух дорожек означает разные моменты, и в стенограмме реплики встают
    /// не в том порядке. Каждый кадр приходит со своей меткой времени, и обе
    /// дорожки выравниваются по этой отметке.
    private var originHost: UInt64 = 0

    /// Перевод системных тиков в секунды.
    private static let tickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Формат, который ждёт ядро: 16 кГц, моно, 16 бит.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    // MARK: запуск

    func start(source: Source, folder: URL) {
        guard !active else { return }
        active = true
        failure = nil
        seconds = 0
        systemFrames = 0
        originHost = 0

        let stamp = DateFormatter()
        // Секунды в имени, а не только минуты: две записи, начатые в одну
        // минуту, складывались в одну семью результатов и затирали друг друга.
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Встреча \(stamp.string(from: Date())).wav"
        let url = folder.appending(path: name)
        result = url
        systemURL = nil
        micURL = nil
        systemConverter = nil
        micConverter = nil

        // Черновики дорожек лежат не рядом с результатом, а у приложения.
        // В папке записей человек должен видеть один файл — свою встречу, а
        // не пару служебных дорожек, из которых непонятно, какая настоящая.
        // Здесь же они переживут падение: файл остаётся на диске и его можно
        // отдать в обработку руками.
        let drafts = Paths.support.appending(path: "capture")
        sweepDrafts(in: drafts)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)

            if source == .meeting {
                let base = url.deletingPathExtension().lastPathComponent
                let sys = drafts.appending(path: "\(base) — компьютер.wav")
                systemFile = try AVAudioFile(forWriting: sys, settings: Self.format.settings,
                                             commonFormat: .pcmFormatInt16, interleaved: true)
                systemURL = sys

                let mic = drafts.appending(path: "\(base) — микрофон.wav")
                micFile = try AVAudioFile(forWriting: mic, settings: Self.format.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
                micURL = mic
                lastFile = url
            } else {
                // Только микрофон — сводить нечего, пишем сразу набело.
                micFile = try AVAudioFile(forWriting: url, settings: Self.format.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
                micURL = url
                lastFile = url
            }
        } catch {
            failure = "Не удалось создать файл записи: \(error.localizedDescription)"
            active = false
            return
        }

        // Отсчёт открываем сразу, до запуска дорожек.
        //
        // Ждать первого кадра со звука компьютера нельзя: отвод поднимается
        // сотни миллисекунд, а прежде, пока агрегат строился на устройстве
        // вывода, на простаивающем выводе кадров не было вовсе. Запись
        // повисла бы до первого звука собеседника. Провалы закрывает
        // выравнивание: пропущенное время дописывается тишиной, и дорожка
        // остаётся привязанной к настоящим часам.
        originHost = mach_absolute_time()

        // Микрофон нужен в обоих режимах: в нём ваш собственный голос.
        startMicrophone()
        guard engine != nil else { active = false; return }
        startTicker()
        if source == .meeting { startSystemAudio() }
    }

    /// Убрать черновики, оставшиеся от прерванных записей.
    ///
    /// В обычной жизни они удаляются сразу после сведения. Остаются только
    /// после падения или выключения посреди встречи — тогда неделя есть,
    /// чтобы забрать их руками, а дальше они просто занимают место.
    private func sweepDrafts(in folder: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let deadline = Date().addingTimeInterval(-7 * 24 * 3600)
        for url in items {
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if stamp < deadline { try? fm.removeItem(at: url) }
        }
    }

    private func startTicker() {
        isRecording = true
        // Считаем по часам, а не сложением шагов: таймер macOS сдвигает
        // срабатывания под нагрузкой, и за четверть часа накапливалось
        // почти полсекунды расхождения с настоящей длиной записи.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.originHost != 0 else { return }
            self.seconds = Double(mach_absolute_time() - self.originHost) * Self.tickSeconds
        }
    }

    // MARK: микрофон

    private func startMicrophone() {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Эхоподавление. Без него запись звонка через динамики непригодна:
        // звук собеседников идёт в файл дважды — из системного захвата и
        // повторно с микрофона, который слышит те же динамики. Сумма двух
        // копий уходит в перегруз, и распознавание на ней разваливается.
        // Режим вычитает из микрофона то, что играет в колонках.
        // Эхоподавление здесь НЕ включается, хотя микрофон и слышит динамики.
        //
        // Проверено замером: setVoiceProcessingEnabled(true) перехватывает
        // маршрутизацию звука и глушит отвод Core Audio — системная дорожка
        // выходила пустой. Одновременно эти два механизма не работают.
        //
        // Эхо убирается дальше по конвейеру: ядро сверяет реплики микрофонной
        // дорожки с системной по времени и тексту и отбрасывает совпавшие.
        // Так собеседник не попадает в стенограмму дважды, а системный звук
        // при этом пишется.

        let sourceFormat = input.outputFormat(forBus: 0)

        micConverter = AVAudioConverter(from: sourceFormat, to: Self.format)
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, when in
            guard let self, let file = self.micFile, let converter = self.micConverter else { return }
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            self.write(buffer, to: file, using: converter, at: host, meterLevel: true)
        }

        do {
            try engine.start()
        } catch {
            failure = "Микрофон недоступен: \(error.localizedDescription)"
            self.engine = nil
        }
    }

    // MARK: звук компьютера

    private func startSystemAudio() {
        do {
            try tap.start { [weak self] buffer, host in
                guard let self, let file = self.systemFile else { return }
                if self.systemConverter == nil
                    || self.systemConverter?.inputFormat != buffer.format {
                    self.systemConverter = AVAudioConverter(from: buffer.format, to: Self.format)
                }
                guard let converter = self.systemConverter else { return }
                self.systemFrames += Int(buffer.frameLength)
                self.write(buffer, to: file, using: converter, at: host, meterLevel: false)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Привести кадр к 16 кГц моно и дописать в указанный файл.
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile,
                       using converter: AVAudioConverter, at host: UInt64,
                       meterLevel: Bool) {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        // До общего начала кадры отбрасываем: иначе дорожки снова разъедутся.
        guard conversionError == nil, out.frameLength > 0, originHost != 0 else { return }

        align(file, to: host)
        try? file.write(from: out)

        // Уровень для индикатора считаем по микрофону: это самый наглядный
        // признак, что запись живая.
        if meterLevel, let channel = out.int16ChannelData?[0] {
            var peak = 0
            for i in 0..<Int(out.frameLength) {
                peak = max(peak, abs(Int(channel[i])))
            }
            let value = Double(peak) / 32768.0
            Task { @MainActor in self.level = value }
        }
    }

    /// Догнать реальное время тишиной.
    ///
    /// Позиция в файле должна отвечать секунде встречи, а не порядку
    /// пришедших кадров. Здесь закрывается и задержка на старте, и расхождение
    /// часов микрофона и звуковой карты: у них разные генераторы, и за час
    /// записи дорожки успевают разъехаться на заметную долю секунды.
    private func align(_ file: AVAudioFile, to host: UInt64) {
        guard originHost != 0 else { return }
        let stamp = host > originHost ? host : mach_absolute_time()
        guard stamp > originHost else { return }

        let elapsed = Double(stamp - originHost) * Self.tickSeconds
        let expected = AVAudioFramePosition(elapsed * Self.format.sampleRate)
        let gap = expected - file.length

        // Порог в 20 мс — чтобы не реагировать на обычное дрожание меток.
        // Верхняя граница защищает от единичной дикой метки: сдвиг больше
        // пяти минут означает ошибку в часах, а не паузу в записи.
        guard gap > 320 else { return }
        writeSilence(min(gap, AVAudioFramePosition(Self.format.sampleRate * 300)), to: file)
    }

    private func writeSilence(_ frames: AVAudioFramePosition, to file: AVAudioFile) {
        let chunk = AVAudioFrameCount(16000)
        guard let pad = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: chunk),
              let data = pad.int16ChannelData?[0]
        else { return }

        var left = frames
        while left > 0 {
            let count = AVAudioFrameCount(min(left, AVAudioFramePosition(chunk)))
            pad.frameLength = count
            memset(data, 0, Int(count) * MemoryLayout<Int16>.size)
            try? file.write(from: pad)
            left -= AVAudioFramePosition(count)
        }
    }

    // MARK: остановка

    @discardableResult
    func stop() -> URL? {
        ticker?.invalidate(); ticker = nil
        isRecording = false
        active = false
        level = 0

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        tap.stop()

        micFile = nil
        systemFile = nil
        micConverter = nil
        systemConverter = nil

        // Дорожки сводятся в одну.
        //
        // Раньше обе уходили в обработку по отдельности: ядро распознавало
        // каждую и склеивало стенограммы по времени. Это стоило двух полных
        // проходов распознавания — на встрече в двадцать минут лишние полчаса
        // ожидания, — и оставляло в папке два файла вместо записи встречи.
        // Теперь склейка происходит здесь, на звуке: одна дорожка, один
        // проход, один файл.
        //
        // Эхо от динамиков (микрофон слышит собеседников второй раз) снимает
        // Mixdown: он сам проверяет, есть ли оно, и приглушает микрофон под
        // системную речь. Если человек в наушниках, приглушения не будет.
        guard let target = result else { return lastFile }

        // Системный захват промолчал: разрешение могло быть выдано уже после
        // запуска программы. Отдавать пустую дорожку в обработку нельзя —
        // основной становится микрофонная, она записала хотя бы вашу часть.
        if let sys = systemURL, systemFrames < 16000 {
            failure = "Звук компьютера не записался: система не отдала ни одного кадра. "
                    + "Если разрешение выдано только что, перезапустите Славатор — "
                    + "macOS применяет его к уже запущенной программе не сразу. "
                    + "Сохранена запись с микрофона."
            try? FileManager.default.removeItem(at: sys)
            systemURL = nil
            promote(micURL, to: target)
            return lastFile
        }

        if let sys = systemURL, let mic = micURL {
            do {
                try Mixdown.combine(system: sys, microphone: mic, into: target)
                try? FileManager.default.removeItem(at: sys)
                try? FileManager.default.removeItem(at: mic)
                systemURL = nil
                micURL = nil
                lastFile = target
            } catch {
                // Сведение не вышло — лучше отдать в обработку звук
                // компьютера, чем не отдать ничего: в нём собеседники.
                failure = "Не удалось свести дорожки: \(error). Сохранён звук компьютера."
                promote(sys, to: target)
                if let mic = micURL { try? FileManager.default.removeItem(at: mic) }
                micURL = nil
                systemURL = nil
            }
        }
        return lastFile
    }

    /// Перенести черновик на место готовой записи.
    private func promote(_ draft: URL?, to target: URL) {
        guard let draft else { lastFile = nil; return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: draft, to: target)
            lastFile = target
        } catch {
            // Перенести не вышло (другой том, права) — отдаём как есть.
            lastFile = draft
        }
        if draft == micURL { micURL = nil }
        if draft == systemURL { systemURL = nil }
    }

    /// Готовая запись встречи — одна дорожка, уже сведённая.
    var recording: URL? { lastFile }
}
