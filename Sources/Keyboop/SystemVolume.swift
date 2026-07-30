import Foundation
import CoreAudio

/// Громкость системного вывода: приглушить на время диктовки и вернуть как было.
///
/// Зачем (просьба автора 30.07): человек диктует, а в наушниках играет музыка или идёт видео. Она
/// лезет в микрофон и мешает распознаванию, а главное — мешает самому человеку говорить.
///
/// ⚠️ Почему ГРОМКОСТЬ, а не «поставить медиа на паузу». Пауза делается медиа-клавишей, то есть
/// системным событием, и попадает она в то приложение, которое macOS сейчас считает «главным
/// источником». Когда открыты вкладка с ютубом, музыка и созвон, угадать это невозможно: на паузу
/// встанет не то, что играет, а иногда всё сразу. Громкость же принадлежит устройству вывода и
/// ведёт себя одинаково всегда (разбор с автором 30.07).
enum SystemVolume {

    /// Громкость по умолчанию у текущего устройства вывода, 0…1. nil — устройство её не отдаёт
    /// (так бывает у некоторых USB-ЦАПов и агрегированных устройств: громкость там аппаратная).
    static func current() -> Float? {
        guard let dev = defaultOutputDevice() else { return nil }
        for var addr in volumeAddresses(dev) {
            var vol = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr { return vol }
        }
        return nil
    }

    /// Пишем во ВСЕ доступные адреса: если главного регулятора нет, каналы надо выставить оба, иначе
    /// приглушится только левое ухо.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        var ok = false
        for var addr in volumeAddresses(dev) {
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { continue }
            var v = Float32(max(0, min(1, value)))
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                ok = true
                // Главный регулятор перекрывает каналы — дальше идти незачем.
                if addr.mElement == kAudioObjectPropertyElementMain { break }
            }
        }
        return ok
    }

    // MARK: - Приглушение на время диктовки

    /// Что было до нас и что мы выставили. Второе нужно, чтобы НЕ вернуть громкость, если человек
    /// покрутил её сам, пока диктовал: его последнее слово важнее нашего.
    private static var savedBefore: Float?
    private static var appliedByUs: Float?

    /// Приглушить до `level` (0…1; 0 = полная тишина). Идемпотентно: повторный вызов не затирает
    /// исходное значение, иначе после второй диктовки подряд мы бы «вернули» уже приглушённое.
    static func duck(to level: Float) {
        guard savedBefore == nil else { return }
        guard let now = current() else {
            kbLog("громкость: устройство не отдаёт уровень — приглушать нечего")
            return
        }
        // Уже тише желаемого — не трогаем вовсе, иначе диктовка сделала бы ГРОМЧЕ.
        guard now > level else { return }
        savedBefore = now
        if set(level) {
            appliedByUs = level
            kbLog(String(format: "громкость: %.0f%% → %.0f%% на время диктовки", now * 100, level * 100))
        } else {
            savedBefore = nil
            kbLog("громкость: устройство не даёт её менять — оставляю как есть")
        }
    }

    /// Вернуть как было. Ничего не делает, если мы не приглушали или если громкость трогали руками.
    static func restore() {
        guard let before = savedBefore else { return }
        defer { savedBefore = nil; appliedByUs = nil }
        if let applied = appliedByUs, let now = current(), abs(now - applied) > 0.01 {
            kbLog("громкость: её изменили во время диктовки — не возвращаю, оставляю выбор человека")
            return
        }
        set(before)
        kbLog(String(format: "громкость: вернул %.0f%%", before * 100))
    }

    // MARK: - CoreAudio

    /// Куда писать громкость, по порядку предпочтения: сначала ГЛАВНЫЙ регулятор устройства
    /// (element main), потом левый и правый каналы по отдельности.
    ///
    /// ⚠️ Две ветки нужны, одной не хватает. У встроенных динамиков и большинства наушников главный
    /// регулятор есть, и работать надо через него: правка каналов по отдельности перекашивает баланс,
    /// если у человека он был сдвинут. А у части USB-ЦАПов и у агрегированных устройств главного нет
    /// вовсе, и там единственный путь — каналы. Не сводить к чему-то одному.
    private static func volumeAddresses(_ dev: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        return elements.map {
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeOutput,
                                       mElement: $0)
        }.filter { var a = $0; return AudioObjectHasProperty(dev, &a) }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }
}
