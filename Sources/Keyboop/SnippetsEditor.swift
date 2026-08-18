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
    /// Моноширинный ли шрифт в ЛЕВОЙ колонке.
    ///
    /// ⚠️ У автозамены и сниппетов — да: слева стоит последовательность КЛАВИШ («!ee», «итд»), и
    /// моноширинный шрифт честно показывает, что важен каждый знак. У словаря диктовки слева
    /// обычные произнесённые слова, и мониширина превращала бы их в код: «кейбуп» набранное как
    /// консольная команда выглядит настройкой для программиста, а это список для всех.
    private let monoLeft: Bool
    /// Можно ли менять порядок строк перетаскиванием.
    ///
    /// ⚠️ ТОЛЬКО У СНИППЕТОВ (автор 10.08). В автозамене порядок не значит ничего: там срабатывает
    /// совпадение по триггеру, и из списка человек не выбирает. Ручка там была бы предложением
    /// сделать бессмысленную работу, а заодно лишней целью рядом с корзиной.
    private let allowsReorder: Bool
    private let rowsStack = NSStackView()
    private let scroll = NSScrollView()
    private let rowHeight: CGFloat = 30
    /// Ширина левой колонки. 120 вместо 150 (автор 06.08): и триггер автозамены, и название
    /// сниппета короткие, а отнятые 30 пунктов уходят туда, где текст длинный.
    private let trigW: CGFloat = 120
    private let trashW: CGFloat = 24

    /// ВЫСОТА СПИСКА ПО СОДЕРЖИМОМУ (автор 06.08.2026). Раньше стояла жёсткая константа 470, то есть
    /// почти шестнадцать строк ВСЕГДА: у человека с двумя сниппетами полраздела занимала пустота, а
    /// у человека с тридцатью список всё равно скроллился. Теперь растём по числу строк.
    ///
    /// Границы: не ниже трёх строк, чтобы пустой список не выглядел щелью и в него было куда целить
    /// мышью, и не выше десяти, иначе один длинный список выдавит из раздела всё остальное. Дальше
    /// прокрутка, она тут была и раньше.
    private let minRows = 3
    private let maxRows = 10
    private var scrollH: NSLayoutConstraint!

    /// `count` уже включает пустую строку-приглашение в конце, отдельно её не добавляем.
    private func heightForRows(_ count: Int) -> CGFloat {
        CGFloat(min(maxRows, max(minRows, count))) * rowHeight + 2   // +2 на рамку
    }

    init(frame frameRect: NSRect, store: PairListStore = SnippetStore.shared,
         phLeft: String = "snip.phTrigger", phRight: String = "snip.phExpansion",
         allowsReorder: Bool = false, monoLeft: Bool = true) {
        self.store = store
        self.phLeft = phLeft
        self.phRight = phRight
        self.allowsReorder = allowsReorder
        self.monoLeft = monoLeft
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

        scrollH = scroll.heightAnchor.constraint(equalToConstant: heightForRows(rows.count))
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollH,
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
        // Высота меняется вместе с числом строк: добавили сниппет — список подрос, удалили — сжался.
        scrollH?.constant = heightForRows(rows.count)
    }

    private func addRow(_ index: Int) {
        let row = makeRow(index)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true   // строка на всю ширину
    }

    private func makeRow(_ index: Int) -> NSView {
        let empty = rows[index].0.isEmpty && rows[index].1.isEmpty
        let isLast = index == rows.count - 1

        let trig = field(mono: monoLeft, value: rows[index].0, id: "trig",
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

        // Ручка перетаскивания. Слева, а не справа как в iOS: справа уже стоит корзина, и две
        // «хватательные» цели рядом это верный способ удалить сниппет вместо переноса.
        let grip = DragHandle()
        // Прячем И схлопываем: скрытая вью в NSStackView всё равно держит место, и в автозамене
        // слева оставалась бы необъяснимая пустая колонка.
        grip.isHidden = !allowsReorder || empty || rows.count <= 2   // одну строку переставлять некуда
        grip.onBegan = { [weak self] h, p in self?.dragBegan(h, at: p) }
        grip.onMoved  = { [weak self] p in self?.dragMoved(to: p) }
        grip.onEnded  = { [weak self] in self?.dragEnded() }

        let h = NSStackView(views: allowsReorder ? [grip, trig, exp, trash] : [trig, exp, trash])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 0, left: allowsReorder ? 4 : 10, bottom: 0, right: 8)
        h.translatesAutoresizingMaskIntoConstraints = false
        h.wantsLayer = true
        h.layer?.backgroundColor = (index % 2 == 1) ? NSColor.white.withAlphaComponent(0.03).cgColor : NSColor.clear.cgColor

        // trig фикс, корзина фикс, exp тянется (низкий hugging) → корзина всегда у правого края.
        if allowsReorder {
            grip.widthAnchor.constraint(equalToConstant: 16).isActive = true
            grip.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        }
        trig.widthAnchor.constraint(equalToConstant: trigW).isActive = true
        trash.widthAnchor.constraint(equalToConstant: trashW).isActive = true
        h.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        trig.setContentHuggingPriority(.required, for: .horizontal)
        trig.setContentCompressionResistancePriority(.required, for: .horizontal)
        exp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return h
    }

    // MARK: - Перестановка строк перетаскиванием (автор 10.08)

    private var dragGhost: NSImageView?
    private var dropLine: NSView?
    private var dragFrom: Int?
    private var dragTarget = 0
    private var dragStartY: CGFloat = 0
    private var dragOriginY: CGFloat = 0

    /// ⚠️ БЕЗ ВЛОЖЕННОГО ЦИКЛА СОБЫТИЙ (переделано 10.08 после того, как первая версия не работала).
    ///
    /// Сначала я вёл перетаскивание своим циклом `window.nextEvent(matching:)`. автор сообщил, что
    /// ручку видно, а строки не двигаются. Ловить это логами дорого, а идиоматический путь тут
    /// короче и не зависит от того, кто и как доставляет события: `DragHandle` просто получает
    /// `mouseDown`, `mouseDragged` и `mouseUp` от AppKit и передаёт их сюда. Вложенный цикл в
    /// AppKit требует, чтобы события доходили именно до него, и на вью внутри `NSScrollView`
    /// это условие соблюдается не всегда.
    ///
    /// Что видит человек: строка приподнимается полупрозрачной копией и едет за курсором, а между
    /// строками стоит коралловая линия, показывающая, КУДА она встанет. Без линии перетаскивание
    /// превращается в угадайку, ради этого всё и затевалось.
    fileprivate func dragBegan(_ handle: DragHandle, at point: NSPoint) {
        guard let rowView = handle.superview,
              let from = rowsStack.arrangedSubviews.firstIndex(of: rowView),
              let doc = rowsStack.superview else { return }
        let movable = max(0, rows.count - 1)          // последняя строка пустая по инварианту
        guard from < movable, movable > 1 else { return }

        let snapshot = NSImage(size: rowView.bounds.size)
        if let rep = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) {
            rowView.cacheDisplay(in: rowView.bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        let ghost = NSImageView(image: snapshot)
        ghost.frame = doc.convert(rowView.bounds, from: rowView)
        ghost.wantsLayer = true
        ghost.layer?.shadowOpacity = 0.35
        ghost.layer?.shadowRadius = 8
        ghost.layer?.shadowOffset = .zero
        ghost.alphaValue = 0.92
        doc.addSubview(ghost)

        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = DS.coral.cgColor
        line.layer?.cornerRadius = 1
        doc.addSubview(line)

        dragGhost = ghost
        dropLine = line
        dragFrom = from
        dragTarget = from
        dragStartY = doc.convert(point, from: nil).y
        dragOriginY = ghost.frame.origin.y
        rowView.alphaValue = 0.25
        kbLog("сниппеты: начали перенос строки \(from) из \(movable)")
    }

    fileprivate func dragMoved(to point: NSPoint) {
        guard let ghost = dragGhost, let line = dropLine, let from = dragFrom,
              let doc = rowsStack.superview else { return }
        let movable = max(0, rows.count - 1)
        let y = doc.convert(point, from: nil).y
        ghost.frame.origin.y = dragOriginY + (y - dragStartY)
        let t = dropIndex(forGhostMidY: ghost.frame.midY, movable: movable, from: from)
        if t != dragTarget {
            dragTarget = t
            kbLog("сниппеты: цель вставки \(t)")
        }
        placeDropLine(line, at: dragTarget, in: doc, movable: movable)
    }

    fileprivate func dragEnded() {
        guard let ghost = dragGhost, let from = dragFrom else { return }
        dropLine?.removeFromSuperview(); dropLine = nil
        if from < rowsStack.arrangedSubviews.count { rowsStack.arrangedSubviews[from].alphaValue = 1 }
        let target = dragTarget
        dragGhost = nil; dragFrom = nil

        let dest = target > from ? target - 1 : target
        guard dest != from else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ghost.animator().alphaValue = 0
            }, completionHandler: { ghost.removeFromSuperview() })
            return
        }
        // Доводим призрака до места и только потом перестраиваем: без этого строка «прыгает».
        let destFrame = rowFrame(index: dest)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().frame.origin.y = destFrame.origin.y
        }, completionHandler: { [weak self] in
            ghost.removeFromSuperview()
            guard let self else { return }
            let moved = self.rows.remove(at: from)
            self.rows.insert(moved, at: dest)
            self.normalizeTrailing()
            self.rebuild()
            self.save()
            kbLog("сниппеты: строка \(from) → \(dest)")
        })
    }

    /// Куда встанет строка: индекс ВСТАВКИ, считаем по середине призрака.
    ///
    /// ⛔️ ЗДЕСЬ БЫЛИ ДВЕ ОШИБКИ СРАЗУ, и обе давали один и тот же симптом: «таскаю, а строки не
    /// меняются местами, один раз из двадцати вдруг сработало» (автор 10.08). Записано подробно,
    /// потому что ошибка ровно того класса, который глазами по коду не виден.
    ///
    /// **Первая: разные системы координат.** Призрак живёт в `doc`, а рамки строк я брал прямо из
    /// `rowsStack.arrangedSubviews[i].frame`, то есть в координатах СТЕКА. Сравнивать их между собой
    /// нельзя: они разъезжаются ровно на отступ стека внутри документа. Теперь всё приводится к
    /// `doc` одним и тем же способом.
    ///
    /// **Вторая: документ НЕ перевёрнут.** Перевёрнут только `FlippedClipView`, то есть КЛИП, а сам
    /// `documentView` это обычный `NSView`, у которого y растёт ВВЕРХ. Мой комментарий утверждал
    /// обратное, и сравнение шло не в ту сторону: индекс вставки почти всегда получался равным
    /// исходному, поэтому «ничего не происходило». Сработать могло лишь тогда, когда призрак
    /// улетал за край списка.
    ///
    /// Теперь направление НЕ ПРЕДПОЛАГАЕТСЯ, а определяется по двум первым строкам. Это дешевле
    /// одной проверки и переживёт любую будущую смену клипа на перевёрнутый и обратно.
    private func dropIndex(forGhostMidY midY: CGFloat, movable: Int, from: Int) -> Int {
        guard movable > 1 else { return 0 }
        let downward = rowFrame(index: 1).midY < rowFrame(index: 0).midY   // «ниже» = меньший y?
        var idx = 0
        for i in 0..<movable {
            let m = rowFrame(index: i).midY
            let passed = downward ? (midY < m) : (midY > m)
            if passed { idx = i + 1 }
        }
        return min(max(0, idx), movable)
    }

    /// Рамка строки В КООРДИНАТАХ ДОКУМЕНТА — той же системе, где живёт призрак и линия вставки.
    private func rowFrame(index: Int) -> NSRect {
        guard index >= 0, index < rowsStack.arrangedSubviews.count,
              let doc = rowsStack.superview else { return .zero }
        let v = rowsStack.arrangedSubviews[index]
        return doc.convert(v.bounds, from: v)
    }

    private func placeDropLine(_ line: NSView, at target: Int, in doc: NSView, movable: Int) {
        guard movable > 0 else { line.frame = .zero; return }
        let stackRect = doc.convert(rowsStack.bounds, from: rowsStack)
        let downward = movable > 1 ? rowFrame(index: 1).midY < rowFrame(index: 0).midY : true
        let y: CGFloat
        if target <= 0 {
            y = downward ? rowFrame(index: 0).maxY : rowFrame(index: 0).minY
        } else if target >= movable {
            y = downward ? rowFrame(index: movable - 1).minY : rowFrame(index: movable - 1).maxY
        } else {
            y = downward ? rowFrame(index: target).maxY : rowFrame(index: target).minY
        }
        line.frame = NSRect(x: stackRect.minX + 8, y: y - 1, width: stackRect.width - 16, height: 2)
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
        // Начали писать в последней (пустой) строке → строка стала настоящей: показываем её корзину
        // и ручку, добавляем новую пустую снизу.
        //
        // ⛔️ ЗДЕСЬ ЖИЛ БАГ «сниппет не добавляется» (автор 10.08). Новая пустая строка в стек
        // добавлялась, но ВЫСОТА СПИСКА не пересчитывалась: она задана константой по числу строк и
        // меняется только в `rebuild()`. То есть строка существовала, но оказывалась ЗА нижней
        // границей прокрутки, и человек видел, что «ничего не произошло». Данные при этом
        // сохранялись, поэтому после перехода в другой раздел всё оказывалось на месте.
        //
        // ⚠️ Полный `rebuild()` здесь звать НЕЛЬЗЯ: он пересоздаёт поля, а человек в этот момент
        // печатает, и фокус вместе с курсором улетит на первом же символе. Поэтому правим точечно.
        if row == rows.count - 1, !(rows[row].0.isEmpty && rows[row].1.isEmpty) {
            if let h = f.superview as? NSStackView {
                for v in h.arrangedSubviews {
                    if let b = v as? NSButton, b.image != nil { b.isHidden = false }   // корзина
                }
            }
            rows.append(("", ""))
            addRow(rows.count - 1)
            scrollH?.constant = heightForRows(rows.count)   // без этого новая строка уезжает за край
            refreshGrips()
        }
    }

    /// Показать или спрятать ручки перетаскивания по текущему состоянию списка.
    /// Зовётся после точечного добавления строки: пока сниппет был один, ручки прятались за
    /// ненадобностью, а со второго их пора показать.
    private func refreshGrips() {
        guard allowsReorder else { return }
        let movable = rows.count - 1
        for (i, rowView) in rowsStack.arrangedSubviews.enumerated() {
            guard let h = rowView as? NSStackView,
                  let grip = h.arrangedSubviews.first as? DragHandle else { continue }
            grip.isHidden = !(i < movable && movable > 1)
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
        // ⚠️ Ищем именно ПОЛЕ, а не первую вью в строке: с 10.08 слева от него может стоять ручка
        // перетаскивания, и `first` возвращал бы её. Кнопка «+» тогда молча ничего не делала.
        guard let last = rowsStack.arrangedSubviews.last as? NSStackView,
              let trig = last.arrangedSubviews.compactMap({ $0 as? NSTextField }).first else { return }
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

/// РУЧКА ПЕРЕТАСКИВАНИЯ строки списка.
///
/// Отдельный класс, а не `NSButton`: кнопка съедает `mouseDown` своим циклом отслеживания нажатия,
/// и до перетаскивания дело не доходит вовсе.
///
/// ⚠️ События отдаём наружу ПО ОДНОМУ (`mouseDown` → `mouseDragged` → `mouseUp`), а не крутим
/// вложенный цикл внутри: так перетаскивание работает независимо от того, как AppKit доставляет
/// события вью внутри прокрутки. Первая версия крутила свой цикл и у автора не поехала вовсе.
final class DragHandle: NSView {
    var onBegan: ((DragHandle, NSPoint) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var onEnded: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent)    { onBegan?(self, event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onMoved?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent)      { onEnded?() }

    override func draw(_ dirtyRect: NSRect) {
        let c = hovering ? NSColor.labelColor.withAlphaComponent(0.75) : NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        c.setFill()
        // Три полоски, как принято у списков с перетаскиванием: узнаётся без подписи.
        let w: CGFloat = 10, h: CGFloat = 1.5, gap: CGFloat = 4
        let x = (bounds.width - w) / 2
        let midY = bounds.height / 2
        for dy in [-gap, 0, gap] {
            NSBezierPath(roundedRect: NSRect(x: x, y: midY + dy - h / 2, width: w, height: h),
                         xRadius: h / 2, yRadius: h / 2).fill()
        }
    }
}
