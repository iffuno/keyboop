import AppKit

/// ВЫБОР СНИППЕТА ПО ХОТКЕЮ (задача 17, отзыв #62, сделано 06.08.2026).
///
/// «Было бы удобно хранить там длинные консольные команды». У аббревиатуры есть риск случайного
/// срабатывания, и для редких длинных вставок хоткей честнее.
///
/// Решение автора 06.08: **один общий хоткей**, а не по одному на каждый сниппет. Хоткеев мало, и
/// раздавать их по штуке на строку списка нельзя.
///
/// ⚠️ ПОЧЕМУ ПАНЕЛЬ НЕ КРАДЁТ ФОКУС, И ПОЧЕМУ ЭТО ГЛАВНОЕ В ЗАДАЧЕ. Обычное окно выбора сделало бы
/// активными НАС, и вставлять сниппет пришлось бы, возвращая фокус чужому приложению, то есть
/// гонкой. Мы этого избегаем целиком: панель `nonactivatingPanel` только рисует, а цифру ловит
/// перехватчик, который и так слушает клавиатуру. Фокус чужого приложения не трогается вообще, и
/// каретка остаётся ровно там, где была. Тот же приём спасает нас от ловушки, из-за которой в
/// быстрых действиях правого клика нет пункта «вставить» (см. `MenuBarController.runQuickAction`).
final class SnippetPicker {
    static let shared = SnippetPicker()
    private init() {}

    private var panel: NSPanel?
    private var idleTimer: Timer?

    /// Что сейчас показано: список пар в том же порядке, что и цифры на экране.
    private(set) var shown: [(String, String)] = []

    var isOpen: Bool { panel != nil }

    /// Выбор МЫШЬЮ. Ведёт в тот же обработчик, что и цифра: путь вставки обязан быть один,
    /// иначе две дороги разойдутся на первой же правке.
    var onPick: ((Int) -> Void)?

    /// Показать список.
    ///
    /// ⚠️ Показываем ВСЕ сниппеты, а не первые девять (автор 06.08). Ограничение в девять появилось,
    /// когда выбор шёл только цифрой. С появлением мыши оно стало искусственным: кликнуть можно по
    /// любой строке, а обрезка молча прятала остальные без единого способа до них добраться. Цифры
    /// по-прежнему адресуют только 1…9, поэтому номер стоит лишь у первых девяти: обещать цифру там,
    /// где она не сработает, хуже, чем не обещать вовсе.
    /// Возвращает false, если показывать нечего — вызывающий тогда не глотает хоткей.
    @discardableResult
    func show() -> Bool {
        let pairs = TextSnippetStore.shared.orderedPairs
        guard !pairs.isEmpty else {
            VoiceIndicator.shared.showToast(L10n.t("snip.pickEmpty"))
            return false
        }
        // ⚠️ ПОРЯДОК ВАЖЕН, здесь была ошибка (найдена автором 06.08). Сначала стояло `shown = pairs`,
        // а следом `hide()`, который список ОЧИЩАЕТ. Выбор цифрой всегда бил в пустой массив: клавиша
        // глоталась, вставки не было, и снаружи это выглядело как «цифры не работают». Escape при
        // этом работал, потому что ему список не нужен, и расхождение поведения было единственной
        // уликой. Гасим старое ДО того, как записать новое.
        hide()
        shown = pairs
        let p = makePanel(for: pairs)
        panel = p
        p.orderFrontRegardless()
        // ⚠️ СТОРОЖ ПОЯВИЛСЯ ВМЕСТЕ С МЫШЬЮ. Пока панель игнорировала клики, забытый на экране
        // список был безобиден. Теперь он перехватывает мышь в своей области, то есть забытая
        // панель заслоняет кусок чужого окна. Полминуты бездействия и закрываемся сами.
        idleTimer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: false) { [weak self] _ in self?.hide() }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
        return true
    }

    func hide() {
        idleTimer?.invalidate(); idleTimer = nil
        panel?.orderOut(nil)
        panel = nil
        shown = []
    }

    /// Выбор цифрой 1…9. Возвращает раскрытие или nil, если такой строки нет.
    func pick(index: Int) -> String? {
        guard index >= 0, index < shown.count else { return nil }
        let expansion = shown[index].1
        hide()
        return expansion
    }

    // MARK: - Отрисовка

    private func makePanel(for pairs: [(String, String)]) -> NSPanel {
        let rowH: CGFloat = 28, padV: CGFloat = 12, width: CGFloat = 620, tipH: CGFloat = 22
        // ВЫСОТА ОГРАНИЧЕНА ЭКРАНОМ, дальше прокрутка (автор 06.08). Без потолка список из тридцати
        // строк вырос бы за пределы экрана, и нижние оказались бы недостижимы вообще ничем.
        // Потолок берём от рабочей области того экрана, где сейчас мышь, а не от главного.
        // ⚠️ ОДНА ТОЧКА ОТСЧЁТА НА ВСЁ. И потолок высоты, и положение считаем от ОДНОГО якоря:
        // сначала каретка, иначе мышь. Пока потолок брался от экрана мыши, а ставили по каретке,
        // на двух мониторах разной высоты панель могла оказаться выше того экрана, где её показали.
        let anchor = Self.anchorPoint()
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rowsH = rowH * CGFloat(pairs.count)
        let maxRowsH = max(rowH * 3, visible.height * 0.6 - padV * 2 - tipH)   // хотя бы три строки видно всегда
        let shownRowsH = min(rowsH, maxRowsH)
        let height = padV * 2 + shownRowsH + tipH
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Та же тёмная HUD-плашка, что у индикатора диктовки: пиннем тёмную тему, иначе в светлой
        // системной .labelColor резолвится в тёмный и получается тёмное по тёмному.
        p.appearance = NSAppearance(named: .darkAqua)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // ⚠️ МЫШЬ РАЗРЕШЕНА, И ЭТО БЕЗОПАСНО ТОЛЬКО БЛАГОДАРЯ `nonactivatingPanel` (автор 06.08).
        // Клик по такой панели НЕ активирует наше приложение, значит каретка остаётся в чужом
        // окне и вставлять есть куда. С обычным окном клик забрал бы фокус, и весь смысл затеи
        // (не трогать чужой фокус) исчез бы ровно в момент выбора.
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        // Углы ПРЯМЫЕ (решение автора 06.08): плашка выбора это не всплывашка-подсказка, а рабочий
        // список, и строгий прямоугольник читается как таблица, а не как уведомление.
        bg.layer?.cornerRadius = 0
        p.contentView = bg

        // ШИРИНА КОЛОНКИ НАЗВАНИЙ — ПО САМОМУ ДЛИННОМУ, но не больше потолка (автор 06.08).
        // Фиксированная колонка держала пустоту: названия обычно короткие, а место рядом нужно
        // тексту, ради которого список и открывают. Потолок оставляем, иначе одно длинное название
        // съело бы всю строку и от текста осталось бы многоточие.
        let nameW = Self.nameColumnWidth(for: pairs)

        // Строки живут в прокручиваемой области. Когда всё влезает, полосы не видно и ведёт себя
        // ровно как раньше: `hasVerticalScroller` рисует её только при переполнении.
        // ⚠️ ДОКУМЕНТ ПЕРЕВЁРНУТ, и это не вкусовщина. У обычного NSView начало координат внизу, и
        // прокрутка открывалась с середины списка: попытка «доехать до верха» арифметикой дала
        // четырнадцатую строку сверху (стенд 06.08). С `isFlipped` верх это y = 0, строки кладутся
        // сверху вниз в порядке чтения, а начальное положение прокрутки не требует расчётов вовсе.
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: rowsH))
        for (i, pair) in pairs.enumerated() {
            let r = row(index: i + 1, trigger: pair.0, expansion: pair.1, nameW: nameW,
                        frame: NSRect(x: 0, y: CGFloat(i) * rowH, width: width, height: rowH),
                        separator: i < pairs.count - 1)
            let idx = i
            r.onClick = { [weak self] in self?.onPick?(idx) }
            doc.addSubview(r)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: tipH, width: width, height: shownRowsH + padV * 2))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = rowsH > shownRowsH
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        // ⚠️ ПОЛОЖЕНИЕ ПРОКРУТКИ СТАВИМ ЯВНО. Ни свежий NSScrollView, ни перевёрнутый документ сами
        // по себе начала не гарантируют: список дважды открывался с середины (стенд 06.08). Явные
        // две строки дешевле любых рассуждений о том, кто тут кого должен был выставить.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        bg.addSubview(scroll)
        // Подсказка честная: пока строк девять, обещаем цифры, дальше называем и модификаторы.
        let tip = NSTextField(labelWithString: L10n.t(pairs.count > 9 ? "snip.pickTipMore" : "snip.pickTip"))
        tip.font = .systemFont(ofSize: 10.5)
        tip.textColor = .tertiaryLabelColor
        tip.frame = NSRect(x: 14, y: 5, width: width - 28, height: 14)
        bg.addSubview(tip)
        p.setFrameOrigin(Self.originNearMouse(mouse: anchor, size: p.frame.size, visible: visible))
        return p
    }

    /// ГДЕ ПОКАЗЫВАТЬ: у каретки, а если её не видно — у курсора мыши (автор 06.08). Тот же порядок,
    /// что у плашки диктовки: список открывают, чтобы вставить текст ТУДА, где стоит курсор ввода.
    ///
    /// ⚠️ Фолбэк здесь не редкий случай, а половина жизни. Замер 04.08 по логу: каретка недоступна в
    /// 345 случаях из 586, то есть ЧАЩЕ, чем доступна. В Electron-приложениях (Claude Code и прочие)
    /// её не видно вовсе. Поэтому обе ветки равноправны.
    ///
    /// Якорь у каретки — её левый НИЖНИЙ угол: список раскрывается под строкой, как подсказка ввода,
    /// а не поверх того, что человек печатает.
    static func anchorPoint() -> NSPoint {
        if let caret = CaretLocator.caretScreenRect() { return NSPoint(x: caret.minX, y: caret.minY) }
        return NSEvent.mouseLocation
    }

    /// Левый нижний угол панели для якоря. Три меры против выхода за экран, каждая закрывает своё:
    /// 1. Считаем по `visibleFrame`, а не по `frame`: по `frame` панель «помещалась», заезжая под
    ///    полосу меню и под Док.
    /// 2. Не влезает снизу — показываем СВЕРХУ, а не прижимаем к краю: прижатая панель накрывает
    ///    сам якорь, то есть ровно то место, куда человек смотрит.
    /// 3. Зажим по обеим осям последним шагом, как страховка для экранов уже самой панели.
    static func originNearMouse(mouse: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        var x = mouse.x + 16
        var y = mouse.y - size.height - 16
        if y < visible.minY + 8 { y = mouse.y + 16 }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return NSPoint(x: x, y: y)
    }

    /// Строка списка: сама следит за наведением и сама сообщает о клике. Отдельный класс, потому
    /// что и то и другое требует `NSTrackingArea` и `mouseDown`, а на голом NSView их не повесить.
    final class Row: NSView {
        var onClick: (() -> Void)?
        private let base: NSColor
        private var tracking: NSTrackingArea?

        init(frame: NSRect, separator: Bool) {
            // ⚠️ ЧЕРЕДОВАНИЯ ЦВЕТОВ НЕТ (автор 06.08). Более светлая строка читалась как ВЫДЕЛЕННАЯ и
            // спорила с подсветкой наведения: на экране оказывались две «активные» строки сразу.
            // Подсветка должна быть ровно одна, поэтому фон у всех одинаковый, а строки разделяет линия.
            base = .clear
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = base.cgColor
            guard separator else { return }
            let line = NSView(frame: NSRect(x: 14, y: frame.height - 1, width: frame.width - 28, height: 1))
            line.autoresizingMask = [.width]
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            addSubview(line)
        }
        required init?(coder: NSCoder) { fatalError("no xib") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }
        override func mouseEntered(with event: NSEvent) {
            // Подсветка ТЕМНЕЕ, а не светлее (автор 06.08). На тёмной плашке светлое пятно читается
            // как «эта строка активна сама по себе», то есть как выделение в списке. Углубление
            // читается как «сюда сейчас нажмут», и это ровно то, что происходит.
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        }
        override func mouseExited(with event: NSEvent) { layer?.backgroundColor = base.cgColor }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    /// Шрифт колонки названий. Вынесен, потому что им же и МЕРЯЕМ ширину: считать одним шрифтом,
    /// а рисовать другим — верный способ получить обрезку там, где по расчёту всё влезало.
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private static let nameColumnMax: CGFloat = 120
    private static let nameColumnMin: CGFloat = 44

    /// Подпись клавиши для строки. 1…9 — голые цифры, 10…18 — с ⇧, 19…27 — с ⌘, дальше пусто:
    /// нарисовать клавишу, которой не существует, хуже, чем не рисовать ничего.
    static func shortcutLabel(for index: Int) -> String {
        switch index {
        case 1...9:   return "\(index)"
        case 10...18: return "⇧\(index - 9)"
        case 19...27: return "⌘\(index - 18)"
        default:      return ""
        }
    }

    static func nameColumnWidth(for pairs: [(String, String)]) -> CGFloat {
        let widest = pairs
            .map { ($0.0 as NSString).size(withAttributes: [.font: nameFont]).width }
            .max() ?? 0
        // ⚠️ Запас 8, а не 2. У NSTextField есть собственный внутренний отступ, и поле, обрезанное
        // ровно по ширине текста, обрезает САМУЮ ДЛИННУЮ строку многоточием — то есть ту
        // единственную, по которой колонку и мерили. Поймано на стенде 06.08.
        return min(nameColumnMax, max(nameColumnMin, ceil(widest) + 8))
    }

    private func row(index: Int, trigger: String, expansion: String, nameW: CGFloat,
                     frame: NSRect, separator: Bool) -> Row {
        let v = Row(frame: frame, separator: separator)
        let num = NSTextField(labelWithString: Self.shortcutLabel(for: index))
        num.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        num.textColor = NSColor(red: 1.0, green: 0.478, blue: 0.349, alpha: 1)   // coral #FF7A59
        num.frame = NSRect(x: 14, y: 5, width: 26, height: 16)
        v.addSubview(num)

        let trig = NSTextField(labelWithString: trigger)
        trig.font = Self.nameFont
        trig.textColor = .labelColor
        trig.frame = NSRect(x: 46, y: 5, width: nameW, height: 16)
        trig.lineBreakMode = .byTruncatingTail
        v.addSubview(trig)

        // Раскрытие показываем ОДНОЙ строкой и с обрезкой: сниппет может быть на десять строк, а
        // панель нужна для узнавания, а не для чтения. Переводы строк схлопываем, иначе в одну
        // строку приедет «первая строка» и обрыв на самом интересном.
        let flat = expansion.replacingOccurrences(of: "\n", with: " ")
        let exp = NSTextField(labelWithString: flat)
        exp.font = .systemFont(ofSize: 12)
        exp.textColor = .secondaryLabelColor
        let expX = 46 + nameW + 10
        exp.frame = NSRect(x: expX, y: 5, width: frame.width - expX - 14, height: 16)
        exp.lineBreakMode = .byTruncatingTail
        v.addSubview(exp)
        return v
    }
}
