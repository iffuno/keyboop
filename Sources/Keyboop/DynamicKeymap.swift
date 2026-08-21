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
    static var isReady: Bool { !enToRu.isEmpty }

    /// Перестраивает таблицу из включённых раскладок. Идемпотентно, дёшево (~200 UCKeyTranslate).
    /// `preferLat`/`preferCyr` — идентификаторы раскладок, которые человек выбрал сам (их хранит
    /// `LayoutManager`). Пустые строки означают «бери что найдёшь», как было раньше.
    ///
    /// ⚠️ НАСТРОЙКИ СЮДА НЕ ТЯНЕМ, ИХ ПЕРЕДАЁТ ВЫЗЫВАЮЩИЙ. Первая версия правки читала
    /// `AppSettings.shared` прямо здесь, и четыре стенда перестали собираться: они компилируют
    /// только нужный им срез файлов, а такая зависимость тянет за собой AppKit. Низкоуровневой
    /// таблице символов знать про настройки и не положено.
    static func rebuild(preferLat: String = "", preferCyr: String = "") {
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
            guard let ch = translate(data, 0, false).first else { continue }
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

        var e2r: [Character: Character] = [:]
        var r2e: [Character: Character] = [:]
        // Печатные клавиши ANSI: буквы, цифровой ряд, знаки — keyCodes 0…50.
        for kc in UInt16(0)...UInt16(50) {
            for shift in [false, true] {
                let ls = translate(L, kc, shift)
                let cs = translate(C, kc, shift)
                guard ls.count == 1, cs.count == 1,
                      let l = ls.first, let c = cs.first, l != c else { continue }
                if e2r[l] == nil { e2r[l] = c }
                if r2e[c] == nil { r2e[c] = l }
            }
        }
        guard !e2r.isEmpty else { return }
        addTypographicAliases(&e2r)
        enToRu = e2r
        ruToEn = r2e
    }

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
    private static func translate(_ blob: Data, _ keyCode: UInt16, _ shift: Bool) -> String {
        var dead: UInt32 = 0
        let first = translateOnce(blob, keyCode, shift, &dead)
        if !first.isEmpty { return first }
        return translateOnce(blob, keyCode, shift, &dead)     // мёртвая клавиша: её базовый символ
    }

    private static func translateOnce(_ blob: Data, _ keyCode: UInt16, _ shift: Bool,
                                      _ dead: inout UInt32) -> String {
        var mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        return blob.withUnsafeBytes { rb -> String in
            guard let layout = rb.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), mods,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
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
