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

    /// ИКОНКА ИЗ БАНДЛА, А НЕ ПОДМЕНЁННАЯ (14.09.2026).
    ///
    /// ⚠️ `NSApp.applicationIconImage` это ЗАПИСЫВАЕМОЕ свойство, и мы сами его подменяем, пока
    /// открыто окно истории. Всё, что рисует «иконку приложения» через него, подменённую и
    /// показывает: окно знакомства, плашки, «О программе», анимированный логотип. автор поймал это
    /// в онбординге — там красовалась иконка с подписью «История», хотя к знакомству она отношения
    /// не имеет. Кто хочет ИМЕННО значок приложения, берёт его отсюда.
    static var bundleIcon: NSImage { NSImage(named: NSImage.applicationIconName) ?? NSImage() }

    private static let historyIcon: NSImage = makeHistoryIcon()

    /// Иконка приложения с подписью-таблеткой снизу. Рисуется в 512 pt: Dock сам масштабирует.
    static func makeHistoryIcon() -> NSImage {
        let base = bundleIcon   // ⚠️ только из бандла: applicationIconImage к этому моменту уже наш же
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

    /// ⚗️ ВАРИАНТЫ ЗНАЧКА ДЛЯ ВЫБОРА (14.09.2026). Текстовая таблетка внутри иконки читается плохо
    /// и не по-маковски: в Доке она мелкая, а в ⌘Tab почти неразличима. Рисуем три кандидата, чтобы
    /// автор посмотрел глазами, а не на описание. Останется один, остальные уйдут.
    enum Badge: String, CaseIterable { case text, glyph, dot }

    static func makeHistoryIcon(_ badge: Badge) -> NSImage {
        if badge == .text { return makeHistoryIcon() }
        let base = bundleIcon
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            // Кружок в правом нижнем углу самого квадрата иконки (он занимает ~80% холста).
            let d: CGFloat = badge == .glyph ? 196 : 128
            let circle = NSRect(x: 462 - d, y: 50, width: d, height: d)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -6, dy: -6)).fill()
            DS.coral.setFill(); NSBezierPath(ovalIn: circle).fill()
            guard badge == .glyph else { return true }
            // Часы со стрелкой назад: узнаваемый системный знак «история», без единой буквы,
            // поэтому одинаково понятен на любом языке интерфейса.
            let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.56, weight: .semibold)
            if let sym = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let s = sym.size
                let box = NSRect(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2,
                                 width: s.width, height: s.height)
                NSColor.white.set()
                sym.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }

    /// Dev: снимок значка для проверки глазами (правило «посмотреть на пиксели до релиза»).
    static func writeHistoryIconPNG(to path: String) { writeHistoryIconPNG(to: path, badge: .text) }

    static func writeHistoryIconPNG(to path: String, badge: Badge) {
        let img = makeHistoryIcon(badge)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
