import CoreAudio
import Foundation

/// Громкость системного вывода — чтобы приглушить её на время диктовки.
///
/// Через CoreAudio, а не `osascript -e "set volume"`: диктовка начинается по
/// нажатию клавиши, и запускать ради этого чужой процесс — задержка там, где
/// её слышно. Заодно возвращается ровно то значение, что было, а не
/// округлённое до шага системного ползунка.
///
/// Трогаем ползунок, который человек видит в строке меню, а не громкость
/// приложения: приглушить нужно то, что играет сейчас, чем бы оно ни было.
enum OutputVolume {

    /// Текущая громкость вывода, 0…1. nil — устройство громкостью не
    /// управляет: так ведут себя многие внешние ЦАПы и часть USB-гарнитур.
    static func read() -> Float? {
        guard let device = defaultOutput() else { return nil }
        for element in elements(of: device) {
            var address = volumeAddress(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    /// Поставить громкость. Возвращает, получилось ли: у устройства без
    /// управления громкостью не получится, и тогда приглушать нечего.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = defaultOutput() else { return false }
        var done = false
        for element in elements(of: device) {
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var level = Float32(min(1, max(0, value)))
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &level) == noErr {
                done = true
                // Общий регулятор устройства перекрывает каналы: поставили
                // его — по каналам ходить незачем.
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return done
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Сначала общий регулятор устройства, затем левый и правый каналы:
    /// у части устройств общего нет вовсе, громкость живёт только по каналам.
    private static func elements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }
}
