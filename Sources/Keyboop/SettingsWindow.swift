import AppKit
import QuartzCore
import AVFoundation
import UniformTypeIdentifiers

/// Дизайн-система Keyboop — единая шкала (8-pt grid), чтобы интерфейс был
/// системным и «вне времени». Числа из Apple HIG (Layout / Sidebars / Typography).
enum DS {
    // Sidebar
    static let sidebarWidth: CGFloat = 220
    static let rowHeight: CGFloat = 32
    static let rowGap: CGFloat = 2
    static let pillInsetH: CGFloat = 9      // капсула выделения отступает от краёв sidebar
    static let rowLeadingInset: CGFloat = 12 // иконка от левого края капсулы
    static let iconTextGap: CGFloat = 9
    static let iconPointSize: CGFloat = 14
    static let pillRadius: CGFloat = 6        // concentric с control-радиусами Tahoe
    // Content
    static let contentMaxWidth: CGFloat = 600 // Apple grouped-form cap (macOS 15+); контент НЕ растягивается
    static let contentWidth: CGFloat = 480    // ФИКС ширина блока настроек: прижат влево, поля узкие
    static let contentMargin: CGFloat = 24
    /// Минимальная ширина окна = sidebar + поле + блок + правое поле → блок всегда влезает.
    static let minWindowWidth: CGFloat = 220 + 24 + 480 + 28   // = 752
    static let sectionGap: CGFloat = 18
    static let itemGap: CGFloat = 10
    // Поля ввода
    static let fieldMaxWidth: CGFloat = 360
    /// Фирменный coral-акцент (#FF7A59) — направление B (инженерный blueprint).
    static let coral = NSColor(srgbRed: 1.0, green: 122.0/255.0, blue: 89.0/255.0, alpha: 1)
    /// Графит (#1C1B1A) — тёмная подложка бренда (герой сайта/онбординга, blueprint-фон).
    static let graphite = NSColor(srgbRed: 0x1C/255.0, green: 0x1B/255.0, blue: 0x1A/255.0, alpha: 1)
}

enum SettingsSection: Int, CaseIterable {
    case switching, exceptions, snippets, translate, voice, general, updates, privacy, about
    var l10nKey: String {
        switch self {
        case .switching: return "sec.switching"
        case .exceptions: return "sec.exceptions"
        case .snippets:   return "sec.snippets"
        case .translate:  return "sec.translate"
        case .voice:      return "sec.voice"
        case .general:    return "sec.general"
        case .updates:    return "sec.updates"
        case .privacy:    return "sec.privacy"
        case .about:      return "sec.about"
        }
    }
    var symbol: String {
        switch self {
        case .switching: return "keyboard"
        case .exceptions: return "tag"
        case .snippets:   return "wand.and.stars"
        case .translate:  return "character.bubble"
        case .voice:      return "mic"
        case .general:    return "gearshape"
        case .updates:    return "arrow.triangle.2.circlepath"
        case .privacy:    return "lock.shield"
        case .about:      return "info.circle"
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let split = NSSplitViewController()
    private let sidebar = SidebarVC()
    private let detail = DetailVC()

    convenience init() {
        let de = ProcessInfo.processInfo.environment
        let w0: CGFloat = (de["KEYBOOP_DUMP"] == "1" || de["KEYBOOP_LIVEDIAG"] == "1") ? 1040 : DS.minWindowWidth + 24
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w0, height: 700),  // плейсхолдер; реальная высота — по контенту (ниже)
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // КРИТИЧНО: не восстанавливать прошлый (мелкий ~500pt) размер из Saved Application State —
        // именно он перебивал наш дефолт и давал скролл. Открываем всегда на h0, сжать можно.
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Keyboop"
        window.minSize = NSSize(width: DS.minWindowWidth, height: 420)
        self.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = DS.sidebarWidth
        sidebarItem.maximumThickness = DS.sidebarWidth
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: detail)
        if #available(macOS 26.0, *) { detailItem.automaticallyAdjustsSafeAreaInsets = true }
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        // ПОСЛЕ contentViewController (иначе split диктует свой ~500pt): высота АВТО по самому
        // длинному разделу (+поля колонки +небольшой запас), но не выше видимой части экрана.
        let needed = detail.tallestSectionHeight() + DS.contentMargin * 2 + 16
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 1000) - 40
        window.setContentSize(NSSize(width: w0, height: min(needed, screenMaxH)))
        window.center()
        // Окно тянется ТОЛЬКО по высоте: ширина контента фиксирована (поля прижаты влево, тянуть
        // вширь незачем и некрасиво). minSize.width == maxSize.width → горизонтальный ресайз запрещён.
        let fixedW = window.frame.width
        window.minSize = NSSize(width: fixedW, height: 420)
        window.maxSize = NSSize(width: fixedW, height: 100_000)

        sidebar.onSelect = { [weak self] s in self?.detail.show(s) }
        detail.onLanguageChanged = { [weak self] in
            self?.sidebar.refreshTitles()
            self?.detail.reshow()
        }
        sidebar.select(0, animated: false)
    }

    func show(section: SettingsSection? = nil) {
        detail.reload()
        if let section { sidebar.select(section.rawValue, animated: false) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dev: отрендерить раздел в PNG (отладка дизайна без Screen Recording).
    func dump(section i: Int, to path: String) {
        window?.appearance = NSAppearance(named: .darkAqua)   // как видит юзер (тёмная тема)
        sidebar.select(i, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let base = (path as NSString).deletingPathExtension
        // Числа геометрии (без рендера — надёжно): видно, шире ли docView, чем viewport, и где колонка.
        try? detail.layoutDiag().write(toFile: base + "_diag.txt", atomically: true, encoding: .utf8)
        if let png = detail.renderColumnPNG() { try? png.write(to: URL(fileURLWithPath: base + ".png")) }
        if let png = detail.renderColumnPNG(extraRight: 180, forceWidth: 392) {
            try? png.write(to: URL(fileURLWithPath: base + "_narrow.png"))
        }
    }
    func windowWillClose(_ notification: Notification) { detail.saveAll() }
    /// Обновить поля (напр. список «Выученные» после обучения на отмене), если окно открыто.
    func reload() { if window?.isVisible == true { detail.reload() } }

    /// Dev: живая диагностика ТЕКУЩЕГО раздела (без re-select/forced-layout) — после settle окна.
    func liveDiag(to path: String) {
        let wh = window?.frame.height ?? -1
        let screenH = NSScreen.main?.visibleFrame.height ?? -1
        let s = "windowH=\(Int(wh)) screenVisibleH=\(Int(screenH))\n" + detail.liveDiag()
        try? s.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Dev: снимок ВСЕГО окна (sidebar+detail) как видит пользователь — тёмная тема, реальные
    /// пропорции. Требует KEYBOOP_WINSHOT (непрозрачные фоны sidebar/detail → cacheDisplay ок).
    func dumpFullWindow(section i: Int, to path: String) {
        window?.appearance = NSAppearance(named: .darkAqua)
        sidebar.select(i, animated: false)
        guard let root = window?.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let b = root.bounds
        guard b.width > 1, b.height > 1,
              let rep = root.bitmapImageRepForCachingDisplay(in: b) else { return }
        root.cacheDisplay(in: b, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Sidebar: перетекающее выделение (Liquid-Glass morph) с правильными отступами

/// Строка sidebar: иконка + подпись с явными внутренними отступами (а не «прилипшие»).
final class SidebarRow: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: DS.iconPointSize, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.rowLeadingInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.iconTextGap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    func setSelected(_ on: Bool) {
        icon.contentTintColor = on ? DS.coral : .secondaryLabelColor
        label.textColor = on ? DS.coral : .labelColor
    }
}

final class SidebarVC: NSViewController {
    var onSelect: ((SettingsSection) -> Void)?
    private var rows: [SidebarRow] = []
    private let pill = NSView()
    private let brand = NSTextField(labelWithString: "Keyboop")
    private let tag = NSTextField(labelWithString: L10n.t("tagline"))
    private let verLabel = NSButton()   // версия внизу сайдбара; клик — пасхалка
    private var selectedIndex = 0

    override func loadView() {
        let root = FlippedView()

        pill.wantsLayer = true
        pill.layer?.cornerRadius = DS.pillRadius
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = DS.coral.withAlphaComponent(0.16).cgColor
        root.addSubview(pill)

        brand.font = .systemFont(ofSize: 17, weight: .bold)
        root.addSubview(brand)
        tag.font = .systemFont(ofSize: 11)
        tag.textColor = .secondaryLabelColor
        tag.lineBreakMode = .byTruncatingTail
        root.addSubview(tag)

        for (i, sec) in SettingsSection.allCases.enumerated() {
            let row = SidebarRow(symbol: sec.symbol, title: L10n.t(sec.l10nKey))
            row.onClick = { [weak self] in self?.select(i) }
            rows.append(row)
            root.addSubview(row)
        }
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        verLabel.isBordered = false
        verLabel.bezelStyle = .inline
        verLabel.attributedTitle = NSAttributedString(string: "v\(ver)", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        verLabel.target = self
        verLabel.action = #selector(versionClicked)
        verLabel.toolTip = "🐾"
        root.addSubview(verLabel)

        if ProcessInfo.processInfo.environment["KEYBOOP_WINSHOT"] == "1" {
            root.wantsLayer = true                       // непрозрачный sidebar → cacheDisplay всего окна
            root.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        }
        view = root
    }

    @objc private func versionClicked() { CueSynth.versionTap() }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width
        let top = view.safeAreaInsets.top
        brand.frame = NSRect(x: 18, y: top + 14, width: w - 30, height: 24)
        tag.frame = NSRect(x: 18, y: top + 38, width: w - 30, height: 16)
        let rowsTop = top + 72
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: DS.pillInsetH, y: rowsTop + CGFloat(i) * (DS.rowHeight + DS.rowGap),
                               width: w - DS.pillInsetH * 2, height: DS.rowHeight)
        }
        verLabel.frame = NSRect(x: 18, y: view.bounds.height - 26, width: w - 30, height: 15)
        positionPill(animated: false)
    }

    func select(_ i: Int, animated: Bool = true) {
        selectedIndex = i
        for (j, row) in rows.enumerated() { row.setSelected(j == i) }
        positionPill(animated: animated)
        onSelect?(SettingsSection.allCases[i])
    }

    func refreshTitles() {
        for (i, sec) in SettingsSection.allCases.enumerated() {
            rows[i].label.stringValue = L10n.t(sec.l10nKey)
        }
    }

    private func positionPill(animated: Bool) {
        guard selectedIndex < rows.count else { return }
        let target = rows[selectedIndex].frame
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                pill.animator().frame = target
            }
        } else {
            pill.frame = target
        }
    }
}

// MARK: - Detail

final class DetailVC: NSViewController {
    var onLanguageChanged: (() -> Void)?
    private let settings = AppSettings.shared
    private let exceptions = ExceptionStore.shared
    private let snippets = SnippetStore.shared

    private var ignoredChips: ChipFlowView?
    private var learnedChips: ChipFlowView?
    private var wordInput: NSTextField?
    private var voiceModelStatus: [String: NSTextField] = [:]
    private var historyWC: VoiceHistoryWindowController?
    private let docView = FlippedView()
    private let column = FlippedView()           // колонка контента с ограниченной шириной
    private var contentStack: NSStackView?
    private var currentSection: SettingsSection = .switching

    override func loadView() {
        let env = ProcessInfo.processInfo.environment
        let bg: NSView
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_WINSHOT"] == "1" {
            let solid = NSView(); solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor  // тёмный (дампы под .darkAqua)
            bg = solid
        } else {
            let eff = NSVisualEffectView()
            eff.material = .underPageBackground
            eff.blendingMode = .behindWindow
            bg = eff
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false   // только вертикальный скролл — контент не уезжает вбок
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        docView.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView
        docView.addSubview(column)
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_WINSHOT"] == "1" {
            // непрозрачный тёмный фон колонки → cacheDisplay-снимок не «белеет» в прозрачных зонах
            column.wantsLayer = true
            column.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        }

        bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bg.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            // КРИТИЧНО: к contentView (clip-view = истинный viewport), НЕ к scroll.widthAnchor
            // (та включает вертикальный скроллер) — иначе docView шире viewport и контент обрезается.
            docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        // Колонка (research-канон): centerX + (≤max required) + (leading/trailing ≥ margin required)
        // + жертвенный (== max @ high). При узком окне жертвенный ломается → колонка сжимается до
        // viewport−2·margin; при широком — ровно max, центрирована. Без конфликта приоритетов.
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: docView.topAnchor, constant: DS.contentMargin),
            column.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -DS.contentMargin),
            // ЛЕВЫЙ КРАЙ + ФИКС ширина (по просьбе Ивана): блок прижат влево, ширина 480, справа —
            // свободное место. Окно не сужается ниже minWindowWidth → блок гарантированно влезает,
            // обрезки нет. Никакого центрирования и «docView шире вьюпорта».
            column.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: DS.contentMargin),
            column.widthAnchor.constraint(equalToConstant: DS.contentWidth)
        ])
        view = bg
    }

    override func viewDidLayout() { super.viewDidLayout() }

    /// Dev: PDF самой контентной колонки (для отладки дизайна на видимом окне).
    func renderColumnPDF() -> Data {
        column.layoutSubtreeIfNeeded()
        return column.dataWithPDF(inside: column.bounds)
    }

    /// Dev: снимок ВСЕГО detail-pane (bg solid в DUMP) — видно центрирование колонки внутри
    /// широкой панели и реальную обрезку справа (то, что снимок изолированной колонки скрывает).
    func renderPanePNG() -> Data? {
        view.layoutSubtreeIfNeeded()
        let b = view.bounds
        guard b.width > 1, b.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: b) else { return nil }
        view.cacheDisplay(in: b, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    /// docView/clipview/column ширины — для диагностики (печатаем в лог).
    func layoutDiag() -> String {
        view.layoutSubtreeIfNeeded()
        let clip = (view.subviews.first as? NSScrollView)?.contentView.bounds.width ?? -1
        return "pane=\(Int(view.bounds.width)) docView=\(Int(docView.bounds.width)) clip=\(Int(clip)) column=\(Int(column.bounds.width)) colX=\(Int(column.frame.minX))"
    }
    /// Живая диагностика БЕЗ forced-layout — читаем кадры переносимых подписей как в реальном окне.
    func liveDiag() -> String {
        let scroll = view.subviews.first as? NSScrollView
        let vpH = scroll?.contentView.bounds.height ?? -1
        let docH = (scroll?.documentView)?.bounds.height ?? -1
        let scrolls = docH > vpH + 1
        var out = "paneH=\(Int(view.bounds.height)) viewportH=\(Int(vpH)) docH=\(Int(docH)) columnH=\(Int(column.frame.height)) СКРОЛЛ=\(scrolls ? "ДА (docH>viewport)" : "нет")\n"
        out += "column.w=\(Int(column.frame.width)) colX=\(Int(column.frame.minX)) pane=\(Int(view.bounds.width))\n"
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let wl = sub as? WrappingLabel {
                    out += "  WL frame.w=\(Int(wl.frame.width)) frameH=\(Int(wl.frame.height)) pMLW=\(Int(wl.preferredMaxLayoutWidth)) '\(wl.stringValue.prefix(22))'\n"
                }
                walk(sub)
            }
        }
        walk(column)
        return out
    }

    /// Dev: PNG колонки через cacheDisplay — В ОТЛИЧИЕ от PDF рендерит NSControl
    /// (чекбоксы, segmented, popup) с реальным accent-цветом (coral). Композитим на
    /// белый фон, т.к. cacheDisplay оставляет прозрачные зоны там, где view не рисует фон.
    func renderColumnPNG(extraRight: CGFloat = 0, forceWidth: CGFloat? = nil) -> Data? {
        var temp: NSLayoutConstraint?
        if let fw = forceWidth {                      // надёжно сузить колонку (ресайз окна в дампе асинхронен)
            temp = column.widthAnchor.constraint(equalToConstant: fw)
            temp!.priority = .required
            temp!.isActive = true
        }
        column.superview?.layoutSubtreeIfNeeded()
        column.layoutSubtreeIfNeeded()
        defer { temp?.isActive = false }
        let cb = column.bounds
        guard cb.width > 1, cb.height > 1 else { return nil }
        // Кадр шире колонки: всё, что субвью рисуют за правым краем column (не clipped),
        // попадёт в снимок. Красная линия = правый край колонки (где должно всё кончаться).
        let frame = NSRect(x: cb.minX, y: cb.minY, width: cb.width + extraRight, height: cb.height)
        guard let rep = column.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        column.cacheDisplay(in: frame, to: rep)
        let out = NSImage(size: frame.size)
        out.lockFocus()
        NSColor(white: 0.14, alpha: 1).setFill()   // тёмный фон (как реальное окно)
        NSRect(origin: .zero, size: frame.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: frame.size))
        if extraRight > 0 {                     // маркер правого края колонки
            NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            let line = NSBezierPath(); line.lineWidth = 1.5
            line.move(to: NSPoint(x: cb.width, y: 0)); line.line(to: NSPoint(x: cb.width, y: frame.height))
            line.stroke()
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let outRep = NSBitmapImageRep(data: tiff) else { return nil }
        return outRep.representation(using: .png, properties: [:])
    }

    private func buildSection(_ section: SettingsSection) -> NSView {
        switch section {
        case .switching:  return buildSwitching()
        case .exceptions: return buildExceptions()
        case .snippets:   return buildSnippets()
        case .translate:  return buildTranslate()
        case .voice:      return buildVoice()
        case .general:    return buildGeneral()
        case .updates:    return buildUpdates()
        case .privacy:    return buildPrivacy()
        case .about:      return buildAbout()
        }
    }

    /// Авто-высота: max высота контента среди разделов при ширине колонки. Окно строим по самому
    /// длинному разделу (Голосовой набор) — чтобы не зашивать число руками и не «прыгать» по вкладкам.
    func tallestSectionHeight() -> CGFloat {
        var maxH: CGFloat = 0
        for s in [SettingsSection.switching, .voice, .privacy] {   // самые длинные кандидаты
            guard let stack = buildSection(s) as? NSStackView else { continue }
            stack.translatesAutoresizingMaskIntoConstraints = false
            let probe = FlippedView(frame: NSRect(x: 0, y: 0, width: DS.contentWidth, height: 6000))
            probe.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: probe.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: probe.trailingAnchor),
                stack.topAnchor.constraint(equalTo: probe.topAnchor),
                stack.widthAnchor.constraint(equalToConstant: DS.contentWidth)
            ])
            probe.layoutSubtreeIfNeeded()
            maxH = max(maxH, stack.fittingSize.height)
        }
        return maxH
    }

    func show(_ section: SettingsSection) {
        currentSection = section
        contentStack?.removeFromSuperview()
        guard let stack = buildSection(section) as? NSStackView else { return }
        contentStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stack.topAnchor.constraint(equalTo: column.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: column.widthAnchor)   // явная ширина (stack.w был 0)
        ])
        view.needsLayout = true
    }

    func reshow() { show(currentSection) }
    func reload() {
        ignoredChips?.set(exceptions.ignoredSorted)
        learnedChips?.set(exceptions.learnedSorted)
    }
    func saveAll() {
        // Чипы пишут в модель сразу при добавлении/удалении; добиваем недобавленное из поля ввода.
        addIgnoredFromInput()
    }
    @objc private func toggleLearnOnUndo(_ s: NSSwitch) { settings.learnOnUndoEnabled = (s.state == .on) }
    @objc private func clearLearned() {
        exceptions.clearLearned()
        learnedChips?.set(exceptions.learnedSorted)
    }
    /// Добавить слово(а) из поля ввода в исключения (по Enter или кнопке «Добавить»).
    @objc private func addIgnoredWord() { addIgnoredFromInput() }
    private func addIgnoredFromInput() {
        guard let f = wordInput else { return }
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        for w in raw.split(whereSeparator: { $0 == " " || $0 == "," }) { exceptions.addIgnored(String(w)) }
        f.stringValue = ""
        ignoredChips?.set(exceptions.ignoredSorted)
    }

    // MARK: builders

    private func buildSwitching() -> NSView {
        let tSpace = check("key.space", settings.triggerSpace, #selector(toggleTSpace))
        let tEnter = check("key.enter", settings.triggerEnter, #selector(toggleTEnter))
        let tTab = check("key.tab", settings.triggerTab, #selector(toggleTTab))
        let trigKeys = NSStackView(views: [tSpace, tEnter, tTab])
        trigKeys.orientation = .horizontal; trigKeys.spacing = 12

        return vstack([
            title(L10n.t("switch.title")),
            sub(L10n.t("switch.sub")),
            group(8),
            card([
                switchRow(L10n.t("switch.auto"), L10n.t("switch.autoSub"), settings.autoEnabled, #selector(toggleAuto)),
                switchRow(L10n.t("switch.live"), L10n.t("switch.liveSub"), settings.liveFixEnabled, #selector(toggleLive)),
                switchRow(L10n.t("switch.dev"), L10n.t("switch.devSub"), settings.developerMode, #selector(toggleDev)),
                controlRow(L10n.t("switch.manual"), HotkeyControl()),
                groupConvertRow()            // «переключать несколько слов» — сразу после ручного хоткея
            ]),
            group(6),
            sectionTitle(L10n.t("switch.trig")),
            card([
                controlRow(L10n.t("switch.trigAfter"), trigKeys),
                switchRow(L10n.t("switch.arrows"), nil, settings.arrowsCancel, #selector(toggleArrows))
            ]),
            group(6),
            card([
                switchRow(L10n.t("switch.soundOn"), nil, settings.soundEnabled, #selector(toggleSound)),
                controlRow(L10n.t("switch.sound"), SoundPicker()),
                controlRow(L10n.t("switch.soundVol"), soundVolumeSlider())
            ])
        ])
    }
    // Авто-переключение вкл/выкл влияет на доступность «несколько слов» → перерисовываем раздел.
    @objc private func toggleGroupConvert(_ s: NSSwitch) { settings.groupConvert = (s.state == .on) }

    private weak var trPackLabel: NSTextField?

    private func buildTranslate() -> NSView {
        var items: [NSView] = [
            title(L10n.t("tr.title")),
            sub(L10n.t("tr.sub")),
            group(8),
            card([
                switchRow(L10n.t("tr.enabled"), L10n.t("tr.enabledSub"), settings.translateEnabled, #selector(toggleTranslate)),
                controlRow(L10n.t("tr.hotkey"), TranslateHotkeyControl())
            ]),
            group(6),
            card([
                switchRow(L10n.t("tr.sound"), nil, settings.translateSoundEnabled, #selector(toggleTranslateSound)),
                controlRow(L10n.t("switch.sound"), TranslateSoundPicker()),
                controlRow(L10n.t("tr.soundVol"), translateVolumeSlider())
            ])
        ]
        if #available(macOS 15.0, *) {
            items.append(group(6))
            items.append(sectionTitle(L10n.t("tr.packTitle")))
            items.append(trPackCard())
        }
        items.append(group(6))
        items.append(sub(L10n.t("tr.how")))
        return vstack(items)
    }

    /// Карточка языкового пакета RU↔EN: статус + переход в системный менеджер языков (там
    /// реальная загрузка с прогрессом). Своего окна докачки НЕ показываем — оно виснет.
    @available(macOS 15.0, *)
    private func trPackCard() -> NSView {
        let name = NSTextField(labelWithString: L10n.t("tr.packName"))
        name.font = .systemFont(ofSize: 13); name.textColor = .labelColor
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let meta = NSTextField(labelWithString: L10n.t("tr.checking"))
        meta.font = .systemFont(ofSize: 11); meta.textColor = .secondaryLabelColor
        trPackLabel = meta
        let nameCol = NSStackView(views: [name, meta]); nameCol.orientation = .vertical
        nameCol.alignment = .leading; nameCol.spacing = 1

        let sys = NSButton(title: L10n.t("tr.openSys"), target: self, action: #selector(openLangSettings))
        sys.bezelStyle = .rounded; sys.controlSize = .regular
        sys.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [nameCol, spacer, sys])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        refreshTrPackStatus()
        return card([row])
    }

    private func refreshTrPackStatus() {
        guard #available(macOS 15.0, *) else { return }
        Task { [weak self] in
            let ok = await TranslationEngine.shared.isInstalled(from: "ru", to: "en")
            await MainActor.run {
                self?.trPackLabel?.stringValue = ok ? L10n.t("tr.installed") : L10n.t("tr.notInstalled")
                self?.trPackLabel?.textColor = ok ? DS.coral : .secondaryLabelColor
            }
        }
    }

    /// Открыть Системные настройки → «Язык и регион» (там менеджер языков перевода с реальным прогрессом).
    @objc private func openLangSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Маленькая «клавишная» плашка с моноширинным текстом — для показа хоткея.
    private func keycapLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView(); chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        chip.layer?.cornerRadius = 6
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 24)
        ])
        chip.setContentHuggingPriority(.required, for: .horizontal)
        return chip
    }

    private var runningAppsList: [String] = []

    private func buildExceptions() -> NSView {
        var views: [NSView] = [title(L10n.t("exc.appsTitle")), sub(L10n.t("exc.appsSub")), group(8)]
        let apps = ExceptionStore.shared.appModes.keys.sorted { appName($0) < appName($1) }
        if apps.isEmpty {
            let empty = NSTextField(labelWithString: L10n.t("exc.appsEmpty"))
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            let row = NSStackView(views: [empty]); row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            views.append(card([row]))
        } else {
            views.append(card(apps.map { appExceptionRow($0, ExceptionStore.shared.appMode($0)) }))
        }
        let addBtn = NSButton(title: L10n.t("exc.addApp"), target: self, action: #selector(addExceptionApp))
        addBtn.bezelStyle = .rounded; addBtn.controlSize = .regular
        views.append(contentsOf: [group(4), buttonRow([addBtn, runningAppsPopup()]), group(2), hint(L10n.t("exc.appsHint"))])

        // Слова-исключения: чипы с крестиком + поле ввода («вк»/«тг» предзаполнены как образец).
        let ignoredView = ChipFlowView()
        ignoredView.emptyText = L10n.t("exc.empty")
        ignoredView.onDelete = { [weak self] w in
            self?.exceptions.removeIgnored(w)
            self?.ignoredChips?.set(self?.exceptions.ignoredSorted ?? [])
        }
        ignoredView.set(exceptions.ignoredSorted)
        ignoredChips = ignoredView
        let wInput = NSTextField()
        wInput.placeholderString = L10n.t("exc.addPlaceholder")
        wInput.target = self; wInput.action = #selector(addIgnoredWord)
        wInput.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wordInput = wInput
        let addWordBtn = NSButton(title: L10n.t("exc.addWord"), target: self, action: #selector(addIgnoredWord))
        addWordBtn.bezelStyle = .rounded; addWordBtn.controlSize = .regular
        addWordBtn.setContentHuggingPriority(.required, for: .horizontal)
        let addRow = NSStackView(views: [wInput, addWordBtn])
        addRow.orientation = .horizontal; addRow.spacing = 8; addRow.alignment = .centerY
        views.append(contentsOf: [
            group(12),
            title(L10n.t("exc.title")),
            sub(L10n.t("exc.sub")),
            group(DS.itemGap - 4),
            ChipFieldView(ignoredView),
            group(6),
            addRow
        ])
        // Обучение на отмене: тумблер + чипы выученных слов (крестик на каждом).
        let learnedView = ChipFlowView()
        learnedView.emptyText = L10n.t("learn.empty")
        learnedView.onDelete = { [weak self] w in
            self?.exceptions.removeLearned(w)
            self?.learnedChips?.set(self?.exceptions.learnedSorted ?? [])
        }
        learnedView.set(exceptions.learnedSorted)
        learnedChips = learnedView
        let clearLearnedBtn = NSButton(title: L10n.t("learn.clear"), target: self, action: #selector(clearLearned))
        clearLearnedBtn.bezelStyle = .rounded; clearLearnedBtn.controlSize = .regular
        views.append(contentsOf: [
            group(12),
            switchRow(L10n.t("learn.title"), L10n.t("learn.sub"), settings.learnOnUndoEnabled, #selector(toggleLearnOnUndo)),
            group(DS.itemGap - 4),
            ChipFieldView(learnedView),
            group(4),
            buttonRow([clearLearnedBtn])
        ])
        return vstack(views)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
    private func appExceptionRow(_ bundleID: String, _ mode: String) -> NSView {
        let icon = NSImageView()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let name = NSTextField(labelWithString: appName(bundleID))
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingTail
        let seg = NSSegmentedControl(labels: [L10n.t("exc.off"), L10n.t("exc.soft")],
                                     trackingMode: .selectOne, target: self, action: #selector(appModeChanged(_:)))
        seg.selectedSegment = mode == "soft" ? 1 : 0
        seg.controlSize = .small
        seg.identifier = NSUserInterfaceItemIdentifier(bundleID)
        seg.setContentHuggingPriority(.required, for: .horizontal)
        let del = NSButton(title: "", target: self, action: #selector(removeExceptionApp(_:)))
        del.bezelStyle = .regularSquare; del.isBordered = false
        del.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "remove")
        del.contentTintColor = .tertiaryLabelColor
        del.identifier = NSUserInterfaceItemIdentifier(bundleID)
        del.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [icon, name, spacer, seg, del])
        row.orientation = .horizontal; row.spacing = 9; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }
    private func runningAppsPopup() -> NSView {
        let pop = NSPopUpButton(); pop.controlSize = .regular
        pop.addItem(withTitle: L10n.t("exc.fromRunning"))
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != "ru.keyboop.app" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        runningAppsList = apps.compactMap { $0.bundleIdentifier }
        for a in apps { pop.addItem(withTitle: a.localizedName ?? (a.bundleIdentifier ?? "?")) }
        pop.target = self; pop.action = #selector(addRunningApp(_:))
        return pop
    }
    @objc private func appModeChanged(_ s: NSSegmentedControl) {
        guard let bid = s.identifier?.rawValue else { return }
        ExceptionStore.shared.setAppMode(bid, s.selectedSegment == 1 ? "soft" : "off")
    }
    /// Фокусирует поле токенов — кнопка «Добавить слово» как альтернатива Enter.

    @objc private func removeExceptionApp(_ s: NSButton) {
        guard let bid = s.identifier?.rawValue else { return }
        ExceptionStore.shared.removeApp(bid); reshow()
    }
    @objc private func addExceptionApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let bid = Bundle(url: url)?.bundleIdentifier {
            ExceptionStore.shared.setAppMode(bid, "off"); reshow()
        }
    }
    @objc private func addRunningApp(_ s: NSPopUpButton) {
        let idx = s.indexOfSelectedItem - 1
        guard idx >= 0, idx < runningAppsList.count else { return }
        ExceptionStore.shared.setAppMode(runningAppsList[idx], "off"); reshow()
    }

    private func buildSnippets() -> NSView {
        let editor = SnippetsEditor(frame: .zero)
        editor.translatesAutoresizingMaskIntoConstraints = false
        return vstack([
            title(L10n.t("snip.title")),
            sub(L10n.t("snip.sub")),
            group(DS.itemGap - 6),
            editor,                      // таблица: «что заменять | на что», редактирование в ячейках + кнопки + / −
            hint(L10n.t("snip.hint"))    // раскладка/регистр не учитываются + пример
        ])
    }

    /// Приватность — чистая страница доверия (только манифест, без посторонних контролов).
    private func buildPrivacy() -> NSView {
        return vstack([
            title(L10n.t("priv.title")),
            sub(L10n.t("priv.body")),
            group(2),
            sub(L10n.t("priv.body2")),
            group(6),
            hint(L10n.t("priv.foot"))
        ])
    }

    /// Общие — настройки уровня приложения: язык интерфейса, автозапуск, доступ Accessibility.
    private func buildGeneral() -> NSView {
        let langPop = NSPopUpButton()
        langPop.addItems(withTitles: [L10n.t("lang.auto"), L10n.t("lang.ru"), L10n.t("lang.en")])
        switch settings.language { case "ru": langPop.selectItem(at: 1); case "en": langPop.selectItem(at: 2); default: langPop.selectItem(at: 0) }
        langPop.target = self; langPop.action = #selector(langChanged(_:))

        let perm = NSButton(title: L10n.t("priv.perm"), target: self, action: #selector(openPerms))
        perm.bezelStyle = .rounded; perm.controlSize = .regular

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let mic = NSButton(title: L10n.t(micGranted ? "gen.micOk" : "gen.mic"),
                           target: self, action: #selector(requestMic))
        mic.bezelStyle = .rounded; mic.controlSize = .regular

        return vstack([
            title(L10n.t("gen.title")),
            sub(L10n.t("gen.sub")),
            group(8),
            card([
                controlRow(L10n.t("priv.lang"), langPop),
                switchRow(L10n.t("switch.login"), nil, settings.launchAtLogin, #selector(toggleLogin))
            ]),
            group(6),
            sectionTitle(L10n.t("gen.access")),
            card([ buttonRow([perm, mic]) ]),
            group(2),
            hint(L10n.t("gen.accessHint")),
            group(2),
            hint(L10n.t("gen.micHint"))
        ])
    }

    /// Обновления — ОТДЕЛЬНЫЙ раздел (раньше тонули в «Общих» → реальный пользователь не нашёл, где
    /// обновлять). Зависимость: «Ставить сразу без вопросов» требует включённой проверки, поэтому при
    /// нём тумблер «Проверять обновления» форсится ВКЛ и НЕДОСТУПЕН (нельзя выключить, не сняв silent).
    private func buildUpdates() -> NSView {
        let checkBtn = NSButton(title: L10n.t("upd.check"), target: self, action: #selector(checkForUpdates))
        checkBtn.bezelStyle = .rounded; checkBtn.controlSize = .regular

        let silent = settings.silentAutoUpdate
        let checkOn = silent ? true : UpdaterController.shared.automaticChecks   // при silent — форс ВКЛ
        return vstack([
            title(L10n.t("upd.title")),
            sub(L10n.t("upd.sub")),
            group(8),
            card([
                switchRow(L10n.t("upd.check2"), L10n.t("upd.check2Sub"), checkOn, #selector(toggleAutoCheck), enabled: !silent),
                switchRow(L10n.t("upd.silent"), L10n.t("upd.silentSub"), silent, #selector(toggleSilentUpdate)),
                buttonRow([checkBtn])
            ]),
            group(2),
            hint(L10n.t("upd.foot"))
        ])
    }

    @objc private func toggleAutoCheck(_ s: NSSwitch) { UpdaterController.shared.automaticChecks = (s.state == .on) }
    @objc private func toggleSilentUpdate(_ s: NSSwitch) {
        settings.silentAutoUpdate = (s.state == .on)
        // silent требует проверки → при включении форсим её ВКЛ; reshow перерисует раздел, и тумблер
        // «Проверять обновления» станет вкл+серым (а при выключении silent — снова доступным).
        if settings.silentAutoUpdate { UpdaterController.shared.automaticChecks = true }
        reshow()
    }
    @objc private func checkForUpdates() { UpdaterController.shared.checkNow() }

    /// О программе — версия, лицензия, обновления.
    private func buildAbout() -> NSView {
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
        let fb = NSButton(title: L10n.t("about.fbBtn"), target: self, action: #selector(openFeedback))
        fb.bezelStyle = .rounded; fb.controlSize = .regular
        let tg = NSButton(title: L10n.t("about.updTg"), target: self, action: #selector(openTelegram))
        tg.bezelStyle = .rounded; tg.controlSize = .regular
        let updMail = NSButton(title: L10n.t("about.updMail"), target: self, action: #selector(openUpdates))
        updMail.bezelStyle = .rounded; updMail.controlSize = .regular
        let whatsNew = NSButton(title: L10n.t("about.whatsNew"), target: self, action: #selector(showWhatsNew))
        whatsNew.bezelStyle = .rounded; whatsNew.controlSize = .regular
        let welBtn = NSButton(title: L10n.t("about.welcome"), target: self, action: #selector(showWelcomeTour))
        welBtn.bezelStyle = .rounded; welBtn.controlSize = .regular

        return vstack([
            title(L10n.t("about.title")),
            sub(L10n.t("about.tagline")),
            group(10),
            sectionTitle(L10n.t("about.whatTitle")),
            sub(L10n.t("about.what")),
            group(8),
            sectionTitle(L10n.t("about.canTitle")),
            sub(L10n.t("about.can")),
            group(8),
            sectionTitle(L10n.t("about.nuanceTitle")),
            sub(L10n.t("about.nuance")),
            group(10),
            sectionTitle(L10n.t("about.fbTitle")),
            sub(L10n.t("about.fbBody")),
            group(4),
            card([ buttonRow([fb]) ]),
            group(10),
            sectionTitle(L10n.t("about.updTitle")),
            sub(L10n.t("about.updBody")),
            group(4),
            card([ buttonRow([tg, updMail]) ]),
            group(10),
            card([
                controlRow(L10n.t("about.version"), versionValue(ver)),
                controlRow(L10n.t("about.license"), valueText(L10n.t("about.licenseVal"))),
                controlRow(L10n.t("about.rescued"), valueText(rescuedDisplay())),
                buttonRow([whatsNew, welBtn])
            ]),
            group(6),
            hint(L10n.t("about.foot")),
            group(2),
            hint(L10n.t("about.credits"))
        ])
    }
    private func valueText(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabelColor
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }
    /// Счётчик спасённых раскладок с разделителями тысяч («1 247»). Пока 0 — тёплая заглушка.
    private func rescuedDisplay() -> String {
        let n = settings.rescuedCount
        guard n > 0 else { return L10n.current == .ru ? "пока ни одной 🥚" : "none yet 🥚" }
        let fmt = NumberFormatter(); fmt.numberStyle = .decimal; fmt.groupingSeparator = " "
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// Версия как кликабельный текст — пасхалка: клик = «мяу».
    private func versionValue(_ s: String) -> NSView {
        let b = NSButton(title: s, target: self, action: #selector(meowEasterEgg))
        b.isBordered = false; b.bezelStyle = .inline
        b.attributedTitle = NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        b.toolTip = "🐾"
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }
    @objc private func meowEasterEgg() { CueSynth.versionTap() }

    private var welcomeTourWC: WelcomeWindowController?
    @objc private func showWelcomeTour() {
        if welcomeTourWC == nil { welcomeTourWC = WelcomeWindowController() }
        welcomeTourWC?.show()
    }

    private var whatsNewWindow: NSWindow?
    @objc private func showWhatsNew() {
        if whatsNewWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = L10n.t("about.whatsNew")
            w.titlebarAppearsTransparent = true
            w.center()
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            scroll.autohidesScrollers = true
            let tv = NSTextView()
            tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 20, height: 18)
            tv.textStorage?.setAttributedString(changelogAttributed())
            scroll.documentView = tv
            tv.minSize = NSSize(width: 0, height: 0)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            w.contentView = scroll
            whatsNewWindow = w
        } else {
            // язык мог смениться — пересоберём текст
            (whatsNewWindow?.contentView as? NSScrollView)?.documentView
                .flatMap { $0 as? NSTextView }?.textStorage?.setAttributedString(changelogAttributed())
        }
        whatsNewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func changelogAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let isRu = L10n.current == .ru
        let hdr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.labelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        let gap: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 6)]
        for r in Changelog.releases {
            s.append(NSAttributedString(string: "v\(r.version)\n", attributes: hdr))
            for item in (isRu ? r.ru : r.en) {
                s.append(NSAttributedString(string: "  •  \(item)\n", attributes: body))
            }
            s.append(NSAttributedString(string: "\n", attributes: gap))
        }
        return s
    }

    // MARK: helpers

    private func buildVoice() -> NSView {
        voiceModelStatus.removeAll()
        // Единый список моделей (Parakeet + whisper) — без тумблера движка: движок выводится из
        // активной модели. Любую можно скачать / активировать / удалить (по просьбе Ивана 2026-06-14).
        unifiedCatalog = unifiedModels()
        let modelCard = card(unifiedCatalog.enumerated().map { unifiedModelRow($1, index: $0) })

        let histClear = NSButton(title: L10n.t("voice.histClear"), target: self, action: #selector(clearVoiceHistory))
        histClear.bezelStyle = .rounded; histClear.controlSize = .regular
        let histShow = NSButton(title: L10n.t("voice.showHistory"), target: self, action: #selector(showVoiceHistory))
        histShow.bezelStyle = .rounded; histShow.controlSize = .regular
        let logBtn = NSButton(title: L10n.t("voice.log"), target: self, action: #selector(openLog))
        logBtn.bezelStyle = .rounded; logBtn.controlSize = .regular

        var views: [NSView] = [
            title(L10n.t("voice.title")),
            group(8),
            card([
                switchRow(L10n.t("voice.on"), nil, settings.voiceEnabled, #selector(toggleVoice)),
                controlRow(L10n.t("voice.hotkey"), VoiceHotkeyControl()),
                controlRow(L10n.t("voice.mode"), voiceModeControl()),
                controlRow(L10n.t("voice.lang"), voiceLangControl()),
                controlRow(L10n.t("voice.mic"), micSelectorControl()),
                buttonRow([soundSettingsLink()]),
                switchRow(L10n.t("voice.escCancel"), nil, settings.escCancelsDictation, #selector(toggleEscCancel)),
                switchRow(L10n.t("voice.warm"), L10n.t("voice.warmSub"), settings.voiceWarmWindow, #selector(toggleWarmWindow)),
                controlRow(L10n.t("voice.warmDur"), warmDurationControl()),
                switchRow(L10n.t("voice.sound"), nil, settings.voiceSoundEnabled, #selector(toggleVoiceSound)),
                controlRow(L10n.t("voice.soundVol"), voiceVolumeSlider())
            ]),
            group(6),
            sectionTitle(L10n.t("voice.modelsTitle")),
            group(8),
            modelCard
        ]
        views.append(contentsOf: [
            group(2),
            hint(L10n.t("voice.modelsNote")),
            group(6),
            card([
                switchRow(L10n.t("voice.history"), L10n.t("voice.historySub"), settings.voiceHistoryEnabled, #selector(toggleVoiceHistory)),
                controlRow(L10n.t("voice.retention"), historyRetentionControl()),
                buttonRow([histShow, histClear, logBtn])
            ]),
            group(2),
            hint(L10n.t("voice.logHint")),
            group(2),
            hint(L10n.t("voice.foot"))
        ])
        return vstack(views)
    }

    // MARK: единый список моделей распознавания (Parakeet + whisper, без тумблера движка)

    private var unifiedCatalog: [UnifiedModel] = []
    private var downloadingModelId: String?      // какая модель качается сейчас (одна за раз)
    private var downloadProgress = 0.0

    /// Одна запись каталога моделей. Движок выводится из активной модели (тумблер Whisper/Parakeet убран).
    struct UnifiedModel {
        let engine: String      // "parakeet" | "whisper"
        let id: String          // "parakeet" или имя whisper-модели (base/small/…)
        let display: String
        let size: String
        let note: String
        func isInstalled() -> Bool {
            engine == "parakeet" ? ParakeetEngine.modelInstalled : ModelDownloader.shared.isInstalled(id)
        }
    }

    /// Полный каталог: Parakeet (рекомендуемый, по умолчанию) первым, затем whisper по возрастанию размера.
    private func unifiedModels() -> [UnifiedModel] {
        var list: [UnifiedModel] = [
            UnifiedModel(engine: "parakeet", id: "parakeet",
                         display: L10n.t("voice.pkName"), size: "~465 МБ", note: L10n.t("voice.pkDesc"))
        ]
        list += ModelDownloader.catalog.map {
            UnifiedModel(engine: "whisper", id: $0.name, display: $0.name, size: $0.size, note: $0.note)
        }
        return list
    }

    /// Активна ли модель (движок + конкретная whisper-модель).
    private func isActiveModel(_ m: UnifiedModel) -> Bool {
        m.engine == "parakeet"
            ? settings.voiceEngine == "parakeet"
            : (settings.voiceEngine == "whisper" && settings.voiceModel == m.id)
    }

    /// Сделать модель активной: движок выводится из неё (whisper-модель ещё и запоминается).
    private func activateModel(_ m: UnifiedModel) {
        if m.engine == "parakeet" {
            settings.voiceEngine = "parakeet"
        } else {
            settings.voiceEngine = "whisper"
            settings.voiceModel = m.id
        }
        reshow()
    }

    /// Строка модели в едином списке: имя + (размер · статус) слева; справа — Скачать / Использовать
    /// + корзина-удаление (для любой установленной). Активная подсвечена coral, статус «используется».
    private func unifiedModelRow(_ m: UnifiedModel, index: Int) -> NSView {
        let installed = m.isInstalled()
        // Подсветка «активная» (coral + «используется») — только если модель РЕАЛЬНО скачана. Иначе
        // дефолтный, но не скачанный Parakeet выглядел бы «активным» без файла на диске (путаница).
        let activeNow = isActiveModel(m) && installed

        let name = NSTextField(labelWithString: m.display)
        name.font = .systemFont(ofSize: 13, weight: activeNow ? .semibold : .regular)
        name.textColor = activeNow ? DS.coral : .labelColor
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)

        let metaText = "\(m.size)  ·  " + (installed ? (activeNow ? L10n.t("voice.active") : L10n.t("voice.installed")) : m.note)
        let status = NSTextField(labelWithString: metaText)
        status.font = .systemFont(ofSize: 11)
        status.textColor = activeNow ? DS.coral.withAlphaComponent(0.85) : .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceModelStatus[m.id] = status

        let nameCol = NSStackView(views: [name, status]); nameCol.orientation = .vertical
        nameCol.alignment = .leading; nameCol.spacing = 1

        var right: [NSView] = []
        if !installed {
            let dl = NSButton(title: L10n.t("voice.download"), target: self, action: #selector(downloadModelAction(_:)))
            dl.bezelStyle = .rounded; dl.controlSize = .regular; dl.tag = index
            dl.setContentCompressionResistancePriority(.required, for: .horizontal)
            if downloadingModelId == m.id { dl.isEnabled = false; dl.title = "\(Int(downloadProgress * 100))%" }
            right = [dl]
        } else {
            if !activeNow {
                let use = NSButton(title: L10n.t("voice.use"), target: self, action: #selector(activateModelAction(_:)))
                use.bezelStyle = .rounded; use.controlSize = .regular; use.tag = index
                use.setContentCompressionResistancePriority(.required, for: .horizontal)
                right.append(use)
            }
            // Корзина-удаление — для ЛЮБОЙ установленной модели (освободить место).
            let del = NSButton(title: "", target: self, action: #selector(deleteModelAction(_:)))
            del.bezelStyle = .rounded; del.controlSize = .regular; del.tag = index
            del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.t("voice.delete"))
            del.imagePosition = .imageOnly
            del.toolTip = L10n.t("voice.delete")
            del.setContentCompressionResistancePriority(.required, for: .horizontal)
            del.setContentHuggingPriority(.required, for: .horizontal)
            right.append(del)
        }

        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [nameCol, spacer] + right)
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        return row
    }

    private func voiceModeControl() -> NSView {
        let seg = NSSegmentedControl(labels: [L10n.t("voice.modeHold"), L10n.t("voice.modeToggle")],
                                     trackingMode: .selectOne, target: self, action: #selector(voiceModeChanged(_:)))
        seg.selectedSegment = settings.voiceHoldMode == "toggle" ? 1 : 0
        return seg
    }

    private func soundVolumeSlider() -> NSView {
        let s = NSSlider(value: settings.soundVolume, minValue: 0, maxValue: 1,
                         target: self, action: #selector(soundVolChanged(_:)))
        s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return s
    }
    @objc private func soundVolChanged(_ s: NSSlider) {
        settings.soundVolume = s.doubleValue
        if settings.soundEnabled, !settings.soundName.isEmpty {   // короткое превью на новой громкости
            let snd = NSSound(named: settings.soundName); snd?.volume = Float(settings.soundVolume); snd?.play()
        }
    }

    private func voiceVolumeSlider() -> NSView {
        let s = NSSlider(value: settings.voiceSoundVolume, minValue: 0, maxValue: 1,
                         target: self, action: #selector(voiceVolChanged(_:)))
        s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return s
    }
    @objc private func toggleVoiceSound(_ s: NSSwitch) { settings.voiceSoundEnabled = (s.state == .on) }

    private func translateVolumeSlider() -> NSView {
        let s = NSSlider(value: settings.translateSoundVolume, minValue: 0, maxValue: 1,
                         target: self, action: #selector(translateVolChanged(_:)))
        s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return s
    }
    @objc private func toggleTranslateSound(_ s: NSSwitch) { settings.translateSoundEnabled = (s.state == .on) }
    private var translateVolPreview: NSSound?   // удерживаем превью, иначе оборвётся
    @objc private func translateVolChanged(_ s: NSSlider) {
        settings.translateSoundVolume = s.doubleValue
        guard settings.translateSoundEnabled else { return }   // превью на новой громкости
        let vol = Float(settings.translateSoundVolume)
        let name = settings.translateSoundName
        if name == "keyboop" {
            translateVolPreview?.stop()
            translateVolPreview = NSSound(data: CueSynth.translateData)
            translateVolPreview?.volume = vol; translateVolPreview?.play()
        } else if !name.isEmpty {
            let snd = NSSound(named: name); snd?.volume = vol; snd?.play()
        }
    }
    @objc private func toggleEscCancel(_ s: NSSwitch) { settings.escCancelsDictation = (s.state == .on) }
    @objc private func toggleWarmWindow(_ s: NSSwitch) { settings.voiceWarmWindow = (s.state == .on) }
    private var cuePreview: NSSound?   // удерживаем превью, иначе звук оборвётся
    @objc private func voiceVolChanged(_ s: NSSlider) {
        settings.voiceSoundVolume = s.doubleValue
        if settings.voiceSoundEnabled {   // превью звука старта на новой громкости
            cuePreview?.stop()
            cuePreview = NSSound(data: CueSynth.startData)
            cuePreview?.volume = Float(settings.voiceSoundVolume)
            cuePreview?.play()
        }
    }

    private let voiceLangCodes = ["auto", "ru", "en"]
    private func voiceLangControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: [L10n.t("voice.langAuto"), "Русский", "English"])
        let idx = voiceLangCodes.firstIndex(of: settings.voiceLanguage) ?? 1
        pop.selectItem(at: idx)
        pop.target = self; pop.action = #selector(voiceLangChanged(_:))
        return pop
    }
    @objc private func voiceLangChanged(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        if i >= 0, i < voiceLangCodes.count { settings.voiceLanguage = voiceLangCodes[i] }
    }

    // MARK: - Карточки (нативный grouped-стиль macOS System Settings)

    /// Скруглённая карточка: строки, разделённые тонкими hairline (как в System Settings).
    /// Цвета заливки/границы задаёт CardView.updateLayer — адаптивно к РЕАЛЬНОЙ теме view (иначе
    /// dynamic-NSColor.cgColor резолвится один раз под дефолтной темой → карточка белеет в dark).
    private func card(_ rows: [NSView]) -> CardView {
        let c = CardView()
        c.wantsLayer = true
        let v = NSStackView()
        v.orientation = .vertical; v.alignment = .width; v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            if i > 0 { v.addArrangedSubview(hairline()) }
            v.addArrangedSubview(r)
        }
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor)
        ])
        return c
    }
    private func hairline() -> NSView {
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = HairlineView(); line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),  // hairline под текстом, как у Apple
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
        ])
        return wrap
    }
    /// Строка-переключатель: заголовок (+подзаголовок) слева, NSSwitch справа (on = coral через accent).
    private func switchRow(_ title: String, _ subtitle: String?, _ on: Bool, _ action: Selector) -> NSView {
        let sw = NSSwitch(); sw.state = on ? .on : .off; sw.target = self; sw.action = action
        return settingRow(title, subtitle, trailing: sw)
    }
    /// Вариант switchRow с возможностью приглушить (серый + недоступен) — для зависимых настроек.
    private func switchRow(_ title: String, _ subtitle: String?, _ on: Bool, _ action: Selector, enabled: Bool) -> NSView {
        let sw = NSSwitch(); sw.state = on ? .on : .off; sw.target = self; sw.action = action
        sw.isEnabled = enabled
        let row = settingRow(title, subtitle, trailing: sw)
        row.alphaValue = enabled ? 1.0 : 0.5
        return row
    }
    /// Тумблер «переключать несколько слов». Доступен ТОЛЬКО при выключенном авто-переключении
    /// (см. Engine.convertGroup guard): при авто sessionWords рассинхронятся с экраном → группа
    /// испортила бы текст, и она бессмысленна (авто чинит на лету). Поэтому серый, пока auto вкл.
    private func groupConvertRow() -> NSView {
        let autoOn = settings.autoEnabled
        let subtitle = autoOn ? L10n.t("exp.groupConvertAutoOff") : L10n.t("exp.groupConvertSub")
        return switchRow(L10n.t("exp.groupConvert"), subtitle,
                         settings.groupConvert && !autoOn, #selector(toggleGroupConvert),
                         enabled: !autoOn)
    }
    /// Строка с произвольным контролом справа (popup / segmented / hotkey).
    private func controlRow(_ title: String, _ control: NSView) -> NSView {
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return settingRow(title, nil, trailing: control)
    }
    /// Доступная ширина текстовой колонки строки = ширина блока − отступы − контрол справа − зазор.
    /// Замер (2026-06-09): contentWidth 480, insets 14+14, NSSwitch 54, spacing 10 → ≈388pt под
    /// подпись с переключателем. tooltip ставим ТОЛЬКО когда текст в неё не влезает (короткие
    /// подписи читаются целиком — лишний tooltip не нужен).
    private func availTextWidth(trailing: NSView) -> CGFloat {
        let tw = trailing.intrinsicContentSize.width
        let trailingW = tw > 1 ? tw : 54   // fallback: ширина NSSwitch
        return DS.contentWidth - 28 - trailingW - 10
    }
    private func truncates(_ text: String, font: NSFont, within avail: CGFloat) -> Bool {
        (text as NSString).size(withAttributes: [.font: font]).width > avail
    }
    private func settingRow(_ title: String, _ subtitle: String?, trailing: NSView) -> NSView {
        let avail = availTextWidth(trailing: trailing)
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13); l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // tooltip — только если заголовок реально усекается (обычно короткий → нет tooltip)
        if truncates(title, font: l.font!, within: avail) { l.toolTip = title }
        let textCol: NSView
        if let sub = subtitle {
            // Однострочная подсказка с усечением «…»; полный текст — в tooltip ТОЛЬКО когда не
            // умещается (откат правки с переносом на 2 строки — она ломала выравнивание).
            let s = NSTextField(labelWithString: sub)
            s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor
            s.lineBreakMode = .byTruncatingTail
            if truncates(sub, font: s.font!, within: avail) { s.toolTip = sub }
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let vs = NSStackView(views: [l, s]); vs.orientation = .vertical; vs.alignment = .leading; vs.spacing = 1
            textCol = vs
        } else { textCol = l }
        textCol.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [textCol, spacer, trailing])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }
    /// Маленький серый заголовок-секция над карточкой.
    /// Подзаголовок-секция: коралловый «eyebrow» (uppercase + кернинг), как на сайте и в онбординге.
    /// БЕЗ левого отступа — выравнивается с телом (старые 11pt серые + indent 4px выглядели мелко и
    /// рассинхронно). Единый стиль с WelcomeWindow.eyebrowLabel.
    private func sectionTitle(_ t: String) -> NSView {
        return Self.eyebrowLabel(t)
    }
    /// Общий стиль «eyebrow» (используется и в онбординге через WelcomeWindow).
    static func eyebrowLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: t.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: DS.coral,
            .kern: 1.1
        ])
        l.isEditable = false; l.isSelectable = false; l.isBordered = false; l.drawsBackground = false
        l.alignment = .left
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }
    /// Строка-карточка с кнопками слева (история / приватность).
    private func buttonRow(_ buttons: [NSView]) -> NSView {
        let hs = NSStackView(views: buttons); hs.orientation = .horizontal; hs.spacing = 8
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [hs, spacer]); row.orientation = .horizontal; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    private func vstack(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        // research-канон (Apple docs NSStackView.alignment): .leading — X-якорь ВЛЕВО для всех subview.
        // НЕ .width: .width — атрибут РАЗМЕРА, не позиции; single-line label не растягивается из-за
        // content-hugging и центрируется по дефолтному .centerX вертикального стека → уезжает вправо.
        s.alignment = .leading
        s.distribution = .fill
        s.spacing = DS.itemGap
        // Растягиваемые (multiline-текст, скроллы, поля, row-стеки) пиним по ширине к стеку — иначе
        // .leading даёт им intrinsic-ширину, и multiline-текст не знает ширину для переноса.
        for v in views {
            let wide = v is NSScrollView || v is NSTokenField || v is SnippetsEditor || v is NSStackView
                || v is CardView   // карточки — во всю ширину колонки
                || v is NSSegmentedControl   // переключатель движка — две широкие кнопки на всю ширину
                || v is NSButton   // чекбоксы: пин к ширине колонки → длинная подпись переносится, не торчит
                || v is ChipFlowView   // поток чипов — знает ширину для переноса + считает высоту
                || v is ChipFieldView  // поле-обрамление вокруг чипов — во всю ширину колонки
                || ((v as? NSTextField)?.maximumNumberOfLines == 0)
            if wide { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        }
        return s
    }
    private func stackH(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 12; return s
    }
    private func leftAlign(_ v: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [v, spacer]); row.orientation = .horizontal
        return row
    }
    private func title(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 20, weight: .semibold); l.textColor = .labelColor; l.alignment = .left; return l
    }
    private func sub(_ t: String) -> NSTextField { wrappingText(t, size: 13, color: .secondaryLabelColor) }
    private func hint(_ t: String) -> NSTextField { wrappingText(t, size: 11, color: .tertiaryLabelColor) }
    private func wrappingText(_ t: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = WrappingLabel(string: t)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return l
    }
    private func check(_ key: String, _ on: Bool, _ a: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(key), target: self, action: a)
        b.state = on ? .on : .off; b.font = .systemFont(ofSize: 13)
        // КЛЮЧ: длинная подпись чекбокса по умолчанию НЕ переносится и НЕ усекается →
        // распирает колонку и заезжает за правый край. Включаем перенос по словам + низкую
        // compression-resistance, чтобы подпись жила в пределах ширины колонки (см. wide-правило vstack).
        b.lineBreakMode = .byWordWrapping
        (b.cell as? NSButtonCell)?.wraps = true
        (b.cell as? NSButtonCell)?.usesSingleLineMode = false
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return b
    }
    private func labeledRow(_ text: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 13)
        // Если окно совсем узкое — усекаем ПОДПИСЬ, а контрол держит нужную ширину (не торчит).
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [l, control]); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }
    private func group(_ h: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: max(0, h)).isActive = true; return v
    }

    @objc private func toggleAuto(_ s: NSSwitch) {
        settings.autoEnabled = (s.state == .on)
        reshow()   // обновить доступность тумблера «несколько слов» (серый при авто вкл)
    }
    @objc private func toggleLive(_ s: NSSwitch) { settings.liveFixEnabled = (s.state == .on) }
    @objc private func toggleTranslate(_ s: NSSwitch) { settings.translateEnabled = (s.state == .on) }
    @objc private func toggleDev(_ s: NSSwitch) { settings.developerMode = (s.state == .on) }
    @objc private func toggleSound(_ s: NSSwitch) { settings.soundEnabled = (s.state == .on) }
    @objc private func toggleLogin(_ s: NSSwitch) { settings.launchAtLogin = (s.state == .on); s.state = settings.launchAtLogin ? .on : .off }
    @objc private func toggleTSpace(_ s: NSButton) { settings.triggerSpace = (s.state == .on) }
    @objc private func toggleTEnter(_ s: NSButton) { settings.triggerEnter = (s.state == .on) }
    @objc private func toggleTTab(_ s: NSButton) { settings.triggerTab = (s.state == .on) }
    @objc private func toggleArrows(_ s: NSSwitch) { settings.arrowsCancel = (s.state == .on) }
    @objc private func openUpdates() { Permissions.openUpdatesPage() }
    @objc private func openFeedback() { Permissions.openFeedbackMail() }
    @objc private func openTelegram() { Permissions.openTelegramBot() }
    @objc private func openLog() { Permissions.openDiagnosticLog() }
    @objc private func openPerms() { Permissions.openAccessibilitySettings() }
    /// Ручной доступ к микрофону: не спрашивали → системный промпт; иначе — открыть
    /// панель System Settings (отозвать/выдать вручную). После промпта — обновить заголовок.
    @objc private func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Task { @MainActor in
                _ = await AudioRecorder.requestAccess()
                self.reshow()
            }
        default:
            Permissions.openMicrophoneSettings()
        }
    }
    @objc private func langChanged(_ s: NSPopUpButton) {
        settings.language = [0: "auto", 1: "ru", 2: "en"][s.indexOfSelectedItem] ?? "auto"
        onLanguageChanged?()
        // Меню в статус-баре локализуется отдельно — пнём его пересобраться.
        NotificationCenter.default.post(name: .keyboopLanguageChanged, object: nil)
    }
    @objc private func toggleVoice(_ s: NSSwitch) { settings.voiceEnabled = (s.state == .on) }
    @objc private func voiceModeChanged(_ s: NSSegmentedControl) { settings.voiceHoldMode = s.selectedSegment == 1 ? "toggle" : "hold" }
    @objc private func toggleVoiceHistory(_ s: NSSwitch) { settings.voiceHistoryEnabled = (s.state == .on) }
    // Значения в МИНУТАХ: 30, 60, 120, 240, 480, 0 (без удаления)
    private let retentionMins = [30, 60, 120, 240, 480, 0]
    private func historyRetentionControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: ["30 минут", "1 час", "2 часа", "4 часа", "8 часов", "Не удалять"])
        let cur = settings.voiceHistoryMinutes
        pop.selectItem(at: retentionMins.firstIndex(of: cur) ?? 1)
        pop.target = self; pop.action = #selector(retentionChanged(_:))
        return pop
    }
    @objc private func retentionChanged(_ s: NSPopUpButton) {
        settings.voiceHistoryMinutes = retentionMins[s.indexOfSelectedItem]
        VoiceHistory.shared.applyRetention()
    }
    private let warmSecondsOptions = [15, 30, 60, 120, 300]   // 10 мин убрано — слишком долго держать HAL
    private func warmDurationControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: warmSecondsOptions.map { L10n.warmDurTitle($0) })
        pop.selectItem(at: warmSecondsOptions.firstIndex(of: settings.voiceWarmSeconds) ?? 1)
        pop.target = self; pop.action = #selector(warmDurationChanged(_:))
        return pop
    }
    @objc private func warmDurationChanged(_ s: NSPopUpButton) {
        settings.voiceWarmSeconds = warmSecondsOptions[s.indexOfSelectedItem]
    }
    @objc private func clearVoiceHistory() { VoiceHistory.shared.clear() }
    @objc private func showVoiceHistory() {
        if historyWC == nil { historyWC = VoiceHistoryWindowController() }
        historyWC?.show()
    }
    // MARK: - G: Mic selector

    private func micSelectorControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: L10n.t("voice.micSystem"))
        pop.lastItem?.representedObject = ""
        let devices = AudioDevices.inputs()
        for d in devices {
            pop.addItem(withTitle: d.name)
            pop.lastItem?.representedObject = d.uid
        }
        // Выбрать текущий UID (или первый пункт «системный» если UID не найден)
        let curUID = settings.voiceMicUID
        if curUID.isEmpty {
            pop.selectItem(at: 0)
        } else if let idx = (0..<pop.numberOfItems).first(where: { (pop.item(at: $0)?.representedObject as? String) == curUID }) {
            pop.selectItem(at: idx)
        } else {
            pop.selectItem(at: 0)
        }
        pop.target = self; pop.action = #selector(micSelectorChanged(_:))
        return pop
    }
    @objc private func micSelectorChanged(_ s: NSPopUpButton) {
        settings.voiceMicUID = (s.selectedItem?.representedObject as? String) ?? ""
    }
    private func soundSettingsLink() -> NSButton {
        let b = NSButton(title: L10n.t("voice.micSettings"), target: self, action: #selector(openSoundSettings))
        b.bezelStyle = .rounded; b.controlSize = .regular
        return b
    }
    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func activateModelAction(_ s: NSButton) {
        guard s.tag < unifiedCatalog.count else { return }
        activateModel(unifiedCatalog[s.tag])
    }

    @objc private func downloadModelAction(_ s: NSButton) {
        guard s.tag < unifiedCatalog.count else { return }
        let m = unifiedCatalog[s.tag]
        guard downloadingModelId == nil else { return }   // одна загрузка за раз
        downloadingModelId = m.id; downloadProgress = 0
        s.isEnabled = false; s.title = "0%"
        let onProgress: (Double) -> Void = { [weak self, weak s] p in
            self?.downloadProgress = p
            self?.voiceModelStatus[m.id]?.stringValue = "\(Int(p * 100)) %"
            s?.title = "\(Int(p * 100))%"
        }
        let onDone: (Bool) -> Void = { [weak self] ok in
            self?.downloadingModelId = nil
            if ok { self?.activateModel(m) }   // скачал → сразу активна (reshow внутри)
            else { self?.reshow() }
        }
        if m.engine == "whisper" {
            ModelDownloader.shared.download(m.id, progress: onProgress, done: onDone)
        } else {
            Task {
                let ok = await ParakeetEngine.shared.download(progress: { p in
                    DispatchQueue.main.async { onProgress(p) }
                })
                await MainActor.run { onDone(ok) }
            }
        }
    }

    @objc private func deleteModelAction(_ s: NSButton) {
        guard s.tag < unifiedCatalog.count else { return }
        let m = unifiedCatalog[s.tag]
        guard downloadingModelId != m.id else { return }   // не удаляем то, что качается
        let a = NSAlert()
        a.messageText = String(format: L10n.t("voice.delConfirm"), m.display)
        a.informativeText = L10n.t("voice.delConfirmSub")
        a.alertStyle = .warning
        a.addButton(withTitle: L10n.t("voice.delete"))
        a.addButton(withTitle: L10n.t("common.cancel"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let wasActive = isActiveModel(m)
        if m.engine == "whisper" { ModelDownloader.shared.delete(m.id) }
        else { ParakeetEngine.shared.deleteModel() }

        // Удалили активную → переключиться на другую установленную, если есть (иначе диктовка
        // честно попросит скачать модель при следующем использовании — onNeedModel).
        if wasActive, let fallback = unifiedModels().first(where: { $0.id != m.id && $0.isInstalled() }) {
            activateModel(fallback)   // reshow внутри
        } else {
            reshow()
        }
    }
}

/// Flipped — контент идёт сверху вниз.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Карточка-секция настроек. Цвет резолвится в updateLayer под РЕАЛЬНОЙ темой view
/// (dynamic NSColor → .cgColor статичен и не подхватывает смену темы).
final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.075)
                                        : NSColor.white.withAlphaComponent(0.85)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10)
                                    : NSColor.black.withAlphaComponent(0.07)).cgColor
    }
}

/// Тонкий разделитель строк в карточке (цвет — под реальную тему).
final class HairlineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.separatorColor.cgColor }
}

/// NSTextField, который сам держит preferredMaxLayoutWidth = своей ширине → корректный
/// перенос многострочного текста в Auto Layout (иначе AppKit считает текст однострочным
/// и он уезжает за край). Это надёжнее ручного пересчёта в viewDidLayout.
final class WrappingLabel: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; isBezeled = false
        drawsBackground = false
        alignment = .left
        usesSingleLineMode = false          // КЛЮЧ: иначе label однострочный и текст обрезается
        cell?.usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)  // не диктовать ширину
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)      // не обрезать по высоте
        stringValue = string
    }
    required init?(coder: NSCoder) { fatalError("no xib") }
    /// КАНОН self-sizing wrapping NSTextField: ширину переноса обновляем в setFrameSize —
    /// он срабатывает РОВНО когда Auto Layout ставит реальный кадр (в отличие от layout(),
    /// который в живом окне может выстрелить пока колонка ещё транзитно широкая → текст не
    /// переносится и уезжает за край). Прецедент: настройки лезли вправо именно из-за этого.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(preferredMaxLayoutWidth - newSize.width) > 0.5 {
            preferredMaxLayoutWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// Поток «чипов»-слов с крестиком на каждом (списки исключений и выученных слов). Перенос по ширине,
/// высота считается сама. Стиль — округлый прямоугольник в общем DS-стиле (как keycap-плашки).
/// Удаление — клик по ✕ на чипе (раньше было неочевидно: выдели тег + Delete).
final class ChipFlowView: NSView {
    var onDelete: ((String) -> Void)?
    var emptyText: String = ""
    private(set) var words: [String] = []
    private var heightC: NSLayoutConstraint!
    private let rowGap: CGFloat = 8, chipGap: CGFloat = 8
    private var emptyLabel: NSTextField?

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: 28)
        heightC.isActive = true
    }
    override var isFlipped: Bool { true }   // y вниз — проще флоу сверху-вниз

    func set(_ words: [String]) {
        self.words = words
        subviews.forEach { $0.removeFromSuperview() }
        emptyLabel = nil
        if words.isEmpty {
            let l = NSTextField(labelWithString: emptyText)
            l.font = .systemFont(ofSize: 12); l.textColor = .tertiaryLabelColor
            addSubview(l); emptyLabel = l
        } else {
            for w in words { addSubview(makeChip(w)) }
        }
        needsLayout = true
    }

    private func makeChip(_ word: String) -> NSView {
        let label = NSTextField(labelWithString: word)
        label.font = .systemFont(ofSize: 12.5); label.textColor = .labelColor
        let x = NSButton()
        x.target = self; x.action = #selector(deleteTapped(_:))
        x.bezelStyle = .regularSquare; x.isBordered = false; x.imagePosition = .imageOnly
        x.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "удалить")
        x.contentTintColor = .tertiaryLabelColor
        x.identifier = NSUserInterfaceItemIdentifier(word)
        x.translatesAutoresizingMaskIntoConstraints = false
        x.widthAnchor.constraint(equalToConstant: 13).isActive = true
        x.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let stack = NSStackView(views: [label, x])
        stack.orientation = .horizontal; stack.spacing = 5; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView(); chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        chip.layer?.cornerRadius = 7
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        chip.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: chip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: chip.bottomAnchor)
        ])
        return chip
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        if let w = sender.identifier?.rawValue { onDelete?(w) }
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        guard W > 1 else { return }
        if let e = emptyLabel {
            e.sizeToFit()
            e.frame = NSRect(x: 0, y: 5, width: W, height: max(e.frame.height, 16))
            setHeight(e.frame.height + 8); return
        }
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for chip in subviews {
            chip.layoutSubtreeIfNeeded()
            let sz = chip.fittingSize
            if x > 0 && x + sz.width > W { x = 0; y += rowH + rowGap; rowH = 0 }
            chip.frame = NSRect(x: x, y: y, width: sz.width, height: sz.height)
            x += sz.width + chipGap
            rowH = max(rowH, sz.height)
        }
        setHeight(y + rowH)
    }
    private func setHeight(_ h: CGFloat) {
        let hh = max(h, 24)
        if abs(heightC.constant - hh) > 0.5 { heightC.constant = hh }
    }
}

/// Поле-контейнер для потока чипов (исключения / выученные слова): округлая рамка + фон, как у
/// поля ввода. Высота следует за ChipFlowView внутри (тот считает высоту по числу строк чипов) —
/// поле само растёт, когда слов больше. Чтобы чипы не «висели в воздухе» без обрамления.
final class ChipFieldView: NSView {
    init(_ chips: ChipFlowView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        chips.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chips)
        let p: CGFloat = 10
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            chips.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            chips.topAnchor.constraint(equalTo: topAnchor, constant: p),
            chips.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p)
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
