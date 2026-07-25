import Foundation

/// Обучение на отмене: если пользователь СРАЗУ откатил нашу авто-конверсию и точь-в-точь
/// восстановил оригинал — мы НЕ заносим слово молча, а показываем баннер-вопрос (в правом верхнем
/// углу) «Добавить в исключения?». Решает пользователь:
///   • «Добавить» → слово в «выученные исключения», больше не трогаем;
///   • «Не надо»  → запоминаем отказ и по этому слову больше НЕ спрашиваем.
///
/// Баннер показываем НЕ по первому откату, а на strikeThreshold-м (порог 3; счётчик копится между
/// сессиями/сменами контекста и затухает) — иначе на каждой случайной отмене он слишком назойлив
/// (просьба автора 2026-06-22/23). Любой откат всё равно кладёт слово в sessionProtected (в этой сессии
/// больше не трогаем); баннер — отдельно, только по достижении порога.
///
/// Два честных жеста отмены, оба требуют ТОЧНЫЙ оригинал → near-zero ложных срабатываний:
///  U1 — ручной ре-флип: авто сделало W→C, юзер хоткеем флипнул C обратно в W (canonical Punto-жест).
///  U2 — стереть наш вывод C целиком и перенабрать оригинал W посимвольно.
/// Cmd+Z (системный undo) НЕ детектируем — мы не видим результат текстовой операции; U1/U2 покрывают
/// реальные жесты. Машинные тесты — Tools/UndoSim.swift (run-undosim.sh).
final class UndoLearner {
    static let shared = UndoLearner()
    private let d = UserDefaults.standard
    private let declinedKey = "undoDeclinedWords"
    private let strikeCountKey = "undoStrikeCount"
    private let strikeTimeKey = "undoStrikeTime"

    /// Окно, в которое после конверсии должен уложиться откат. Позже — это уже не «отмена», а правка.
    private let undoWindow: TimeInterval = 4

    /// Сколько РАЗ одно и то же слово нужно откатить, прежде чем предложить добавить в исключения.
    /// Порог 3 (просьба автора 2026-06-22: на каждый одиночный откат баннер слишком назойлив; копим).
    private let strikeThreshold = 3
    /// Затухание: если слово давно не откатывали — счётчик сбрасываем (случайные отмены не копятся вечно).
    private let strikeDecay: TimeInterval = 30 * 24 * 3600   // 30 дней

    /// Персистентный счётчик откатов по слову (typed-форма, lowercased) + время последнего отката.
    /// Копится МЕЖДУ сессиями (в отличие от sessionProtected); сбрасывается затуханием/обучением.
    private var strikeCount: [String: Int]
    private var strikeTime: [String: Double]

    /// Кандидат на откат: что мы только что авто/лайв-сконвертировали и в какой стадии отмена.
    private struct Candidate {
        let original: String     // что юзер набрал (lowercased), напр. "гифки"
        let converted: String    // что мы вывели на экран (lowercased), напр. "ubarb"
        let createdAt: Date
        var stage: Stage
        enum Stage { case fresh, deleting, retyping }
    }
    private var candidate: Candidate?

    /// Слова (typed-форма), восстановленные в этом контексте набора — не конвертируем повторно сразу
    /// (анти-«драка»). Сбрасывается на смене контекста (клик/навигация/смена окна). Transient, не персист.
    private var sessionProtected: Set<String> = []

    /// Слова, по которым юзер сказал «не добавлять» — больше НЕ спрашиваем (персист).
    private var declined: Set<String>
    /// Слова, по которым баннер-вопрос уже показан и ждёт ответа — не дублируем баннер.
    private var pending: Set<String> = []

    /// Баннер-вопрос «добавить слово в исключения?» (AppDelegate подвязывает). Параметр — слово.
    var onSuggestLearn: ((String) -> Void)?
    /// Тихий тост после подтверждения («запомнил: больше не трогаю …»).
    var onLearned: ((String) -> Void)?

    private init() {
        declined = Set(d.stringArray(forKey: declinedKey) ?? [])
        strikeCount = Self.loadIntDict(strikeCountKey, d)
        strikeTime = Self.loadDoubleDict(strikeTimeKey, d)
    }

    private static func loadIntDict(_ key: String, _ d: UserDefaults) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in (d.dictionary(forKey: key) ?? [:]) { if let n = v as? NSNumber { out[k] = n.intValue } }
        return out
    }
    private static func loadDoubleDict(_ key: String, _ d: UserDefaults) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in (d.dictionary(forKey: key) ?? [:]) { if let n = v as? NSNumber { out[k] = n.doubleValue } }
        return out
    }

    /// Засчитать откат слова. Возвращает true, когда накоплен порог (пора предлагать добавить).
    /// Затухание: давний последний откат → счётчик сбрасываем, начинаем с 1.
    @discardableResult
    private func registerStrike(_ word: String) -> Bool {
        let w = word.lowercased()
        let t = now().timeIntervalSince1970
        if let last = strikeTime[w], t - last > strikeDecay { strikeCount[w] = 0 }
        let c = (strikeCount[w] ?? 0) + 1
        strikeCount[w] = c
        strikeTime[w] = t
        d.set(strikeCount, forKey: strikeCountKey)
        d.set(strikeTime, forKey: strikeTimeKey)
        return c >= strikeThreshold
    }

    private func clearStrikes(_ word: String) {
        let w = word.lowercased()
        strikeCount[w] = nil; strikeTime[w] = nil
        d.set(strikeCount, forKey: strikeCountKey)
        d.set(strikeTime, forKey: strikeTimeKey)
    }

    /// Для машинных тестов.
    func _strikeCount(_ word: String) -> Int { strikeCount[word.lowercased()] ?? 0 }

    /// Тумблер фичи. Читаем ключ напрямую (а не через AppSettings) — чтобы UndoLearner не тянул
    /// ServiceManagement и компилировался в лёгком тест-таргете. Дефолт — ВКЛ (object==nil).
    private var enabled: Bool {
        d.object(forKey: "learnOnUndoEnabled") == nil ? true : d.bool(forKey: "learnOnUndoEnabled")
    }

    // MARK: - Вход от Engine

    /// Слово было авто/лайв-сконвертировано (W→C). Заводим кандидата на откат.
    func noteConversion(original: String, converted: String) {
        guard enabled else { candidate = nil; return }
        let o = original.lowercased(), c = converted.lowercased()
        guard o != c, !o.isEmpty, !c.isEmpty else { candidate = nil; return }
        if ExceptionStore.shared.learned.contains(o) || declined.contains(o) { candidate = nil; return }
        candidate = Candidate(original: o, converted: c, createdAt: now(), stage: .fresh)
    }

    /// Ручная конверсия (U1): юзер хоткеем превратил `from` в `to`. Если это точный откат нашей
    /// недавней авто-конверсии (to == оригинал, from == наш вывод, в окне) — предлагаем добавить.
    @discardableResult
    func noteManualConvert(from: String, to: String) -> String? {
        guard enabled, let cand = liveCandidate() else { return nil }
        let f = from.lowercased(), t = to.lowercased()
        guard f == cand.converted, t == cand.original else { return nil }
        candidate = nil
        sessionProtected.insert(cand.original)
        if registerStrike(cand.original) { suggestLearn(cand.original) }   // баннер только по достижении порога
        return cand.original
    }

    /// Наблюдение за набором (U2). Зовётся из Engine ПОСЛЕ обновления буфера на каждый печатный
    /// символ / Backspace. `current` — buffer.currentWord. Возвращает true, если откат подтверждён.
    @discardableResult
    func observe(current raw: String) -> Bool {
        guard enabled, var cand = liveCandidate() else { return false }
        let cur = raw.lowercased()
        switch cand.stage {
        case .fresh, .deleting:
            if cur.isEmpty {
                cand.stage = .retyping; candidate = cand            // наш вывод стёрт целиком → перенабор
            } else if cand.converted.hasPrefix(cur) && cur.count < cand.converted.count {
                cand.stage = .deleting; candidate = cand            // стирают наш вывод по букве
            } else {
                candidate = nil                                     // продолжили печатать / другое → приняли конверсию
            }
            return false
        case .retyping:
            if cur == cand.original {
                candidate = nil
                sessionProtected.insert(cand.original)
                // Диагностика 23.07 («перестало переключаться»): фиксация отката — главный тихий
                // глушитель авто. Если откаты сыплются БЕЗ реальных действий юзера — в буфер
                // просочилась наша же синтетика (стирание+перенабор выглядит как ручной откат).
                kbLog("undo-learn: откат зафиксирован — слово под session-защитой (len \(cand.original.count))")
                if registerStrike(cand.original) { suggestLearn(cand.original) }   // баннер только по порогу
                return true                                         // точно восстановили оригинал → откат
            } else if cand.original.hasPrefix(cur) {
                return false                                        // ещё строят оригинал (конверсию глушим)
            } else {
                candidate = nil; return false                       // ушли в сторону → не откат
            }
        }
    }

    /// Пока юзер ВОССТАНАВЛИВАЕТ оригинал (current — его префикс) — глушим конверсию (анти-драка).
    func shouldSuppress(current raw: String) -> Bool {
        guard enabled, let cand = liveCandidate(), cand.stage == .retyping else { return false }
        let cur = raw.lowercased()
        return !cur.isEmpty && cand.original.hasPrefix(cur) && cur != cand.original
    }

    func isSessionProtected(_ word: String) -> Bool {
        // НЕ гейтим флагом обучения: «только что тронул вручную → авто не трогает повторно» —
        // базовая корректность (анти-«драка»), работает даже если обучение-на-отмене выключено.
        sessionProtected.contains(word.lowercased())
    }

    /// Защитить слово от НЕМЕДЛЕННОЙ повторной авто-конверсии (любая ручная конверсия/отмена). Юзер
    /// тронул слово сам → следующий пробел не должен авто-конвертнуть его обратно «не туда» (просьба
    /// автора 2026-06-22). Безусловно (не зависит от обучения). Сбрасывается на смене контекста.
    func protect(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        sessionProtected.insert(w)
    }

    /// Смена контекста набора (клик/навигация/смена окна) — кандидат и session-защита неактуальны.
    func resetContext() {
        candidate = nil
        sessionProtected.removeAll()
    }

    // MARK: - Предложение/решение (баннер)

    /// Откат засчитан → предлагаем добавить слово в исключения (если не выучено, не отклонено и
    /// баннер по нему ещё не висит).
    private func suggestLearn(_ word: String) {
        let w = word.lowercased()
        guard enabled else { return }
        if ExceptionStore.shared.learned.contains(w) { return }
        if declined.contains(w) { return }     // сказал «нет» → молчим навсегда
        if pending.contains(w) { return }      // уже спросили, ждём ответа
        pending.insert(w)
        onSuggestLearn?(w)
    }

    /// Пользователь нажал «Добавить в исключения».
    func confirmLearn(_ word: String) {
        let w = word.lowercased()
        pending.remove(w)
        guard !ExceptionStore.shared.learned.contains(w) else { return }
        ExceptionStore.shared.addLearned(w)
        clearStrikes(w)                 // выучено — счётчик откатов больше не нужен
        kbLog("undo-learn: пользователь подтвердил — слово в исключениях (len \(w.count))")
        onLearned?(w)
    }

    /// Пользователь нажал «Не надо» — больше про это слово не спрашиваем.
    func declineLearn(_ word: String) {
        let w = word.lowercased()
        pending.remove(w)
        declined.insert(w)
        d.set(Array(declined), forKey: declinedKey)
        clearStrikes(w)                 // отказ — счётчик не нужен (и так больше не спросим)
        kbLog("undo-learn: пользователь отказал — больше не спрашиваем (len \(w.count))")
    }

    // MARK: - Утилиты

    private func liveCandidate() -> Candidate? {
        guard let c = candidate else { return nil }
        if now().timeIntervalSince(c.createdAt) > undoWindow { candidate = nil; return nil }
        return c
    }

    /// Источник времени — инъектируемый для машинных тестов.
    var nowProvider: () -> Date = { Date() }
    private func now() -> Date { nowProvider() }

    /// Сброс между подтестами (не в проде).
    func _resetForTests() {
        candidate = nil
        sessionProtected.removeAll()
        pending.removeAll()
        declined.removeAll()
        strikeCount.removeAll()
        strikeTime.removeAll()
        d.removeObject(forKey: declinedKey)
        d.removeObject(forKey: strikeCountKey)
        d.removeObject(forKey: strikeTimeKey)
    }
}
