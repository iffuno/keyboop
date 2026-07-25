import Foundation

/// Автозамена сниппетов: триггер → раскрытие (`!ee` → e-mail, `итд` → «и так далее»).
/// Хранится в UserDefaults УПОРЯДОЧЕННО (массив пар) — порядок = как пользователь добавлял,
/// без сортировки по алфавиту. Срабатывает на границе слова (пробел/таб/Enter).
final class SnippetStore {
    static let shared = SnippetStore()
    private let d = UserDefaults.standard
    private let key = "snippetsOrdered"     // [[trigger, expansion]] — порядок сохраняется
    private let legacyKey = "snippets"      // старый словарь (для миграции)

    /// Пары (триггер, раскрытие) в порядке добавления — источник для редактора и матча.
    private(set) var orderedPairs: [(String, String)] = []
    private var byCanonical: [String: String] = [:]    // канон-триггер → раскрытие (для матча, порядок неважен)

    private init() {
        if let arr = d.array(forKey: key) as? [[String]] {
            orderedPairs = arr.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        } else if let legacy = d.dictionary(forKey: legacyKey) as? [String: String] {
            // Миграция: словарь не упорядочен → один раз берём по алфавиту, дальше порядок ручной.
            orderedPairs = legacy.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            persist()
        }
        rebuildIndex()
    }

    /// Канонический вид триггера/слова: РАСКЛАДКА-НЕЗАВИСИМО (по физическим клавишам, через
    /// Keymap RU→EN) и БЕЗ РЕГИСТРА. Поэтому `!test` == `!TEST` == `!еуые` (одни и те же клавиши).
    static func canonical(_ s: String) -> String {
        Keymap.convert(s, toCyrillic: false).lowercased()
    }

    private func rebuildIndex() {
        byCanonical = [:]
        for (t, e) in orderedPairs {
            let c = Self.canonical(t)
            if !c.isEmpty { byCanonical[c] = e }
        }
    }

    private func persist() {
        d.set(orderedPairs.map { [$0.0, $0.1] }, forKey: key)
    }

    /// Совпадение для НАБРАННОГО слова — игнорирует раскладку и регистр.
    func expansion(forTyped word: String) -> String? { byCanonical[Self.canonical(word)] }

    /// Пары для табличного редактора — В ПОРЯДКЕ ДОБАВЛЕНИЯ (без сортировки).
    func pairs() -> [(String, String)] { orderedPairs }

    /// Сохранить В ТОМ ПОРЯДКЕ, как передал редактор. Пустые триггеры отбрасываем; дубликаты
    /// триггера (раскладко-независимо) схлопываем — позиция первого, значение последнего.
    func setAll(_ pairs: [(String, String)]) {
        var out: [(String, String)] = []
        for (t, e) in pairs {
            let trig = t.trimmingCharacters(in: .whitespaces)
            if trig.isEmpty { continue }
            let c = Self.canonical(trig)
            if let idx = out.firstIndex(where: { Self.canonical($0.0) == c }) {
                out[idx].1 = e                       // тот же триггер → обновляем значение, позицию сохраняем
            } else {
                out.append((trig, e))
            }
        }
        orderedPairs = out
        persist()
        rebuildIndex()
    }
}
