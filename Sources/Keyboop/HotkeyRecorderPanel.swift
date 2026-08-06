import AppKit
import CoreGraphics

/// Окно записи комбинации: показывает, ЧТО назначаем, рисует набранное сочетание клавишами-капсулами
/// и спрашивает подтверждение.
///
/// Зачем (просьба автора 28.07): раньше запись шла молча — ни что именно назначается, ни что уже
/// нажато, ни как отменить. Первое же нажатие молча записывалось.
///
/// ⚠️ ГЛАВНОЕ — МОДЕЛЬ ПОВЕДЕНИЯ (переделано по замечанию автора в тот же день). Первая версия
/// показывала «что зажато ПРЯМО СЕЙЧАС», и это было неюзабельно: человек отпускал клавиши, чтобы
/// дотянуться мышью до «Назначить», а комбинация исчезала с экрана. Чтобы подтвердить, пришлось бы
/// держать сочетание зубами.
///
/// Правильная модель — «набрал и отпустил = зафиксировали»:
///   • пока клавиши ЗАЖАТЫ — показываем растущий набор вживую (⌘ → ⌘⇧ → ⌘⇧K);
///   • как только всё отпущено — набор ЗАМИРАЕТ на экране и становится кандидатом, кнопка активна;
///   • начал жать заново — кандидат сбрасывается, читаем новый.
/// То есть держать ничего не нужно: отпустил, посмотрел, нажал «Назначить» мышью.
final class HotkeyRecorderPanel {
    static let shared = HotkeyRecorderPanel()

    private var panel: NSPanel?
    private let subtitle = NSTextField(labelWithString: "")
    private let keysRow = NSStackView()
    private let placeholder = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let commitBtn = NSButton(title: "", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "", target: nil, action: nil)

    private var onCommit: (() -> Void)?
    private var onCancel: (() -> Void)?
    /// Наблюдатель: родительское окно попыталось стать активным, пока идёт запись.
    private var parentKeyObserver: NSObjectProtocol?

    /// Ширина окна. Считана от содержимого: пять капсул по 38 с просветами по 10 это ~330,
    /// плюс поля по 24. Не «на глаз пошире»: именно от самой длинной комбинации, которую вообще
    /// можно записать.
    private static let panelWidth: CGFloat = 380

    private init() {}

    /// Показать окно. `what` — человеческое имя функции («голосовой набор»).
    func show(what: String, over parent: NSWindow?,
              onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        build()
        subtitle.stringValue = String(format: L10n.t("hkrec.for"), what)
        render(parts: [], complete: false)
        guard let p = panel else { return }
        if let parent {
            let pf = parent.frame, s = p.frame
            p.setFrameOrigin(NSPoint(x: pf.midX - s.width / 2, y: pf.midY - s.height / 2))
        } else {
            p.center()
        }
        p.makeKeyAndOrderFront(nil)

        // ⚠️ Пока идёт запись, фокус не должен уезжать на окно настроек (просьба автора 28.07).
        // Настоящий модальный цикл (runModal) сюда не годится: он остановил бы наш локальный монитор
        // событий, которым мы и считываем клавиши. Поэтому мягкая блокировка: как только родительское
        // окно пытается стать ключевым, возвращаем ключ панели. Уход в ДРУГОЕ приложение при этом
        // по-прежнему прекращает запись — это автор счёл правильным (случайно не нажмёшь лишнего).
        if let parent {
            parentKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: parent, queue: .main
            ) { [weak self] _ in
                guard let p = self?.panel, p.isVisible else { return }
                p.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Отрисовать сочетание. `parts` — подписи клавиш по порядку (["⌘", "⇧", "K"]).
    /// `complete` — сочетание зафиксировано и его можно назначать.
    /// `warning` — МЯГКОЕ предупреждение: сочетание занято системной функцией, но назначить
    /// можно. Тем и отличается от `warn(_:parts:)`, который гасит кнопку: там отказ, здесь выбор.
    func render(parts: [String], complete: Bool, warning: String? = nil) {
        keysRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.isHidden = !parts.isEmpty
        for (i, part) in parts.enumerated() {
            if i > 0 { keysRow.addArrangedSubview(Self.plusLabel()) }
            keysRow.addArrangedSubview(Self.keycap(part))
        }
        commitBtn.isEnabled = complete
        commitBtn.keyEquivalent = ""   // подтверждаем только мышью, см. build()
        clearWarning()

        if let w = warning, !w.isEmpty {
            self.warning.stringValue = w
            self.warning.isHidden = false
            hint.isHidden = true
        }
    }

    /// Показать отказ ПРЯМО в окне: сочетание видно, объяснение под ним, запись продолжается.
    ///
    /// Раньше здесь всплывал модальный алерт: он перекрывал само окно записи и обрывал её, так что
    /// человек, случайно нажавший ⌘C, вылетал в начало вместо того, чтобы просто нажать другое
    /// (замечание автора 28.07).
    func warn(_ text: String, parts: [String]) {
        keysRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.isHidden = !parts.isEmpty
        for (i, part) in parts.enumerated() {
            if i > 0 { keysRow.addArrangedSubview(Self.plusLabel()) }
            keysRow.addArrangedSubview(Self.keycap(part, muted: true))
        }
        commitBtn.isEnabled = false
        warning.stringValue = text
        warning.isHidden = false
        hint.isHidden = true
    }

    private func clearWarning() {
        warning.isHidden = true
        hint.isHidden = false
    }

    func hide() {
        onCommit = nil; onCancel = nil
        if let o = parentKeyObserver { NotificationCenter.default.removeObserver(o); parentKeyObserver = nil }
        panel?.orderOut(nil)
    }

    /// Разложить модификаторы в подписи в привычном порядке ⌃⌥⇧⌘ (+ клавиша, если есть).
    static func parts(mods: CGEventFlags, keyLabel: String? = nil) -> [String] {
        var out: [String] = []
        // Caps сюда тоже попадает: пока он зажат, окно иначе показывало «нажмите клавиши», как
        // будто нажатия не видно вовсе — а мы его прекрасно видим и даже разрешаем назначить.
        if mods.contains(.maskAlphaShift) { out.append("⇪") }
        if mods.contains(.maskControl) { out.append("⌃") }
        if mods.contains(.maskAlternate) { out.append("⌥") }
        if mods.contains(.maskShift) { out.append("⇧") }
        if mods.contains(.maskCommand) { out.append("⌘") }
        if let keyLabel, !keyLabel.isEmpty { out.append(keyLabel) }
        return out
    }

    // MARK: - Внутреннее

    /// Клавиша-капсула: как на схемах клавиатуры, а не строкой символов подряд. Так «⌘⇧K» перестаёт
    /// читаться как одно слово, и видно, что клавиш три.
    /// Капсула клавиши. Своим классом, а не голым NSView, ровно из-за одной строчки ниже:
    /// `viewDidChangeEffectiveAppearance`.
    ///
    /// ⚠️ `.cgColor` СНИМАЕТ ДИНАМИЧЕСКИЙ ЦВЕТ ОДИН РАЗ, под текущим оформлением рисования. Раньше
    /// заливка и рамка задавались в статической фабрике и больше никогда не пересчитывались, а
    /// подпись это настоящий NSTextField на `.labelColor`, и она перекрашивается сама. Стоило сменить
    /// тему при открытом окне, и получалось тёмное на тёмном или светлое на светлом. Тот же класс
    /// ошибки, что сломал светлую тему в окне настроек (04.08.2026): цвет надо разрешать в СВОЁМ
    /// оформлении и пересчитывать при его смене.
    private final class KeycapView: NSView {
        var muted = false
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }
        func applyColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderColor = (muted ? NSColor.separatorColor.withAlphaComponent(0.5)
                                            : NSColor.separatorColor).cgColor
            }
        }
    }

    private static func keycap(_ text: String, muted: Bool = false) -> NSView {
        let v = KeycapView()
        v.wantsLayer = true
        v.muted = muted
        v.layer?.cornerRadius = DS.pillRadius
        v.layer?.borderWidth = 1
        v.applyColors()

        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 18, weight: .medium)
        l.textColor = muted ? .tertiaryLabelColor : .labelColor
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualTo: l.widthAnchor, constant: 20),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            v.heightAnchor.constraint(equalToConstant: 38),
        ])
        return v
    }

    /// Тонкий разделитель между клавишами. Именно тонкий и приглушённый, иначе читается как клавиша
    /// «+» в составе сочетания (замечание автора).
    private static func plusLabel() -> NSView {
        let l = NSTextField(labelWithString: "+")
        l.font = .systemFont(ofSize: 12, weight: .ultraLight)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func build() {
        if panel != nil { return }
        // Крестик оставляем (просьба автора): закрытие окна = отмена, обрабатываем через делегата,
        // чтобы запись не осталась висеть с невидимым окном.
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 230),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = L10n.t("hkrec.title")
        p.isReleasedWhenClosed = false     // держим панель сами (см. краш «Что нового», 27.07)
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = PanelDelegate.shared
        PanelDelegate.shared.owner = self

        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingTail

        placeholder.stringValue = L10n.t("hkrec.waiting")
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        keysRow.orientation = .horizontal
        keysRow.spacing = 10                // просвет между клавишами (замечание автора)
        keysRow.alignment = .centerY

        warning.font = .systemFont(ofSize: 11)
        warning.textColor = DS.coral
        warning.alignment = .center
        warning.isHidden = true
        warning.maximumNumberOfLines = 4

        hint.stringValue = L10n.t("hkrec.hint")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 3

        commitBtn.title = L10n.t("hkrec.assign")
        commitBtn.bezelStyle = .rounded
        commitBtn.controlSize = .large
        commitBtn.target = self
        commitBtn.action = #selector(commitTapped)
        commitBtn.isEnabled = false

        cancelBtn.title = L10n.t("hkrec.cancel")
        cancelBtn.bezelStyle = .rounded
        cancelBtn.controlSize = .large
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelTapped)
        // ⚠️ keyEquivalent НЕ ставим ни одной кнопке: Return и Esc — это клавиши, которые человек
        // может захотеть назначить (⌘Return вполне рабочее сочетание). Esc обрабатывает рекордер.

        // Область показа клавиш: фиксированной высоты, чтобы окно не «дышало» при наборе.
        let stage = NSView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(placeholder)
        stage.addSubview(keysRow)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        keysRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stage.heightAnchor.constraint(equalToConstant: 52),
            placeholder.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            keysRow.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            keysRow.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])

        // Кнопки своей естественной ширины и ПАРОЙ ПО ЦЕНТРУ (решение автора 04.08.2026). Растянутые
        // на половину окна каждая и делали его «здоровым и бесполезным»; прижатые вправо смотрелись
        // сиротливо под центрованным текстом. Центруем двумя одинаковыми распорками по краям:
        // так пара стоит по центру независимо от длины подписей и языка интерфейса.
        let leftGap = NSView(), rightGap = NSView()
        let buttons = NSStackView(views: [leftGap, cancelBtn, commitBtn, rightGap])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fill
        leftGap.widthAnchor.constraint(equalTo: rightGap.widthAnchor).isActive = true

        let stack = NSStackView(views: [subtitle, stage, hint, warning, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: DS.contentMargin, bottom: 16, right: DS.contentMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // ⚠️ ШИРИНА ОКНА ПРИБИТА (04.08.2026). Раньше её задавал самый длинный НЕПЕРЕНОСИМЫЙ
            // текст, то есть подсказка: стоило её удлинить, и окно растягивалось на пол-экрана.
            // Теперь наоборот, ширину диктует содержимое, ради которого окно и открыто: самая
            // длинная комбинация это четыре модификатора плюс клавиша, пять капсул по 38 с
            // просветами, около 330 пунктов. Всё остальное переносится по этой ширине.
            content.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stage.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: DS.contentMargin),
            stage.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -DS.contentMargin),
            // ⚠️ Поля для текста предупреждения задаём ЯВНО. Отступов стека многострочной подписи
            // мало: NSTextField с переносом сам растягивает окно и прижимается к краям (замечание
            // автора 28.07 — «текст прям в край»). Плюс переносим по этой же ширине.
            warning.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: DS.contentMargin + 8),
            warning.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -(DS.contentMargin + 8)),
            hint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: DS.contentMargin),
            hint.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -DS.contentMargin),
        ])
        warning.preferredMaxLayoutWidth = Self.panelWidth - 2 * (DS.contentMargin + 8)
        hint.preferredMaxLayoutWidth = Self.panelWidth - 2 * DS.contentMargin
        p.contentView = content
        panel = p
    }

    @objc fileprivate func commitTapped() {
        let cb = onCommit
        hide()
        cb?()
    }

    @objc fileprivate func cancelTapped() {
        let cb = onCancel
        hide()
        cb?()
    }

    /// Закрытие крестиком = отмена. Без этого запись осталась бы активной при невидимом окне,
    /// то есть движок молча стоял бы до перезапуска.
    private final class PanelDelegate: NSObject, NSWindowDelegate {
        static let shared = PanelDelegate()
        weak var owner: HotkeyRecorderPanel?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            owner?.cancelTapped()
            return false          // прячем сами в cancelTapped, окно переиспользуем
        }
    }
}
