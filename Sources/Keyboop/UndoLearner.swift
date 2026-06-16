import Foundation

/// Обучение на отмене: если пользователь СРАЗУ откатил нашу авто-конверсию и точь-в-точь
/// восстановил оригинал — мы это запоминаем. После N таких откатов одного слова оно
/// переезжает в «выученные исключения» и больше не трогается.
///
/// Главный принцип (просьба Ивана): СЛУЧАЙНО не занести нормальное слово. Поэтому:
///  • откат засчитывается ТОЛЬКО при точном воспроизведении оригинала (не «просто удалил»);
///  • нужно ПОРОГ откатов (одиночный мог быть случайным);
///  • счётчик «протухает» (старые откаты не копятся в ложное добавление);
///  • выученное — в ОТДЕЛЬНОМ списке (виден в настройках, полностью обратим).
///
/// Два честных жеста отмены, оба требуют ТОЧНЫЙ оригинал → near-zero ложных срабатываний:
///  U1 — ручной ре-флип: авто сделало W→C, юзер хоткеем флипнул C обратно в W (canonical Punto-жест).
///  U2 — стереть наш вывод C целиком и перенабрать оригинал W посимвольно.
///
/// Cmd+Z (системный undo) НЕ детектируем — мы не видим результат текстовой операции; U1/U2 покрывают
/// реальные жесты. Машинные тесты — Tools/UndoSim.swift (run-undosim.sh).
final class UndoLearner {
    static let shared = UndoLearner()
    private let d = UserDefaults.standard
    private let statsKey = "undoStrikeStats"

    // --- Настраиваемые константы (тюнятся по реальному опыту; см. docs/IDEAS.md L) ---
    /// Сколько откатов ОДНОГО слова нужно для перевода в выученные. 1 откат мог быть случайным.
    private let learnThreshold = 3
    /// Окно, в которое после конверсии должен уложиться откат. Позже — это уже не «отмена», а правка.
    private let undoWindow: TimeInterval = 4
    /// Через сколько «протухает» накопленный счётчик откатов слова (чтобы 3 случайных за месяцы не слились).
    private let strikeDecay: TimeInterval = 7 * 24 * 3600

    /// Кандидат на откат: что мы только что авто/лайв-сконвертировали и в какой стадии отмена.
    private struct Candidate {
        let original: String     // что юзер набрал (lowercased), напр. "links"
        let converted: String    // что мы вывели на экран (lowercased), напр. "дштлы"
        let createdAt: Date
        var stage: Stage
        enum Stage { case fresh, deleting, retyping }
    }
    private var candidate: Candidate?

    /// Слова (typed-форма), которые юзер ВОССТАНОВИЛ в этом контексте набора — не конвертируем их
    /// повторно сразу же (анти-«драка»), даже если порог обучения ещё не достигнут. Сбрасывается на
    /// смене контекста (клик/навигация/смена окна) — это transient, не персист.
    private var sessionProtected: Set<String> = []

    /// Счётчики откатов по словам (персист). Хранится как [word: [count, lastEpoch]].
    private var stats: [String: (count: Int, last: Date)]

    /// Тихое уведомление об обучении (Engine подвязывает тост). Параметр — выученное слово.
    var onLearned: ((String) -> Void)?

    private init() {
        var loaded: [String: (count: Int, last: Date)] = [:]
        if let raw = d.dictionary(forKey: statsKey) as? [String: [Double]] {
            for (w, pair) in raw where pair.count == 2 {
                loaded[w] = (Int(pair[0]), Date(timeIntervalSince1970: pair[1]))
            }
        }
        stats = loaded
    }

    private func persist() {
        var raw: [String: [Double]] = [:]
        for (w, s) in stats { raw[w] = [Double(s.count), s.last.timeIntervalSince1970] }
        d.set(raw, forKey: statsKey)
    }

    /// Тумблер фичи. Читаем ключ напрямую (а не через AppSettings) — чтобы UndoLearner не тянул
    /// ServiceManagement и компилировался в лёгком тест-таргете. Дефолт — ВКЛ (object==nil).
    private var enabled: Bool {
        d.object(forKey: "learnOnUndoEnabled") == nil ? true : d.bool(forKey: "learnOnUndoEnabled")
    }

    // MARK: - Вход от Engine

    /// Слово было авто/лайв-сконвертировано (W→C). Заводим кандидата на откат.
    /// Только авто/лайв — ручную конверсию юзер сделал сам, её отмена ≠ «мы ошиблись».
    func noteConversion(original: String, converted: String) {
        guard enabled else { candidate = nil; return }
        let o = original.lowercased(), c = converted.lowercased()
        guard o != c, !o.isEmpty, !c.isEmpty else { candidate = nil; return }
        // Уже выучено — кандидат не нужен (мы и не должны были конвертить, но на всякий случай).
        if ExceptionStore.shared.learned.contains(o) { candidate = nil; return }
        candidate = Candidate(original: o, converted: c, createdAt: now(), stage: .fresh)
    }

    /// Ручная конверсия (U1): юзер хоткеем превратил `from` в `to`. Если это точный откат нашей
    /// недавней авто-конверсии (to == оригинал, from == наш вывод, в окне) — засчитываем.
    /// Возвращает восстановленное слово, если это был откат (Engine добавит его в sessionProtected).
    @discardableResult
    func noteManualConvert(from: String, to: String) -> String? {
        guard enabled, let cand = liveCandidate() else { return nil }
        let f = from.lowercased(), t = to.lowercased()
        guard f == cand.converted, t == cand.original else { return nil }
        candidate = nil
        sessionProtected.insert(cand.original)
        recordUndo(cand.original)
        return cand.original
    }

    /// Наблюдение за набором (U2). Зовётся из Engine ПОСЛЕ обновления буфера на каждый
    /// печатный символ / Backspace. `current` — buffer.currentWord. Возвращает true, если это
    /// был подтверждённый откат (Engine может тихо отреагировать).
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
                recordUndo(cand.original)
                return true                                         // точно восстановили оригинал → откат
            } else if cand.original.hasPrefix(cur) {
                return false                                        // ещё строят оригинал (конверсию глушим, см. shouldSuppress)
            } else {
                candidate = nil; return false                       // ушли в сторону → не откат
            }
        }
    }

    /// Пока юзер ВОССТАНАВЛИВАЕТ оригинал (current — его префикс) — глушим авто/лайв-конверсию,
    /// чтобы не «драться» с ним во время перенабора.
    func shouldSuppress(current raw: String) -> Bool {
        guard enabled, let cand = liveCandidate(), cand.stage == .retyping else { return false }
        let cur = raw.lowercased()
        return !cur.isEmpty && cand.original.hasPrefix(cur) && cur != cand.original
    }

    /// Слово восстановлено в этом контексте — не конвертировать его сразу повторно (анти-драка).
    func isSessionProtected(_ word: String) -> Bool {
        enabled && sessionProtected.contains(word.lowercased())
    }

    /// Смена контекста набора (клик/навигация/смена окна) — кандидат и session-защита неактуальны.
    func resetContext() {
        candidate = nil
        sessionProtected.removeAll()
    }

    // MARK: - Учёт откатов

    private func recordUndo(_ word: String) {
        let w = word.lowercased()
        guard !ExceptionStore.shared.learned.contains(w) else { return }
        var s = stats[w] ?? (0, now())
        if now().timeIntervalSince(s.last) > strikeDecay { s.count = 0 }   // протухло — начинаем заново
        s.count += 1
        s.last = now()
        if s.count >= learnThreshold {
            stats.removeValue(forKey: w)
            ExceptionStore.shared.addLearned(w)
            persist()
            kbLog("undo-learn: слово выучено (len \(w.count), порог \(learnThreshold)) → больше не трогаем")
            onLearned?(w)
        } else {
            stats[w] = s
            persist()
            kbLog("undo-learn: откат слова (len \(w.count)) (\(s.count)/\(learnThreshold))")
        }
    }

    // MARK: - Утилиты

    /// Кандидат, если он ещё в окне; иначе чистим и nil.
    private func liveCandidate() -> Candidate? {
        guard let c = candidate else { return nil }
        if now().timeIntervalSince(c.createdAt) > undoWindow { candidate = nil; return nil }
        return c
    }

    /// Источник времени — инъектируемый для машинных тестов затухания (Tools/UndoSim.swift).
    var nowProvider: () -> Date = { Date() }
    private func now() -> Date { nowProvider() }

    /// Сброс между подтестами в UndoSim (не вызывается в проде).
    func _resetForTests() {
        candidate = nil
        sessionProtected.removeAll()
        stats.removeAll()
        persist()
    }
    /// Текущий счётчик откатов слова — для проверок в тестах.
    func _strikeCount(_ word: String) -> Int { stats[word.lowercased()]?.count ?? 0 }
}
