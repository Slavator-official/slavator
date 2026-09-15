import AVFoundation
import CoreAudio
import Foundation

/// Захват звука компьютера через Core Audio process tap.
///
/// Это профильный API Apple для записи того, что играет на машине (появился
/// в macOS 14.2). Прежняя реализация тянула ScreenCaptureKit: он умеет
/// звук, но задуман для видео, поэтому приходилось поднимать фиктивный
/// видеопоток 2×2 пикселя и просить разрешение на запись экрана. Работало
/// плохо и просило лишнего.
///
/// Здесь ничего этого нет: нужен только доступ к системному звуку, никаких
/// виртуальных устройств вроде BlackHole ставить не надо.
final class SystemAudioTap {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "ru.slavator.tap", qos: .userInitiated)
    /// Следит, не сменился ли формат, в котором приходят кадры.
    private var formatListener: AudioObjectPropertyListenerBlock?

    /// Частота, на которой работает запись, — своя, а не частота наушников.
    private static let rate: Float64 = 48000

    private(set) var format: AVAudioFormat?
    private(set) var framesSeen = 0

    /// Вызывается на очереди захвата для каждого пришедшего блока.
    /// Второй аргумент - системное время первого кадра в блоке: по нему
    /// дорожка выравнивается с микрофонной.
    private var onAudio: ((AVAudioPCMBuffer, UInt64) -> Void)?

    enum TapError: LocalizedError {
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case formatUnavailable
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapFailed(let code):
                return code == 1852797029   // 'nope' — отказ по правам
                    ? "Нет доступа к системному звуку. Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → «Только запись системного звука» → включите «Славатор»."
                    : "Не удалось подключиться к звуку компьютера (код \(code))."
            case .aggregateFailed(let code):
                return "Не удалось создать аудиоустройство для записи (код \(code))."
            case .formatUnavailable:
                return "Система не сообщила формат звука."
            case .startFailed(let code):
                return "Не удалось запустить запись звука (код \(code))."
            }
        }
    }

    // MARK: запуск

    func start(onAudio: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        self.onAudio = onAudio
        framesSeen = 0

        // Слушаем всё, что звучит, кроме нас самих: иначе в запись попадёт
        // прослушивание образцов голоса из самого приложения.
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [processObjectID()].compactMap { $0 })
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Славатор — запись встречи"

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.tapFailed(status)
        }

        // Агрегатное устройство — способ читать отвод как обычный вход. В нём
        // только сам отвод, без устройства вывода.
        //
        // Раньше устройство вывода входило в агрегат подустройством, и это
        // ломало запись в Bluetooth-наушниках дважды. Во-первых, агрегат жил
        // на частоте наушников, а те, стоит кому-то взять их микрофон,
        // переходят в режим гарнитуры и опускаются с 48 до 16 кГц. Формат же
        // читался один раз на старте: кадры на 16 кГц разбирались как 48,
        // каждый кусок звучал втрое быстрее, а оставшиеся две трети времени
        // выравнивание добивало тишиной. В записи 15.09 это видно по
        // отсчётам: 13,3 мс звука, 26,7 мс нулей, ровно по кругу. Во-вторых,
        // у гарнитуры есть свой вход, и в агрегате он вставал первым
        // потоком, впереди отвода — а запись брала первый.
        //
        // Агрегат из одного отвода живёт на своих часах и своей частоте, а
        // отвод подгоняется к нему компенсацией дрейфа. Замерено: кадры идут
        // и на простаивающем выводе, частота по меткам времени — ровно та,
        // что задана.
        let uid = "ru.slavator.tap.\(description.uuid.uuidString)"
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Славатор",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            cleanup(); throw TapError.aggregateFailed(status)
        }
        // Своя частота — не ждём, какую выберет система. Не вышло — не беда:
        // ниже формат всё равно читается с того, что устройство отдаёт.
        setNominalRate(Self.rate)

        // Формат берём у входного потока агрегата — в нём кадры и приходят.
        // Формат отвода совпадает с ним только пока частоты равны.
        guard let delivered = deliveredFormat() ?? (try? streamFormat(of: tapID)) else {
            cleanup(); throw TapError.formatUnavailable
        }
        format = delivered
        watchFormat()

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, input, inputTime, _, _ in
            self?.receive(input, at: inputTime)
        }
        guard status == noErr, let ioProcID else {
            cleanup(); throw TapError.startFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup(); throw TapError.startFailed(status)
        }
    }

    func stop() {
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        cleanup()
        onAudio = nil
    }

    private func cleanup() {
        if aggregateID != 0, let formatListener {
            var address = Self.nominalRateAddress
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, ioQueue, formatListener)
        }
        formatListener = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = 0
        tapID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
    }

    // MARK: приём звука

    private func receive(_ input: UnsafePointer<AudioBufferList>,
                         at time: UnsafePointer<AudioTimeStamp>) {
        guard let format else { return }
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard let first = list.first, first.mDataByteSize > 0 else { return }

        let frames = AVAudioFrameCount(
            first.mDataByteSize / UInt32(format.streamDescription.pointee.mBytesPerFrame))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            bufferListNoCopy: input)
        else { return }

        // Метка времени первого кадра. Core Audio отдаёт её в тех же
        // системных часах, что и AVAudioEngine на микрофоне, - это и есть
        // общая точка отсчёта для двух дорожек.
        let stamp = time.pointee
        let host = stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0
            ? stamp.mHostTime
            : mach_absolute_time()

        framesSeen += Int(frames)
        onAudio?(buffer, host)
    }

    // MARK: свойства Core Audio

    private static var nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func setNominalRate(_ rate: Float64) {
        var address = Self.nominalRateAddress
        var value = rate
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil,
                                   UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// Формат, в котором агрегат отдаёт кадры: виртуальный формат его
    /// первого входного потока. Поток в агрегате один — сам отвод.
    private func deliveredFormat() -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size)
        else { return nil }
        var streams = [AudioStreamID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &streams) == noErr,
              let stream = streams.first
        else { return nil }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &asbdSize, &asbd) == noErr
        else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Перечитывать формат, если частота агрегата всё же сменилась.
    ///
    /// Частоту мы ставим сами, и меняться ей не с чего. Но формат,
    /// прочитанный один раз на старте, уже подвёл однажды — и ошибка эта
    /// тихая: запись идёт, а в файле ускоренный звук вперемешку с тишиной.
    /// Слушатель срабатывает на той же очереди, что и приём кадров, так
    /// что формат не меняется посреди разбора буфера.
    private func watchFormat() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let fresh = self.deliveredFormat() else { return }
            self.format = fresh
        }
        var address = Self.nominalRateAddress
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, ioQueue, listener) == noErr {
            formatListener = listener
        }
    }

    private func streamFormat(of object: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { throw TapError.formatUnavailable }
        return format
    }

    /// Идентификатор нашего процесса в терминах Core Audio — чтобы исключить
    /// собственный звук приложения из записи.
    private func processObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != AudioObjectID(kAudioObjectUnknown) ? object : nil
    }
}
