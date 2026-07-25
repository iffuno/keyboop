import ApplicationServices
import Foundation

/// «Экранная правда» перед заменой: хвост текста ДО каретки в фокусном элементе.
///
/// Фантомный предохранитель (24.07). Весь день фантомы имели одну форму: буфер разошёлся с экраном
/// (стейл-переводы TIS/событий), и конверсия перепечатывала слово САМО В СЕБЯ — звук и анимация без
/// видимой пользы. Источников рассинхрона несколько, и ловить каждый по отдельности — гонка с
/// эпициклами. Этот предохранитель бьёт по следствию у всех сразу: прямо перед авто-заменой
/// спрашиваем ЭКРАН; если там уже итог конверсии — заменять нечего.
///
/// Только ЧТЕНИЕ через AX (буфер обмена не участвует — принцип №1; содержимое в лог не пишем —
/// принцип №2). Electron/веб, где AX молчит или врёт, возвращают nil → ведём себя как раньше.
/// Читаем последние N символов через kAXStringForRange (НЕ весь kAXValue: в редакторе документ
/// может весить мегабайты).
enum AXScreenCheck {
    /// Последние maxLen символов до каретки; nil = экран не читается (нет фокуса / AX не отвечает /
    /// есть выделение — тогда «текст до каретки» неоднозначен).
    static func textBeforeCaret(maxLen: Int) -> String? {
        let sys = AXUIElementCreateSystemWide()
        // ЖЁСТКИЙ ТАЙМАУТ 50мс (ревью research 24.07): AXUIElementCopy* — синхронный IPC, который
        // обслуживает main-цикл ЦЕЛЕВОГО приложения. Занято оно спиннером — мы бы висели секунды
        // на СВОЁМ main, где живёт event tap → kCGEventTapDisabledByTimeout → «ввод не работает
        // нигде» (класс инцидента 21.07). С таймаутом худший случай — 2×50мс и честный nil.
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return nil }
        let el = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(el, 0.05)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeAny = rangeRef, CFGetTypeID(rangeAny) == AXValueGetTypeID() else { return nil }
        let rangeVal = unsafeDowncast(rangeAny as AnyObject, to: AXValue.self)
        var sel = CFRange()
        guard AXValueGetValue(rangeVal, .cfRange, &sel), sel.length == 0, sel.location > 0 else { return nil }
        let start = max(0, sel.location - maxLen)
        var want = CFRange(location: start, length: sel.location - start)
        guard let wantVal = AXValueCreate(.cfRange, &want) else { return nil }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  el, kAXStringForRangeParameterizedAttribute as CFString, wantVal, &strRef) == .success,
              let s = strRef as? String else { return nil }
        return s
    }

    /// Текст до каретки уже заканчивается этим суффиксом? nil = не знаем (AX молчит) — тогда
    /// вызывающий действует как раньше. Пробельный хвост сравниваем без придирок к \u{00A0}.
    static func caretEndsWith(_ suffix: String) -> Bool? {
        guard !suffix.isEmpty else { return nil }
        guard let tail = textBeforeCaret(maxLen: suffix.count + 8) else { return nil }
        let norm = { (s: String) in s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        return norm(tail).hasSuffix(norm(suffix))
    }
}
