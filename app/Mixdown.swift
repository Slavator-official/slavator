import AVFoundation

/// Сведение дорожек живой записи в один файл.
///
/// Запись звонка идёт двумя дорожками: звук компьютера (в нём собеседники) и
/// микрофон (в нём вы). Раньше обе так и уходили в обработку — и это стоило
/// двух полных проходов распознавания, то есть двойного времени на встречу,
/// а в папке оставалось два файла, из которых человеку было неясно, какой
/// «настоящий». Здесь они сводятся в одну дорожку: распознавание работает
/// один раз, а на диск ложится один файл.
///
/// Мешает этому эхо: если звонок слушают через динамики, микрофон ловит
/// собеседников второй раз. Простая сумма даёт их удвоенными, с задержкой —
/// расшифровка на такой записи разваливается. Поэтому перед сведением
/// проверяется, слышит ли микрофон динамики, и если слышит — он приглушается
/// ровно там, где звучит системная дорожка.
enum Mixdown {

    /// Формат обеих дорожек и результата: 16 кГц, моно, 16 бит.
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Окно измерения громкости — 20 мс. Короче нет смысла: слог короче не
    /// бывает, а дрожание уровня начинает управлять приглушением.
    private static let window = 320

    /// Насколько приглушается микрофон там, где звучит системная дорожка.
    /// −18 дБ: эхо уходит под шум, но если вы говорите одновременно с
    /// собеседником, ваши слова остаются различимы.
    private static let duckGain: Float = 0.125

    /// Сколько окон занимает возврат громкости после конца системной речи.
    /// 15 окон — 300 мс: быстрее начинает щёлкать на паузах между словами.
    private static let release = 15

    /// Порог, выше которого считаем, что микрофон слышит динамики.
    /// Речь двух разных людей так не совпадает: 0.4 по огибающим — это уже
    /// одна и та же звуковая волна, пойманная дважды.
    private static let echoThreshold: Float = 0.4

    enum Failure: Error { case unreadable, unwritable }

    /// Свести системную дорожку и микрофон в один файл.
    ///
    /// Возвращает, приглушался ли микрофон — это стоит написать в лог: если
    /// эхо нашлось, значит человек слушает встречу через динамики.
    @discardableResult
    static func combine(system: URL, microphone: URL, into target: URL) throws -> Bool {
        let sys = try envelope(of: system)
        let mic = try envelope(of: microphone)
        let ducking = echoLikely(system: sys, microphone: mic)
        try write(system: system, microphone: microphone,
                  systemEnvelope: sys, into: target, ducking: ducking)
        return ducking
    }

    // MARK: громкость по окнам

    /// Среднеквадратичная громкость каждого 20-миллисекундного окна.
    ///
    /// По ней и ищется эхо, и решается, когда приглушать микрофон. Считается
    /// отдельным проходом: держать в памяти час записи целиком незачем.
    private static func envelope(of url: URL) throws -> [Float] {
        // Читаем в float32: AVAudioFile отдаёт содержимое только так, целочисленный
        // формат чтения он не открывает вовсе. Громкость сразу переводим в шкалу
        // 16 бит, чтобы пороги ниже читались как обычные уровни звука.
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        var result: [Float] = []
        result.reserveCapacity(Int(file.length) / window + 1)

        let chunk = AVAudioFrameCount(window * 100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)
        else { throw Failure.unreadable }

        var carry: Double = 0      // недосчитанная сумма квадратов
        var carried = 0            // сколько отсчётов в ней уже есть
        // Читаем, пока не дошли до конца: чтение ЗА концом файла AVAudioFile
        // не возвращает ноль кадров, а бросает ошибку.
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let samples = buffer.floatChannelData?[0] else { break }

            var index = 0
            while index < count {
                let take = min(window - carried, count - index)
                var sum = carry
                for i in index..<(index + take) {
                    let value = Double(samples[i]) * 32768
                    sum += value * value
                }
                carried += take
                index += take
                if carried == window {
                    result.append(Float((sum / Double(window)).squareRoot()))
                    carry = 0
                    carried = 0
                } else {
                    carry = sum
                }
            }
        }
        if carried > 0 { result.append(Float((carry / Double(carried)).squareRoot())) }
        return result
    }

    /// Слышит ли микрофон то же, что играет в динамиках.
    ///
    /// Считается корреляция громкостей двух дорожек по тем окнам, где
    /// системный звук вообще есть. Своя речь идёт своим ритмом и даёт около
    /// нуля; эхо повторяет чужую громкость почти точно. Небольшой сдвиг —
    /// путь от динамика до микрофона плюс буферы — перебирается лагом.
    private static func echoLikely(system: [Float], microphone: [Float]) -> Bool {
        let level = speechFloor(system)
        var best: Float = 0
        for lag in 0...3 {
            var xs: [Float] = [], ys: [Float] = []
            var index = 0
            while index + lag < min(system.count, microphone.count) {
                if system[index] > level {
                    xs.append(log10(system[index] + 1))
                    ys.append(log10(microphone[index + lag] + 1))
                }
                index += 1
            }
            if xs.count < 50 { continue }
            best = max(best, correlation(xs, ys))
        }
        return best >= echoThreshold
    }

    /// Граница между тишиной и речью: тихие три четверти записи — это фон.
    private static func speechFloor(_ envelope: [Float]) -> Float {
        guard !envelope.isEmpty else { return 150 }
        let sorted = envelope.sorted()
        let quiet = sorted[sorted.count / 4]
        return max(quiet * 4, 150)
    }

    private static func correlation(_ xs: [Float], _ ys: [Float]) -> Float {
        let n = Float(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var cov: Float = 0, vx: Float = 0, vy: Float = 0
        for i in 0..<xs.count {
            let dx = xs[i] - mx, dy = ys[i] - my
            cov += dx * dy; vx += dx * dx; vy += dy * dy
        }
        guard vx > 0, vy > 0 else { return 0 }
        return cov / (vx * vy).squareRoot()
    }

    // MARK: сведение

    private static func write(system: URL, microphone: URL, systemEnvelope: [Float],
                              into target: URL, ducking: Bool) throws {
        guard let sysFile = try? AVAudioFile(forReading: system),
              let micFile = try? AVAudioFile(forReading: microphone)
        else { throw Failure.unreadable }

        try? FileManager.default.removeItem(at: target)
        guard let out = try? AVAudioFile(forWriting: target, settings: format.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true)
        else { throw Failure.unwritable }

        let gains = ducking ? gainCurve(systemEnvelope) : []

        let chunk = AVAudioFrameCount(window * 50)
        guard let sysBuffer = AVAudioPCMBuffer(pcmFormat: sysFile.processingFormat,
                                               frameCapacity: chunk),
              let micBuffer = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat,
                                               frameCapacity: chunk),
              let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let mixed = mixBuffer.int16ChannelData?[0]
        else { throw Failure.unwritable }

        var position = 0     // отсчёт от начала записи
        // Дорожки редко одной длины: микрофон поднимается раньше отвода, и
        // после конца одной из них дописывается то, что осталось во второй.
        while sysFile.framePosition < sysFile.length || micFile.framePosition < micFile.length {
            sysBuffer.frameLength = 0
            micBuffer.frameLength = 0
            if sysFile.framePosition < sysFile.length {
                try sysFile.read(into: sysBuffer, frameCount: chunk)
            }
            if micFile.framePosition < micFile.length {
                try micFile.read(into: micBuffer, frameCount: chunk)
            }
            let count = Int(max(sysBuffer.frameLength, micBuffer.frameLength))
            if count == 0 { break }

            let sys = sysBuffer.floatChannelData?[0]
            let mic = micBuffer.floatChannelData?[0]
            for i in 0..<count {
                let a = (sys != nil && i < Int(sysBuffer.frameLength)) ? sys![i] : 0
                let b = (mic != nil && i < Int(micBuffer.frameLength)) ? mic![i] : 0
                // Приглушение меняется плавно внутри окна: ступенька на
                // границе слышна щелчком и сама попадает в расшифровку.
                let gain = ducking ? gain(at: position + i, in: gains) : 1
                let sum = max(-1, min(1, a + b * gain)) * 32767
                mixed[i] = Int16(sum.rounded())
            }
            mixBuffer.frameLength = AVAudioFrameCount(count)
            try out.write(from: mixBuffer)
            position += count
        }
    }

    /// Коэффициент микрофона для каждого окна: тихо там, где звучит
    /// системная дорожка, и плавный возврат к единице после неё.
    private static func gainCurve(_ envelope: [Float]) -> [Float] {
        let level = speechFloor(envelope)
        var gains = [Float](repeating: 1, count: envelope.count)
        var hold = 0
        for index in 0..<envelope.count {
            if envelope[index] > level {
                hold = release
                gains[index] = duckGain
            } else if hold > 0 {
                hold -= 1
                // Чем дальше от последнего громкого окна, тем ближе к единице.
                let back = Float(release - hold) / Float(release)
                gains[index] = duckGain + (1 - duckGain) * back
            }
        }
        return gains
    }

    /// Коэффициент на конкретном отсчёте — с линейной подтяжкой между окнами.
    private static func gain(at sample: Int, in gains: [Float]) -> Float {
        guard !gains.isEmpty else { return 1 }
        let index = sample / window
        guard index < gains.count else { return gains[gains.count - 1] }
        let next = min(index + 1, gains.count - 1)
        let part = Float(sample % window) / Float(window)
        return gains[index] + (gains[next] - gains[index]) * part
    }
}
