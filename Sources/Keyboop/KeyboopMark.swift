import AppKit

/// Знак Keyboop — клавиша-кейкап (скруглённый квадрат-обводка) + жирная геометрическая «K» по
/// фирменному логотипу. Рисуется ЧЁРНЫМ в заданный прямоугольник → для template-иконки строки меню
/// (сама адаптируется под свет/тьму). Векторно, чтобы читалось чётко и на 16pt. (автор 2026-06-30.)
enum KeyboopMark {
    /// Нарисовать знак, вписав в квадрат по меньшей стороне rect.
    static func draw(in rect: NSRect, color: NSColor = .black) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }
        color.set()

        // Кейкап: скруглённый квадрат-обводка.
        let inset: CGFloat = 0.06
        let keycap = NSBezierPath(
            roundedRect: NSRect(x: ox + inset * s, y: oy + inset * s,
                                width: s * (1 - 2 * inset), height: s * (1 - 2 * inset)),
            xRadius: s * 0.23, yRadius: s * 0.23)
        keycap.lineWidth = s * 0.075
        keycap.lineJoinStyle = .round
        keycap.stroke()

        // «K»: жирная вертикаль + две диагонали от её середины к правым углам внутренней зоны.
        let vx0: CGFloat = 0.30, vx1: CGFloat = 0.435
        let ky0: CGFloat = 0.255, ky1: CGFloat = 0.745
        NSBezierPath(roundedRect: NSRect(x: ox + vx0 * s, y: oy + ky0 * s,
                                         width: (vx1 - vx0) * s, height: (ky1 - ky0) * s),
                     xRadius: s * 0.015, yRadius: s * 0.015).fill()

        let arm = NSBezierPath()
        arm.lineWidth = s * 0.12
        arm.lineCapStyle = .round
        arm.lineJoinStyle = .round
        let mid = P(vx1 - 0.01, 0.50)
        arm.move(to: mid); arm.line(to: P(0.72, ky1))   // верхняя рука
        arm.move(to: mid); arm.line(to: P(0.72, ky0))   // нижняя нога
        arm.stroke()
    }
}
