import Carbon
import Foundation

/// Стабильная подпись ФИЗИЧЕСКОЙ клавиши по keyCode — НЕ зависит от текущей раскладки.
///
/// Проблема (автор 2026-06-30): подпись хоткея капчерилась из `charactersIgnoringModifiers`. При записи
/// на РУ-раскладке клавиша `` ` `` (keyCode 50) сохранялась как «ё» (там на ЙЦУКЕН ё), хотя на железе
/// Mac это `` ` ``/`~` — буква «ё» вообще на клавише `\`. Пользователи путались: «⌥`» показывался как
/// «⌥ё». Решение: транслируем keyCode через ASCII-capable раскладку (ABC/U.S., всегда доступна) →
/// латинский символ клавиши, как он подписан на корпусе, для любой текущей раскладки.
enum KeyLabels {
    /// Несимвольные клавиши — собственные имена/символы.
    private static let special: [Int: String] = [
        49: "Space", 36: "⏎", 48: "⇥", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Символ клавиши для подписи хоткея (буквы — в верхнем регистре). "" — если не удалось.
    static func symbol(forKeyCode keyCode: Int) -> String {
        if keyCode < 0 { return "" }
        if let s = special[keyCode] { return s }
        if let ch = asciiChar(forKeyCode: UInt16(keyCode)), !ch.isEmpty { return ch.uppercased() }
        return ""
    }

    /// keyCode → символ через ASCII-capable раскладку (ABC/U.S.), без зависимости от текущей.
    private static func asciiChar(forKeyCode keyCode: UInt16) -> String? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &dead, buf.count, &len, &buf)
            let s = String(utf16CodeUnits: buf, count: len)
            return s.isEmpty ? nil : s
        }
    }
}
