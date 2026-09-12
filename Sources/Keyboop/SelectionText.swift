import ApplicationServices
import AppKit

/// Чтение и замена ВЫДЕЛЕННОГО текста через Accessibility (нативные приложения:
/// TextEdit, Notes, Mail, Pages, поля Safari и т.п.). Для Electron/web AX часто
/// не отдаёт выделение → read() вернёт nil, и вызывающий просто не трогает выделение
/// (буфер обмена НЕ задействуем — принцип №1; clipboard-fallback — отдельная задача).
enum SelectionText {
    /// Прочитать выделенный текст из сфокусированного элемента. nil — если выделения
    /// нет или AX молчит. Возвращает сам элемент (чтобы записать обратно туда же).
    /// Прочитать выделение. Возвращает текст + опциональный AX-writeback (для нативных полей).
    /// Если AX молчит (Electron/web) — fallback на Cmd+C; тогда writeBack == nil (писать печатью).
    static func read() -> (text: String, writeBack: ((String) -> Bool)?)? {
        // Признак живёт ровно одно чтение. Без сброса он протух бы: прочитали объект в Figma,
        // потом текст в другом приложении — и там сработала бы ветка холста.
        lastCopyLooksLikeCanvasNode = false
        // ⚠️ ПУТЬ И ПРИЛОЖЕНИЕ ПИШЕМ ВСЕГДА (07.09.2026). По жалобе из Figma «остался только хвост»
        // разбор упёрся в то, что по логу нельзя отличить AX-путь от буферного и не видно, в какой
        // программе это было: три конкурирующих объяснения различались ровно тем, чего в логе нет.
        if let (element, text) = readAX() {
            kbLog("selection: AX, \(text.count) симв., \(Engine.frontmostBundleID())")
            return (text, { SelectionText.write(element, $0) })
        }
        if let text = readViaClipboard() {
            kbLog("selection: через буфер (Cmd+C), \(text.count) симв., \(Engine.frontmostBundleID())")
            // Figma съедает первое событие после нашего ⌘C — отдаём ей жертву, чтобы она съела
            // её, а не первый кусок текста (и не первую клавишу человека). Разбор и матрица
            // опытов — у `TextReplacer.sacrificeKeyAfterClipboardRead`.
            TextReplacer.sacrificeKeyAfterClipboardRead()
            return (text, nil)
        }
        kbLog("selection: не прочитано ни AX, ни буфером, \(Engine.frontmostBundleID())")
        return nil
    }

    private static func readAX() -> (element: AXUIElement, text: String)? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let fErr = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard fErr == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var sel: CFTypeRef?
        let sErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &sel)
        guard sErr == .success, let text = sel as? String, !text.isEmpty else { return nil }
        return (element, text)
    }

    /// Fallback для Electron/web/везде: прочитать выделение через Cmd+C, ВОССТАНОВИВ буфер
    /// по анти-Punto чеклисту (снимок всех типов + changeCount, восстановление только если
    /// буфер с тех пор никто не трогал). Блокирует ~150мс (поллинг). Запись — печатью, НЕ вставкой.
    static func readViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        // Окно владения (задача 228): пока мы крутим runloop в ожидании ⌘C, наблюдатель истории
        // буфера не должен принять выделение человека за «скопированный текст». Оба наших
        // изменения буфера (результат ⌘C и восстановление) ниже регистрируются как свои.
        PasteboardOwnership.beginOwnedWindow()
        defer { PasteboardOwnership.endOwnedWindow() }
        // Снимок ВСЕХ типов всех элементов (картинки/файлы/RTF), чтобы вернуть как было.
        //
        // ⚠️ ПОРЯДОК ТИПОВ ЗНАЧИМ, И ХРАНИТЬ ЕГО НАДО СПИСКОМ, А НЕ СЛОВАРЁМ (отзыв #88, 05.08.2026).
        // Здесь стоял `[PasteboardType: Data]`, а обход словаря в Swift не упорядочен. Приложение при
        // вставке берёт ПЕРВЫЙ подходящий тип из списка, поэтому после нашего восстановления первым
        // мог оказаться любой, вплоть до приватного бинарного типа мессенджера. Человек копировал из
        // Telegram, вставлял в Заметки и получал «шифр», а в приложения попроще, которые просят
        // обычный текст, всё вставлялось нормально. Воспроизведено: три прогона одного и того же
        // снимка дали три разных порядка, и в одном первым встал `org.telegram.messenger.custom`.
        //
        // Это ровно тот класс, ради которого написан краеугольный принцип №1: мы обещаем, что буфер
        // после нас такой же, каким был. Порядок типов это часть «такой же».
        let snapshot: [[(type: NSPasteboard.PasteboardType, data: Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (type: t, data: $0) } }
        }
        sendCmdC()
        var copied: String?
        // Прокручиваем runloop (НЕ usleep) — иначе синтетическое событие не доставляется,
        // и даём целевому приложению время скопировать. До ~250мс.
        for _ in 0..<25 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                noteFlavours(pb)
                break
            }
        }
        kbLog("selection clipboard: changeCount \(before)→\(pb.changeCount), строка=\(copied?.count ?? -1) симв.")
        // восстановить исходный буфер, только если изменили его мы (changeCount сдвинулся)
        if pb.changeCount != before {
            pb.kbNoteOurs()   // результат нашего ⌘C, а не то, что человек скопировал
            pb.clearContents()
            if !snapshot.isEmpty {
                pb.writeObjects(snapshot.map { pairs -> NSPasteboardItem in
                    let it = NSPasteboardItem()
                    for p in pairs { it.setData(p.data, forType: p.type) }   // строго в исходном порядке
                    // Помечаем ВОССТАНОВЛЕНИЕ transient — менеджеры буфера (Paste/Maccy/…) игнорируют
                    // нашу служебную запись: не плодят дубликат и не «подсматривают» (анти-Punto чеклист,
                    // security-аудит L2, 01.07). Данные в item реальные → пользователь вставляет как обычно.
                    it.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                    return it
                })
            }
            pb.kbNoteOurs()   // и восстановление тоже наше
        }
        guard let text = copied, !text.isEmpty else { return nil }
        return text
    }

    /// ЧЕМ ОТЛИЧИТЬ «ВЫДЕЛЕН ОБЪЕКТ» ОТ «ВЫДЕЛЕН ТЕКСТ ВНУТРИ» (11.09.2026, задача 249).
    ///
    /// Зачем. Отзыв @alpus: «текстовое поле уже набрано, я его снова активирую, пытаюсь сменить
    /// раскладку или регистр — звучок есть, реакции никакой». Так и есть: когда в Figma выделен
    /// текстовый ОБЪЕКТ, а не текст внутри него, ⌘C отдаёт содержимое С ПЕРЕВОДОМ СТРОКИ на конце,
    /// и наш предохранитель «многострочное это авто-копия строки» отказывается конвертировать.
    ///
    /// Почему нельзя просто срезать перевод строки. Ровно ту же форму даёт ⌘C БЕЗ выделения в
    /// редакторах кода и терминалах: там он копирует текущую строку целиком, тоже с переводом в
    /// конце. Срезав его вслепую, мы начнём конвертировать строку кода, которую человек не выделял.
    /// Различить по самому тексту невозможно, различие лежит в ТИПАХ данных на доске.
    ///
    /// Что проверяем. Приложения с холстом кладут рядом с простым текстом СВОЙ тип: у Figma это
    /// `com.figma.*` либо HTML со служебной пометкой `figmeta`/`figma`. Редактор кода в том же
    /// случае кладёт простой текст (и, может быть, свою пометку про строку без выделения), но
    /// никакого «фигмовского» типа там не появится никогда.
    ///
    /// ⚠️ ПРИЗНАК РАБОТАЕТ В ОБОИХ ВАРИАНТАХ FIGMA, и это главная причина выбрать именно его.
    /// По имени приложения различить нельзя: настольная Figma это `com.figma.Desktop`, а веб-версия
    /// это обычный Chrome, неотличимый от VS Code или почты.
    ///
    /// ⚠️ ПРИЗНАК ТРЕБУЕТ ПОЛОЖИТЕЛЬНОГО ДОКАЗАТЕЛЬСТВА, А НЕ ОТСУТСТВИЯ ВОЗРАЖЕНИЙ. Пока в буфере
    /// не увиден «фигмовский» тип, ничего нового не включается и поведение остаётся ровно как
    /// в 0.4.7. Это сознательный выбор формы правки: гипотеза про типы данных проверена рассуждением,
    /// но НЕ замерена живьём (автор закрыл Figma раньше, чем я успел). Если гипотеза неверна, цена
    /// ошибки нулевая — функция просто не включится, и это будет видно по строке в логе.
    private static func noteFlavours(_ pb: NSPasteboard) {
        let types = (pb.pasteboardItems ?? []).flatMap { $0.types.map { $0.rawValue } }
        // ⚠️ ТОЛЬКО СЛУЖЕБНЫЕ ПРИЗНАКИ, НИКОГДА НЕ СОДЕРЖИМОЕ (поймано до выпуска, 11.09.2026).
        // Первая версия проверяла ещё и слово «figma» в HTML-теле. Это ложное срабатывание в
        // обычной жизни: человек выделяет в почте или на сайте кусок текста, где упомянута Figma,
        // жмёт хоткей — и мы принимаем письмо за объект холста со всеми последствиями (Enter в
        // почте это отправка). Имя типа данных пишет приложение, а не человек, поэтому по типам
        // судить можно. В HTML ищем ровно служебную пометку Figma `figmeta`, которая в живом тексте
        // не встречается.
        var canvas = types.contains { $0.lowercased().contains("figma") }
        if !canvas, let html = pb.string(forType: .html) {
            canvas = html.contains("figmeta")
        }
        lastCopyLooksLikeCanvasNode = canvas
        kbLog("selection clipboard: типы [\(types.joined(separator: ", "))] → объект холста=\(canvas)")
    }

    /// Последний ⌘C принёс данные объекта холста (Figma), а не выделенный текст. Живёт до
    /// следующего чтения; читается сразу после `read()`, в том же обработчике хоткея.
    private(set) static var lastCopyLooksLikeCanvasNode = false

    private static func sendCmdC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // 'c' = 8
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        // КРИТИЧНО (репорт пользователя 25.07): без маркера наш собственный ⌘C выглядит для нашего
        // же tap'а РЕАЛЬНЫМ нажатием. Если хоткей перевода оказался ⌘C (а записать его раньше было
        // можно), получался бесконечный цикл: перевод → ⌘C → снова перевод → «ритмичный звук», пока
        // человек не сменит хоткей. Маркер разрывает петлю в принципе — для любого нашего хоткея.
        down?.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    /// Заменить выделение через AX (с верификацией re-read против «Safari bug»:
    /// set может вернуть .success, но текст не поменяться).
    /// ВАЖНО: после успешной замены выделение в большинстве приложений СХЛОПЫВАЕТСЯ
    /// (курсор в конце строки), поэтому kAXSelectedTextAttribute вернёт "" — и это успех.
    /// Нельзя проверять `now == newText` — это всегда false в нормальных приложениях
    /// → false → двойная вставка через TextReplacer.insert (баг двойного текста).
    /// Правило: успех если выделение либо пустое (схлопнулось), либо стало newText
    ///           (некоторые приложения держат выделение на вставленном тексте).
    ///           Провал — только если по-прежнему читается что-то ДРУГОЕ (AX нас обманул).
    @discardableResult
    static func write(_ element: AXUIElement, _ newText: String) -> Bool {
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
        guard err == .success else { return false }
        var check: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &check) == .success,
           let now = check as? String {
            // "" → схлопнулось (норм); newText → осталось выделенным (тоже норм)
            // что-то другое → Safari bug (set соврал, текст не сменился) → false → TextReplacer fallback
            return now.isEmpty || now == newText
        }
        return true   // перечитать не вышло — доверяем err == .success
    }
}

// MARK: - Что стоит слева от каретки (задача 187)

/// Что находится непосредственно СЛЕВА от точки ввода.
enum CaretLeft {
    /// Буква: каретка внутри слова или сразу за ним. Одиночную букву тут трогать нельзя.
    case letter
    /// Пробел, знак препинания или самое начало поля: слева слова нет, конверсия безопасна.
    case boundary
    /// Accessibility не ответил (Electron, web, запрет доступа, таймаут). Ведём себя осторожно.
    case unknown
}

extension SelectionText {
    /// Спросить у системы, что слева от каретки. ⚠️ ТОЛЬКО В ФОНЕ И ТОЛЬКО ЗАРАНЕЕ.
    ///
    /// Зачем это вообще (задача 187, наблюдение автора 22.08.2026). После прыжка каретки мы не трогаем
    /// первую одиночную букву: слева на экране может стоять целое слово, которого мы не видим, и
    /// «починив» букву внутри него, мы отменяем правку, которую человек только что сделал руками
    /// (его же баг 02.08). Но правило слепое: в пустом поле оно тоже молчит, хотя там чинить безопасно.
    /// Этот запрос превращает догадку в наблюдение.
    ///
    /// ⚠️ ПОЧЕМУ ЗАРАНЕЕ, А НЕ В МОМЕНТ РЕШЕНИЯ. Решение принимается на границе слова, в главном
    /// потоке, где живёт runloop нашего перехватчика. Обращение к Accessibility оттуда может занять
    /// десятки миллисекунд, а система убивает перехватчик, если колбэк не уложился в срок. У проекта
    /// уже есть шрам ровно этого рода: вызов за разрешением из горячего пути заморозил ВЕСЬ ввод в
    /// системе. Поэтому спрашиваем в момент КЛИКА, в фоне, и к границе слова ответ уже лежит готовым.
    ///
    /// ⚠️ Таймаут обязателен: неотвечающее приложение (зависший Electron) иначе держит наш фоновый
    /// поток минутами, и ответ приходит к чужому уже клику.
    static func caretLeftAsync(_ done: @escaping (CaretLeft) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            done(caretLeftBlocking())
        }
    }

    /// Синхронная часть. Отдельно — чтобы её можно было позвать из стенда.
    static func caretLeftBlocking() -> CaretLeft {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return .unknown }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return .unknown }
        // Каретка в самом начале поля: слева заведомо ничего нет.
        if range.location <= 0 { return .boundary }

        var before = CFRange(location: range.location - 1, length: 1)
        guard let arg = AXValueCreate(.cfRange, &before) else { return .unknown }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, arg, &strRef) == .success,
              let ch = (strRef as? String)?.first else { return .unknown }
        return ch.isLetter ? .letter : .boundary
    }
}
