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
        convert(text, toCyrillic: toCyrillic, table: liveTable(toCyrillic: toCyrillic))
    }

    /// Живая таблица нужного направления, либо nil, пока её нет (тогда работает статическая запаска).
    static func liveTable(toCyrillic: Bool) -> [Character: Character]? {
        guard DynamicKeymap.isReady else { return nil }
        return toCyrillic ? DynamicKeymap.enToRu : DynamicKeymap.ruToEn
    }

    /// Чистое ядро конверсии: таблица приходит снаружи (`nil` = статическая запаска). Стенды гоняют
    /// его на таблицах, снятых с любой установленной раскладки, в том числе выключенной.
    ///
    /// ⚠️ ЦИКЛ ЖИВЁТ ЗДЕСЬ, А НЕ В `DynamicKeymap.convert`, И ЭТО НАРОЧНО (задача 263, 26.09.2026).
    /// Правило про знак между цифрами ниже должно достаться ВСЕМ путям: ручному хоткею, выделению,
    /// группе, авто на границе и правке на лету. Все они идут сюда, а живую таблицу мы читаем
    /// напрямую. Посимвольная замена та же, что в `DynamicKeymap.convert` (`таблица[знак] ?? знак`),
    /// так что для текста без чисел результат прежний до символа. Отдельного прохода по строке ради
    /// редкого случая нет: соседей смотрим в том же цикле, как предупреждает `DynamicKeymap`.
    static func convert(_ text: String, toCyrillic: Bool, table: [Character: Character]?) -> String {
        let fallback = toCyrillic ? enToRu : ruToEn
        var out = ""
        out.reserveCapacity(text.count)
        var it = text.makeIterator()
        var prev: Character? = nil
        var cur = it.next()
        var runHasSeparator = false     // в текущем числе слева уже был разделитель между цифрами
        while let ch = cur {
            let next = it.next()
            if ch == "," || ch == ".", let p = prev, isASCIIDigit(p), let n = next, isASCIIDigit(n) {
                out.append(numberSeparator(ch, toCyrillic: toCyrillic,
                                           leftHasSeparator: runHasSeparator, rest: it))
                runHasSeparator = true
            } else {
                if let table {
                    out.append(table[ch] ?? ch)
                } else {
                    out += fallback[String(ch)] ?? fallback[String(Self.straighten(ch))] ?? String(ch)
                }
                if !isASCIIDigit(ch) { runHasSeparator = false }
            }
            prev = ch
            cur = next
        }
        return out
    }

    /// ЗАПЯТАЯ И ТОЧКА МЕЖДУ ДВУМЯ ЦИФРАМИ (задача 263, отзыв #305, 26.09.2026).
    ///
    /// Отзыв: «5,5» с цифрового блока в русской раскладке, хоткей, получилось «5?5». Причина в том,
    /// что таблица знает знак только по клавише основного ряда: русская «,» спарена с той клавишей,
    /// которая её печатает (Shift+/ «?» в «Русской — ПК», Shift+6 «^» в Apple «Русской»). Откуда
    /// пришла запятая, с цифрового блока или нет, к моменту конверсии уже не известно.
    ///
    /// ⚠️ ПОЭТОМУ ЗНАК МЕЖДУ ЦИФРАМИ В ТАБЛИЦУ НЕ ОТПРАВЛЯЕМ ВОВСЕ. Такой знак это разделитель
    /// числа, а не буква и не клавиша: «5ю5», «5?5» и «25&09&2026» не нужны никому. Решение автора,
    /// вариант А из разбора:
    ///   • в английскую: «5,5» → «5.5» (так печатает цифровой блок в английской, и так просили);
    ///   • в русскую: знак как набран, «5.5» остаётся «5.5» (номера версий вроде «17.2» не портим).
    ///
    /// ⚠️ ЗАПЯТАЯ СТАНОВИТСЯ ТОЧКОЙ, ТОЛЬКО КОГДА ОНА ЕДИНСТВЕННЫЙ РАЗДЕЛИТЕЛЬ В ЧИСЛЕ. «1,000,000»,
    /// «10,5,7» и «1.000,50» это разряды, списки или чужая запись дробей, и угадывать там нельзя:
    /// оставляем как набрано («не навреди»). Точка между цифрами в английскую не меняется («25.09.2026»).
    ///
    /// Зовётся только на найденной «цифра, знак, цифра». `leftHasSeparator` приносит цикл, а правую
    /// часть числа смотрим по копии итератора (`rest` стоит сразу за цифрой после знака), так что
    /// строку заново не проходим.
    private static func numberSeparator(_ ch: Character, toCyrillic: Bool, leftHasSeparator: Bool,
                                        rest: String.Iterator) -> Character {
        if toCyrillic || ch == "." || leftHasSeparator { return ch }
        var look = rest
        while let c = look.next() {
            if isASCIIDigit(c) { continue }
            if c == "," || c == ".", let after = look.next(), isASCIIDigit(after) { return ch }
            break
        }
        return "."
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return v >= 48 && v <= 57
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
        smartConvert(word, toCyrillic: toCyrillic, isValidTarget: isValidTarget,
                     table: liveTable(toCyrillic: toCyrillic))
    }

    /// Чистое ядро `smartConvert` с таблицей снаружи (`nil` = статическая запаска), для стендов.
    static func smartConvert(_ word: String, toCyrillic: Bool, isValidTarget: ((String) -> Bool)?,
                             table: [Character: Character]?) -> String {
        if toCyrillic, let valid = isValidTarget {
            let full = convert(word, toCyrillic: true, table: table)
            if valid(full.lowercased()) { return full }
        }
        var core = Substring(word)
        var trailing = ""
        while let last = core.last, trailingPunctuation.contains(last) {
            trailing = String(peeledMark(last, toCyrillic: toCyrillic, table: table)) + trailing
            core = core.dropLast()
        }
        guard !core.isEmpty else { return word }
        return convert(String(core), toCyrillic: toCyrillic, table: table) + trailing
    }

    /// Каким оставить срезанный концевой знак (задача 263, отзыв #306, 26.09.2026).
    ///
    /// Набор `trailingPunctuation` исходит из того, что знак одинаков в обеих раскладках и просто
    /// лежит на разных клавишах. Для «Русской — ПК» это неправда: клавиша, которая в английской даёт
    /// «?», в ней печатает «,». Человек набрал «Lf?», имея в виду «Да,», а получал «Да?».
    ///
    /// ⚠️ ЗНАК МЕНЯЕМ, ТОЛЬКО КОГДА ТАБЛИЦА ЧЕЛОВЕКА ПЕРЕВОДИТ ЕГО В ДРУГОЙ ЗНАК ИЗ ТОГО ЖЕ НАБОРА.
    /// Если клавиша даёт букву («.»→«ю», «,»→«б», «;»→«ж») или пары нет вовсе, знак остаётся как
    /// набран, ровно как было: «ghbdtn.» по-прежнему «привет.». У Apple «Русской» в паре с U.S. или
    /// ABC таких пар нет («?» и «!» там на тех же клавишах), так что её пользователи разницы не увидят.
    /// Решает сама живая таблица, отдельной настройки нет.
    ///
    /// ⚠️ С РЕДКИМИ ЛАТИНСКИМИ РАСКЛАДКАМИ ПАРЫ ЕСТЬ И У APPLE «РУССКОЙ» (перебор всех установленных
    /// раскладок на ANSI, ISO и JIS, 26.09.2026). Итальянская, польская, бразильская ABNT2, канадская
    /// CSA и ещё несколько кладут концевой знак на клавишу, которая в русской печатает другой знак.
    /// Там знак тоже переводится по клавише. Это то же правило, а не новое: человек жал клавиши
    /// русской раскладки, и концевой знак не исключение.
    ///
    /// ⚠️ ТОЛЬКО В СТОРОНУ КИРИЛЛИЦЫ. Об этом и был отзыв. Обратное направление («Руддщ,» →
    /// «Hello?» у пользователя «ПК») было бы новым поведением, которого никто не просил, поэтому
    /// там знак остаётся как набран.
    private static func peeledMark(_ p: Character, toCyrillic: Bool, table: [Character: Character]?) -> Character {
        guard toCyrillic else { return p }
        let mapped = convert(String(p), toCyrillic: true, table: table)
        guard mapped.count == 1, let m = mapped.first, m != p, trailingPunctuation.contains(m) else { return p }
        return m
    }

    /// Конверсия для правки НА ЛЕТУ, пока слово не дописано (задача 262, отзыв #312, 26.09.2026).
    /// nil означает «ждём следующую клавишу».
    ///
    /// ⚠️ ЗАЧЕМ ЖДАТЬ. Человек печатает «переключение» в английской раскладке. На седьмой клавише, на
    /// «ю», которая в английской даёт «.», правка на лету решала конвертить: детектор читает точку как
    /// букву и видит «переклю». А `smartConvert` проверял по словарю ПОЛНОЕ слово, не находил
    /// недописанное «переклю» и срезал точку как конец предложения. На экране оставалось «перекл.»,
    /// раскладка переключалась, и слово дописывалось как «перекл.чение». Так же «ю», «б», «ж» в
    /// середине любого слова. Правило про концевой знак писалось для конца слова, а здесь слово ещё
    /// не кончилось.
    ///
    /// Поэтому, если `smartConvert` срезал бы концевой знак, который в таблице человека БУКВА,
    /// мид-словные пути не стреляют. Следующая клавиша делает знак внутренним, и «gthtrk.x» честно
    /// даёт «переключ». Если следом пробел, решает обычный путь на границе слова, как и сегодня.
    /// Цена: на таких словах правка на лету приходит на одну клавишу позже.
    ///
    /// ⚠️ ГРАНИЦУ СЛОВА ЭТО НЕ ТРОГАЕТ. «малую», набранное в английской, на пробеле по-прежнему даёт
    /// «малу.»: формы нет в словаре, и что с этим делать, автор решил пока не менять.
    static func liveConvert(_ word: String, toCyrillic: Bool, isValidTarget: ((String) -> Bool)?) -> String? {
        liveConvert(word, toCyrillic: toCyrillic, isValidTarget: isValidTarget,
                    table: liveTable(toCyrillic: toCyrillic))
    }

    /// Чистое ядро `liveConvert` с таблицей снаружи (`nil` = статическая запаска), для стендов.
    static func liveConvert(_ word: String, toCyrillic: Bool, isValidTarget: ((String) -> Bool)?,
                            table: [Character: Character]?) -> String? {
        let smart = smartConvert(word, toCyrillic: toCyrillic, isValidTarget: isValidTarget, table: table)
        guard smart != word else { return smart }               // конвертить нечего, всё как было
        let full = convert(word, toCyrillic: toCyrillic, table: table)
        guard smart != full else { return smart }
        // Обе строки один в один по длине и различаются только в срезанных концевых знаках.
        // Ждём, только если такой знак в таблице человека БУКВА: «&» вместо «.» буквой не станет.
        for (s, f) in zip(smart, full) where s != f && f.isLetter { return nil }
        return smart
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
