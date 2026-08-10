import AppKit

/// ВСТАВКА БЕЗ ФОРМАТИРОВАНИЯ (задача 102: отзывы #109 и #110, плюс просьба автора 10.08).
///
/// Два независимых человека попросили это в один день, и это у нас редкость. Механика простая:
/// подменяем в буфере богатое содержимое на голый текст, шлём ⌘V, возвращаем буфер как было.
///
/// # ⚠️ ЭТО ПЕРВАЯ НАША ФУНКЦИЯ, КОТОРАЯ ПО ПРИРОДЕ ЖИВЁТ В БУФЕРЕ
///
/// Краеугольный принцип №1 гласит: буфер священен, и весь проект существует потому, что
/// предшественник его ломал. Поэтому здесь дословно повторяется анти-Punto чеклист из
/// `SelectionText.readViaClipboard`, включая урок, оплаченный отзывом #88:
///
///   • снимок ВСЕХ типов ВСЕХ элементов, **строго списком, а не словарём** — порядок типов значим,
///     приложение берёт первый подходящий, и перемешанный порядок однажды уже превратил вставку из
///     Telegram в «шифр»;
///   • восстановление ТОЛЬКО если с момента нашей записи буфер никто не трогал (`changeCount`),
///     иначе мы затрём чужое свежее содержимое;
///   • наша служебная запись помечается `org.nspasteboard.TransientType`, чтобы менеджеры буфера
///     (Paste, Maccy) не плодили дубликат и не «подсматривали».
///
/// ⚠️ ЧЕСТНО ПРО СЛАБОЕ МЕСТО. Узнать, что целевое приложение уже прочитало буфер, системного
/// способа НЕТ: `NSPasteboard` о чтении не сообщает. Поэтому мы, как и все остальные, ждём
/// фиксированное окно, прокручивая runloop. Отличие от Punto принципиальное и оно не в задержке:
/// он восстанавливал **по таймеру и без проверок**, затирая то, что человек скопировал за это время.
/// Мы перед восстановлением сверяем `changeCount` и молча отступаем, если буфер уже чужой.
///
/// ⚠️ И ПРО ⇧⌘V. Во многих программах (Заметки, Pages, браузеры) это сочетание УЖЕ означает
/// «вставить и согласовать стиль». Перехватывая его, мы подменяем работающее системное поведение
/// своим. Поэтому функция выключена по умолчанию и сочетание настраивается: смысл она имеет там,
/// где приложение так не умеет.
enum PlainPaste {

    /// Сколько ждём, пока целевое приложение заберёт содержимое, прежде чем вернуть буфер.
    ///
    /// 300 мс: у чтения буфера нет уведомления, а 250 мс уже хватает медленным Electron-окнам на
    /// собственный цикл вставки (замер `SelectionText` на ⌘C). Запас взят намеренно: вернуть буфер
    /// рано значит вставить форматированный текст, то есть не сделать ровно то, ради чего звали.
    private static let settleWindow = 0.30

    /// Вставить содержимое буфера как голый текст. Возвращает false, если вставлять нечего.
    @discardableResult
    static func paste() -> Bool {
        let pb = NSPasteboard.general
        guard let plain = pb.string(forType: .string), !plain.isEmpty else {
            kbLog("вставка без форматирования: в буфере нет текста — ничего не делаю")
            return false
        }
        // Уже голый текст? Тогда подмена бессмысленна: просто отдаём ⌘V, не трогая буфер вовсе.
        // Это не оптимизация, а безопасность: чем реже мы вообще прикасаемся к буферу, тем лучше.
        let onlyPlain = (pb.pasteboardItems ?? []).allSatisfy { item in
            item.types.allSatisfy { $0 == .string || $0.rawValue.hasPrefix("public.utf") }
        }
        if onlyPlain {
            kbLog("вставка без форматирования: в буфере и так голый текст — буфер не трогаю")
            sendCmdV()
            return true
        }

        let before = pb.changeCount
        let snapshot: [[(type: NSPasteboard.PasteboardType, data: Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (type: t, data: $0) } }
        }

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount

        sendCmdV()

        // Прокручиваем runloop, а не спим: синтетическое событие иначе не доставляется, и целевое
        // приложение не получает шанса прочитать буфер (тот же приём, что в SelectionText).
        let deadline = Date(timeIntervalSinceNow: settleWindow)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        guard pb.changeCount == ours else {
            // За время вставки человек или другая программа положили в буфер своё. Их содержимое
            // новее нашего, и восстанавливать поверх него нельзя ни при каких обстоятельствах.
            kbLog("вставка без форматирования: буфер сменился на чужой (\(ours)→\(pb.changeCount)) — не восстанавливаю")
            return true
        }
        pb.clearContents()
        if !snapshot.isEmpty {
            pb.writeObjects(snapshot.map { pairs -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for p in pairs { it.setData(p.data, forType: p.type) }   // строго в исходном порядке
                it.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                return it
            })
        }
        kbLog("вставка без форматирования: \(plain.count) симв., буфер восстановлен (типов было \(snapshot.first?.count ?? 0))")
        return true
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)    // 'v' = 9
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        // Маркер обязателен: без него наш собственный ⌘V выглядит для нашего же тапа настоящим
        // нажатием, и если человек назначит на вставку сочетание с ⌘V, получится бесконечная петля
        // (ровно этот случай уже ловили с ⌘C в SelectionText, репорт 25.07).
        down?.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
