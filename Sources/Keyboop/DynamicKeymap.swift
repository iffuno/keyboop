import Carbon
import Foundation

/// Таблица соответствия символов между латинской и кириллической раскладками
/// пользователя, построенная ИЗ САМОЙ macOS через `UCKeyTranslate`.
///
/// Зачем: статический хардкод (`Keymap`) неточен — Apple «Russian» и «Russian — PC»
/// кладут символы по разным клавишам (напр. на Apple «Russian» кавычка `"` = Shift+2,
/// а `` ` `` даёт `]`; на «Russian — PC» иначе). Динамика читает РЕАЛЬНУЮ раскладку
/// и покрывает все символы (буквы, цифровой Shift-ряд, кавычки, скобки) для любого
/// варианта и любой языковой пары. Используется как primary; `Keymap` — fallback.
enum DynamicKeymap {
    private(set) static var enToRu: [Character: Character] = [:]
    private(set) static var ruToEn: [Character: Character] = [:]
    /// Физическая клавиша каждой строчной латинской буквы в ЛАТИНСКОЙ раскладке человека (той же,
    /// что в паре выше): у AZERTY «a» стоит не там, где у U.S. Нужна скрытым дублям пунктов меню
    /// (задача 255, `MenuBarController.addLayoutTwins`). Пусто, пока таблица не построена.
    private(set) static var latinKeyCodes: [Character: UInt16] = [:]
    static var isReady: Bool { !enToRu.isEmpty }

    /// Перестраивает таблицу из включённых раскладок. Идемпотентно, дёшево (~200 UCKeyTranslate).
    /// `preferLat`/`preferCyr` — идентификаторы раскладок, которые человек выбрал сам (их хранит
    /// `LayoutManager`). Пустые строки означают «бери что найдёшь», как было раньше.
    ///
    /// ⚠️ НАСТРОЙКИ СЮДА НЕ ТЯНЕМ, ИХ ПЕРЕДАЁТ ВЫЗЫВАЮЩИЙ. Первая версия правки читала
    /// `AppSettings.shared` прямо здесь, и четыре стенда перестали собираться: они компилируют
    /// только нужный им срез файлов, а такая зависимость тянет за собой AppKit. Низкоуровневой
    /// таблице символов знать про настройки и не положено.
    ///
    /// `keyboardType` это тип физической клавиатуры в числах Carbon (`LMGetKbdType()`), по умолчанию
    /// настоящий. Параметром он сделан для стенда `stands/run-dynamickeymap.sh`: так на одном Маке
    /// проверяются и ANSI, и ISO (задача 260). Приложение его не передаёт.
    static func rebuild(preferLat: String = "", preferCyr: String = "",
                        keyboardType: UInt32 = UInt32(LMGetKbdType())) {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(cf)
        var latin: Data? = nil
        var cyrillic: Data? = nil
        var latFallback: Data? = nil
        var cyrFallback: Data? = nil
        let wantCyr = preferCyr
        let wantLat = preferLat
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard boolProp(src, kTISPropertyInputSourceIsSelectCapable),
                  let data = layoutData(src) else { continue }
            // Классифицируем по символу клавиши 'a' (keyCode 0).
            guard let ch = translate(data, 0, false, keyboardType).first else { continue }
            let sid = stringProp(src, kTISPropertyInputSourceID) ?? ""
            if isCyrillic(ch) {
                if sid == wantCyr { cyrillic = data }             // ровно та, которой человек пользуется
                else if cyrillic == nil, wantCyr.isEmpty || cyrFallback == nil { cyrFallback = data }
            } else if isLatin(ch) {
                if sid == wantLat { latin = data }
                else if latin == nil, wantLat.isEmpty || latFallback == nil { latFallback = data }
            }
        }
        // ⚠️ ПАРУ БЕРЁМ ТУ, МЕЖДУ КОТОРОЙ ЧЕЛОВЕК ХОДИТ, А НЕ ПЕРВУЮ ПОПАВШУЮСЯ (задача 171,
        // 20.08.2026). Раньше здесь стояло «первая латинская + первая кириллическая из
        // перечисления». У кого включены и «Русская», и «Русская — ПК» (частый набор, отзыв #143),
        // в пару попадала та, что раньше в списке, а не та, которой печатают.
        //
        // ⚠️ ЦЕНА ОШИБКИ ИЗМЕРЕНА (`Tools/LayoutDiffProbe.swift`): эти две раскладки расходятся на
        // четырёх клавишах, и среди них ТОЧКА С ЗАПЯТОЙ. Клавиша `/` даёт «/ ?» в Русской и «. ,» в
        // Русской ПК; `` ` `` даёт «] [» против «ё Ë»; `\` даёт «ё Ё» против «\ /»; `5` с шифтом
        // «:» против «%». То есть при неверной паре человек получает не тот знак препинания.
        //
        // Какую считать «его»: ту, которую он выбрал сам, — мы её и так запоминаем, чтобы
        // возвращать его в свою раскладку (задачи 105/106).
        let L0 = latin ?? latFallback
        let C0 = cyrillic ?? cyrFallback
        guard let L = L0, let C = C0 else { return }

        let t = buildTables(latin: L, cyrillic: C, keyboardType: keyboardType)
        latinKeyCodes = t.latinKeyCodes
        guard !t.enToRu.isEmpty else { return }
        enToRu = t.enToRu
        ruToEn = t.ruToEn
    }

    /// Таблицы для заданной пары раскладок и типа клавиатуры. Ничего не запоминает, только считает:
    /// `rebuild` кладёт результат в поля, а стенд `stands/run-dynamickeymap.sh` зовёт напрямую с
    /// раскладками, которые у человека могут быть и выключены (задача 260, 26.09.2026).
    static func buildTables(latin L: Data, cyrillic C: Data, keyboardType: UInt32)
        -> (enToRu: [Character: Character], ruToEn: [Character: Character],
            latinKeyCodes: [Character: UInt16]) {
        var keys: [Character: UInt16] = [:]
        for kc in UInt16(0)...UInt16(50) {
            let ls = translate(L, kc, false, keyboardType)
            if ls.count == 1, let ch = ls.first, ch.isASCII, ch.isLetter, keys[ch] == nil { keys[ch] = kc }
        }

        // ⚠️ КЛАВИШИ 10 НА ANSI И JIS НЕТ, ЕЁ ПАРЫ НЕ БЕРЁМ (задача 260, 26.09.2026). В «Русской – ПК»
        // (`RussianWin`) «ё» лежит сразу на двух клавишах: keyCode 10 (`kVK_ISO_Section`, в U.S. это
        // «§») и keyCode 50 (в U.S. «`»). Перебор идёт по возрастанию, первая пара побеждает, и
        // «ё» уезжала в «§», «Ё» в «±». Но keyCode 10 бывает только на ISO-клавиатуре (так и
        // написано в `Events.h`). На ANSI слева от «1» стоит keyCode 50, и правильный ответ «ё»→«`».
        // Пары с несуществующей клавиши и в других раскладках были мусором: в Apple «Русской» с неё
        // приходило «>»↔«§» и «<»↔«±», то есть «>» в русском тексте превращался в «§».
        //
        // ⚠️ НА ISO НИЧЕГО НЕ МЕНЯЕТСЯ. Там keyCode 10 настоящая клавиша слева от «1», и «ё»→«§»
        // физически верно. Если тип клавиатуры не опознан, тоже оставляем всё как было. На JIS у
        // «Русской – ПК» «ё» после пропуска остаётся без пары вовсе (keyCode 50 там даёт «]»): с
        // клавиатуры её там не набрать, и «§» было такой же выдумкой.
        //
        // ⚠️ СЛЕДСТВИЕ ДЛЯ ПРАВИЛА 268 (ревью 26.09.2026). `Keymap.symbolDirection` считает знак
        // однозначно английским, если его нет в `ruToEn`. «>» и «<» Apple «Русской» держались там
        // только парой с клавиши 10, поэтому на ANSI выделенное «->» по хоткею теперь становится «-Ю»,
        // а не остаётся нетронутым. У «Русской – ПК» так было и до правки. Закреплено стендом
        // `stands/run-dynamickeymap.sh`, раздел 4.
        //
        // ⚠️ ТИП КЛАВИАТУРЫ БЕРЁТСЯ НА МОМЕНТ СБОРКИ ТАБЛИЦЫ, то есть при смене раскладки. При двух
        // клавиатурах разных типов таблица следует той, о которой macOS сообщит в этот момент. Так
        // было и раньше: `UCKeyTranslate` получал тот же `LMGetKbdType()` и уже отдавал ANSI и ISO
        // разные символы на клавишах 10 и 50.
        let skipSection = lacksISOSectionKey(keyboardType: keyboardType)

        var e2r: [Character: Character] = [:]
        var r2e: [Character: Character] = [:]
        var yoKey: UInt16? = nil      // клавиша, с которой «ё» получила пару
        // Печатные клавиши ANSI: буквы, цифровой ряд, знаки — keyCodes 0…50.
        for kc in UInt16(0)...UInt16(50) {
            if skipSection, kc == isoSectionKeyCode { continue }
            for shift in [false, true] {
                let ls = translate(L, kc, shift, keyboardType)
                let cs = translate(C, kc, shift, keyboardType)
                guard ls.count == 1, cs.count == 1,
                      let l = ls.first, let c = cs.first, l != c else { continue }
                if e2r[l] == nil { e2r[l] = c }
                if r2e[c] == nil {
                    r2e[c] = l
                    if c == "ё", !shift { yoKey = kc }
                }
            }
        }

        // ⚠️ «Ё» ПОСЛЕ ПРОПУСКА ОСТАЛАСЬ БЕЗ ПАРЫ, ДАЁМ ЕЙ ШИФТ ТОЙ ЖЕ КЛАВИШИ (задача 260). В
        // «Русской – ПК» на ANSI Shift плюс клавиша «ё» печатает ЛАТИНСКУЮ «Ë» (U+00CB), а не
        // кириллическую «Ё»: так устроена сама раскладка Apple. Раньше «Ё» получала пару только с
        // клавиши 10 («±»); без неё «Ё» не переводилась бы вовсе. Правильный ответ тот же, что у
        // строчной: шифт клавиши, которая печатает «ё», на ANSI это «~».
        //
        // ⚠️ ТОЛЬКО ЕСЛИ ПАРУ «Ё» ОТНЯЛ ИМЕННО ПРОПУСК. Раскладки, где у «Ё» пары не было и раньше,
        // не трогаем, и обратную сторону («~»→«Ë», как печатает сама раскладка) тоже.
        if skipSection, r2e["Ё"] == nil, let k = yoKey,
           translate(C, isoSectionKeyCode, true, keyboardType) == "Ё" {
            let ls = translate(L, k, true, keyboardType)
            if ls.count == 1, let l = ls.first, l != "Ё" { r2e["Ё"] = l }
        }

        addTypographicAliases(&e2r)
        return (e2r, r2e, keys)
    }

    /// keyCode 10 (`kVK_ISO_Section`): клавиша, которая физически есть только на ISO-клавиатуре.
    static let isoSectionKeyCode: UInt16 = 10

    /// Правда, если на клавиатуре этого типа клавиши 10 нет, то есть она ANSI или JIS.
    /// Тип «неизвестно» и недоступная функция дают ложь: тогда таблица строится как раньше.
    ///
    /// ⚠️ `KBGetLayoutType` БЕРЁМ ЧЕРЕЗ dlsym. Функция живая и экспортируется Carbon (проверено
    /// 26.09.2026: 91 даёт ANSI, 92 ISO, 93 JIS), но из заголовков SDK её объявление убрали, и
    /// напрямую Swift её не видит. Так же в `GlobeKey` достаётся `TISUpdateFnUsageType`.
    static func lacksISOSectionKey(keyboardType: UInt32) -> Bool {
        guard let fn = kbGetLayoutType else { return false }
        let physical = fn(Int16(truncatingIfNeeded: keyboardType))
        return physical == 0x414E_5349 /* 'ANSI' */ || physical == 0x4A49_5320 /* 'JIS ' */
    }

    private static let kbGetLayoutType: (@convention(c) (Int16) -> UInt32)? = {
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW),
              let symbol = dlsym(carbon, "KBGetLayoutType") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int16) -> UInt32).self)
    }()

    /// Типографские двойники прямых кавычек и апострофа — на те же места в таблице.
    ///
    /// ⚠️ ЗАЧЕМ (вторая половина задачи 168, отзыв #153). В текст приезжает НЕ то, что мы кладём в
    /// таблицу. Таблица строится переводом клавиш и знает прямой апостроф `'` U+0027, а в поле
    /// оказывается типографский `’` U+2019: его подставляет либо мёртвая клавиша раскладки, либо
    /// системная замена «умные кавычки», включённая почти везде по умолчанию. Незнакомый символ мы
    /// оставляли как есть, и «`'`nj» превращалось в «’то» вместо «это».
    ///
    /// ⚠️ ДЕЛАЕМ ПСЕВДОНИМАМИ ПРИ СБОРКЕ ТАБЛИЦЫ, А НЕ НОРМАЛИЗАЦИЕЙ НА КАЖДЫЙ СИМВОЛ. Конверсия
    /// живёт на горячем пути; лишний проход по строке ради редкого символа платился бы всегда, а
    /// так это один дополнительный ключ в словаре и ноль работы во время набора.
    ///
    /// ⚠️ ТИРЕ И «ЁЛОЧКИ» СЮДА НЕ ВХОДЯТ НАРОЧНО. Длинное тире и «кавычки-ёлочки» это осмысленные
    /// самостоятельные знаки, их подмена ломала бы нормальный текст. Здесь только те двойники,
    /// которые система сама подставляет вместо прямых.
    private static func addTypographicAliases(_ map: inout [Character: Character]) {
        let twins: [(Character, [Character])] = [
            ("'", ["\u{2019}", "\u{2018}", "\u{00B4}", "\u{2032}"]),   // ’ ‘ ´ ′
            ("\"", ["\u{201C}", "\u{201D}", "\u{201F}"]),              // “ ” ‟
        ]
        for (straight, curly) in twins {
            guard let target = map[straight] else { continue }
            for c in curly where map[c] == nil { map[c] = target }
        }
    }

    /// Конвертирует строку посимвольно. Символы вне таблицы — как есть.
    static func convert(_ text: String, toCyrillic: Bool) -> String {
        let map = toCyrillic ? enToRu : ruToEn
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text { out.append(map[ch] ?? ch) }
        return out
    }

    // MARK: - UCKeyTranslate

    /// Символ клавиши в этой раскладке. `shift` — с зажатым шифтом.
    ///
    /// ⚠️ МЁРТВЫЕ КЛАВИШИ ДОСТАЁМ ВТОРЫМ ПЕРЕВОДОМ (задача 168, 20.08.2026). В раскладках вроде
    /// «США международная» клавиша апострофа мёртвая: она взводится для составных символов (`\'`
    /// плюс `e` даёт `é`) и сама по себе не отдаёт НИЧЕГО — ни с флагом NoDeadKeys, ни без него,
    /// проверено стендом `Tools/DeadKeyProbe.swift`. Пустой ответ означал, что пара для этой
    /// клавиши не создавалась вовсе, и у человека с такой раскладкой «э» не мог получиться
    /// конверсией ни при каких условиях (отзыв #153: «’nj» превращалось в «’то» вместо «это»).
    ///
    /// Лечение оттуда же, из замера: перевести ту же клавишу ВТОРОЙ раз, не сбрасывая состояние.
    /// Взведённая мёртвая клавиша тогда отдаёт свой базовый символ («первый = пусто, второй = `'`»).
    ///
    /// `keyboardType` это тип клавиатуры для `UCKeyTranslate`, по умолчанию настоящий
    /// (`LMGetKbdType()`, как было всегда). От него зависит ответ: на ISO раскладка отдаёт клавишам
    /// 10 и 50 другие символы, чем на ANSI (задача 260).
    private static func translate(_ blob: Data, _ keyCode: UInt16, _ shift: Bool,
                                  _ keyboardType: UInt32 = UInt32(LMGetKbdType())) -> String {
        var dead: UInt32 = 0
        let first = translateOnce(blob, keyCode, shift, keyboardType, &dead)
        if !first.isEmpty { return first }
        return translateOnce(blob, keyCode, shift, keyboardType, &dead)  // мёртвая клавиша: её базовый символ
    }

    private static func translateOnce(_ blob: Data, _ keyCode: UInt16, _ shift: Bool,
                                      _ keyboardType: UInt32, _ dead: inout UInt32) -> String {
        let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        return blob.withUnsafeBytes { rb -> String in
            guard let layout = rb.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), mods,
                           keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &dead, buf.count, &len, &buf)
            return String(utf16CodeUnits: buf, count: len)
        }
    }

    private static func layoutData(_ src: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return (Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data)
    }
    private static func stringProp(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(src, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }
    private static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }
    private static func isLatin(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
    }
}
