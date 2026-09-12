import AppKit

/// Значок в Dock, пока открыто окно, к которому человек захочет вернуться.
///
/// У LSUIElement-агента значка нет. Настройки включали его для себя с июля (меню-бар у многих
/// переполнен, и Dock это надёжный путь обратно). 04.09.2026 автор попросил того же для окна
/// истории: «если я куда-то нажал и окно оказалось под другим, его сложно потом найти, если заново
/// не вызывать через меню». Причин стало две, и закрытие одного окна не должно прятать значок, пока
/// открыто другое, поэтому политика активации собрана здесь, а не в каждом окне.
///
/// Значок истории отличается подписью (автор: «попробуем написать History или какое-то другое
/// слово, чтобы понятно было, что это не основное меню настроек»). Иначе в Dock стояли бы две
/// одинаковые «K», и по ним не понять, какая вернёт расшифровку, а какая настройки. Подпись словом,
/// не цветом: цвет никогда не носитель смысла.
enum DockPresence {
    enum Reason: Hashable { case settings, history }
    private static var reasons = Set<Reason>()

    static func acquire(_ r: Reason) { reasons.insert(r); apply() }
    static func release(_ r: Reason) { reasons.remove(r); apply() }
    static var showsHistory: Bool { reasons.contains(.history) }

    private static func apply() {
        if reasons.isEmpty {
            NSApp.applicationIconImage = nil            // nil = штатная иконка бандла
            NSApp.setActivationPolicy(.accessory)       // снова чистый агент
            return
        }
        NSApp.applicationIconImage = reasons.contains(.history) ? historyIcon : nil
        NSApp.setActivationPolicy(.regular)
    }

    private static let historyIcon: NSImage = makeHistoryIcon()

    /// Иконка приложения с подписью-таблеткой снизу. Рисуется в 512 pt: Dock сам масштабирует.
    static func makeHistoryIcon() -> NSImage {
        let base = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage ?? NSImage()
        let label = L10n.t("dock.history")
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            // Шрифт подбираем под ширину: «История» и «History» разной длины, а таблетка должна
            // оставаться ВНУТРИ скруглённого квадрата иконки. Сам квадрат занимает только ~80%
            // холста 512 (стандартные поля иконок macOS, x ≈ 50…462), и первый рендер с таблеткой
            // по всему холсту вылез за его края.
            var fontSize: CGFloat = 78
            var attrs: [NSAttributedString.Key: Any] = [:]
            var textSize = NSSize.zero
            repeat {
                attrs = [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white]
                textSize = (label as NSString).size(withAttributes: attrs)
                fontSize -= 4
            } while textSize.width > 264 && fontSize > 36
            let pillH = textSize.height + 18
            let pillW = textSize.width + 56
            let pill = NSRect(x: (rect.width - pillW) / 2, y: 82, width: pillW, height: pillH)
            let path = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
            DS.coral.setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.28).setStroke(); path.lineWidth = 3; path.stroke()
            (label as NSString).draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                                     withAttributes: attrs)
            return true
        }
    }

    /// Dev: снимок значка для проверки глазами (правило «посмотреть на пиксели до релиза»).
    static func writeHistoryIconPNG(to path: String) {
        let img = makeHistoryIcon()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
