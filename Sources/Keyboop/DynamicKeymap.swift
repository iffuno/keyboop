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
    static func rebuild() {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(cf)
        var latin: Data? = nil
        var cyrillic: Data? = nil
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard boolProp(src, kTISPropertyInputSourceIsSelectCapable),
                  let data = layoutData(src) else { continue }
            // Классифицируем по символу клавиши 'a' (keyCode 0).
            guard let ch = translate(data, 0, false).first else { continue }
            if isCyrillic(ch), cyrillic == nil { cyrillic = data }
            else if isLatin(ch), latin == nil { latin = data }
        }
        guard let L = latin, let C = cyrillic else { return }

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
        enToRu = e2r
        ruToEn = r2e
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

    private static func translate(_ data: Data, _ keyCode: UInt16, _ shift: Bool) -> String {
        data.withUnsafeBytes { raw -> String in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var dead: UInt32 = 0
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
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
