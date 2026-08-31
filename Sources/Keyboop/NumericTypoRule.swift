import Foundation

/// Детерминированные числовые опечатки, которые не требуют словарей.
enum NumericTypoRule {
    /// Десятичная точка, набранная на русской раскладке: `1ю8` → `1.8` (отзыв #218).
    ///
    /// Условие максимально узкое — строчная `ю` непосредственно между ASCII-цифрами. Не используем
    /// `isNumber`: арабские, полноширинные и прочие цифры не приходят с цифрового ряда русской
    /// раскладки, а значит приписывать им клавиатурную ошибку без доказательств нельзя.
    static func suggestion(for text: String) -> String? {
        var chars = Array(text)
        guard chars.count >= 3 else { return nil }

        func isASCIIDigit(_ ch: Character) -> Bool {
            guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
            return scalar.value >= 48 && scalar.value <= 57
        }

        var changed = false
        for i in 1..<(chars.count - 1) {
            guard chars[i] == "ю", isASCIIDigit(chars[i - 1]), isASCIIDigit(chars[i + 1]) else { continue }
            chars[i] = "."
            changed = true
        }
        return changed ? String(chars) : nil
    }
}
