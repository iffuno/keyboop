import AppKit

/// Своё всплывающее окно-баннер вместо системных уведомлений (UNUserNotification): без запроса
/// разрешений, без лишнего раздражения, полный контроль над видом. Появляется вверху справа под
/// меню-баром — как нативное уведомление, но это НАШЕ окно. Тёмный фон + coral.
/// Два вида: ИНФО-тост (без кнопок) — компактный, авто-скрытие, клик/свайп/× закрывают;
/// и баннер-вопрос/обновление (с кнопками) — ждёт решения.
final class AppBanner {
    static let shared = AppBanner()

    /// Кнопка баннера. `coral` — основной (залитый) стиль; иначе обычная.
    struct Action { let title: String; let coral: Bool; let handler: () -> Void }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var actionHandlers: [() -> Void] = []
    private var restX: CGFloat = 0          // x в покое (для свайпа/возврата)

    /// Показать баннер. `actions` пусто → инфо-тост. `autoDismiss` > 0 → сам скроется через N сек.
    func show(title: String, body: String, actions: [Action] = [], autoDismiss: TimeInterval = 0) {
        DispatchQueue.main.async { self.present(title: title, body: body, actions: actions, autoDismiss: autoDismiss) }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18; p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    // MARK: present

    private func present(title: String, body: String, actions: [Action], autoDismiss: TimeInterval) {
        dismiss(); dismissTimer?.invalidate()
        let (content, width, height) = makeContent(title: title, body: body, actions: actions, solidDarkBG: true)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 14
        let rect = NSRect(x: screen.maxX - width - margin, y: screen.maxY - height - margin, width: width, height: height)
        restX = rect.minX

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Баннер всегда на тёмно-сером фоне (0.15) — пиннем тёмную тему, иначе в СВЕТЛОЙ системной
        // теме .labelColor/.secondaryLabelColor резолвятся в тёмный → тёмный текст на тёмном (автор
        // поймал «серое окошко с чёрным шрифтом»). Раньше пиннилось только в dev-хуке renderSample.
        p.appearance = NSAppearance(named: .darkAqua)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = content
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.setFrame(NSRect(x: rect.minX, y: rect.minY + 8, width: width, height: height), display: false)  // слайд-ин
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 1
            p.animator().setFrame(rect, display: true)
        }
        panel = p

        // Свайп вправо → закрыть (как у нативных уведомлений). Работает в обоих видах.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // ⚠️ НЕ ЗАДЕРЖИВАТЬ нажатие мыши (фикс 30.07). По умолчанию распознаватель придерживает
        // mouseDown у себя, пока не решит, жест это или нет, и отдаёт вью только задним числом. Для
        // кнопки внутри контейнера это означает сорванный цикл отслеживания нажатия: визуально
        // «кнопка не реагирует». Свайпу вправо задержка не нужна, он опознаётся по движению.
        pan.delaysPrimaryMouseButtonEvents = false
        content.addGestureRecognizer(pan)
        // Инфо-тост (без кнопок) — клик по нему тоже закрывает (кнопок нет, не конфликтует).
        if actions.isEmpty {
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            content.addGestureRecognizer(click)
        }

        // Авто-скрытие — таймер в .common, чтобы срабатывал даже во время трекинга/скролла.
        if autoDismiss > 0 {
            let t = Timer(timeInterval: autoDismiss, repeats: false) { [weak self] _ in self?.dismiss() }
            RunLoop.main.add(t, forMode: .common)
            dismissTimer = t
        }
    }

    // MARK: content

    /// Возвращает (вью, ширина, высота). ИНФО-тост (actions пусто): компактный — логотип слева с
    /// равными полями сверху/снизу/слева, ширина по контенту. Баннер с кнопками: крупный логотип + колонка.
    private func makeContent(title: String, body: String, actions: [Action], solidDarkBG: Bool = false) -> (NSView, CGFloat, CGFloat) {
        let compact = actions.isEmpty
        let maxW: CGFloat = 420
        let pad: CGFloat = compact ? 14 : 18          // равные поля (сверху/снизу/слева)
        let rightPad: CGFloat = compact ? 34 : 22     // справа чуть больше — под крестик
        let iconSize: CGFloat = compact ? 40 : 60
        let gap: CGFloat = compact ? 12 : 16

        let content: NSView
        if solidDarkBG {
            let v = NSView(); v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
            content = v
        } else {
            let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            content = v
        }
        content.wantsLayer = true
        content.layer?.cornerRadius = compact ? 14 : 18
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let icon = NSImageView(); icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleL = NSTextField(labelWithString: title)
        titleL.font = .systemFont(ofSize: 14.5, weight: .semibold); titleL.textColor = .labelColor
        titleL.lineBreakMode = .byTruncatingTail
        let bodyL = NSTextField(labelWithString: body)
        bodyL.font = .systemFont(ofSize: 12.5); bodyL.textColor = .secondaryLabelColor
        bodyL.lineBreakMode = .byWordWrapping; bodyL.maximumNumberOfLines = 2
        bodyL.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textCol = NSStackView(views: [titleL, bodyL]); textCol.orientation = .vertical
        textCol.alignment = .leading; textCol.spacing = 3

        var colRows: [NSView] = [textCol]
        if !actions.isEmpty {
            actionHandlers = actions.map { $0.handler }
            let btns: [NSView] = actions.enumerated().map { (i, a) in pillButton(a.title, coral: a.coral, tag: i) }
            let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            let btnRow = NSStackView(views: btns + [spacer]); btnRow.orientation = .horizontal
            btnRow.spacing = 10; btnRow.alignment = .centerY
            colRows.append(btnRow)
        }
        let rightCol = NSStackView(views: colRows); rightCol.orientation = .vertical
        rightCol.alignment = .leading; rightCol.spacing = 12

        let row = NSStackView(views: [icon, rightCol]); row.orientation = .horizontal
        row.spacing = gap; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: rightPad)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Ширина: с кнопками — фиксированные 420 (тексту есть где переноситься); тост — по контенту (до maxW).
        // ⚠️ ШИРИНА ПО СОДЕРЖИМОМУ И ДЛЯ БАННЕРА С КНОПКАМИ (30.07). Раньше она была прибита к 420
        // независимо от текста, и на коротких строках справа зияла пустота — заметно на английском,
        // где всё короче русского («Either button installs it now»). Теперь ширину диктует контент,
        // но в рамках: не шире maxW (иначе плашка растёт на пол-экрана и текст перестаёт переноситься)
        // и не у́же minW (иначе две кнопки в ряд начинают тесниться и лепиться друг к другу).
        let minW: CGFloat = compact ? 0 : 340
        var widthC: NSLayoutConstraint? = nil
        content.layoutSubtreeIfNeeded()
        var w = min(max(content.fittingSize.width, minW), maxW)
        if content.fittingSize.width > maxW || content.fittingSize.width < minW {
            widthC = content.widthAnchor.constraint(equalToConstant: w); widthC!.isActive = true
            content.layoutSubtreeIfNeeded()
        }

        // × — в правом верхнем углу (поверх, не влияет на раскладку). FirstMouseButton — иначе первый
        // клик по неактивной .nonactivatingPanel macOS глотает и кнопка кажется «мёртвой».
        let close = FirstMouseButton(title: "", target: self, action: #selector(closeTapped))
        close.isBordered = false; close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("act.close"))
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .tertiaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16)
        ])

        content.layoutSubtreeIfNeeded()
        return (content, w, content.fittingSize.height)
    }

    /// Кнопка-«пилюля» с гарантированным цветом (layer-фон). FirstMouseButton — первый клик срабатывает.
    private func pillButton(_ title: String, coral: Bool, tag: Int) -> NSButton {
        let b = FirstMouseButton(title: "", target: self, action: #selector(actionTapped(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.cornerCurve = .continuous
        b.layer?.backgroundColor = (coral ? DS.coral : NSColor.white.withAlphaComponent(0.14)).cgColor
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: coral ? NSColor.white : NSColor.labelColor, .font: font])
        let tw = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        b.translatesAutoresizingMaskIntoConstraints = false
        // Пилюля по тексту плюс воздух с боков, а не «кнопка на всю ширину»: две штуки в ряд
        // должны укладываться в 420pt вместе с полями, иначе правая упирается в край плашки.
        b.widthAnchor.constraint(equalToConstant: tw + 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Off-screen рендер образца баннера в PNG (dev-хук визуальной проверки; язык — по L10n.current).
    func renderSample(to path: String) {
        let (content, width, height) = makeContent(
            title: String(format: L10n.t("upd.notifyTitle"), "0.2.4"), body: L10n.t("upd.notifyBody"),
            // ⚠️ Цвета КАК В БОЮ (30.07): левая серая, правая коралловая. Раньше образец рисовал
            // наоборот и тихо врал — визуальную проверку по нему делать было нельзя.
            actions: [.init(title: L10n.t("upd.now"), coral: false) {}, .init(title: L10n.t("upd.autoShort"), coral: true) {}],
            solidDarkBG: true)
        content.appearance = NSAppearance(named: .darkAqua)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: жесты

    @objc private func handleClick(_ g: NSClickGestureRecognizer) { dismiss() }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        guard let p = panel else { return }
        let tx = g.translation(in: nil).x
        switch g.state {
        case .changed:
            var f = p.frame; f.origin.x = restX + max(0, tx); p.setFrame(f, display: true)   // тянем только вправо
        case .ended, .cancelled, .failed:
            if tx > 60 {                                   // свайп достаточный → улетает вправо и закрывается
                dismissTimer?.invalidate(); dismissTimer = nil
                let win = p; panel = nil
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.16
                    var f = win.frame; f.origin.x += 360; win.animator().setFrame(f, display: true)
                    win.animator().alphaValue = 0
                }, completionHandler: { win.orderOut(nil) })
            } else {                                       // недостаточно → возврат на место
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    var f = p.frame; f.origin.x = restX; p.animator().setFrame(f, display: true)
                }
            }
        default: break
        }
    }

    @objc private func actionTapped(_ s: NSButton) {
        // Лог, потому что «нажал и ничего» мы уже один раз разбирали вслепую: теперь видно, дошло
        // нажатие до нас или нет, и был ли под кнопкой обработчик.
        let h = actionHandlers[safe: s.tag]
        kbLog("баннер: нажата кнопка \(s.tag)\(h == nil ? " — обработчика нет!" : "")")
        dismiss(); h?()
    }
    @objc private func closeTapped() { kbLog("баннер: закрыт крестиком"); dismiss() }
}

/// Кнопка, реагирующая на ПЕРВЫЙ клик даже когда окно неактивно (.nonactivatingPanel).
/// Без этого первый клик по × / кнопкам баннера macOS «съедает» — кнопка кажется мёртвой.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⚠️ ВСЯ ПЛОЩАДЬ КНОПКИ КЛИКАБЕЛЬНА (фикс 30.07, срочный баг-репорт: «в плашке об обновлении
    /// не нажимаются кнопки, работает только крестик»).
    ///
    /// У безрамочной NSButton (`isBordered = false`) зона попадания считается по СОДЕРЖИМОМУ ячейки,
    /// то есть по нарисованному тексту. У наших кнопок-пилюль фон — это слой, а не рамка, и он
    /// заметно шире надписи: человек целится в коралловый прямоугольник, попадает в пустоту вокруг
    /// букв, и кнопка выглядит мёртвой. Крестик при этом работал и сбивал с толку: у него
    /// содержимое — картинка, растянутая на все 16×16, то есть совпадает с рамкой.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
