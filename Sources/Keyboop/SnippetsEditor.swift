import AppKit

/// Редактор автозамены: таблица из двух колонок (что заменять | на что).
/// UX: кнопка-корзина в каждой строке удаляет её; кнопка «+» добавляет новую строку;
/// поддерживается вставка (Cmd+V) в оба поля — NSTextField принимает нативно.
final class SnippetsEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var rows: [(String, String)]
    private let table = NSTableView()
    private let store = SnippetStore.shared

    override init(frame frameRect: NSRect) {
        rows = store.pairs()
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func build() {
        let trig = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trigger"))
        trig.title = L10n.t("snip.colTrigger")
        trig.minWidth = 90; trig.width = 140; trig.maxWidth = 220

        let exp = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("expansion"))
        exp.title = L10n.t("snip.colExpansion")
        exp.minWidth = 120

        let trash = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trash"))
        trash.title = ""; trash.minWidth = 30; trash.width = 30; trash.maxWidth = 30

        table.addTableColumn(trig)
        table.addTableColumn(exp)
        table.addTableColumn(trash)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Скрываем стандартный header (колонка корзины выглядит чище без header-бордера)
        table.headerView = nil

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Кнопка «+» для добавления новой строки
        let add = NSButton(title: "", target: self, action: #selector(addRow))
        add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.t("snip.add"))
        add.imagePosition = .imageOnly
        add.widthAnchor.constraint(equalToConstant: 30).isActive = true
        add.translatesAutoresizingMaskIntoConstraints = false
        addSubview(add)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            add.leadingAnchor.constraint(equalTo: leadingAnchor),
            add.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let colID = tableColumn?.identifier.rawValue ?? ""

        if colID == "trash" {
            let id = NSUserInterfaceItemIdentifier("trashBtn")
            let btn = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton) ?? {
                let b = NSButton(title: "", target: self, action: #selector(deleteRow(_:)))
                b.identifier = id
                b.bezelStyle = .regularSquare
                b.isBordered = false
                b.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Удалить")
                b.imagePosition = .imageOnly
                b.contentTintColor = .tertiaryLabelColor
                // При hover подсвечиваем coral — через tracking
                b.wantsLayer = true
                return b
            }()
            btn.tag = row
            return btn
        }

        let isTrig = colID == "trigger"
        let id = NSUserInterfaceItemIdentifier(isTrig ? "tCell" : "eCell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField()
            f.identifier = id
            f.isBordered = false
            f.drawsBackground = false
            f.isEditable = true
            f.font = isTrig ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            f.placeholderString = isTrig ? L10n.t("snip.phTrigger") : L10n.t("snip.phExpansion")
            f.target = self
            f.action = #selector(edited(_:))
            return f
        }()
        field.stringValue = isTrig ? rows[row].0 : rows[row].1
        field.tag = row * 2 + (isTrig ? 0 : 1)
        return field
    }

    @objc private func edited(_ s: NSTextField) {
        let row = s.tag / 2
        let isTrig = (s.tag % 2 == 0)
        guard row < rows.count else { return }
        if isTrig { rows[row].0 = s.stringValue } else { rows[row].1 = s.stringValue }
        save()
    }

    @objc private func addRow() {
        rows.append(("", ""))
        table.reloadData()
        table.scrollRowToVisible(rows.count - 1)
        // Сразу начинаем редактировать поле «триггер» новой строки
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.table.editColumn(0, row: self.rows.count - 1, with: nil, select: true)
        }
    }

    @objc private func deleteRow(_ sender: NSButton) {
        let row = sender.tag
        guard row < rows.count else { return }
        rows.remove(at: row)
        table.reloadData()
        save()
    }

    private func save() {
        var map: [String: String] = [:]
        for (t, e) in rows {
            let trigger = t.trimmingCharacters(in: .whitespaces)
            if !trigger.isEmpty { map[trigger] = e }
        }
        store.setAll(map)
    }
}
