import Carbon
import Foundation

/// Таблиця відповідності символів між латинською та кирилічною розкладками
/// користувача, побудована З САМОЇ macOS через `UCKeyTranslate`.
///
/// Чому: статичний хардкод (`Keymap`) неточний — Apple «Ukrainian» та інші
/// варіанти кирилічних розкладок кладуть символи по різним клавішах. Динаміка читає РЕАЛЬНУ розкладку
/// і покриває всі символи (букви, цифровий Shift-ряд, кавички, дужки) для будь-якого
/// варіанта й будь-якої мовної пари. Використовується як primary; `Keymap` — fallback.
enum DynamicKeymap {
    private(set) static var enToUa: [Character: Character] = [:]
    private(set) static var uaToEn: [Character: Character] = [:]
    static var isReady: Bool { !enToUa.isEmpty }

    /// Перебудовує таблицю з включених розкладок. Ідемпотентно, дешево (~200 UCKeyTranslate).
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
            // Класифікуємо за символом клавіші 'a' (keyCode 0).
            guard let ch = translate(data, 0, false).first else { continue }
            if isCyrillic(ch), cyrillic == nil { cyrillic = data }
            else if isLatin(ch), latin == nil { latin = data }
        }
        guard let L = latin, let C = cyrillic else { return }

        var e2u: [Character: Character] = [:]
        var u2e: [Character: Character] = [:]
        // Друковані клавіші ANSI: букви, цифровий ряд, знаки — keyCodes 0…50.
        for kc in UInt16(0)...UInt16(50) {
            for shift in [false, true] {
                let ls = translate(L, kc, shift)
                let cs = translate(C, kc, shift)
                guard ls.count == 1, cs.count == 1,
                      let l = ls.first, let c = cs.first, l != c else { continue }
                if e2u[l] == nil { e2u[l] = c }
                if u2e[c] == nil { u2e[c] = l }
            }
        }
        guard !e2u.isEmpty else { return }
        enToUa = e2u
        uaToEn = u2e
    }

    /// Конвертирует строку посимвольно. Символи поза таблицею — як є.
    static func convert(_ text: String, toCyrillic: Bool) -> String {
        let map = toCyrillic ? enToUa : uaToEn
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
        return (Unmanaged<CFData>.fromOpaque(ptr).takeRetainedValue() as Data)
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
