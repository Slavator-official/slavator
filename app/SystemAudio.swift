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

    private(set) var format: AVAudioFormat?
    private(set) var framesSeen = 0

    /// Вызывается на очереди захвата для каждого пришедшего блока.
    /// Второй аргумент - системное время первого кадра в блоке: по нему
    /// дорожка выравнивается с микрофонной.
    private var onAudio: ((AVAudioPCMBuffer, UInt64) -> Void)?

    enum TapError: LocalizedError {
        case noOutputDevice
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case formatUnavailable
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                return "Не найдено устройство вывода звука."
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

        let outputUID = try defaultOutputUID()

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

        // Формат читаем у самого отвода: он повторяет формат вывода и меняется
        // от машины к машине — 44.1 или 48 кГц, моно или стерео.
        guard let tapFormat = try? streamFormat(of: tapID) else {
            cleanup(); throw TapError.formatUnavailable
        }
        format = tapFormat

        // Агрегатное устройство — способ читать отвод как обычный вход.
        let uid = "ru.slavator.tap.\(description.uuid.uuidString)"
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Славатор",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            cleanup(); throw TapError.aggregateFailed(status)
        }

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

    private func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != 0
        else { throw TapError.noOutputDevice }

        address.mSelector = kAudioDevicePropertyDeviceUID
        // Core Audio кладёт сюда ссылку на строку, а не саму строку. Переменная
        // типа CFString заставляла Swift отдавать адрес готового объекта под
        // запись — компилятор об этом предупреждал, а поведение оставалось
        // неопределённым. Unmanaged описывает ровно то, что происходит на деле,
        // и takeRetainedValue снимает владение, которое Core Audio передаёт нам.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr,
              let value = uid?.takeRetainedValue()
        else { throw TapError.noOutputDevice }
        return value as String
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
