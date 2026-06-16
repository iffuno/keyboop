import Foundation

/// Автозамена сниппетов: триггер → раскрытие (`!ee` → e-mail, `итд` → «и так далее»).
/// Хранится в UserDefaults. Срабатывает на границе слова (пробел/таб/Enter).
final class SnippetStore {
    static let shared = SnippetStore()
    private let d = UserDefaults.standard
    private let key = "snippets"

    private(set) var map: [String: String]            // оригинальные триггеры (как ввёл юзер — для редактора)
    private var byCanonical: [String: String] = [:]    // канон-триггер → раскрытие (для матча)

    private init() {
        map = (d.dictionary(forKey: key) as? [String: String]) ?? [:]
        rebuildIndex()
    }

    /// Канонический вид триггера/слова: РАСКЛАДКА-НЕЗАВИСИМО (по физическим клавишам, через
    /// Keymap RU→EN) и БЕЗ РЕГИСТРА. Поэтому `!test` == `!TEST` == `!еуые` (одни и те же клавиши).
    static func canonical(_ s: String) -> String {
        Keymap.convert(s, toCyrillic: false).lowercased()
    }

    private func rebuildIndex() {
        byCanonical = [:]
        for (t, e) in map {
            let c = Self.canonical(t)
            if !c.isEmpty { byCanonical[c] = e }
        }
    }

    /// Точное совпадение (как сохранён триггер) — оставлено на всякий случай.
    func expansion(for trigger: String) -> String? { map[trigger] }

    /// Совпадение для НАБРАННОГО слова — игнорирует раскладку и регистр.
    func expansion(forTyped word: String) -> String? { byCanonical[Self.canonical(word)] }

    func setAll(_ m: [String: String]) {
        map = m
        d.set(map, forKey: key)
        rebuildIndex()
    }

    /// Парсинг из текста вида «триггер = раскрытие» по строке.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let trigger = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let expansion = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !trigger.isEmpty && !expansion.isEmpty { result[trigger] = expansion }
        }
        return result
    }

    func asText() -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }

    /// Пары (триггер, раскрытие), отсортированы — для табличного редактора.
    func pairs() -> [(String, String)] {
        map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
