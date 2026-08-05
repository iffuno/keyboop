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
        if let (element, text) = readAX() {
            return (text, { SelectionText.write(element, $0) })
        }
        if let text = readViaClipboard() {
            kbLog("selection: прочитано через буфер (Cmd+C), \(text.count) симв.")
            return (text, nil)
        }
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
            if pb.changeCount != before { copied = pb.string(forType: .string); break }
        }
        kbLog("selection clipboard: changeCount \(before)→\(pb.changeCount), строка=\(copied?.count ?? -1) симв.")
        // восстановить исходный буфер, только если изменили его мы (changeCount сдвинулся)
        if pb.changeCount != before {
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
        }
        guard let text = copied, !text.isEmpty else { return nil }
        return text
    }

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
