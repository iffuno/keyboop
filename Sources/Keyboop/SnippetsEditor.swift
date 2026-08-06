import AppKit

/// Clip-view с верхним якорем — контент скролла начинается СВЕРХУ (а не снизу), как в канонe автора.
private final class FlippedClipView: NSClipView { override var isFlipped: Bool { true } }

/// Редактор автозамены: список строк «что заменять | на что | корзина», РУЧНАЯ вёрстка на NSStackView.
///
/// Почему не NSTableView (отказались 2026-06-25): его column-tiling неуправляем при фиксированной
/// ширине scrollview — колонка «на что» (без maxWidth) упорно раздувалась на весь клип и выносила
/// колонку корзины за правый край (frameOfCell корзины оказывался на x=tableW, кнопка «пряталась
/// правее» — баг-репорт). Жёсткая фиксация колонок и привязка ширины таблицы не помогали.
/// Ручные строки-HStack дают железную раскладку: trig (фикс) | exp (тянется) | корзина (фикс, у правого
/// края, всегда видна). Бонусом нативно решаются: редактирование по ПЕРВОМУ клику (NSTextField ловит
/// клик сам, без перехвата выделением таблицы) и сохранение на ЛЮБОЙ уход из поля (delegate).
///
/// Инвариант: всегда ровно одна пустая строка в конце — «куда добавлять». Начал писать в неё → снизу
/// появляется новая пустая. Сохраняем в SnippetStore на каждое изменение и на конец редактирования.
final class SnippetsEditor: NSView, NSTextFieldDelegate {
    private var rows: [(String, String)] = []
    /// Какой список редактируем. Их два и они не связаны: автозамена и сниппеты для вставки.
    private let store: PairListStore
    /// Подписи-приглашения в пустой строке: у списков разный смысл колонок.
    private let phLeft: String
    private let phRight: String
    private let rowsStack = NSStackView()
    private let scroll = NSScrollView()
    private let rowHeight: CGFloat = 30
    /// Ширина левой колонки. 120 вместо 150 (автор 06.08): и триггер автозамены, и название
    /// сниппета короткие, а отнятые 30 пунктов уходят туда, где текст длинный.
    private let trigW: CGFloat = 120
    private let trashW: CGFloat = 24

    init(frame frameRect: NSRect, store: PairListStore = SnippetStore.shared,
         phLeft: String = "snip.phTrigger", phRight: String = "snip.phExpansion") {
        self.store = store
        self.phLeft = phLeft
        self.phRight = phRight
        super.init(frame: frameRect)
        rows = store.pairs()
        normalizeTrailing()
        build()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    /// Всегда ровно одна пустая строка в конце (и без «дыр» — пустые в середине схлопываем).
    private func normalizeTrailing() {
        rows.removeAll { $0.0.isEmpty && $0.1.isEmpty }
        rows.append(("", ""))
    }

    private func build() {
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading           // строки прижаты влево; ширину каждой пиним отдельно
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        scroll.contentView = FlippedClipView()   // контент сверху
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false     // по горизонтали НИКОГДА не скроллим
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // «+» — добавить строку (фокус в пустую снизу) с клавиатуры.
        let add = NSButton(title: "", target: self, action: #selector(addRowAction))
        add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.t("snip.add"))
        add.imagePosition = .imageOnly
        add.translatesAutoresizingMaskIntoConstraints = false
        addSubview(add)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 470),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            add.leadingAnchor.constraint(equalTo: leadingAnchor),
            add.widthAnchor.constraint(equalToConstant: 30),
            add.bottomAnchor.constraint(equalTo: bottomAnchor),

            // documentView шириной В КЛИП (без горизонтального скролла), высота — по контенту строк.
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: - Построение строк

    private func rebuild() {
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for i in rows.indices { addRow(i) }
    }

    private func addRow(_ index: Int) {
        let row = makeRow(index)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true   // строка на всю ширину
    }

    private func makeRow(_ index: Int) -> NSView {
        let empty = rows[index].0.isEmpty && rows[index].1.isEmpty
        let isLast = index == rows.count - 1

        let trig = field(mono: true,  value: rows[index].0, id: "trig",
                         placeholder: isLast ? L10n.t(phLeft) : nil)
        let exp  = field(mono: false, value: rows[index].1, id: "exp",
                         placeholder: isLast ? L10n.t(phRight) : nil)

        let trash = NSButton(title: "", target: self, action: #selector(deleteRowAction(_:)))
        trash.bezelStyle = .regularSquare
        trash.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.t("act.delete"))?.withSymbolConfiguration(cfg)
        trash.imagePosition = .imageOnly
        trash.imageScaling = .scaleProportionallyDown
        trash.contentTintColor = .secondaryLabelColor
        trash.toolTip = L10n.t("snip.delRow")
        trash.isHidden = empty                        // у пустой строки удалять нечего
        trash.translatesAutoresizingMaskIntoConstraints = false

        let h = NSStackView(views: [trig, exp, trash])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        h.translatesAutoresizingMaskIntoConstraints = false
        h.wantsLayer = true
        h.layer?.backgroundColor = (index % 2 == 1) ? NSColor.white.withAlphaComponent(0.03).cgColor : NSColor.clear.cgColor

        // trig фикс, корзина фикс, exp тянется (низкий hugging) → корзина всегда у правого края.
        trig.widthAnchor.constraint(equalToConstant: trigW).isActive = true
        trash.widthAnchor.constraint(equalToConstant: trashW).isActive = true
        h.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        trig.setContentHuggingPriority(.required, for: .horizontal)
        trig.setContentCompressionResistancePriority(.required, for: .horizontal)
        exp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return h
    }

    private func field(mono: Bool, value: String, id: String, placeholder: String?) -> NSTextField {
        let f = NSTextField()
        f.identifier = NSUserInterfaceItemIdentifier(id)
        f.stringValue = value
        f.placeholderString = placeholder
        f.isBordered = false
        f.drawsBackground = false
        f.isEditable = true
        f.focusRingType = .none
        f.font = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // MARK: - Редактирование (нативно по первому клику в поле)

    /// Индекс строки, которой принадлежит поле/кнопка (по позиции в стеке — устойчиво к сдвигам).
    private func rowIndex(of view: NSView) -> Int? {
        guard let rowView = view.superview else { return nil }
        return rowsStack.arrangedSubviews.firstIndex(of: rowView)
    }

    @discardableResult
    private func syncField(_ f: NSTextField) -> Int? {
        guard let row = rowIndex(of: f), row < rows.count else { return nil }
        if f.identifier?.rawValue == "trig" { rows[row].0 = f.stringValue } else { rows[row].1 = f.stringValue }
        return row
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let row = syncField(f) else { return }
        save()                                        // сохраняем на КАЖДОЕ изменение, не только по Enter
        // Начали писать в последней (пустой) строке → показать её корзину и добавить новую пустую снизу.
        if row == rows.count - 1, !(rows[row].0.isEmpty && rows[row].1.isEmpty) {
            if let h = f.superview as? NSStackView, let trash = h.arrangedSubviews.last { trash.isHidden = false }
            rows.append(("", ""))
            addRow(rows.count - 1)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        syncField(f)
        save()                                        // уход из поля (Tab/клик/Enter) — тоже сохраняет
    }

    // MARK: - Кнопки

    @objc private func addRowAction() {
        // последняя строка по инварианту пустая → просто ставим в неё фокус
        guard let last = rowsStack.arrangedSubviews.last as? NSStackView,
              let trig = last.arrangedSubviews.first as? NSTextField else { return }
        window?.makeFirstResponder(trig)
    }

    @objc private func deleteRowAction(_ sender: NSButton) {
        guard let row = rowIndex(of: sender), row < rows.count else { return }
        rows.remove(at: row)
        normalizeTrailing()
        rebuild()
        save()
    }

    private func save() {
        // В ПОРЯДКЕ строк (по добавлению) — стор сам отфильтрует пустые и схлопнет дубли.
        store.setAll(rows.map { ($0.0, $0.1) })
    }
}
