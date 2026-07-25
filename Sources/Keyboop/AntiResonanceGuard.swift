import Foundation

/// Анти-резонансный предохранитель (circuit breaker) против «быстрого циклического переключения
/// раскладки» — когда раскладка дёргается A→B→A→B десятки раз в секунду.
///
/// ПРИЧИНА (анализ 2026-06-26): авто-конверсия печатает синтетику (Backspace+Unicode) через
/// TextReplacer. Если хоть одно синтетическое событие не опознано как «наше» (маркер
/// `.eventSourceUserData` потерян при posting / гонка снятия `muted` на длинном слове / дребезг
/// детектора на смешанном «кир-префикс+лат-хвост» слове) — оно попадает обратно в buffer.append,
/// меняет currentWord, и maybeLiveFix снова конвертирует → синтетика → … Петля крутится в темпе
/// usleep-пауз (1–2 мс). Защита `word != liveFixLast` хранит ОДНО значение и осцилляцию A→B→A
/// не ловит.
///
/// РЕШЕНИЕ: не debounce (его пробовали в 0.2.25 — сам даёт резонанс/лаг), а детект осцилляции +
/// заморозка. Барьер общий: гасит ВИДИМЫЙ симптом независимо от микропричины, и логирует факт —
/// для диагностики первопричины. Применяем ТОЛЬКО к авто-конверсии (live-fix + boundary-auto);
/// ручной хоткей не трогаем (юзер решает сам, резонировать не может).
final class AntiResonanceGuard {

    /// Окно наблюдения за недавними авто-конверсиями.
    private let window: TimeInterval
    /// Сколько авто-конверсий в окне — это уже «шторм» (человек так быстро осмысленные слова не
    /// конвертирует; live-fix срабатывает не на каждый символ). Запас от ложных срабатываний.
    private let maxFlips: Int
    /// На сколько замораживаем авто-конверсии после детекта резонанса.
    private let freezeFor: TimeInterval

    private var recent: [(produced: String, at: TimeInterval)] = []
    private var frozenUntil: TimeInterval = 0
    private var didLogFreeze = false

    /// Инъектируемые часы (для тестов — desync-харнесс).
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(window: TimeInterval = 0.7, maxFlips: Int = 6, freezeFor: TimeInterval = 2.5) {
        self.window = window
        self.maxFlips = maxFlips
        self.freezeFor = freezeFor
    }

    /// Спросить перед АВТО-конверсией `word` → `produced`. Возвращает true, если конверсия разрешена.
    /// false — резонанс: вызывающий ДОЛЖЕН пропустить конверсию (и желательно сбросить буфер/якорь).
    func allow(word: String, produced: String) -> Bool {
        let now = clock()
        if now < frozenUntil { return false }                 // ещё в заморозке — глушим всё авто

        recent.removeAll { now - $0.at > window }
        // Осцилляция: мы собираемся ПРОИЗВЕСТИ форму, которую только что конвертировали ПРОЧЬ
        // (`word` ∈ недавно произведённые) — классический откат A→B→A. В авто этого быть не должно
        // (liveFixLast/applyConversion гасят легитимный повтор), значит это резонанс.
        let oscillation = recent.contains { $0.produced == word }
        recent.append((produced: produced, at: now))

        if oscillation || recent.count > maxFlips {
            frozenUntil = now + freezeFor
            recent.removeAll()
            if !didLogFreeze {
                didLogFreeze = true
                kbLog("anti-resonance: обнаружено циклическое переключение — авто заморожено на \(freezeFor)с (\(oscillation ? "осцилляция" : "шторм"))")
            }
            return false
        }
        return true
    }

    /// Заморожены ли авто-конверсии прямо сейчас (для быстрой проверки без записи истории).
    var isFrozen: Bool { clock() < frozenUntil }

    /// Сбросить историю (не заморозку — она по таймеру). Зовётся на смене контекста.
    func resetHistory() { recent.removeAll() }

    /// Полный сброс — для тестов.
    func _resetForTests() { recent.removeAll(); frozenUntil = 0; didLogFreeze = false }
}
