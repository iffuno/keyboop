import ApplicationServices
import AppKit

/// Экранное положение КАРЕТКИ ВВОДА ТЕКСТА (мигающего курсора) через Accessibility — чтобы плашка
/// «Слушаю» появлялась у места ввода, а не у курсора мыши. Работает в нативных полях (TextEdit, Notes,
/// Mail, Pages, поля Safari…). Electron/web (Chrome, VS Code, Slack) часто не отдают bounds каретки →
/// возвращаем nil, и вызывающий падает на позицию мыши. (автор 2026-06-30.)
enum CaretLocator {

    /// Прямоугольник каретки в Cocoa-координатах (origin снизу-слева). nil — если недоступно.
    static func caretScreenRect() -> NSRect? {
        let sys = AXUIElementCreateSystemWide()
        // Кап на AX-сообщения: не вешаем старт диктовки, если фронтальное приложение тупит.
        AXUIElementSetMessagingTimeout(sys, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let rawEl = focused, CFGetTypeID(rawEl) == AXUIElementGetTypeID() else { return nil }
        let element = rawEl as! AXUIElement

        // Диапазон выделения/каретки (каретка = длина 0 в позиции курсора).
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range) else { return nil }
        let loc = max(range.location, 0)

        // bounds диапазона — устойчиво: (1) сама каретка длины 0 (истинная позиция; многие поля
        // отдают её напрямую); (2) символ У каретки (loc,1); (3) символ ПЕРЕД кареткой (loc-1,1) →
        // каретка на его правом краю. Пункт 3 закрывает КЛЮЧЕВОЙ кейс диктовки: каретка в КОНЦЕ
        // текста (или поле пустое) — тогда (loc,1) за концом строки и падает.
        func bounds(_ l: Int, _ n: Int) -> CGRect? {
            var r = CFRange(location: l, length: n)
            guard l >= 0, let v = AXValueCreate(.cfRange, &r) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, v, &ref) == .success,
                  let rr = ref, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
            var q = CGRect.zero
            guard AXValueGetValue(rr as! AXValue, .cgRect, &q),
                  q.origin.x.isFinite, q.origin.y.isFinite, q.width.isFinite, q.height.isFinite,
                  q.height > 0 else { return nil }
            return q
        }

        var quartz = bounds(loc, 0)
        if quartz == nil { quartz = bounds(loc, 1) }
        if quartz == nil, loc > 0, let before = bounds(loc - 1, 1) {
            quartz = CGRect(x: before.maxX, y: before.origin.y, width: 1, height: before.height)
        }
        guard let q = quartz, q != .zero else { return nil }
        return flipToCocoa(q)
    }

    /// Quartz global (origin top-left главного экрана) → Cocoa (origin bottom-left главного экрана).
    private static func flipToCocoa(_ r: CGRect) -> NSRect {
        guard let main = NSScreen.screens.first else { return r }   // screens[0] = главный, origin (0,0) в Cocoa
        let mainHeight = main.frame.height
        return NSRect(x: r.origin.x, y: mainHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
