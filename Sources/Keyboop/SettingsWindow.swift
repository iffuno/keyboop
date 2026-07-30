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
    /// ФИКС ширина блока настроек: прижат влево, поля узкие.
    /// 480 → 600 (28.07): подписи под строками резались, а половину из них ширина как раз лечит.
    /// Ровно 600, а не «сколько влезет»: шире строка «подпись слева, контрол справа» превращается в
    /// таблицу с дырой посередине, а короткие заголовки вроде «Голосовой ввод» выглядят брошенными.
    /// Совпадает с contentMaxWidth выше (Apple grouped-form cap).
    /// Проверка по экранам: окно 896 это 61% ширины на 13" Air (1470×956), 62% на 1440×900 и 70% в
    /// худшем реалистичном случае «крупный текст» 1280×800. Запас есть везде, где вообще идёт macOS 13.
    static let contentWidth: CGFloat = 600
    static let contentMargin: CGFloat = 24
    /// Минимальная ширина окна = sidebar + поле + блок + правое поле → блок всегда влезает.
    static let minWindowWidth: CGFloat = 220 + 24 + contentWidth + 28   // сайдбар + поле + контент + инсет
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
    case switching, exceptions, ambiguous, snippets, translate, voice, general, updates, privacy, about

    /// Что показываем в левом меню. «Спорные слова» — подстраница «Исключений» (кнопка внутри):
    /// в меню это был бы одиннадцатый пункт ради списка, который открывают раз в жизни.
    static var sidebarCases: [SettingsSection] { allCases.filter { $0 != .ambiguous } }
    var l10nKey: String {
        switch self {
        case .switching: return "sec.switching"
        case .exceptions: return "sec.exceptions"
        case .ambiguous:  return "sec.ambiguous"
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
        case .ambiguous:  return "arrow.left.arrow.right"
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
        // ПОЛНОЭКРАННЫЙ РЕЖИМ ЗАПРЕЩЁН (просьба автора 30.07). Настройки на весь экран — это полоса
        // контента посередине и километры пустоты по бокам: ширина у окна фиксированная (строка выше),
        // растягиваться ему некуда. `.fullScreenNone` убирает не только сам режим, но и превращает
        // зелёную кнопку обратно в ZOOM — а он здесь как раз осмысленный: ширину зум не трогает
        // (minSize.width == maxSize.width), высоту дотягивает до видимой части экрана. Ровно то, что
        // нужно длинному списку настроек. Двойной клик по заголовку тоже зовёт зум, если у человека
        // так настроено в системе, и это уже не наша забота — поведение стандартное.
        window.collectionBehavior.insert(.fullScreenNone)

        sidebar.onSelect = { [weak self] s in self?.detail.show(s) }
        detail.onLanguageChanged = { [weak self] in
            // Тоже откладываем: приходит из action popup'а языка, а reshow сносит сам popup.
            DispatchQueue.main.async {
                self?.sidebar.refreshTitles()
                self?.detail.reshow()
            }
        }
        sidebar.select(0, animated: false)
    }

    func show(section: SettingsSection? = nil) {
        detail.reload()
        if section == .ambiguous {
            detail.show(.ambiguous)                     // подстраница: в меню строки нет, подсветка остаётся на «Исключениях»
        } else if let section {
            // ⚠️ Выбирать по ИНДЕКСУ строки, а не по rawValue: скрытые разделы (ambiguous) сдвигают
            // нумерацию, и rawValue открыл бы соседний раздел (поймано 25.07 — вместо «Голосового
            // набора» показывались «Общие»).
            if let idx = SettingsSection.sidebarCases.firstIndex(of: section) {
                sidebar.select(idx, animated: false)
            }
        }
        else { detail.revalidateVoiceIfShown() }   // без явного раздела — пере-проверить файлы моделей на диске
        // Пока открыты настройки — показываем иконку в Доке. У LSUIElement-агента её нет, а меню-бар у
        // многих переполнен (наш пункт не умещается и его не видно). Док — надёжный способ вернуться в
        // приложение. На закрытии снова прячем (windowWillClose) — в простое остаёмся чистым агентом.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dev: отрендерить раздел в PNG (отладка дизайна без Screen Recording).
    func dump(section i: Int, to path: String) {
        // ⚠️ .aqua, а не .darkAqua (28.07). Рендер идёт в СВЕТЛУЮ подложку, поэтому под тёмной темой
        // получался светлый текст на светлом фоне — снимок формально есть, а прочитать нельзя.
        // Канон снимков интерфейса в этом проекте: appearance = .aqua.
        window?.appearance = NSAppearance(named: .aqua)
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
    func windowWillClose(_ notification: Notification) {
        detail.saveAll()
        NSApp.setActivationPolicy(.accessory)   // настройки закрыты → убираем иконку из Дока (снова агент)
    }
    /// Фокус вернулся к окну (напр. удалили файл модели в Finder и переключились обратно) — освежаем
    /// статус моделей, если открыт раздел «Голос», чтобы «Установлена/Скачать» отражали реальность на диске.
    func windowDidBecomeKey(_ notification: Notification) {
        detail.revalidateVoiceIfShown()
    }
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
    /// «Поддержать проект ₽» — тихая ссылка внизу левого меню, прямо над версией (просьба автора
    /// 26.07). Подчёркнутая, некрупная и нежирная: приложение бесплатное, это благодарность,
    /// а не продажа, и кричать ей незачем.
    private let supportLink = NSButton()
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

        for (i, sec) in SettingsSection.sidebarCases.enumerated() {
            let row = SidebarRow(symbol: sec.symbol, title: L10n.t(sec.l10nKey))
            row.onClick = { [weak self] in self?.select(i) }
            rows.append(row)
            root.addSubview(row)
        }
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        verLabel.isBordered = false
        verLabel.bezelStyle = .inline
        // С именем версии, как в шапке меню и в «О программе» (Changelog.versionWithName).
        verLabel.attributedTitle = NSAttributedString(string: "v" + Changelog.versionWithName(ver), attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        verLabel.target = self
        verLabel.action = #selector(versionClicked)
        verLabel.toolTip = "🐾"
        root.addSubview(verLabel)

        supportLink.isBordered = false
        supportLink.bezelStyle = .inline
        supportLink.setButtonType(.momentaryChange)
        supportLink.attributedTitle = NSAttributedString(string: L10n.t("about.support"), attributes: [
            .foregroundColor: DS.coral,
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        supportLink.target = self
        supportLink.action = #selector(openSupport)
        root.addSubview(supportLink)

        if ProcessInfo.processInfo.environment["KEYBOOP_WINSHOT"] == "1" {
            root.wantsLayer = true                       // непрозрачный sidebar → cacheDisplay всего окна
            root.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        }
        view = root
    }

    @objc private func versionClicked() { CueSynth.versionTap() }

    /// Ссылка ведёт на страницу поддержки. Без параметров: ничего о пользователе наружу не уходит.
    @objc private func openSupport() {
        if let url = URL(string: "https://keyboop.com/tips/") { NSWorkspace.shared.open(url) }
    }

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
        // Ссылка — строкой выше версии, по той же левой границе.
        supportLink.frame = NSRect(x: 14, y: view.bounds.height - 48, width: w - 26, height: 17)
        positionPill(animated: false)
    }

    func select(_ i: Int, animated: Bool = true) {
        selectedIndex = i
        for (j, row) in rows.enumerated() { row.setSelected(j == i) }
        positionPill(animated: animated)
        onSelect?(SettingsSection.sidebarCases[i])
    }

    func refreshTitles() {
        for (i, sec) in SettingsSection.sidebarCases.enumerated() {
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
    /// Кнопки «Скачать» по id модели. Как и метки выше, ПЕРЕрегистрируются при каждой сборке
    /// раздела — иначе обработчик прогресса держал бы ссылку на кнопку, которой уже нет.
    private var voiceModelButton: [String: NSButton] = [:]
    private var historyWC: VoiceHistoryWindowController?
    private let docView = FlippedView()
    private let column = FlippedView()           // колонка контента с ограниченной шириной
    private var contentStack: NSStackView?
    private var currentSection: SettingsSection = .switching

    override func loadView() {
        let env = ProcessInfo.processInfo.environment
        let bg: NSView
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_WINSHOT"] == "1" {
            // Дампы рендерятся под .aqua (см. dump()), поэтому подложка ДОЛЖНА быть светлой.
            // Раньше здесь стоял жёсткий тёмный 0.14 «для .darkAqua» — из-за него снимки выходили
            // с чёрным фоном и читались хуже живого окна.
            let solid = NSView(); solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.white.cgColor
            bg = solid
        } else {
            // ⚠️ Страница СВЕТЛАЯ в светлой теме (правка 29.07). `.underPageBackground` под .aqua
            // даёт серый, и вместе с белыми карточками это была инверсия системной схемы: у macOS
            // белая страница и серые группы. Материал оставляем только для тёмной темы, где он
            // выглядит правильно и даёт живое размытие за окном.
            let eff = NSVisualEffectView()
            eff.material = .underPageBackground
            eff.blendingMode = .behindWindow
            let solid = NSView(); solid.wantsLayer = true
            let holder = ThemedBackgroundView(dark: eff, light: solid)
            bg = holder
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
            // ЛЕВЫЙ КРАЙ + ФИКС ширина (по просьбе автора): блок прижат влево, ширина DS.contentWidth, справа —
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
        case .ambiguous:  return buildAmbiguous()
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
    /// Дешёвая сигнатура файлов моделей на диске (имя+размер+mtime). Меняется ровно тогда, когда
    /// модель скачали/удалили/подменили — включая удаление ИЗВНЕ через Finder.
    private func modelsSignature() -> String {
        let dir = (VoiceController.modelPath("") as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return "" }
        return names.sorted().map { n -> String in
            let a = try? fm.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(n))
            let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(n):\(size):\(Int(mtime))"
        }.joined(separator: "|")
    }
    private var lastModelsSignature: String?

    /// Пере-проверить статус моделей (файлы на диске), если сейчас показан раздел «Голос».
    /// Нужно, когда модель удалили ИЗВНЕ (Finder/rm) — строка статуса строится один раз по живой
    /// проверке, а `reload()` её не трогает, поэтому «Установлена/Скачать» устаревали (репорт 16.07).
    /// Только раздел «Голос»: у других (Исключения) есть поля ввода — пересборка сбросила бы недонабранное.
    ///
    /// ВАЖНО (20.07): пересобираем ТОЛЬКО если сигнатура файлов изменилась. Безусловный reshow на
    /// каждую активацию окна прогонял SwiftUI-графы всех контролов раздела по 2–3 раза за открытие
    /// и умножал частоту PAC-краша на macOS 26 в разы (см. RowMetrics). Фикс 16.07 при этом цел:
    /// удалили модель в Finder → сигнатура другая → пересборка происходит.
    func revalidateVoiceIfShown() {
        guard currentSection == .voice else { return }
        let sig = modelsSignature()
        guard sig != lastModelsSignature else { return }   // на диске ничего не менялось — не трогаем UI
        lastModelsSignature = sig
        reshow()
    }
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
                switchRow(L10n.t("switch.auto"), L10n.t("switch.autoSub"), settings.autoEnabled, #selector(toggleAuto),
                          help: L10n.t("switch.autoHelp")),
                // «Чинить на лету» — надстройка над авто-переключением: движок и так гейтит его по
                // autoEnabled (Engine ~278). Показываем это честно: авто выкл → тумблер серый и
                // выключенный. САМА настройка при этом не трогается — включат авто обратно, и
                // live-fix вернётся таким, каким был (регресс замечено в тестировании).
                switchRow(L10n.t("switch.live"), L10n.t("switch.liveSub"),
                          settings.autoEnabled && settings.liveFixEnabled, #selector(toggleLive),
                          enabled: settings.autoEnabled, help: L10n.t("switch.liveHelp")),
                switchRow(L10n.t("switch.dev"), L10n.t("switch.devSub"), settings.developerMode, #selector(toggleDev),
                          help: L10n.t("switch.devHelp")),
                controlRow(L10n.t("switch.manual"), HotkeyControl()),
                groupConvertRow()            // «переключать несколько слов» — сразу после ручного хоткея
            ]),
            group(6),
            sectionTitle(L10n.t("is.title")),
            card([
                switchRow(L10n.t("is.enable"), L10n.t("is.enableSub"),
                          settings.instantSwitchEnabled, #selector(toggleInstantSwitch),
                          help: L10n.t("is.enableHelp")),
                controlRow(L10n.t("is.combo"), instantSwitchControl(),
                           enabled: settings.instantSwitchEnabled)
            ]),
            group(2),
            instantSwitchStatusView(),       // что затеняем этой комбинацией — честно и заранее
            group(2),
            hint(L10n.t("is.beta")),         // честная бета-метка: фича новая и трогает системные хоткеи
            group(6),
            sectionTitle(L10n.t("switch.trig")),
            card([
                controlRow(L10n.t("switch.trigAfter"), trigKeys),
                switchRow(L10n.t("switch.arrows"), L10n.t("switch.arrowsSub"), settings.arrowsCancel, #selector(toggleArrows),
                          help: L10n.t("switch.arrowsHelp")),
                switchRow(L10n.t("switch.twoCaps"), L10n.t("switch.twoCapsSub"), settings.twoCapsFix,
                          #selector(toggleTwoCaps), help: L10n.t("switch.twoCapsHelp"))
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
    private weak var trDownloadBtn: NSButton?

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

        // Главная кнопка — докачка ПРЯМО из приложения (акцентная). Появляется, только когда пакета нет.
        let dl = NSButton(title: L10n.t("tr.download"), target: self, action: #selector(downloadTrPack))
        dl.bezelStyle = .rounded; dl.controlSize = .regular
        dl.bezelColor = DS.coral; dl.contentTintColor = .white
        dl.setContentHuggingPriority(.required, for: .horizontal)
        trDownloadBtn = dl

        // Вторично — системный менеджер языков (фолбэк, если по кнопке что-то пошло не так).
        let sys = NSButton(title: L10n.t("tr.openSys"), target: self, action: #selector(openLangSettings))
        sys.bezelStyle = .rounded; sys.controlSize = .regular
        sys.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [nameCol, spacer, dl, sys])
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
                self?.trDownloadBtn?.isHidden = ok            // установлен → кнопка «Скачать» не нужна
            }
        }
    }

    /// Скачать языковой пакет RU↔EN прямо из приложения (без ухода в Системные настройки).
    /// Готовим оба направления сразу. Системный лист скачивания Apple покажется поверх нашего окна.
    @objc private func downloadTrPack() {
        guard #available(macOS 15.0, *) else { return }
        TranslationEngine.shared.presentDownload(pairs: [("ru", "en"), ("en", "ru")]) { [weak self] _ in
            self?.refreshTrPackStatus()
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
        // Вход на подстраницу спорных пар: отдельным пунктом левого меню это был бы одиннадцатый
        // раздел ради списка, который открывают один раз (решение автора 25.07).
        let ambBtn = NSButton(title: L10n.t("amb.open"), target: self, action: #selector(openAmbiguous))
        ambBtn.bezelStyle = .rounded; ambBtn.controlSize = .regular
        views.append(contentsOf: [group(12), title(L10n.t("amb.title")), sub(L10n.t("amb.openSub")),
                                  group(6), buttonRow([ambBtn])])

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

    /// СПОРНЫЕ ПАРЫ. Одна строка — одна пара, тумблер из двух сегментов, подписанных САМИМИ словами:
    /// [ vs | мы ]. Так не нужно объяснять, что значит «латиница победила» — человек видит результат.
    /// Выделен тот сегмент, который выигрывает СЕЙЧАС (спрашиваем детектор, см. AmbiguousPairs.winner).
    private func buildAmbiguous() -> NSView {
        let back = NSButton(title: L10n.t("amb.back"), target: self, action: #selector(backToExceptions))
        back.bezelStyle = .rounded; back.controlSize = .regular
        var views: [NSView] = [buttonRow([back]), group(2),
                               title(L10n.t("amb.title")), sub(L10n.t("amb.sub")), group(DS.itemGap)]
        // Один центрированный столбец тумблеров, БЕЗ карточной подложки: у каждой строки один
        // элемент, и горизонтальные ячейки во всю ширину только растягивали пустоту (правка 25.07).
        let stack = vstack(views) as? NSStackView
        for (i, p) in AmbiguousPairs.list.enumerated() {
            let holder = ambiguousRow(p, index: i)
            stack?.addView(holder, in: .bottom)
            if let stack { holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        stack?.addView(group(6), in: .bottom)
        let footer = hint(L10n.t("amb.hint"))
        stack?.addView(footer, in: .bottom)
        if let stack { footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack ?? vstack(views)
    }

    /// Строка = один тумблер по центру. Три состояния: побеждает латиница · по контексту (наша
    /// обычная логика, дефолт) · побеждает русское. «По контексту» посередине не случайно: это
    /// нейтральная середина между двумя крайностями, и переход влево/вправо читается как выбор.
    private func ambiguousRow(_ pair: AmbiguousPairs.Pair, index: Int) -> NSView {
        let seg = NSSegmentedControl(labels: [pair.en, L10n.t("amb.auto"), pair.ru],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(ambiguousChanged(_:)))
        seg.segmentDistribution = .fillEqually
        switch AmbiguousPairs.choice(pair) {
        case .en:   seg.selectedSegment = 0
        case .auto: seg.selectedSegment = 1
        case .ru:   seg.selectedSegment = 2
        }
        seg.tag = index                      // строку узнаём по тегу — список статичный, индекс стабилен
        seg.toolTip = String(format: L10n.t("amb.rowTip"), pair.en, pair.ru)
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            seg.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
            seg.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3)
        ])
        return holder
    }

    @objc private func ambiguousChanged(_ sender: NSSegmentedControl) {
        guard sender.tag >= 0, sender.tag < AmbiguousPairs.list.count else { return }
        let pair = AmbiguousPairs.list[sender.tag]
        let choice: AmbiguousPairs.Choice = sender.selectedSegment == 0 ? .en
                                         : sender.selectedSegment == 2 ? .ru : .auto
        AmbiguousPairs.choose(pair, choice)
        kbLog("спорная пара \(pair.en)/\(pair.ru) → \(choice)")
    }

    @objc private func openAmbiguous() { (view.window?.windowController as? SettingsWindowController)?.show(section: .ambiguous) }

    @objc private func backToExceptions() { (view.window?.windowController as? SettingsWindowController)?.show(section: .exceptions) }

    private func buildSnippets() -> NSView {
        let editor = SnippetsEditor(frame: .zero)
        editor.translatesAutoresizingMaskIntoConstraints = false

        // Мультивыбор клавиш разворота автозамены (пробел/Enter/Tab). Все сняты → автозамена выключена.
        let cSpace = check("key.space", settings.snippetExpandSpace, #selector(toggleSnipSpace))
        let cEnter = check("key.enter", settings.snippetExpandEnter, #selector(toggleSnipEnter))
        let cTab   = check("key.tab",   settings.snippetExpandTab,   #selector(toggleSnipTab))
        let keys = NSStackView(views: [cSpace, cEnter, cTab])
        keys.orientation = .horizontal; keys.spacing = 12

        let disabled = hint(L10n.t("snip.disabled"))
        disabled.isHidden = !settings.snippetsDisabled
        snipDisabledLabel = disabled

        return vstack([
            title(L10n.t("snip.title")),
            sub(L10n.t("snip.sub")),
            group(DS.itemGap - 6),
            editor,                      // список «что заменять | на что | корзина», правка по клику
            group(8),
            sectionTitle(L10n.t("snip.expandOn")),
            keys,                        // [Пробел] [Enter] [Tab]
            disabled,                    // «Автозамена отключена…» — видна, когда все галочки сняты
            hint(L10n.t("snip.hint"))    // раскладка/регистр не учитываются + пример
        ])
    }
    private weak var snipDisabledLabel: NSTextField?
    private func refreshSnipDisabled() { snipDisabledLabel?.isHidden = !settings.snippetsDisabled }
    @objc private func toggleSnipSpace(_ s: NSButton) { settings.snippetExpandSpace = (s.state == .on); refreshSnipDisabled() }
    @objc private func toggleSnipEnter(_ s: NSButton) { settings.snippetExpandEnter = (s.state == .on); refreshSnipDisabled() }
    @objc private func toggleSnipTab(_ s: NSButton)   { settings.snippetExpandTab   = (s.state == .on); refreshSnipDisabled() }

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

        // Вид ЗНАЧКА — визуальный выбор квадратными сегментами с реальными значками (автор 23.07).
        // Порядок сегментов = iconStyleKeys. Язык рядом — отдельная галка (работает со всеми).
        let iconSeg = NSSegmentedControl()
        iconSeg.segmentStyle = .texturedRounded
        iconSeg.segmentCount = iconStyleKeys.count
        iconSeg.trackingMode = .selectOne
        let brandSeg: NSImage? = {
            guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            let sq = NSImage(size: NSSize(width: 17, height: 17))
            sq.lockFocus(); img.draw(in: NSRect(x: 0, y: 1, width: 17, height: 15)); sq.unlockFocus()
            sq.isTemplate = true; return sq
        }()
        let segImgs: [NSImage?] = [
            brandSeg ?? NSImage(systemSymbolName: "k.square", accessibilityDescription: nil),
            NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil),
            // В самом сегменте — монохромный символ флага, а не эмодзи: в выборе важна узнаваемость
            // пункта, а цветной флажок рядом с серыми значками читался бы как «уже включено».
            NSImage(systemSymbolName: "flag", accessibilityDescription: nil),
            NSImage(systemSymbolName: "nosign", accessibilityDescription: nil),
        ]
        let segTips = [L10n.t("gen.icon.brand"), L10n.t("gen.icon.keyboard"),
                       L10n.t("gen.icon.flag"), L10n.t("gen.icon.hidden")]
        for (i, img) in segImgs.enumerated() {
            iconSeg.setImage(img, forSegment: i)
            iconSeg.setImageScaling(.scaleProportionallyDown, forSegment: i)
            iconSeg.setWidth(44, forSegment: i)
            iconSeg.setToolTip(segTips[i], forSegment: i)
        }
        iconSeg.selectedSegment = iconStyleKeys.firstIndex(of: settings.menuBarStyle) ?? 1
        iconSeg.target = self; iconSeg.action = #selector(iconStyleSegChanged(_:))

        var general: [NSView] = [
            title(L10n.t("gen.title")),
            sub(L10n.t("gen.sub")),
            group(8),
            card([
                controlRow(L10n.t("priv.lang"), langPop),
                switchRow(L10n.t("switch.login"), nil, settings.launchAtLogin, #selector(toggleLogin))
            ]),
            group(6),
            sectionTitle(L10n.t("gen.icon")),
            card([
                controlRow(L10n.t("gen.iconPick"), iconSeg),
                switchRow(L10n.t("gen.iconLang"), nil, settings.menuBarShowLanguage, #selector(toggleIconLang))
            ]),
            group(2),
            hint(L10n.t("gen.iconHint")),
        ]
        if settings.menuBarStyle == "hidden" {
            // Значок скрыт — всегда объясняем, как добраться до приложения. Текст зависит от языка:
            // виден язык → по клику на RU/EN открывается меню; ничего не видно → перезапуск из «Программ».
            general.append(hint(L10n.t(settings.menuBarShowLanguage ? "gen.iconHiddenLang" : "gen.iconHidden")))
        }
        general.append(contentsOf: [
            group(6),
            card([ switchRow(L10n.t("gen.silent"), L10n.t("gen.silentSub"),
                             !settings.silentMode, #selector(toggleSoundsEnabled)) ]),
            group(6),
            sectionTitle(L10n.t("gen.access")),
            card([ buttonRow([perm, mic]) ]),
            group(2),
            hint(L10n.t("gen.accessHint")),
            group(2),
            hint(L10n.t("gen.micHint"))
        ])
        return vstack(general)
    }

    /// Ключи стилей значка в порядке сегментов (см. AppSettings.menuBarStyle).
    private let iconStyleKeys = ["brand", "keyboard", "flag", "hidden"]

    @objc private func iconStyleSegChanged(_ s: NSSegmentedControl) {
        settings.menuBarStyle = iconStyleKeys[max(0, min(s.selectedSegment, iconStyleKeys.count - 1))]
        MenuBarController.shared?.applyIconStyle()
        reshow()   // показать/скрыть предупреждение про пустую строку меню
    }
    /// Контрол выбора комбинации (перерисовывает предупреждение при смене).
    private func instantSwitchControl() -> NSView {
        let c = InstantSwitchControl()
        c.onChange = { [weak self] in
            CapsRemap.reconcile()   // сменили комбинацию (на/с Caps) — ремап должен догнать выбор
            GlobeKey.reconcile()    // …и системная роль 🌐 тоже (забрать/вернуть)
            DispatchQueue.main.async { self?.reshow() }
        }
        return c
    }

    /// Честно пишем, ЧТО перестанет работать с выбранной комбинацией (Spotlight и т.п.) — и что
    /// это обратимо: выключил тумблер, системное действие вернулось само (мы просто перестаём
    /// глотать событие, системные настройки не трогаем).
    private func instantSwitchStatusView() -> NSView {
        guard settings.instantSwitchEnabled else { return hint(L10n.t("is.offHint")) }
        let shadowed = InstantSwitchControl.shadows(mode: settings.instantSwitchMode,
                                                    keyCode: settings.instantSwitchKeyCode,
                                                    mods: settings.instantSwitchMods)
        guard let shadowed else { return hint(L10n.t("is.onClean")) }
        return hint(String(format: L10n.t("is.onShadow"), shadowed))
    }

    @objc private func toggleInstantSwitch(_ s: NSSwitch) {
        if s.state == .on {
            let shadowed = InstantSwitchControl.shadows(mode: settings.instantSwitchMode,
                                                        keyCode: settings.instantSwitchKeyCode,
                                                        mods: settings.instantSwitchMods)
            if let shadowed {
                let a = NSAlert()
                a.messageText = L10n.t("is.warn.title")
                a.informativeText = String(format: L10n.t("is.warn.body"), shadowed)
                a.addButton(withTitle: L10n.t("is.warn.ok"))
                a.addButton(withTitle: L10n.t("common.cancel"))
                guard a.runModal() == .alertFirstButtonReturn else { s.state = .off; return }
            }
        }
        settings.instantSwitchEnabled = (s.state == .on)
        CapsRemap.reconcile()   // Caps-режим живёт через hidutil-ремап — синхронизируем с тумблером
        GlobeKey.reconcile()    // 🌐-режим: забрать клавишу у системы живьём / вернуть как было
        reshow()
    }

    @objc private func toggleIconLang(_ s: NSSwitch) {
        settings.menuBarShowLanguage = (s.state == .on)
        MenuBarController.shared?.applyIconStyle()
        reshow()
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
                switchRow(L10n.t("upd.check2"), L10n.t("upd.check2Sub"), checkOn, #selector(toggleAutoCheck), enabled: !silent,
                          help: L10n.t("upd.check2Help")),
                switchRow(L10n.t("upd.silent"), L10n.t("upd.silentSub"), silent, #selector(toggleSilentUpdate),
                          help: L10n.t("upd.silentHelp")),
                switchRow(L10n.t("upd.beta"), L10n.t("upd.betaSub"), settings.betaChannel, #selector(toggleBetaChannel),
                          help: L10n.t("upd.betaHelp")),
                buttonRow([checkBtn])
            ]),
            group(2),
            hint(L10n.t("upd.foot"))
        ])
    }

    /// Все ползунки громкости в одном месте: ключ запоминания → чтение/запись значения.
    private var volumeSliders: [(key: String, get: () -> Double, set: (Double) -> Void)] {
        [("switch",    { self.settings.soundVolume },          { self.settings.soundVolume = $0 }),
         ("translate", { self.settings.translateSoundVolume }, { self.settings.translateSoundVolume = $0 }),
         ("voice",     { self.settings.voiceSoundVolume },     { self.settings.voiceSoundVolume = $0 })]
    }

    /// Пользователь двигал ползунок, пока звук был выключён → его выбор важнее нашей памяти.
    /// Зовётся из каждого обработчика громкости.
    private func noteVolumeTouchedWhileMuted(_ key: String) {
        guard settings.silentMode else { return }
        settings.setMutedBackup(key, nil)
    }

    /// Тумблер «Звуки». Формулировка ПОЛОЖИТЕЛЬНАЯ намеренно (просьба автора 28.07): у строки
    /// «Вообще без звуков» включение означало тишину, и рефлекс «выключил — молчит, включил —
    /// слышно» не срабатывал. Теперь срабатывает буквально.
    ///
    /// Логика громкостей (его же): выключаем звук — уводим все ползунки в ноль, но ЗАПОМИНАЕМ, где
    /// они стояли. Ползунки остаются активными: захочет — подвинет. Включаем обратно — те, которых
    /// он не трогал, возвращаются на прежние места, а тронутые остаются как он выставил (их память
    /// стёрлась в момент, когда он их двинул).
    @objc private func toggleSoundsEnabled(_ s: NSSwitch) {
        let soundsOn = (s.state == .on)
        settings.silentMode = !soundsOn
        if !soundsOn {
            for v in volumeSliders {
                settings.setMutedBackup(v.key, v.get())
                v.set(0)
            }
        } else {
            for v in volumeSliders {
                let saved = settings.mutedBackup(v.key)
                if saved >= 0 { v.set(saved) }      // не трогал — вернём как было
                settings.setMutedBackup(v.key, nil) // трогал — оставляем его значение
            }
            // Слышно, что именно вернулось и на какой громкости. При ВЫКЛЮЧЕНИИ, разумеется, молчим.
            if settings.soundEnabled, !settings.soundName.isEmpty {
                let cue = settings.soundName == "keyboop"
                    ? NSSound(data: CueSynth.switchData) : NSSound(named: settings.soundName)
                Sounds.play(cue, volume: settings.soundVolume, as: "switch")
            }
        }
        // Перерисовать раздел: ползунки должны показать новые значения (0 либо восстановленные).
        DispatchQueue.main.async { [weak self] in self?.reshow() }
    }
    @objc private func toggleAutoCheck(_ s: NSSwitch) { UpdaterController.shared.automaticChecks = (s.state == .on) }
    @objc private func toggleSilentUpdate(_ s: NSSwitch) {
        settings.silentAutoUpdate = (s.state == .on)
        // silent требует проверки → при включении форсим её ВКЛ; reshow перерисует раздел, и тумблер
        // «Проверять обновления» станет вкл+серым (а при выключении silent — снова доступным).
        if settings.silentAutoUpdate {
            UpdaterController.shared.automaticChecks = true
            // Апдейт мог быть уже скачан и ждать нашего уведомления — в тихом режиме его не будет,
            // поэтому запускаем ожидание простоя прямо сейчас (иначе он висит до перезапуска).
            UpdaterController.shared.noteSilentModeEnabled()
        } else {
            // Передумали: гасим взведённое ожидание, иначе оно доработает и поставит вопреки «нет».
            UpdaterController.shared.cancelSilentWait()
        }
        // Откладываем на такт: reshow() сносит contentStack вместе с ЭТИМ ЖЕ NSSwitch, а на macOS 26
        // это teardown его SwiftUI-графа изнутри собственного sendAction/анимации (см. RowMetrics).
        DispatchQueue.main.async { [weak self] in self?.reshow() }
    }
    @objc private func toggleBetaChannel(_ s: NSSwitch) {
        settings.betaChannel = (s.state == .on)
        // Смена канала — это изменение того, ЧТО мы ищем, а не когда. Без перезавода цикла новый
        // выбор доехал бы только к следующей плановой проверке, а у агента в строке меню она может
        // быть через сутки: человек включил бету и решил бы, что тумблер не работает.
        UpdaterController.shared.noteChannelChanged()
    }
    @objc private func checkForUpdates() { UpdaterController.shared.checkNow() }

    /// О программе — версия, лицензия, обновления.
    private func buildAbout() -> NSView {
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
        let fb = NSButton(title: L10n.t("about.fbBtn"), target: self, action: #selector(openFeedback))
        fb.bezelStyle = .rounded; fb.controlSize = .regular
        // Лог относится ко ВСЕМУ приложению (не только к диктовке) — живёт рядом с «Написать разработчику».
        let logBtn = NSButton(title: L10n.t("voice.log"), target: self, action: #selector(openLog))
        logBtn.bezelStyle = .rounded; logBtn.controlSize = .regular
        let tg = NSButton(title: L10n.t("about.updTg"), target: self, action: #selector(openTelegram))
        tg.bezelStyle = .rounded; tg.controlSize = .regular
        let whatsNew = NSButton(title: L10n.t("about.whatsNew"), target: self, action: #selector(showWhatsNew))
        whatsNew.bezelStyle = .rounded; whatsNew.controlSize = .regular
        let welBtn = NSButton(title: L10n.t("about.welcome"), target: self, action: #selector(showWelcomeTour))
        welBtn.bezelStyle = .rounded; welBtn.controlSize = .regular

        return vstack([
            title(L10n.t("about.title")),
            sub(L10n.t("about.tagline")),
            group(10),
            sectionTitle(L10n.t("about.whatTitle")),
            // Хоткеи в описании — ТЕКУЩИЕ пользовательские, а не зашитые: инструкция,
            // которая расходится с настройками, хуже отсутствующей.
            sub(String(format: L10n.t("about.what"), hotkeyDisplayString())),
            group(8),
            sectionTitle(L10n.t("about.canTitle")),
            sub(String(format: L10n.t("about.can"), hotkeyDisplayString())),
            group(8),
            sectionTitle(L10n.t("about.nuanceTitle")),
            sub(L10n.t("about.nuance")),
            group(10),
            sectionTitle(L10n.t("about.fbTitle")),
            sub(L10n.t("about.fbBody")),
            group(4),
            card([ buttonRow([fb, logBtn]) ]),
            group(2),
            hint(L10n.t("about.logHint")),
            group(10),
            sectionTitle(L10n.t("about.updTitle")),
            sub(L10n.t("about.updBody")),
            group(4),
            card([ buttonRow([tg]) ]),
            group(10),
            card([
                controlRow(L10n.t("about.version"), versionValue(Changelog.versionWithName(ver))),
                controlRow(L10n.t("about.license"), valueText(L10n.t("about.licenseVal"))),
                controlRow(L10n.t("about.rescued"), valueText(rescuedDisplay())),
                controlRow(L10n.t("about.dictated"), valueText(dictatedDisplay())),
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
        return Self.grouped(n)
    }
    /// Счётчик надиктованного голосом: «12 480 символов · 1 903 слова». Пока 0 — тёплая заглушка.
    private func dictatedDisplay() -> String {
        let c = settings.voiceChars, w = settings.voiceWords
        guard c > 0 else { return L10n.current == .ru ? "пока ни слова 🎙" : "not a word yet 🎙" }
        if L10n.current == .ru {
            return "\(Self.grouped(c)) \(Self.pluralRu(c, "символ", "символа", "символов"))"
                 + " · \(Self.grouped(w)) \(Self.pluralRu(w, "слово", "слова", "слов"))"
        }
        return "\(Self.grouped(c)) chars · \(Self.grouped(w)) \(w == 1 ? "word" : "words")"
    }
    /// Число с пробелами-разделителями тысяч («1 247»).
    private static func grouped(_ n: Int) -> String {
        let fmt = NumberFormatter(); fmt.numberStyle = .decimal; fmt.groupingSeparator = " "
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// Русское склонение по числу: 1 символ / 2 символа / 5 символов (11–14 — всегда «многих»).
    private static func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n100 = n % 100, n10 = n % 10
        if n100 >= 11 && n100 <= 14 { return many }
        if n10 == 1 { return one }
        if (2...4).contains(n10) { return few }
        return many
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
            // ⚠️ Краш при ВТОРОМ открытии (крэш-репорт 27.07, EXC_BAD_ACCESS/SIGSEGV на главном
            // потоке с пометкой pointer authentication failure). У NSWindow по умолчанию
            // isReleasedWhenClosed = true: после закрытия красной кнопкой AppKit объект освобождает,
            // а наша переменная whatsNewWindow держит висячий указатель. Проверка «== nil» его не
            // ловит (указатель не nil, он протух), и мы лезем в contentView освобождённого объекта.
            // Само не чинится: владелец (DetailVC) живёт до конца работы приложения.
            w.isReleasedWhenClosed = false
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
        // ⚠️ Ниже — общий хвост для ОБОИХ путей. Правка isReleasedWhenClosed оживила ветку else,
        // которая раньше не выполнялась никогда (окно умирало при закрытии): без этого заголовок
        // остался бы на прежнем языке, а список — прокрученным туда, где человек его бросил, то есть
        // он открыл бы «Что нового» и увидел старые версии вместо свежих.
        whatsNewWindow?.title = L10n.t("about.whatsNew")
        (whatsNewWindow?.contentView as? NSScrollView)?.documentView?.scroll(.zero)
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
        voiceModelButton.removeAll()
        // Раздел собран по ТЕКУЩЕМУ состоянию диска → запоминаем сигнатуру, чтобы ближайший
        // revalidateVoiceIfShown (активация окна) не делал лишнюю пересборку впустую.
        lastModelsSignature = modelsSignature()
        // Единый список моделей (Parakeet + whisper) — без тумблера движка: движок выводится из
        // активной модели. Любую можно скачать / активировать / удалить (по просьбе автора 2026-06-14).
        unifiedCatalog = unifiedModels()
        // РЕКОМЕНДУЕМЫЕ отдельно от остальных: из пяти моделей человек не понимает, какую брать
        // (репорт 25.07). Сверху две, которыми стоит пользоваться, прочие — под спойлером.
        // Индексы берём от ПОЛНОГО каталога: по ним работают кнопки строк (tag → unifiedCatalog).
        let indexed = Array(unifiedCatalog.enumerated())
        let recommended = indexed.filter { Self.recommendedModelIds.contains($0.element.id) }
        let others = indexed.filter { !Self.recommendedModelIds.contains($0.element.id) }
        // Спойлер раскрыт сам, если «спрятанная» модель активна или уже скачана — иначе человек
        // не нашёл бы то, чем прямо сейчас пользуется.
        if voiceOthersExpanded == nil {
            voiceOthersExpanded = others.contains { isActiveModel($0.element) || $0.element.isInstalled() }
        }
        let modelCard = card(recommended.map { unifiedModelRow($0.element, index: $0.offset) })

        let histClear = NSButton(title: L10n.t("voice.histClear"), target: self, action: #selector(clearVoiceHistory))
        histClear.bezelStyle = .rounded; histClear.controlSize = .regular
        let histShow = NSButton(title: L10n.t("voice.showHistory"), target: self, action: #selector(showVoiceHistory))
        histShow.bezelStyle = .rounded; histShow.controlSize = .regular

        // РАСКЛАДКА ПО СМЫСЛУ.
        // Было: 12 разнородных строк в ОДНОЙ карточке. Микрофон стоял в пятой строке, а его же
        // прогрев — в восьмой, через две чужие. Кнопка системной панели звука («Открыть настройки
        // звука…») сидела прямо над нашим собственным «Звуком записи», и слово «звук» в двух
        // разных смыслах читалось как дубль. Теперь четыре карточки с заголовками; ровно четыре,
        // потому что коралловый акцент, встречающийся шесть раз на экране, перестаёт быть акцентом.
        warmBox = nil; volumeBox = nil; autoEnterBox = nil; othersBox = nil; outputBox = nil   // ссылки прошлой сборки недействительны
        var views: [NSView] = [
            title(L10n.t("voice.title")),
            group(8),
            // A. Самое главное: включить и чем вызывать. Без заголовка — идёт сразу под названием.
            card([
                switchRow(L10n.t("voice.on"), nil, settings.voiceEnabled, #selector(toggleVoice)),
                controlRow(L10n.t("voice.hotkey"), voiceHotkeyRow()),
                controlRow(L10n.t("voice.mode"), voiceModeControl(), subtitle: L10n.t("voice.modeSub")),
                // Подпись + кружок «i»: настройка молча ломала диктовку двуязычным людям. Тест 30.07
                // (четыре диктовки смешанной речи): на «Авто» и на «Русском» всё хорошо, а с
                // принудительным English русский не распознаётся вовсе. Связать одно с другим человеку
                // было неоткуда. Подпись однострочная и усекается (settingRow), длинное объяснение — в help.
                controlRow(L10n.t("voice.lang"), voiceLangControl(),
                           subtitle: L10n.t("voice.langSub"), help: L10n.t("voice.langHelp")),
            ]),
            group(6),
            sectionTitle(L10n.t("voice.grpMic")),
            group(8),
            // B. Всё про устройство ввода в одном месте: выбор, прогрев и его окно, системный уровень.
            card([
                controlRow(L10n.t("voice.mic"), micSelectorControl()),
                switchRow(L10n.t("voice.warm"), L10n.t("voice.warmSub"), settings.voiceWarmWindow, #selector(toggleWarmWindow),
                          help: L10n.t("voice.warmHelp")),
                makeWarmBox(),
                buttonRow([soundSettingsLink()]),
            ]),
            group(6),
            sectionTitle(L10n.t("voice.grpDictation")),
            group(8),
            // C. Поведение самой диктовки. Наш звук записи живёт ЗДЕСЬ, а системный уровень входа —
            // в карточке микрофона: два разных смысла разведены по разным карточкам.
            card([
                switchRow(L10n.t("voice.escCancel"), L10n.t("voice.escCancelSub"), settings.escCancelsDictation, #selector(toggleEscCancel),
                          help: L10n.t("voice.escHelp")),
                // ⚠️ Подпись МЕНЯЕТСЯ, когда движок не тот (30.07). Потоковый путь требует Parakeet
                // (VoiceController.useStreaming), и на whisper тумблер включался, а не делал ничего:
                // автор включил, продиктовал, не увидел ничего и решил, что фича сломана. Сам тумблер
                // при этом НЕ гасим: человек мог включить его заранее, до выбора движка, и отнимать
                // у него переключатель было бы грубее, чем честно сказать, чего не хватает.
                switchRow(L10n.t("voice.streaming"),
                          settings.voiceEngine == "parakeet" ? L10n.t("voice.streamingSub")
                                                            : L10n.t("voice.streamNeedsPk"),
                          settings.voiceStreaming, #selector(toggleVoiceStreaming),
                          help: L10n.t("voice.streamHelp")),
                switchRow(L10n.t("voice.sound"), L10n.t("voice.soundSub"), settings.voiceSoundEnabled, #selector(toggleVoiceSound),
                          help: L10n.t("voice.soundHelp")),
                makeVolumeBox(),
                // «Как вставлять текст» больше НЕ висит отдельной ссылкой между карточкой и
                // заголовком — она была там сиротой, без карточки и без заголовка. Теперь это
                // обычная строка внутри «Диктовки», а четыре правила выезжают под ней.
                outputGroupRow(),
                makeOutputBox(),
            ]),
        ]
        views.append(contentsOf: [
            group(6),
            sectionTitle(L10n.t("voice.modelsTitle")),
            group(8),
            modelCard
        ])
        // «Другие модели» — СРАЗУ за двумя рекомендованными, до пояснений: это продолжение списка,
        // а не сноска к нему. Пояснительный текст уходит ниже — под раскрывшийся список.
        if !others.isEmpty {
            // Без треугольника раскрытия (он автору разонравился) и БЕЗ reshow: список строится
            // всегда и лежит в шторке, кнопка лишь меняет её isHidden. Отправитель клика при этом
            // жив, поэтому обёртка в async здесь не нужна.
            let expanded = voiceOthersExpanded ?? false
            let box = CollapsibleRow(row: card(others.map { unifiedModelRow($0.element, index: $0.offset) }),
                                     separator: group(4), visible: expanded)
            othersBox = box
            views.append(contentsOf: [group(4),
                                      flatLink(String(format: L10n.t("voice.othersN"), others.count),
                                               action: #selector(toggleVoiceOthers)),
                                      box])
        }
        views.append(contentsOf: [
            group(6),
            hint(L10n.t("voice.modelsNote")),
            group(2),
            hint(L10n.t("voice.sizeNote")),          // чем крупнее модель, тем медленнее (и, вероятно, точнее)
            group(6),
        ])
        #if !arch(arm64)
        views.append(contentsOf: [hint(L10n.t("voice.intelNote")), group(6)])
        #endif
        views.append(contentsOf: [
            group(6),
            sectionTitle(L10n.t("voice.grpDuck")),
            group(8),
            card([
                switchRow(L10n.t("voice.duck"), L10n.t("voice.duckSub"), settings.voiceDuck,
                          #selector(toggleDuck), help: L10n.t("voice.duckHelp")),
                controlRow(L10n.t("voice.duckLevel"), duckLevelControl(), enabled: settings.voiceDuck),
            ]),
            group(6),
            sectionTitle(L10n.t("voice.grpHistory")),
            group(8),
            card([
                switchRow(L10n.t("voice.history"), L10n.t("voice.historySub"), settings.voiceHistoryEnabled, #selector(toggleVoiceHistory)),
                switchRow(L10n.t("hist.lock.toggle"), L10n.t("hist.lock.toggleSub"), HistoryGate.enabled, #selector(toggleHistoryLock),
                          help: L10n.t("hist.lockHelp")),
                // Срок хранения управляет не только окном истории: по нему же исчезает пункт меню
                // «Скопировать последнюю диктовку» (MenuBarController → VoiceHistory.lastVisible).
                // Связка неочевидная, поэтому названа вслух.
                controlRow(L10n.t("voice.retention"), historyRetentionControl(),
                           subtitle: L10n.t("voice.retentionSub"), help: L10n.t("voice.retentionHelp")),
                buttonRow([histShow, histClear])
            ]),
            group(2),
            hint(L10n.t("voice.foot"))
        ])
        return vstack(views)
    }

    // MARK: единый список моделей распознавания (Parakeet + whisper, без тумблера движка)

    private var unifiedCatalog: [UnifiedModel] = []
    /// Что показываем сразу: Neural-Engine-модель и самая сильная whisper. Остальные — под спойлером.
    private static let recommendedModelIds: Set<String> = ["parakeet", "large-v3-turbo"]
    /// nil — ещё не решали (решим по факту: активна/скачана ли «спрятанная» модель).
    private var voiceOthersExpanded: Bool?
    private var downloadingModelId: String?      // какая модель качается сейчас (одна за раз)
    private var downloadProgress = 0.0
    // Сторож застревания загрузки (репорт 23.07.2026: Parakeet «завис на 2%» — HF-CDN из RU
    // капризен, а прогресс FluidAudio при затыке честно замирает; UI молчал и выглядел сломанным).
    private var dlLastChangeAt = Date()
    private var dlLoggedDecile = -1
    private var dlStallTimer: Timer?

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
        var list: [UnifiedModel] = []
        #if arch(arm64) && !KEYBOOP_NO_PARAKEET   // Intel: Parakeet физически отсутствует в сборке (нет Neural Engine) — не дразним
        list.append(UnifiedModel(engine: "parakeet", id: "parakeet",
                                 display: L10n.t("voice.pkName"), size: L10n.size("~465 MB"), note: L10n.t("voice.pkDesc")))
        #endif
        list += ModelDownloader.catalog.map {
            UnifiedModel(engine: "whisper", id: $0.name, display: Self.whisperDisplayName($0.name),
                         size: L10n.size($0.size), note: L10n.t($0.note))
        }
        return list
    }

    /// Человекочитаемое имя whisper-модели (вопрос автора 28.07: «Base, Small, Medium — непонятно,
    /// что это Whisper»). В списке они стояли голыми идентификаторами рядом с названным по имени
    /// Parakeet, и выглядело это как размеры чего-то безымянного, а не как отдельный движок.
    static func whisperDisplayName(_ id: String) -> String {
        let pretty = id.split(separator: "-").map { part -> String in
            // «v3» оставляем как есть, остальное с заглавной: large-v3-turbo → Large v3 Turbo
            part.first == "v" && part.dropFirst().allSatisfy(\.isNumber) ? String(part) : part.capitalized
        }.joined(separator: " ")
        return "Whisper " + pretty
    }

    /// Шторки раздела «Голос». Ссылки СЛАБЫЕ и обнуляются в начале сборки: иначе после законной
    /// пересборки (смена языка, докачка модели, revalidateVoiceIfShown) они указывали бы на строки
    /// прошлой сборки, и анимация молча перестала бы работать.
    private weak var warmBox: CollapsibleRow?
    private weak var volumeBox: CollapsibleRow?

    private func makeWarmBox() -> CollapsibleRow {
        let box = CollapsibleRow(row: subordinateRow(controlRow(L10n.t("voice.warmDur"), warmDurationControl())),
                                 separator: hairline(), visible: settings.voiceWarmWindow)
        warmBox = box
        return box
    }
    private func makeVolumeBox() -> CollapsibleRow {
        let box = CollapsibleRow(row: subordinateRow(controlRow(L10n.t("voice.soundVol"), voiceVolumeSlider())),
                                 separator: hairline(), visible: settings.voiceSoundEnabled)
        volumeBox = box
        return box
    }
    /// ⚠️ ЗДЕСЬ БЫЛ ЛЕВЫЙ ОТСТУП У ПОДЧИНЁННЫХ СТРОК — УБРАН 29.07, НЕ ВОЗВРАЩАТЬ БЕЗ РАЗБОРА.
    /// Идея была пометить отступом строки-параметры («Громкость» под «Звуком записи», «Окно
    /// прогрева» под «Мгновенным стартом»), чтобы они читались как подчинённые. На практике автор
    /// увидел это как случайную поломку выравнивания: «почему надпись чуть правее съехала, как будто
    /// какой-то отступ появился». Приём, который приходится объяснять, свою работу не делает.
    /// Связь и так очевидна: подчинённая строка появляется и исчезает ВМЕСТЕ с родительским
    /// тумблером, и стоит вплотную под ним.
    private func subordinateRow(_ row: NSView) -> NSView { row }

    private weak var outputBox: CollapsibleRow?
    /// Строка «Как вставлять текст»: заголовок + сводка текущего состояния + ссылка-раскрытие.
    /// Сводка нужна, чтобы человеку не приходилось раскрывать группу ради ответа «а что там сейчас».
    private func outputGroupRow() -> NSView {
        var parts: [String] = []
        if settings.voiceNoCapital { parts.append(L10n.t("voice.sumNoCap")) }
        if settings.voiceNoFinalPeriod { parts.append(L10n.t("voice.sumNoDot")) }
        if settings.voiceAutoEnter { parts.append(L10n.t("voice.sumEnter")) }
        if !settings.voiceTrailingSpace { parts.append(L10n.t("voice.sumNoSpace")) }
        let summary = parts.isEmpty ? L10n.t("voice.sumDefault") : parts.joined(separator: " · ")
        let link = NSButton(title: "", target: self, action: #selector(toggleVoiceOutputGroup))
        link.isBordered = false; link.setButtonType(.momentaryChange)
        link.attributedTitle = NSAttributedString(
            string: L10n.t("voice.outputOpen"),
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DS.coral])
        link.setContentHuggingPriority(.required, for: .horizontal)
        return settingRow(L10n.t("voice.outputGroup"), summary, trailing: link,
                          help: L10n.t("voice.outputHelp"))
    }
    private func makeOutputBox() -> CollapsibleRow {
        let inner = NSStackView(views: [
            subordinateRow(switchRow(L10n.t("voice.noCapital"), L10n.t("voice.noCapitalSub"), settings.voiceNoCapital, #selector(toggleVoiceNoCapital))),
            hairline(),
            subordinateRow(switchRow(L10n.t("voice.noPeriod"), L10n.t("voice.noPeriodSub"), settings.voiceNoFinalPeriod, #selector(toggleVoiceNoPeriod))),
            hairline(),
            subordinateRow(switchRow(L10n.t("voice.autoEnter"), L10n.t("voice.autoEnterSub"), settings.voiceAutoEnter, #selector(toggleVoiceAutoEnter))),
            makeAutoEnterBox(),
            hairline(),
            subordinateRow(switchRow(L10n.t("voice.trailSpace"), L10n.t("voice.trailSpaceSub"), settings.voiceTrailingSpace, #selector(toggleVoiceTrailSpace))),
        ])
        inner.orientation = .vertical; inner.alignment = .width; inner.spacing = 0
        let box = CollapsibleRow(row: inner, separator: hairline(), visible: voiceOutputExpanded ?? false)
        outputBox = box
        return box
    }

    private var voiceOutputExpanded: Bool?
    @objc private func toggleVoiceOutputGroup() {
        let on = !(voiceOutputExpanded ?? false)
        voiceOutputExpanded = on
        outputBox?.setVisible(on, in: contentStack)
    }

    private weak var othersBox: CollapsibleRow?
    @objc private func toggleVoiceOthers() {
        let on = !(voiceOthersExpanded ?? false)
        voiceOthersExpanded = on
        othersBox?.setVisible(on, in: contentStack)
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
        // ⚠️ ГРЕЕМ НОВЫЙ ДВИЖОК СРАЗУ (фикс 30.07). Прогрев жил только в старте приложения
        // (AppDelegate → VoiceController.preload) и грел тот движок, который выбран НА ТОТ МОМЕНТ.
        // Человек менял движок в настройках, новый оставался холодным, и за это платила первая же
        // диктовка: у паракита загрузка под ANE занимает больше полуминуты. Момент переключения —
        // идеальное время греть: человек в настройках, диктовать прямо сейчас не собирается.
        VoiceController.shared.preload()
        // Кнопка «Использовать» живёт в ПЕРЕСОБИРАЕМОЙ строке — снос из её же action это тот самый
        // класс, который на macOS 26 роняет приложение (см. toggleSilentUpdate). Откладываем на такт.
        DispatchQueue.main.async { [weak self] in self?.reshow() }
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
            voiceModelButton[m.id] = dl
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

    /// Строка хоткея диктовки: селектор + кнопка «Проверить».
    private func voiceHotkeyRow() -> NSView {
        let picker = VoiceHotkeyControl()
        let testBtn = NSButton(title: L10n.t("voice.hkTest"), target: self, action: #selector(testVoiceHotkey))
        testBtn.bezelStyle = .rounded
        let row = NSStackView(views: [picker, testBtn])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }

    /// Диагностика: перехватываем следующий keyDown через локальный монитор и сравниваем
    /// с сохранёнными настройками голосового хоткея. Помогает понять, почему «не срабатывает».
    @objc private func testVoiceHotkey() {
        guard settings.voiceEnabled else {
            let a = NSAlert()
            a.messageText = L10n.t("voice.hkTestDisabled")
            a.alertStyle = .informational
            a.addButton(withTitle: L10n.t("voice.hkTestCancel"))
            a.runModal()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90),
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Keyboop"
        let lbl = NSTextField(labelWithString: L10n.t("voice.hkTestPrompt"))
        lbl.font = .systemFont(ofSize: 14)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak panel] ev in
            guard let panel = panel else { return ev }
            NSEvent.removeMonitor(monitor!)
            monitor = nil
            panel.orderOut(nil)
            // Что нажато
            let pressedKC = Int(ev.keyCode)
            var pressedMod: CGEventFlags = []
            if ev.modifierFlags.contains(.option)  { pressedMod.insert(.maskAlternate) }
            if ev.modifierFlags.contains(.shift)   { pressedMod.insert(.maskShift) }
            if ev.modifierFlags.contains(.command) { pressedMod.insert(.maskCommand) }
            if ev.modifierFlags.contains(.control) { pressedMod.insert(.maskControl) }
            // Что сохранено
            let savedMode = self.settings.voiceHotkeyMode
            let savedKC   = self.settings.voiceHotkeyKeyCode
            let savedMod  = CGEventFlags(rawValue: self.settings.voiceHotkeyModifiers)
            let kcOK  = (savedMode == "key") && (pressedKC == savedKC)
            let modOK = pressedMod == savedMod
            let match = kcOK && modOK
            let pressedLabel = ev.charactersIgnoringModifiers?.uppercased() ?? "?"
            func modStr(_ f: CGEventFlags) -> String {
                var s = ""
                if f.contains(.maskControl)  { s += "⌃" }
                if f.contains(.maskAlternate){ s += "⌥" }
                if f.contains(.maskShift)    { s += "⇧" }
                if f.contains(.maskCommand)  { s += "⌘" }
                return s
            }
            let pressedDisp = modStr(pressedMod) + pressedLabel
            let savedDisp   = savedMode == "key"
                ? modStr(savedMod) + (self.settings.voiceHotkeyKeyLabel.isEmpty ? "·" : self.settings.voiceHotkeyKeyLabel)
                : (savedMode == "modkey" ? "одиночный модификатор" : savedMode)
            let a = NSAlert()
            a.messageText = match ? L10n.t("voice.hkTestOk") : L10n.t("voice.hkTestFail")
            var info = "Нажато:   \(pressedDisp)  (kc=\(pressedKC), mod=0x\(String(pressedMod.rawValue, radix: 16)))\n"
            info     += "Сохранено: \(savedDisp)"
            if savedMode == "key" { info += "  (kc=\(savedKC), mod=0x\(String(savedMod.rawValue, radix: 16)))" }
            if !match {
                if savedMode != "key" { info += "\n\nРежим «\(savedMode)» — хоткей-клавиша не задана (нужна запись)." }
                else if !kcOK  { info += "\n\nkeyCode не совпадает: нажата кнопка kc=\(pressedKC), сохранена kc=\(savedKC)." }
                else if !modOK { info += "\n\nМодификатор не совпадает: нажато 0x\(String(pressedMod.rawValue, radix: 16)), сохранено 0x\(String(savedMod.rawValue, radix: 16))." }
            }
            a.informativeText = info
            a.alertStyle = match ? .informational : .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return nil  // не пускаем в поле
        }
        // Если пользователь просто закрыл панель мышью — чистим монитор через 30 сек
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
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
        noteVolumeTouchedWhileMuted("switch")
        settings.soundVolume = s.doubleValue
        if settings.soundEnabled, !settings.soundName.isEmpty {   // короткое превью на новой громкости
            Sounds.play(NSSound(named: settings.soundName), volume: settings.soundVolume)
        }
    }

    private func voiceVolumeSlider() -> NSView {
        let s = NSSlider(value: settings.voiceSoundVolume, minValue: 0, maxValue: 1,
                         target: self, action: #selector(voiceVolChanged(_:)))
        s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return s
    }
    @objc private func toggleVoiceNoCapital(_ s: NSSwitch) { settings.voiceNoCapital = (s.state == .on) }
    @objc private func toggleVoiceNoPeriod(_ s: NSSwitch) { settings.voiceNoFinalPeriod = (s.state == .on) }
    /// Чем «отправлять» после диктовки. Порядок — по распространённости: Enter (Telegram, iMessage,
    /// большинство чатов), ⌘Enter (Gmail, Linear, Slack в режиме «Enter = перенос строки»), ⇧Enter и
    /// ⌃Enter встречаются реже, но у людей просили и их.
    private static let autoEnterCombos: [(String, UInt64)] = [
        ("Enter", 0),
        ("⌘ Enter", CGEventFlags.maskCommand.rawValue),
        ("⇧ Enter", CGEventFlags.maskShift.rawValue),
        ("⌃ Enter", CGEventFlags.maskControl.rawValue),
    ]
    private func autoEnterCombo() -> NSView {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.addItems(withTitles: Self.autoEnterCombos.map { $0.0 })
        let cur = settings.voiceAutoEnterMods
        pop.selectItem(at: Self.autoEnterCombos.firstIndex { $0.1 == cur } ?? 0)
        pop.target = self; pop.action = #selector(autoEnterComboChanged(_:))
        return pop
    }
    @objc private func autoEnterComboChanged(_ p: NSPopUpButton) {
        settings.voiceAutoEnterMods = Self.autoEnterCombos[p.indexOfSelectedItem].1
    }

    private weak var autoEnterBox: CollapsibleRow?
    private func makeAutoEnterBox() -> CollapsibleRow {
        let box = CollapsibleRow(row: subordinateRow(controlRow(L10n.t("voice.autoEnterKey"), autoEnterCombo())),
                                 separator: hairline(), visible: settings.voiceAutoEnter)
        autoEnterBox = box
        return box
    }

    @objc private func toggleVoiceAutoEnter(_ s: NSSwitch) {
        let on = (s.state == .on)
        settings.voiceAutoEnter = on
        autoEnterBox?.setVisible(on, in: contentStack)
    }
    @objc private func toggleVoiceTrailSpace(_ s: NSSwitch) { settings.voiceTrailingSpace = (s.state == .on) }
    @objc private func toggleVoiceSound(_ s: NSSwitch) {
        let on = (s.state == .on)
        settings.voiceSoundEnabled = on
        // Никакого reshow: анимируем ДРУГУЮ вью, отправитель этого action остаётся жив.
        volumeBox?.setVisible(on, in: contentStack)
    }

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
        noteVolumeTouchedWhileMuted("translate")
        settings.translateSoundVolume = s.doubleValue
        guard settings.translateSoundEnabled else { return }   // превью на новой громкости
        let vol = Float(settings.translateSoundVolume)
        let name = settings.translateSoundName
        if name == "keyboop" {
            translateVolPreview?.stop()
            translateVolPreview = Sounds.play(NSSound(data: CueSynth.translateData), volume: Double(vol))
        } else if !name.isEmpty {
            Sounds.play(NSSound(named: name), volume: Double(vol))
        }
    }
    @objc private func toggleEscCancel(_ s: NSSwitch) { settings.escCancelsDictation = (s.state == .on) }
    @objc private func toggleWarmWindow(_ s: NSSwitch) {
        let on = (s.state == .on)
        settings.voiceWarmWindow = on
        warmBox?.setVisible(on, in: contentStack)
    }
    @objc private func toggleVoiceStreaming(_ s: NSSwitch) {
        let on = (s.state == .on)
        settings.voiceStreaming = on
        // Включили, а потоковой модели нет → честно спрашиваем и качаем (~120 МБ).
        guard on, !StreamingEouEngine.modelInstalled, downloadingModelId == nil else { return }
        let a = NSAlert()
        a.messageText = L10n.t("voice.streamDlTitle")
        a.informativeText = L10n.t("voice.streamDlSub")
        a.addButton(withTitle: L10n.t("voice.streamDlGo"))
        a.addButton(withTitle: L10n.t("common.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else {
            settings.voiceStreaming = false; s.state = .off; return   // отказались — выключаем тумблер
        }
        downloadingModelId = "eou-streaming"
        Task {
            let ok = await StreamingEouEngine.shared.download(progress: { _ in })
            await MainActor.run {
                self.downloadingModelId = nil
                let r = NSAlert()
                r.messageText = ok ? L10n.t("voice.streamDlOk") : L10n.t("voice.streamDlFail")
                r.runModal()
                if !ok { self.settings.voiceStreaming = false; s.state = .off }
            }
        }
    }
    private var cuePreview: NSSound?   // удерживаем превью, иначе звук оборвётся
    @objc private func voiceVolChanged(_ s: NSSlider) {
        noteVolumeTouchedWhileMuted("voice")
        settings.voiceSoundVolume = s.doubleValue
        if settings.voiceSoundEnabled {   // превью звука старта на новой громкости
            cuePreview?.stop()
            cuePreview = Sounds.play(NSSound(data: CueSynth.startData), volume: settings.voiceSoundVolume)
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
            // Шторка несёт разделитель внутри себя (см. CollapsibleRow): если добавить ещё и здесь,
            // при схлопывании в карточке повиснет лишняя линия.
            if i > 0, !(r is CollapsibleRow) { v.addArrangedSubview(hairline()) }
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
    private func switchRow(_ title: String, _ subtitle: String?, _ on: Bool, _ action: Selector,
                           help: String? = nil) -> NSView {
        let sw = NSSwitch(); sw.state = on ? .on : .off; sw.target = self; sw.action = action
        return settingRow(title, subtitle, trailing: sw, help: help)
    }
    /// Вариант switchRow с возможностью приглушить (серый + недоступен) — для зависимых настроек.
    private func switchRow(_ title: String, _ subtitle: String?, _ on: Bool, _ action: Selector,
                           enabled: Bool, help: String? = nil) -> NSView {
        let sw = NSSwitch(); sw.state = on ? .on : .off; sw.target = self; sw.action = action
        sw.isEnabled = enabled
        let row = settingRow(title, subtitle, trailing: sw, help: help)
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
    private func controlRow(_ title: String, _ control: NSView, enabled: Bool = true,
                            subtitle: String? = nil, help: String? = nil) -> NSView {
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Выключенная функция не должна предлагать настраивать себя (нелогично и путает): гасим
        // контрол вместе со вложенными — правые контролы часто контейнеры из нескольких кнопок.
        if !enabled { Self.setEnabledDeep(control, false) }
        let row = settingRow(title, subtitle, trailing: control, help: help)
        if !enabled { row.alphaValue = 0.45 }
        return row
    }

    /// Рекурсивно выключить контрол и всё, что внутри (NSControl + наши кастомные вью).
    private static func setEnabledDeep(_ view: NSView, _ on: Bool) {
        if let c = view as? NSControl { c.isEnabled = on }
        for sub in view.subviews { setEnabledDeep(sub, on) }
    }
    /// Ширины правых контролов — КОНСТАНТЫ, без обращения к AppKit-раскладке.
    ///
    /// macOS 26: NSSwitch / NSSlider / NSSegmentedControl / NSPopUpButton внутри рисуются SwiftUI
    /// (AppKit линкует SwiftUICore + PrivateFrameworks/DesignLibrary — WWDC26 session 272). Любой
    /// запрос intrinsicContentSize/fittingSize у такого контрола (и у NSStackView, который их
    /// содержит) прогоняет SwiftUI-ViewGraph через AttributeGraph и делает Swift-Concurrency-проверку
    /// изоляции. Именно там поймали EXC_BREAKPOINT (аппаратный PAC-trap) на машине пользователя в
    /// 0.2.57. Значение нужно ТОЛЬКО чтобы решить, вешать ли tooltip, — меряем «на бумаге».
    /// Белый список «безопасных» вью не годится: правые контролы часто NSStackView-контейнеры,
    /// их intrinsicContentSize рекурсивно меряет вложенные слайдеры/сегменты.
    /// Замеры на macOS 26.3.1 (25D771280a): NSSwitch 54×24, NSPopUpButton 58×24, NSSegmentedControl
    /// 57×24, NSSlider width = NSView.noIntrinsicMetric (-1).
    private enum RowMetrics {
        /// NSSwitch — контрол фиксированного размера (замеры 2026-06-09 и 2026-07-20 совпали).
        static let nsSwitch: CGFloat = 54
        /// Всё остальное справа (popup, слайдер, hotkey-контрол, сегменты, контейнеры-стеки) —
        /// консервативная оценка. Ошибка в бо́льшую сторону безопасна: лишь лишний tooltip там,
        /// где текст и так влезал. Раньше здесь был баг: у NSSlider ширина -1 → ветка `tw > 1`
        /// молча подставляла ширину переключателя строке громкости.
        static let wideControl: CGFloat = 200
        /// Слот кнопки-подсказки «i». Есть у КАЖДОЙ строки, иначе правый край рассыпается между
        /// строками со справкой и без. 22pt — минимум HIG для цели клика: меньше означает, что
        /// промах мимо кружка ПЕРЕКЛЮЧИТ соседний тумблер.
        static let helpSlot: CGFloat = 22
    }

    /// Доступная ширина текстовой колонки строки = ширина блока − отступы − контрол справа − зазор.
    /// contentWidth 600, insets 14+14, spacing 10 → под переключателем ≈508pt (было 388 при 480).
    /// tooltip ставим ТОЛЬКО когда текст в неё не влезает.
    private func availTextWidth(trailing: NSView) -> CGFloat {
        let trailingW = (trailing is NSSwitch) ? RowMetrics.nsSwitch : RowMetrics.wideControl
        return DS.contentWidth - 28 - trailingW - 10
    }
    private func truncates(_ text: String, font: NSFont, within avail: CGFloat) -> Bool {
        (text as NSString).size(withAttributes: [.font: font]).width > avail
    }
    private func settingRow(_ title: String, _ subtitle: String?, trailing: NSView,
                            help: String? = nil) -> NSView {
        let avail = availTextWidth(trailing: trailing) - (help == nil ? 0 : RowMetrics.helpSlot + 10)
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
            // ⚠️ Подсказку в tooltip кладём ВСЕГДА (репорт #41 на 0.2.70: «под некоторыми пунктами
            // есть описание, но оно не отображается полностью… наводя курсор, можно было бы
            // прочитать полностью, хотелось бы иметь возможность прочитать, что там хотел сказать
            // автор»). Раньше tooltip ставился только когда `truncates()` СЧИТАЛ, что текст не
            // влезает, а доступная ширина там оценочная: стоило оценке ошибиться в большую сторону,
            // и текст на экране обрезался, а tooltip не появлялся — то есть прочитать описание было
            // нельзя вообще никак. Лишний tooltip на короткой строке безвреден, недостающий — нет.
            s.toolTip = sub
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let vs = NSStackView(views: [l, s]); vs.orientation = .vertical; vs.alignment = .leading; vs.spacing = 1
            textCol = vs
        } else { textCol = l }
        textCol.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // ⚠️ ПОДСКАЗКА СЛЕВА ОТ КОНТРОЛА И ТОЛЬКО ТАМ, ГДЕ ОНА ЕСТЬ (правка 29.07).
        // Сначала я сделал слот фиксированной ширины в КАЖДОЙ строке — чтобы кружки встали в одну
        // колонку. Вышло хуже: пустые слоты сдвинули ВСЕ тумблеры влево, и ровный правый край,
        // который был раньше, развалился. автор поймал это сразу: «справа от тумблера, там, где их
        // нет, пустое место, отстойно выглядит».
        // Правильно наоборот: кружок вставляем ПЕРЕД контролом и только при наличии текста. Тогда
        // правый край контролов у всех строк одинаковый, а кружок просто стоит рядом со своим.
        var items: [NSView] = [textCol, spacer]
        if let help { items.append(HelpButton(text: help, title: title)) }
        items.append(trailing)
        let row = NSStackView(views: items)
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
        // reshow обновляет доступность тумблера «несколько слов» (серый при авто вкл), но сносит
        // contentStack вместе с этим же NSSwitch — на macOS 26 нельзя делать это изнутри его
        // собственного action (teardown SwiftUI-графа из его же диспатча). Откладываем на такт.
        DispatchQueue.main.async { [weak self] in self?.reshow() }
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
    @objc private func toggleTwoCaps(_ s: NSSwitch) { settings.twoCapsFix = (s.state == .on) }

    /// Насколько приглушать. Проценты, а не «тихо/громко»: у людей очень разные наушники, и «тихо»
    /// у одного громче, чем «громко» у другого. Ноль — полная тишина, вынесен отдельным пунктом,
    /// потому что это не «очень тихо», а другое поведение.
    private let duckLevels = [0, 10, 20, 30, 50]
    private func duckLevelControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: [L10n.t("voice.duckMute")] + duckLevels.dropFirst().map { "\($0)%" })
        pop.selectItem(at: duckLevels.firstIndex(of: settings.voiceDuckLevel) ?? 2)
        pop.target = self; pop.action = #selector(duckLevelChanged(_:))
        return pop
    }
    @objc private func duckLevelChanged(_ s: NSPopUpButton) {
        let i = max(0, min(s.indexOfSelectedItem, duckLevels.count - 1))
        settings.voiceDuckLevel = duckLevels[i]
    }
    @objc private func toggleDuck(_ s: NSSwitch) {
        settings.voiceDuck = (s.state == .on)
        DispatchQueue.main.async { [weak self] in self?.reshow() }   // строка уровня гаснет/зажигается
    }
    /// «Написать разработчику» — теперь наша форма (mailto хрупок: у многих Mail.app не настроен,
    /// кнопка открывала пустоту, и фидбэк умирал молча). Почта осталась фолбэком ВНУТРИ формы.
    @objc private func openFeedback() { FeedbackWindowController.shared.show() }
    @objc private func openTelegram() { Permissions.openTelegramChannel() }
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
    /// Пароль на историю: включение — задать пароль, выключение — подтвердить текущим.
    /// Тумблер откатывается, если пользователь передумал в диалоге.
    @objc private func toggleHistoryLock(_ s: NSSwitch) {
        if s.state == .on {
            HistoryGate.promptSetPassword { ok in s.state = ok ? .on : .off }
        } else {
            HistoryGate.promptDisable { ok in s.state = ok ? .off : .on }
        }
    }
    // Значения в МИНУТАХ: 30, 60, 120, 240, 480, 0 (без удаления)
    private let retentionMins = [30, 60, 120, 240, 480, 0]
    private func historyRetentionControl() -> NSView {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: [L10n.t("ret.30m"), L10n.t("ret.1h"), L10n.t("ret.2h"), L10n.t("ret.4h"), L10n.t("ret.8h"), L10n.t("ret.never")])
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
    /// Ссылка-раскрывашка вместо кнопки. Кнопка читалась как действие («скачать», «применить») и
    /// массивной плашкой перетягивала внимание с двух рекомендованных моделей, хотя всё, что она
    /// делает — «покажи остальные». Правка 25.07.
    /// Коралловая плоская подпись без треугольника: сама говорит, что произойдёт по клику.
    /// Пришла на смену disclosureLink там, где раскрытие анимируется шторкой (автор 28.07:
    /// «эти раскрывающиеся списки я придумал когда-то, но они мне уже не особо нравятся»).
    private func flatLink(_ text: String, action: Selector) -> NSView {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: DS.coral])
        b.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [b, NSView()])
        row.orientation = .horizontal; row.spacing = 0; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        return row
    }

    private func disclosureLink(_ text: String, expanded: Bool, action: Selector) -> NSView {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.attributedTitle = NSAttributedString(
            string: (expanded ? "⌄  " : "›  ") + text,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: DS.coral])
        b.setContentHuggingPriority(.required, for: .horizontal)
        // В общий столбец кладём через контейнер: у vstack выравнивание по левому краю, а плоская
        // кнопка без рамки иначе растянулась бы на всю ширину и ловила клики по пустому месту.
        let row = NSStackView(views: [b, NSView()])
        row.orientation = .horizontal; row.spacing = 0; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        return row
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
        dlLastChangeAt = Date(); dlLoggedDecile = -1
        dlStallTimer?.invalidate()
        dlStallTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, let id = self.downloadingModelId else { return }
            let quiet = Date().timeIntervalSince(self.dlLastChangeAt)
            guard quiet > 45 else { return }
            let pct = Int(self.downloadProgress * 100)
            self.voiceModelStatus[id]?.stringValue = L10n.t("voice.dlStalledShort")
            self.voiceModelStatus[id]?.toolTip = String(format: L10n.t("voice.dlStalledTip"), pct)
            kbLog("модель \(id): скачивание застряло на \(pct)% (без прогресса \(Int(quiet))с) — вероятно, сеть до Hugging Face")
        }
        // ⚠️ Кнопку берём ИЗ СЛОВАРЯ, а не по захваченной ссылке (репорт #39 на 0.2.70: «проценты
        // под моделью растут, а справа стоят на месте; переключишь раздел и вернёшься — актуальные»).
        // Раньше здесь висел `[weak s]` на конкретную кнопку: при любой перестройке раздела кнопка
        // пересоздаётся, слабая ссылка обнуляется, и правая часть замирает навсегда. Метка слева
        // жила в словаре по id и потому продолжала обновляться — отсюда и расхождение цифр.
        let onProgress: (Double) -> Void = { [weak self] p in
            guard let self else { return }
            if p != self.downloadProgress { self.dlLastChangeAt = Date() }
            let dec = Int(p * 10)
            if dec > self.dlLoggedDecile {   // журналим каждые ~10% — репорты «зависло» станут диагностируемыми
                self.dlLoggedDecile = dec
                kbLog("модель \(m.id): скачано \(Int(p * 100))%")
            }
            self.downloadProgress = p
            self.voiceModelStatus[m.id]?.stringValue = "\(Int(p * 100)) %"
            self.voiceModelStatus[m.id]?.toolTip = nil
            self.voiceModelButton[m.id]?.title = "\(Int(p * 100))%"
        }
        let onDone: (Bool) -> Void = { [weak self] ok in
            self?.dlStallTimer?.invalidate(); self?.dlStallTimer = nil
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
        // Удаление тяжёлое (освобождение CoreML-менеджера + removeItem ~465 МБ) и раньше шло на
        // main-потоке → окно морозилось намертво (репорт 03.07.2026, Force Quit). Теперь операция
        // в фоне; кнопку гасим (без двойных кликов), а по завершении на main обновляем список.
        s.isEnabled = false
        s.toolTip = L10n.t("voice.deleting")
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self = self else { return }
            // Удалили активную → переключиться на другую установленную, если есть (иначе диктовка
            // честно попросит скачать модель при следующем использовании — onNeedModel).
            if wasActive, let fallback = self.unifiedModels().first(where: { $0.id != m.id && $0.isInstalled() }) {
                self.activateModel(fallback)   // reshow внутри
            } else {
                self.reshow()
            }
        }
        if m.engine == "whisper" { ModelDownloader.shared.delete(m.id, completion: finish) }
        else { ParakeetEngine.shared.deleteModel(completion: finish) }
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
        // ⚠️ В СВЕТЛОЙ ТЕМЕ У НАС БЫЛО ИНВЕРТИРОВАНО ОТНОСИТЕЛЬНО macOS (замечание автора 29.07 со
        // скриншотом системных настроек). У системы: страница белая, группы чуть СЕРЕЕ. У нас было
        // наоборот — серая страница и белые карточки. В тёмной теме наша схема с системой совпадала,
        // поэтому годами и не бросалось в глаза: баг жил ровно в одной теме.
        // Берём НЕ фиксированный серый, а полупрозрачный чёрный поверх белой страницы: так оттенок
        // следует за «Увеличить контраст» и прочими настройками универсального доступа.
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.075)
                                        : NSColor.black.withAlphaComponent(0.035)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10)
                                    : NSColor.black.withAlphaComponent(0.06)).cgColor
    }
}

/// Подложка страницы настроек: в тёмной теме — живое размытие за окном, в светлой — белый лист.
///
/// Зачем разное (правка 29.07): у macOS в СВЕТЛОЙ теме страница белая, а группы чуть серее. У нас
/// было наоборот, потому что `.underPageBackground` под .aqua даёт серый, а карточки мы рисовали
/// белыми. В тёмной теме материал выглядит правильно, поэтому его и оставляем — меняем только
/// светлую ветку.
final class ThemedBackgroundView: NSView {
    private let darkView: NSView
    private let lightView: NSView
    init(dark: NSView, light: NSView) {
        darkView = dark; lightView = light
        super.init(frame: .zero)
        for v in [dark, light] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        light.wantsLayer = true
        apply()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }
    private func apply() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        darkView.isHidden = !dark
        lightView.isHidden = dark
        lightView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

/// Кружок «i» в строке настройки: по клику показывает полное описание.
///
/// Зачем (репорт #41 и просьба автора 29.07): подписи под строками не влезают по ширине даже после
/// расширения окна до 600 — замерено рендером, четыре подписи всё равно обрезаются. Ширина лечит
/// заголовки и воздух, а описания лечит только сокращённая подпись плюс полный текст по клику.
///
/// Показывается СТРОГО по наличию текста справки, а НЕ по оценке «влезает ли подпись»: эта оценка
/// уже один раз соврала (из-за неё 28.07 tooltip'ы сделали безусловными), и вешать на неё видимую
/// кнопку нельзя.
///
/// Поповер держим СИЛЬНОЙ ссылкой: без неё он умирает сразу после показа (прецедент в
/// VoiceHistoryWindow.showOpacitySlider).
final class HelpButton: NSButton {
    private let helpText: String
    private let rowTitle: String
    private var popover: NSPopover?

    init(text: String, title: String) {
        helpText = text; rowTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        imagePosition = .imageOnly
        target = self
        action = #selector(show)
        // ⚠️ tooltip у кружка НЕ ставим (автор 29.07). Он дублировал бы поповер и вылезал при
        // случайном проходе мышью. Подсказка на «i» — строго по КЛИКУ. Tooltip остаётся у самой
        // ПОДПИСИ строки (там он показывает обрезанный хвост при наведении) — это разные роли.
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    @objc private func show() {
        popover?.close()
        let t = NSTextField(labelWithString: rowTitle)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: helpText)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [t, body])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 328),
        ])
        let vc = NSViewController()
        vc.view = host
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = p
    }
}

/// Строка-«шторка»: подчинённый параметр, который выезжает из-под своего тумблера.
///
/// Зачем именно так: была просьба, чтобы
/// дополнительные пункты «плавно разъезжались, выезжали вниз», и чтобы исчезли треугольники
/// раскрытия. Ключевое ограничение — `reshow()` пересобирает раздел и сносит тот самый тумблер, из
/// чьего action всё началось; анимировать поверх пересборки невозможно в принципе. Поэтому шторка
/// строится ВСЕГДА, а меняется у неё только `isHidden` — отправитель остаётся жив, пересборки нет.
///
/// Скрытый arranged-subview исключается из раскладки NSStackView, поэтому высота карточки и
/// `fittingSize` (её меряет tallestSectionHeight) остаются честными.
///
/// Свой разделитель несёт ВНУТРИ себя: иначе при схлопывании в карточке повисала бы лишняя линия.
final class CollapsibleRow: NSStackView {
    init(row: NSView, separator: NSView, visible: Bool) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(separator)
        addArrangedSubview(row)
        isHidden = !visible
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    /// Показать/спрятать.
    ///
    /// ⚠️ НЕ `animator().isHidden` (правка 29.07 по замечанию автора: «откуда-то они сейчас издалека
    /// очень вылетают»). Появляющаяся вью до первой раскладки имеет нулевой фрейм в левом верхнем
    /// углу, и анимация честно везёт её ОТТУДА на место — через пол-окна. Выглядит как влёт издалека.
    ///
    /// Правильный порядок: сначала показать БЕЗ анимации (вью встаёт на своё место мгновенно, но
    /// прозрачной), и только потом проявить. При скрытии наоборот: сперва погасить, спрятать в
    /// завершении. Двигается при этом только то, что ниже по стеку, и ровно на высоту строки.
    func setVisible(_ on: Bool, in container: NSView?) {
        if on {
            alphaValue = 0
            isHidden = false
            container?.layoutSubtreeIfNeeded()   // встали на место БЕЗ анимации
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak container] in
                self?.isHidden = true
                self?.alphaValue = 1          // вернуть, иначе следующий показ будет невидимым
                container?.layoutSubtreeIfNeeded()
            })
        }
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
        x.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t("act.delete"))
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
