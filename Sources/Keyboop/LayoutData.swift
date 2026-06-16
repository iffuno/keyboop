import Foundation

/// Языковые данные для детекции: триграммные лог-вероятности + словари RU/EN.
/// Источник данных — keyswitcher (MIT, © 2026 Ilya Granin), см. THIRD_PARTY.md.
final class LayoutData {
    static let shared = LayoutData()

    let trigramsRu: [String: Double]
    let trigramsEn: [String: Double]
    let wordsRu: Set<String>
    let wordsEn: Set<String>
    let isLoaded: Bool

    private init() {
        trigramsRu = Self.loadDict("trigrams_ru")
        trigramsEn = Self.loadDict("trigrams_en")
        wordsRu = Self.loadSet("words_ru").union(ExtraWords.ru).union(ExtraWords.ruAbbr).union(ExtraWords.ruShort)
        wordsEn = Self.loadSet("words_en").union(ExtraWords.en)
        isLoaded = !trigramsRu.isEmpty && !wordsEn.isEmpty
        NSLog("Keyboop: LayoutData loaded=\(isLoaded) ru-tri=\(trigramsRu.count) en-tri=\(trigramsEn.count) ru-w=\(wordsRu.count) en-w=\(wordsEn.count)")
    }

    /// Средняя лог-вероятность триграмм слова (с паддингом пробелами). Штраф −20 за отсутствие.
    func plausibility(_ word: String, cyrillic: Bool) -> Double {
        let table = cyrillic ? trigramsRu : trigramsEn
        let chars = Array(" " + word.lowercased() + " ")
        guard chars.count >= 3 else { return -.infinity }
        var sum = 0.0
        for i in 0...(chars.count - 3) {
            sum += table[String(chars[i..<(i + 3)])] ?? -20.0
        }
        return sum / Double(chars.count - 2)
    }

    /// URL данных: из bundle (приложение) или из KEYBOOP_DATA_DIR (CLI-инструменты).
    private static func dataURL(_ name: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["KEYBOOP_DATA_DIR"], !dir.isEmpty {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return Bundle.main.url(forResource: name, withExtension: "json")
    }

    private static func loadDict(_ name: String) -> [String: Double] {
        guard let url = dataURL(name),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
            NSLog("Keyboop: failed to load \(name).json")
            return [:]
        }
        return dict
    }

    private static func loadSet(_ name: String) -> Set<String> {
        guard let url = dataURL(name),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            NSLog("Keyboop: failed to load \(name).json")
            return []
        }
        return Set(arr)
    }
}
