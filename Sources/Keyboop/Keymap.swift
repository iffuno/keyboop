import Foundation

/// Відповідність фізичних клавіш між Apple-розкладками "U.S." та "Ukrainian".
/// Конвертація посимвольна (char↔char) — keycodes не потрібні, т.к. ми працюємо
/// з уже набраною строкою.
enum Keymap {
    // Базові пари: EN-символ (розкладка US) -> UA-символ (розкладка Ukrainian), нижній регістр.
    private static let basePairs: [(String, String)] = [
        ("`","'"),  ("q","й"), ("w","ц"), ("e","у"), ("r","к"), ("t","е"), ("y","н"), ("u","г"),
        ("i","ш"), ("o","щ"), ("p","з"), ("[","х"), ("]","ъ"),
        ("a","ф"), ("s","и"), ("d","в"), ("f","а"), ("g","п"), ("h","р"), ("j","о"), ("k","л"),
        ("l","д"), (";","ж"), ("'","є"),
        ("z","я"), ("x","ч"), ("c","с"), ("v","м"), ("b","і"), ("n","т"), ("m","ь"),
        (",","б"), (".","ю"), ("/",".")
    ]

    static let enToUa: [String: String] = {
        var d: [String: String] = [:]
        for (e, u) in basePairs {
            d[e] = u
            if e.lowercased() != e.uppercased() { // тільки букви отримують верхній регістр
                d[e.uppercased()] = u.uppercased()
            }
        }
        return d
    }()

    static let uaToEn: [String: String] = {
        var d: [String: String] = [:]
        for (e, u) in basePairs {
            d[u] = e
            if e.lowercased() != e.uppercased() {
                d[u.uppercased()] = e.uppercased()
            }
        }
        return d
    }()

    /// Конвертує строку: toCyrillic=true → EN→UA, інакше UA→EN.
    /// Символи поза таблицею залишаються як є.
    /// Primary — DynamicKeymap (точна таблиця з реальної розкладки macOS);
    /// статичні пари нижче — fallback, якщо UCKeyTranslate недоступен.
    static func convert(_ text: String, toCyrillic: Bool) -> String {
        if DynamicKeymap.isReady {
            return DynamicKeymap.convert(text, toCyrillic: toCyrillic)
        }
        let map = toCyrillic ? enToUa : uaToEn
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            out += map[String(ch)] ?? String(ch)
        }
        return out
    }

    /// Семантичні знаки пунктуації: однакові в обох розкладках (просто на різних клавішах),
    /// тому в кінці слова їх НЕ конвертуємо (інакше "." → "ю", "," → "б").
    static let trailingPunctuation = Set<Character>(".,!?;:…")

    /// Розумна конвертація: відділяє кінцеву пунктуацію (залишає як є), конвертує ядро.
    /// `ghbdtn.` → `привіт.` (а не `привітю`).
    ///
    /// НО: клавіші `,` `.` `;` в EN-розкладці — це І знаки пунктуації, І букви **б ю ж**. Якщо ПОВНА
    /// конверсія слова (з цим символом ЯК БУКВАЮ) дає валідне слово — символ був буквою, конвертуємо
    /// цілком: «yj;»→«ніж», «[kt,»→«хліб» (раніше зрізалися → «ні;», «хлі,» — порча). Інакше відділяємо
    /// як пунктуацію: «ghbdtn.»→«привіт.». Тільки EN→UA (`toCyrillic`); перевірка валідності —
    /// `isValidTarget` (словник UA, передає викликаючий, щоб Keymap не тягнув LayoutData).
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

    /// Ядро слова без кінцевої пунктуації — для аналізу детектором.
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
