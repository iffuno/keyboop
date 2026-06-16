import Foundation

/// Соответствие физических клавиш между Apple-раскладками "U.S." и "Russian".
/// Конвертация посимвольная (char↔char) — keycodes не нужны, т.к. мы работаем
/// с уже набранной строкой.
enum Keymap {
    // Базовые пары: EN-символ (раскладка US) -> RU-символ (раскладка Russian), нижний регистр.
    private static let basePairs: [(String, String)] = [
        ("`","ё"),("q","й"),("w","ц"),("e","у"),("r","к"),("t","е"),("y","н"),("u","г"),
        ("i","ш"),("o","щ"),("p","з"),("[","х"),("]","ъ"),
        ("a","ф"),("s","ы"),("d","в"),("f","а"),("g","п"),("h","р"),("j","о"),("k","л"),
        ("l","д"),(";","ж"),("'","э"),
        ("z","я"),("x","ч"),("c","с"),("v","м"),("b","и"),("n","т"),("m","ь"),
        (",","б"),(".","ю"),("/",".")
    ]

    static let enToRu: [String: String] = {
        var d: [String: String] = [:]
        for (e, r) in basePairs {
            d[e] = r
            if e.lowercased() != e.uppercased() { // только буквы получают верхний регистр
                d[e.uppercased()] = r.uppercased()
            }
        }
        return d
    }()

    static let ruToEn: [String: String] = {
        var d: [String: String] = [:]
        for (e, r) in basePairs {
            d[r] = e
            if e.lowercased() != e.uppercased() {
                d[r.uppercased()] = e.uppercased()
            }
        }
        return d
    }()

    /// Конвертирует строку: toCyrillic=true → EN→RU, иначе RU→EN.
    /// Символы вне таблицы остаются как есть.
    /// Primary — DynamicKeymap (точная таблица из реальной раскладки macOS);
    /// статические пары ниже — fallback, если UCKeyTranslate недоступен.
    static func convert(_ text: String, toCyrillic: Bool) -> String {
        if DynamicKeymap.isReady {
            return DynamicKeymap.convert(text, toCyrillic: toCyrillic)
        }
        let map = toCyrillic ? enToRu : ruToEn
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            out += map[String(ch)] ?? String(ch)
        }
        return out
    }

    /// Семантические знаки препинания: одинаковы в обеих раскладках (просто на разных клавишах),
    /// поэтому в конце слова их НЕ конвертируем (иначе "." → "ю", "," → "б").
    static let trailingPunctuation = Set<Character>(".,!?;:…")

    /// Умная конвертация: отделяет концевую пунктуацию (оставляет как есть), конвертит ядро.
    /// `ghbdtn.` → `привет.` (а не `приветю`).
    ///
    /// НО: клавиши `,` `.` `;` в EN-раскладке — это И знаки препинания, И буквы **б ю ж**. Если ПОЛНАЯ
    /// конверсия слова (с этим символом КАК БУКВОЙ) даёт валидное слово — символ был буквой, конвертим
    /// целиком: «yj;»→«нож», «[kt,»→«хлеб» (раньше срезались → «но;», «хле,» — порча). Иначе отделяем
    /// как пунктуацию: «ghbdtn.»→«привет.». Только EN→RU (`toCyrillic`); проверка валидности —
    /// `isValidTarget` (словарь RU, передаёт вызывающий, чтобы Keymap не тянул LayoutData).
    static func smartConvert(_ word: String, toCyrillic: Bool, isValidTarget: ((String) -> Bool)? = nil) -> String {
        if toCyrillic, let valid = isValidTarget {
            let full = convert(word, toCyrillic: true)
            if valid(full.lowercased()) { return full }
        }
        var core = Substring(word)
        var trailing = ""
        while let last = core.last, trailingPunctuation.contains(last) {
            trailing = String(last) + trailing
            core = core.dropLast()
        }
        guard !core.isEmpty else { return word }
        return convert(String(core), toCyrillic: toCyrillic) + trailing
    }

    /// Ядро слова без концевой пунктуации — для анализа детектором.
    static func core(of word: String) -> String {
        var s = Substring(word)
        while let last = s.last, trailingPunctuation.contains(last) { s = s.dropLast() }
        return String(s)
    }
}

extension String {
    var hasCyrillic: Bool {
        unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }
    var hasLatinLetter: Bool {
        unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
    }
}
