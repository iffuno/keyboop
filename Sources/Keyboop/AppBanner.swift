import AppKit

/// Своё всплывающее окно-баннер вместо системных уведомлений (UNUserNotification): без запроса
/// разрешений, без лишнего раздражения, полный контроль над видом. Появляется вверху справа под
/// меню-баром — как нативное уведомление, но это НАШЕ окно. Тёмный HUD-материал + coral.
/// Применяется: предложение обновления (2 кнопки) и инфо «выучил слово» (авто-скрытие).
final class AppBanner {
    static let shared = AppBanner()

    /// Кнопка баннера. `coral` — основной (залитый) стиль; иначе обычная.
    struct Action { let title: String; let coral: Bool; let handler: () -> Void }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var actionHandlers: [() -> Void] = []

    /// Показать баннер. `actions` пусто → инфо-баннер. `autoDismiss` > 0 → сам скроется через N сек.
    func show(title: String, body: String, actions: [Action] = [], autoDismiss: TimeInterval = 0) {
        DispatchQueue.main.async { self.present(title: title, body: body, actions: actions, autoDismiss: autoDismiss) }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18; p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in p.orderOut(nil); self?.panel = nil })
    }

    // MARK: present

    private func present(title: String, body: String, actions: [Action], autoDismiss: TimeInterval) {
        dismiss(); dismissTimer?.invalidate()
        let width: CGFloat = 420   // = makeContent width
        // Сплошной тёмный фон (не HUD-блюр): коралловая кнопка играет, вид как в нашем рендере — чище.
        let (content, height) = makeContent(title: title, body: body, actions: actions, solidDarkBG: true)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 14
        let rect = NSRect(x: screen.maxX - width - margin, y: screen.maxY - height - margin, width: width, height: height)

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        if autoDismiss > 0 {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismiss, repeats: false) { [weak self] _ in self?.dismiss() }
        }
    }

    // MARK: content (общее для показа и off-screen рендера)

    /// `solidDarkBG` — тёмная заливка вместо живого HUD-блюра (блюр off-screen не рисуется).
    ///
    /// Композиция: крупный логотип слева во всю высоту карточки, справа от него — ОДНА колонка
    /// (заголовок → текст → кнопки), выровненная по единой левой линии. Левый край левой кнопки
    /// стоит ровно под текстом, ничего не «торчит» в сторону. Логотип отцентрован по высоте колонки.
    private func makeContent(title: String, body: String, actions: [Action], solidDarkBG: Bool = false) -> (NSView, CGFloat) {
        let width: CGFloat = 420
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
        content.layer?.cornerRadius = 18
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        // Логотип — крупный (~на высоту трёх строк текста), якорь всей композиции.
        let icon = NSImageView(); icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
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

        // Правая колонка: текст + кнопки, всё по одной левой линии.
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
        rightCol.alignment = .leading; rightCol.spacing = 14

        let row = NSStackView(views: [icon, rightCol]); row.orientation = .horizontal
        row.spacing = 16; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)   // ровные щедрые поля
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: width)
        ])

        // × — в правом верхнем углу (абсолютно, не влияет на раскладку).
        let close = NSButton(title: "", target: self, action: #selector(closeTapped))
        close.isBordered = false; close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть")
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .tertiaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -13),
            close.widthAnchor.constraint(equalToConstant: 15),
            close.heightAnchor.constraint(equalToConstant: 15)
        ])

        content.layoutSubtreeIfNeeded()
        return (content, content.fittingSize.height)
    }

    /// Кнопка-«пилюля» с ГАРАНТИРОВАННЫМ цветом (layer-фон + белый/светлый текст), а не капризный
    /// bezelColor (он в живом окне на тёмном HUD не красился — выходил серым).
    private func pillButton(_ title: String, coral: Bool, tag: Int) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(actionTapped(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.layer?.cornerCurve = .continuous
        b.layer?.backgroundColor = (coral ? DS.coral : NSColor.white.withAlphaComponent(0.14)).cgColor
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: coral ? NSColor.white : NSColor.labelColor, .font: font])
        let tw = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: tw + 32).isActive = true   // ~16px поля по бокам
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Off-screen рендер образца баннера в PNG (dev-хук визуальной проверки; язык — по L10n.current).
    func renderSample(to path: String) {
        let (content, height) = makeContent(
            title: String(format: L10n.t("upd.notifyTitle"), "0.2.4"), body: L10n.t("upd.notifyBody"),
            actions: [.init(title: L10n.t("upd.now"), coral: true) {}, .init(title: L10n.t("upd.autoShort"), coral: false) {}],
            solidDarkBG: true)
        content.appearance = NSAppearance(named: .darkAqua)
        content.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    @objc private func actionTapped(_ s: NSButton) {
        let h = actionHandlers[safe: s.tag]; dismiss(); h?()
    }
    @objc private func closeTapped() { dismiss() }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
