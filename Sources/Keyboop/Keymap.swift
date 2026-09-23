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
            out += map[String(ch)] ?? map[String(Self.straighten(ch))] ?? String(ch)
        }
        return out
    }

    /// В КАКУЮ СТОРОНУ КРУТИТЬ, КОГДА БУКВ НЕТ ВООБЩЕ (задача 268, 12.09.2026).
    ///
    /// Отзыв #267 и проверка автора: «поставил вместо запятой `^`, выделил, нажал хоткей, ничего».
    /// Слова и буквы конвертировались, одиночный знак нет. Причина была не в таблице (она знает
    /// все клавиши с шифтом и без), а в том, что направление конверсии выводилось ТОЛЬКО из букв:
    /// нет кириллицы и нет латиницы — нечего решать, отказ.
    ///
    /// Для знаков направление определяется иначе, и это можно сделать честно, без догадок. Знак
    /// однозначно набран в АНГЛИЙСКОЙ раскладке, если он есть в паре `enToRu` и при этом сам
    /// никогда не появляется со стороны русской (`ruToEn[знак] == nil`). Тогда видеть его в тексте
    /// означает ровно одно: человек печатал латиницей. И симметрично в обратную сторону.
    ///
    /// ⚠️ ПОЧЕМУ НЕЛЬЗЯ ПРОСТО КРУТИТЬ ЛЮБОЙ ЗНАК. Замер на живых раскладках автора (U.S. + Русская,
    /// 12.09.2026): из 26 знаковых пар однозначны только 14. Остальные существуют по обе стороны, и
    /// догадка там наугад испортила бы нормальный текст. Однозначны, например: `^`→`,` (в русской
    /// `^` не набрать вовсе), `@`→`"`, `#`→`№`, `$`→`%`, `&`→`.`, `'`→`э`, `\`→`ё`, `|`→`Ё`,
    /// `` ` ``→`]`, `~`→`[`. Спорны и потому не трогаются: `,` `.` `;` `:` `"` `%` `*` `[` `]` `<` `>`
    /// — каждый из них может быть настоящим знаком в любой из двух раскладок.
    ///
    /// ⚠️ ТОЛЬКО ДЛЯ РУЧНОЙ КОНВЕРСИИ. Автоматическая на границе слова этим не пользуется: там
    /// человек ничего не просил, а знаки живут в коде, в командной строке и в формулах, где
    /// «исправление» было бы порчей. Здесь же человек выделил текст и нажал хоткей, то есть заявил
    /// намерение.
    ///
    /// Возвращает `toCyrillic` для `Keymap.convert`, либо nil, если решить нельзя: пусто, есть
    /// буквы, все знаки спорные, или знаки тянут в разные стороны.
    static func unambiguousSymbolDirection(_ text: String) -> Bool? {
        // ⚠️ ТОЛЬКО НА ЖИВОЙ ТАБЛИЦЕ, И ЭТО НЕ ПЕРЕСТРАХОВКА (поймано стендом 12.09.2026).
        // Статическая таблица-запаска знает пары «буква → знак» («ж»→`;`, «б»→`,`), но НЕ знает
        // обратных знаковых пар, которых в ней просто нет. Из-за этого `;` и `,` выглядели в ней
        // однозначно английскими, и правило превращало обычную запятую в «б», а точку с запятой
        // в «ж». Живая таблица строится из самих раскладок системы по всем клавишам с шифтом и без,
        // и только она знает, что `;` в русской раскладке тоже набирается (Shift+8).
        guard DynamicKeymap.isReady else { return nil }
        return symbolDirection(text, enToRu: DynamicKeymap.enToRu, ruToEn: DynamicKeymap.ruToEn)
    }

    /// Чистое ядро правила: решение зависит ТОЛЬКО от переданных таблиц, поэтому его можно гонять
    /// стендом на выдуманных раскладках, не завися от того, какие включены на машине.
    static func symbolDirection(_ text: String,
                                enToRu: [Character: Character],
                                ruToEn: [Character: Character]) -> Bool? {
        var toCyr = false, toLat = false
        for ch in text {
            if ch.isLetter { return nil }          // буквы решают сами, это не наш случай
            guard !ch.isWhitespace, !ch.isNumber else { continue }
            let c = straighten(ch)
            let en = enToRu[c] != nil, ru = ruToEn[c] != nil
            if en, !ru { toCyr = true } else if ru, !en { toLat = true }
        }
        if toCyr == toLat { return nil }           // либо ничего однозначного, либо тянут в разные стороны
        return toCyr
    }

    /// Типографский двойник → прямой знак. То же, что делают псевдонимы в `DynamicKeymap`, но для
    /// СТАТИЧЕСКОЙ таблицы (задача 168).
    ///
    /// ⚠️ ЭТУ ПОЛОВИНУ ПОЙМАЛ СТЕНД, А НЕ ГОЛОВА. Псевдонимы сперва добавили только в динамическую
    /// таблицу, и `run-falsepos.sh` тут же показал «’nj» → «’то»: сам стенд работает на статической,
    /// потому что в его процессе UCKeyTranslate никто не звал. У людей запасная таблица включается
    /// в те же секунды после запуска, пока раскладки ещё не прочитаны, так что дыра была настоящая.
    ///
    /// ⚠️ Длинное тире и «ёлочки» не трогаем: это самостоятельные знаки, а не подмена прямых.
    static func straighten(_ ch: Character) -> Character {
        switch ch {
        case "\u{2019}", "\u{2018}", "\u{00B4}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201F}": return "\""
        default: return ch
        }
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
