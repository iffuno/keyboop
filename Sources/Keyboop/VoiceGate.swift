import Foundation

/// Атомарное зеркало «идёт ли диктовка» — единственное, что колбэку CGEventTap нужно знать
/// СИНХРОННО, чтобы решить start или stop.
///
/// Зачем (ревью 21.07): раньше `EventTap` звал `VoiceController.begin()/end()/cancel()` ПРЯМО из
/// колбэка. За этими вызовами тянется тяжёлое: teardown аудио-сессии, `playCue` (NSSound), RMS-свёртка
/// по всем сэмплам (замер: 0.85 мс на 60 с речи + ~3.8 МБ аллокаций). Всё это выполнялось внутри
/// обработчика события, а `kCGEventTapDisabledByTimeout` меряется по round-trip «WindowServer →
/// mach-порт → ответ» — то есть такая работа прямо приближает отключение тапа системой, а вместе с
/// ним «ввод не проходит нигде» (инцидент).
///
/// Теперь сами begin/end/cancel уезжают на main через `onMain`, а решение toggle остаётся синхронным
/// и атомарным здесь. Без этого зеркала вернулся бы баг 1-к-8 (09.06): `VoiceController.isActive`
/// выставлялся асинхронно, и быстрый второй тап видел устаревшее состояние — «нажал, ничего, нажал
/// ещё — пошло».
enum VoiceGate {
    private static var lock = os_unfair_lock_s()
    private static var active = false

    static var isActive: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return active
    }

    /// Атомарный флип. Возвращает СТАРОЕ значение — по нему решаем start/stop без гонки.
    @discardableResult static func flip() -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let old = active; active = !old; return old
    }

    static func set(_ v: Bool) {
        os_unfair_lock_lock(&lock); active = v; os_unfair_lock_unlock(&lock)
    }
}
