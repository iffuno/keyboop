import Foundation

/// Готовность языковых данных. `LayoutData.shared` строит 4 JSON (162k+59k строк) под `swift_once` —
/// замер 143 мс. Раньше прогрев шёл на `.utility`, а под полной загрузкой ядер эта очередь шедулится
/// последней: первое же слово/Enter входило в `LayoutData` ИЗ КОЛБЭКА tap'а и блокировало его на все
/// 143 мс. `kCGEventTapDisabledByTimeout` меряется по round-trip ответа — то есть это прямой путь к
/// «система вырубила перехват, ввод не проходит нигде» (инцидент 21.07).
///
/// Решение: греем на `.userInitiated`, а авто-пути до готовности МОЛЧА пропускаем — клавиша идёт
/// насквозь. «Первое слово не починилось» несопоставимо лучше, чем «весь ввод замер на 143 мс».
enum Warm {
    private static var lock = os_unfair_lock_s()
    private static var ready = false

    static var isReady: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return ready
    }

    static func prime() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LayoutData.shared.isLoaded
            os_unfair_lock_lock(&lock); ready = true; os_unfair_lock_unlock(&lock)
            kbLog("warm: языковые данные готовы")
        }
    }
}
