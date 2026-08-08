import CoreAudio
import Foundation

/// УРОВЕНЬ ВХОДА МИКРОФОНА (задача 93, просьба автора 07.08.2026).
///
/// Жалоба: «громкость входа сама убавляется». Разбор 07.08 установил три вещи, и все три важны для
/// того, как это устроено ниже.
///
/// **Первое: это не мы.** Единственная запись громкости в проекте живёт в `SystemVolume` и жёстко
/// прибита к области ВЫХОДА, а приглушение в боевой сборке вообще выключено. Проверено.
///
/// **Второе: у устройства нет своей автоматики.** У RØDE VideoMic GO II системный ползунок И ЕСТЬ
/// его цифровое усиление, 0…24 дБ. У macOS собственной регулировки входа нет вовсе: в справке Apple
/// ползунок описан только как ручная компенсация. «Подавление шума» существует лишь для встроенного
/// микрофона и отсутствует на Apple silicon, а Voice Isolation режет усиление ВНУТРИ своей цепочки
/// обработки, которой мы не пользуемся (у нас AVCaptureSession).
///
/// **Третье, и оно определяет решение: уровень уводит кто-то ОДИН РАЗ и не возвращает.** Главный
/// подозреваемый — Chromium: он двигает ровно это системное свойство и не восстанавливает его при
/// закрытии потока. Раз это не непрерывная автоматика, выставления уровня ПЕРЕД диктовкой
/// достаточно. Спорить в реальном времени не нужно и не надо: перетягивание ползунка с чужой
/// программой это война, в которой нет победителя.
///
/// ⚠️ УРОВЕНЬ НЕ ВОЗВРАЩАЕМ ПОСЛЕ ЗАПИСИ (решение автора 07.08). Это осознанный размен, а не
/// недоделка: вернуть значит опустить обратно ровно ту громкость, из-за которой всё и затевалось.
/// Плата в том, что Keyboop меняет системную настройку насовсем, и об этом честно сказано в
/// интерфейсе рядом с переключателем.
enum MicVolume {

    /// Адреса громкости входа: главный регулятор и, если его нет, отдельные каналы.
    ///
    /// ⚠️ Две ветки нужны ровно по той же причине, что у выхода: у части устройств главного
    /// регулятора нет вовсе, и тогда единственный путь это каналы.
    private static func addresses(_ dev: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        return elements.map {
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeInput,
                                       mElement: $0)
        }.filter { var a = $0; return AudioObjectHasProperty(dev, &a) }
    }

    /// Устройство ВВОДА по умолчанию.
    ///
    /// ⚠️ Берём именно системное умолчание, а НЕ резолвим выбранный в настройках UID. Резолв по UID
    /// на пути старта записи запрещён комментарием в `AudioRecorder`: на Bluetooth он стоил сотни
    /// миллисекунд. Практическое следствие: если человек выбрал в наших настройках не системный
    /// микрофон, уровень мы ему не тронем. Это честнее, чем задерживать старт записи.
    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    /// Текущий уровень входа, 0…1. nil — устройство уровня не отдаёт.
    ///
    /// ⚠️ СТАТУС ПРОВЕРЯЕМ ОБЯЗАТЕЛЬНО. Неудачный `AudioObjectGetPropertyData` ЗАТИРАЕТ переданный
    /// буфер нулём (воспроизведено в разборе 07.08). Код, игнорирующий возврат, решил бы, что
    /// громкость входа равна нулю, и бодро «поднял» бы её на устройстве, которое регулировки не
    /// имеет вовсе.
    static func current() -> Float? {
        guard let dev = defaultInputDevice() else { return nil }
        for var addr in addresses(dev) {
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { return Float(v) }
        }
        return nil
    }

    /// Умеет ли текущее устройство отдавать управление уровнем входа.
    /// У «iPhone Microphone», RØDE Wireless GO II и ZOOM H2essential такого свойства нет вовсе —
    /// строка настройки на них обязана честно гаснуть, а не предлагать неработающее.
    static func supported() -> Bool {
        guard let dev = defaultInputDevice() else { return false }
        for var addr in addresses(dev) {
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue { return true }
        }
        return false
    }

    /// Выставить уровень входа. Возвращает true, только если система подтвердила чтением.
    ///
    /// ⚠️ ПРОВЕРЯЕМ ЧТЕНИЕМ, А НЕ ПО ВОЗВРАТУ ЗАПИСИ. Значение квантуется железом: у RØDE шкала
    /// дискретная, 25 шагов по децибелу, поэтому «поставил 0.9» ляжет на ближайший шаг и точного
    /// совпадения не будет никогда. Допуск 0.03 покрывает шаг (1/24 ≈ 0.042 — берём чуть меньше,
    /// чтобы не проглядеть настоящий промах на устройстве с мелкой шкалой).
    @discardableResult
    static func apply(_ target: Float) -> Bool {
        guard let dev = defaultInputDevice() else { return false }
        let want = Float32(max(0, min(1, target)))
        let before = current()
        var wrote = false
        for var addr in addresses(dev) {
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { continue }
            var v = want
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                wrote = true
                if addr.mElement == kAudioObjectPropertyElementMain { break }   // главный перекрывает каналы
            }
        }
        guard wrote, let now = current() else {
            kbLog("микрофон: устройство не даёт менять уровень входа — оставляю как есть")
            return false
        }
        let ok = abs(now - Float(want)) <= 0.03
        // Форма строки такая же, как у приглушения выхода («громкость: 45% → 30% …»), чтобы в
        // диагностике отзывов обе читались одинаково.
        kbLog(String(format: "микрофон: %.0f%% → %.0f%% перед диктовкой%@",
                     (before ?? 0) * 100, now * 100, ok ? "" : " (система не приняла значение)"))
        return ok
    }

    /// Поднять уровень перед записью, если человек включил это в настройках.
    /// Зовётся ПЕРЕД стартом записи: после старта поздно, кусок речи уже уйдёт с прежним уровнем.
    static func raiseIfEnabled() {
        let s = AppSettings.shared
        guard s.voiceMicGain else { return }
        let target = Float(s.voiceMicGainLevel) / 100
        guard let now = current() else { return }
        // Уже не ниже нужного — не трогаем: лишняя запись свойства это лишний повод для чужой
        // программы «ответить» своей.
        guard now < target - 0.03 else { return }
        apply(target)
    }
}
