import Foundation
import CoreGraphics
import Carbon
import AppKit   // замена в НАШЕМ собственном поле ввода идёт через AppKit (см. replaceInOwnField)

/// Маркер «это наша синтетика» в поле `.eventSourceUserData` каждого синтетического события.
/// EventTap фильтрует наши события ПО ЭТОМУ МАРКЕРУ (а не по временно́му флагу muted) → различение
/// «наше/чужое» становится свойством СОБЫТИЯ, а не тайминга. Раньше единственным барьером был muted,
/// который в окне постинга+дренажа РОНЯЛ реальные нажатия быстрого набора (буфер↔экран рассинхрон →
/// «иногда не переключается», «gпривет»). (Аудит 15.06, корни №1/№2.)
///
/// СЛУЧАЙНЫЙ per-launch (security-аудит L3, 01.07): раньше был хардкод `0x4B42_4F50` — открытая
/// константа, которую со-резидентный вредонос мог подставить в `.eventSourceUserData` своих
/// инжектов, чтобы Keyboop их пропускал (обход авто-коррекции, self-DoS). Непредсказуемый ключ,
/// заново на каждый запуск процесса, это исключает. Ненулевой (0 = обычное значение реальных событий).
let kbSyntheticMarker: Int64 = {
    var v: Int64 = 0
    while v == 0 { v = Int64.random(in: .min ... .max) }
    return v
}()

/// Метка события-ПУСТЫШКИ паузной правки (#19). Отдельная от `kbSyntheticMarker`, потому что смысл
/// противоположный: печатающую синтетику тап пропускает НАСКВОЗЬ, а пустышку — ГЛОТАЕТ и выполняет
/// по ней замену. Одна метка на оба смысла означала бы, что любое наше событие может быть принято
/// за команду «чини сейчас».
///
/// ⚠️ Тип события — именно keyDown (28.07). Первая версия слала `flagsChanged` с текущими флагами,
/// и она НЕ ДОХОДИЛА: flagsChanged описывает ПЕРЕХОД состояния модификаторов, а событие «состояние
/// не изменилось» система отбрасывает как no-op. В логе было 53 срабатывания inline-пути и ровно
/// НОЛЬ паузных. keyDown доходит гарантированно — на нём же работает вся синтетика замены.
/// virtualKey 255 не назначен ни на что и без keyboardSetUnicodeString не печатает ничего, поэтому
/// даже утечка (тап умер между постингом и доставкой) безвредна. Пары keyUp мы не шлём вовсе, так
/// что глотание пустышки инвариант парности не затрагивает.
let kbPauseFixMarker: Int64 = {
    var v: Int64 = 0
    while v == 0 || v == kbSyntheticMarker { v = Int64.random(in: .min ... .max) }
    return v
}()

/// Замена текста БЕЗ буфера обмена: синтетические Backspace + печать Unicode напрямую
/// через `keyboardSetUnicodeString` (минуя раскладку). Краеугольный принцип Keyboop.
enum TextReplacer {

    /// Пауза перед первым Backspace. ЕДИНАЯ для всех приложений: попытка удлинить её для
    /// Chromium/Electron (25.07) сделала хуже — она растягивает окно, в которое успевает вклиниться
    /// реальное нажатие пользователя. См. разбор в Engine рядом с F6.
    static var settleMicros: UInt32 = 9_000

    // ⚠️ ЗДЕСЬ БЫЛА «ДЕШЁВАЯ СТРАХОВКА ОТ ГОНКИ» — УБРАНА 28.07, НЕ ВОЗВРАЩАТЬ БЕЗ РАЗБОРА.
    //
    // Идея была такая: если реальная клавиша вклинилась в settle-паузу, а backspace'ы ещё не улетели,
    // отменить задание целиком — и вместо испорченного «GПривет» человек получит слово как набрал.
    // Звучит бесплатно. Ревью показало, что нет:
    //
    //  1. Задания сниппета и Enter-pre ставятся ПОСЛЕ того, как клавиша уже проглочена тапом
    //     (пробел-разделитель, сам Enter). Отмена такого задания теряет проглоченное нажатие
    //     насовсем: «адр» + пробел давало «адрx» вообще без пробела, а проглоченный Enter не
    //     отправлял сообщение. Съеденный ввод — худший класс бага в этом проекте, см. правило F1.
    //  2. Хвост конверсии (звук, смена раскладки, счётчик «расколдовано») выполняется на main ДО
    //     settle-паузы. При отмене человек слышал подтверждение и видел смену языка, а текст не
    //     менялся — ровно та сигнатура «звук был, а текст не переключился», которую мы сами
    //     записали как признак поломки.
    //  3. Прикрывает всего ~9 мс из ~53 мс реального окна гонки (посчитано по логам пользователей),
    //     то есть около 17%.
    //
    // Настоящее лечение — удерживать вклинившуюся клавишу и переигрывать её после замены
    // (задача #19), оно едет отдельным релизом.


    private static let backspaceKey: CGKeyCode = 51

    /// Delete-ВПЕРЁД (kVK_ForwardDelete). Нужен ровно в одном месте — см. `killSpotlightSuggestion`.
    private static let forwardDeleteKey: CGKeyCode = 117

    /// ПОДСКАЗКА SPOTLIGHT СЪЕДАЕТ ПЕРВЫЙ BACKSPACE (05.08.2026).
    ///
    /// Spotlight дополняет запрос ВЫДЕЛЕННЫМ хвостом, и первый наш Backspace гасит это выделение
    /// вместо символа — off-by-one, из-за которого «ghjdthrf» превращалось в «gпров». Диагноз был
    /// известен с середины июня, и лечили его запретом: 31.07 Spotlight внесли в «не конвертировать».
    /// Запрет оказался дорогим (вслепую печатают как раз в поиске), поэтому лечим причину.
    ///
    /// Лишним Backspace'ом компенсировать НЕЛЬЗЯ: когда подсказки нет, он съест настоящий символ, то
    /// есть мы поменяем один класс порчи на другой. Читать выделение через AX тоже нельзя — это IPC
    /// на горячем пути, ровно тот класс, который 31.07 заморозил ввод во всей системе.
    ///
    /// Delete-вперёд решает обе половины одним движением, потому что он РАЗЛИЧАЕТ эти случаи сам:
    /// есть выделение — удаляет выделение; выделения нет, а каретка в конце строки — удалять справа
    /// нечего, и он не делает ничего. То есть после него число символов слева от каретки одинаково в
    /// обоих случаях, и наш счёт бэкспейсов снова верен.
    ///
    /// Проверено снимками окна 05.08: «ощгк» + подсказка → Delete-вперёд → «ощгк» без подсказки,
    /// текст цел, каретка в конце → Backspace → «ощг», ровно один символ.
    ///
    /// ⚠️ Условие применимости — каретка в конце ввода. Для нашего пути это так по построению
    /// (конвертируем сразу после набора), но если когда-нибудь появится замена не у конца строки,
    /// сюда придётся вернуться.
    private static func killSpotlightSuggestion(source src: CGEventSource?) {
        guard SpotlightWatch.isOpen else { return }
        postKey(forwardDeleteKey, source: src)
        usleep(1800)
    }
    private static let returnKey: CGKeyCode = 36

    /// ВСЯ синтетика (Backspace + печать Unicode) с usleep-паузами идёт на ВЫДЕЛЕННОЙ serial-очереди,
    /// а НЕ на главном потоке. На main живёт активный CGEventTap (.defaultTap, глотает ввод); синхронные
    /// usleep там морозили бы доставку ВСЕГО ввода системы (security review 15.06 — класс бага уже был
    /// в 0.1.34). `completion` зовётся на main по факту завершения постинга — там вызывающий снимает
    /// `muted` (с дренаж-задержкой), а не по фикс-таймеру, иначе размьютит до того, как синтетика отыграет.
    private static let synthQueue = DispatchQueue(label: "ru.keyboop.synth", qos: .userInteractive)

    /// Активен «секретный ввод» (поле пароля, системный диалог аутентификации). Синтетику в этот
    /// момент постить НЕЛЬЗЯ: текст ушёл бы в невидимое поле пароля, а Backspace/Return могли бы
    /// подтвердить чужой диалог (инцидент 23.07.2026 — диалог пароля украл фокус в конце диктовки).
    /// Carbon-флаг глобален и честен для всей системы. Проверяем в момент ПОСТИНГА (на synthQueue),
    /// а не постановки в очередь — окно гонки минимально.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Впечатать текст без удаления (для голосового ввода / перевода).
    ///
    /// `thenReturn` — сразу после текста отправить настоящий Return (авто-Enter диктовки, задача #36).
    /// Enter уходит В ТОМ ЖЕ synth-задании, как и у `replace`: между текстом и отправкой физически
    /// нечему вклиниться. Отдельным событием следом это было бы гонкой — реальное нажатие человека
    /// или чужая синтетика могли бы лечь между ними, и отправилось бы полсообщения.
    static func insert(_ text: String, thenReturn: Bool = false, returnMods: CGEventFlags = [],
                       completion: (() -> Void)? = nil) {
        synthQueue.async {
            guard !secureInputActive else {
                kbLog("synth: активен secure input — insert(\(text.count) симв.) пропущен")
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            let src = CGEventSource(stateID: .privateState)
            typeUnicode(text, source: src)
            if thenReturn {
                usleep(1800)   // дать полю принять текст, затем настоящий Return (keyCode, не "\n")
                postKey(returnKey, source: src, mods: returnMods)
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Удалить `deleteCount` символов и впечатать `text`.
    /// `firstKeySettleMicros` — пауза перед ПЕРВЫМ Backspace: даём приложению зафиксировать только что
    /// набранное, иначе Backspace прилетает в ещё-незакоммиченное поле и «теряется». Для автозамены
    /// сниппета пауза больше (триггер мог быть только что добран) — см. Engine.expandSnippet.
    /// `thenReturn` — после замены отпустить ЗАДЕРЖАННЫЙ Enter (enter-pre конверсия, см.
    /// Engine.convertBeforeReturn): синтетический Return в ТОМ ЖЕ synth-задании — строго после
    /// всех Backspace/Unicode, ничто не может вклиниться между заменой и отправкой.
    /// Замена в НАШЕМ собственном поле ввода, через AppKit. true — сделали, синтетика не нужна.
    ///
    /// Работает только когда наше приложение активно и первый откликающийся — редактируемый текст:
    /// NSTextView (форма отзыва) или полевой редактор NSTextField (поле контакта, поля настроек).
    /// Во всех остальных случаях возвращаем false и уходим обычным путём.
    ///
    /// Удаляем ровно `deleteCount` символов ПЕРЕД кареткой и вставляем новый текст одной операцией:
    /// `insertText(_:replacementRange:)` проходит через штатный ввод, поэтому Undo (⌘Z) продолжает
    /// работать, а делегаты поля (у нас на нём висит плейсхолдер) получают своё уведомление.
    private static func replaceInOwnField(deleteCount: Int, with text: String) -> Bool {
        guard Thread.isMainThread else {
            // Вызывают и с фоновых очередей. Синхронный прыжок на main здесь безопасен: замена
            // короткая, а решение «наше ли окно» иначе не принять — AppKit только на главном.
            return DispatchQueue.main.sync { replaceInOwnField(deleteCount: deleteCount, with: text) }
        }
        guard NSApp?.isActive == true, let responder = NSApp?.keyWindow?.firstResponder else { return false }
        guard let tv = responder as? NSTextView, tv.isEditable else { return false }
        let sel = tv.selectedRange()
        let n = max(0, deleteCount)
        guard sel.length == 0, sel.location >= n else { return false }   // выделение — не наш случай
        let range = NSRange(location: sel.location - n, length: n)
        guard tv.shouldChangeText(in: range, replacementString: text) else { return false }
        tv.insertText(text, replacementRange: range)
        tv.didChangeText()
        kbLog("synth: своё поле — заменили напрямую (-\(n)+\(text.count)), без синтетики")
        return true
    }

    static func replace(deleteCount: Int, with text: String,
                        firstKeySettleMicros: UInt32? = nil, thenReturn: Bool = false,
                        completion: (() -> Void)? = nil) {
        // СВОЁ ОКНО — ЗАМЕНЯЕМ НАПРЯМУЮ, БЕЗ СИНТЕТИКИ (30.07).
        //
        // Когда фронт — мы сами (форма отзыва, настройки, редактор сниппетов), бить по своему же полю
        // бэкспейсами и синтетическим Unicode бессмысленно и вредно: мы держим это поле в руках и
        // можем отредактировать его текст вызовом API. Синтетика здесь давала худший из миров — гонки
        // с собственным тапом и, судя по пяти репортам «печатаю в форме и не вижу текста», съеденные
        // символы.
        //
        // Была промежуточная правка (тем же утром): движок в своих окнах выключался целиком. Она
        // симптом убрала, но вместе с ним и пользу — автор сразу заметил, что в «Написать
        // разработчику» перестало работать авто-переключение. Это возврат пользы без синтетики.
        if replaceInOwnField(deleteCount: deleteCount, with: text) {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        // Замер пути (репорт 23.07: «конвертация стала чуть дольше»): ожидание очереди + синтез.
        // Одна строка на замену — это редкое событие, зато жалоба «дольше» становится цифрой.
        let tEnq = ProcessInfo.processInfo.systemUptime
        synthQueue.async {
            let tStart = ProcessInfo.processInfo.systemUptime
            guard !secureInputActive else {
                // Глотаем ВСЁ задание, включая thenReturn: синтетический Enter в диалог
                // аутентификации мог бы его подтвердить — потерянный Enter безопаснее.
                kbLog("synth: активен secure input — replace(-\(deleteCount)+\(text.count)) пропущен")
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            // privateState — чтобы не наследовать зажатые пользователем модификаторы (⌥⇧ хоткея).
            let src = CGEventSource(stateID: .privateState)
            let n = max(0, deleteCount)
            let settle = firstKeySettleMicros ?? settleMicros
            if n > 0 {
                // Пауза перед ПЕРВЫМ Backspace — иначе он иногда теряется, прилетая слишком рано
                // после клавиши-триггера, и первый символ остаётся в старой раскладке («gривет»).
                usleep(settle)
                killSpotlightSuggestion(source: src)
                for _ in 0..<n {
                    postKey(backspaceKey, source: src)
                    usleep(1800)
                }
            }
            typeUnicode(text, source: src)
            if thenReturn {
                usleep(1800)   // дать полю принять замену, затем настоящий Return (keyCode, не "\n")
                postKey(returnKey, source: src)
            }
            let tEnd = ProcessInfo.processInfo.systemUptime
            // Пауза в логе — чтобы по репорту «остался первый символ» сразу было видно, сработала ли
            // удлинённая пауза для Electron, а не гадать по названию приложения.
            kbLog("synth: replace −\(n)+\(text.count) · очередь \(Int((tStart - tEnq) * 1000))мс · синтез \(Int((tEnd - tStart) * 1000))мс · пауза \(settle / 1000)мс")
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - INLINE-замена ВНУТРИ колбэка тапа (гонка закрыта по построению)
    //
    // Почему так (research, 25.07.2026): наш tap АКТИВНЫЙ (.defaultTap), значит
    // WindowServer ЖДЁТ возврата из колбэка — пока мы внутри, НИ ОДНО клавиатурное событие не проходит
    // дальше по цепочке. А `CGEventTapPostEvent` кладёт событие «впереди» того, что вернёт колбэк
    // (CGEvent.h: "The new event enters the system before the event returned by the callback").
    // Итог: окно, в которое вклинивались реальные клавиши (рваное «yнормаmyj»), не сужено, а
    // СТРУКТУРНО ОТСУТСТВУЕТ. Приём известен и в других переключателях (но обычно через keycode-replay + буфер обмена
    // — этого мы не копируем: Unicode не зависит от раскладки, а буфер священен).
    //
    // ЖЁСТКИЕ ПРАВИЛА этого пути: НИ ОДНОГО usleep (мы держим WindowServer), ни одного системного
    // вызова (AX/TIS/NSSound/NSWorkspace) — только создание и постинг событий.

    /// Источник событий создаём ОДИН раз: замер 25.07 показал 23 мс на первом «холодном» создании
    /// внутри колбэка (это выше нашего порога 15 мс — риск kCGEventTapDisabledByTimeout) против
    /// 0.01 мс на прогретом. Дешевле держать источник и прогреть его на старте.
    private static let inlineSource: CGEventSource? = CGEventSource(stateID: .privateState)

    /// Прогрев: создаём (НЕ постим) пару событий, чтобы первый реальный burst не платил за
    /// ленивую инициализацию CoreGraphics. Зовётся один раз при старте движка.
    static func warmUpInline() {
        guard let src = inlineSource else { return }
        for _ in 0..<8 {
            _ = CGEvent(keyboardEventSource: src, virtualKey: backspaceKey, keyDown: true)
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            var u = Array("прогрев".utf16)
            u.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        }
    }

    /// Удалить `deleteCount` символов и впечатать `text` — ЦЕЛИКОМ внутри колбэка тапа.
    /// `post` — замыкание над `event.tapPostEvent(proxy)` (proxy валиден только внутри колбэка).
    ///
    /// F1 (ревью 25.07): «проглотили клавишу, а пакет не ушёл» = съеденное нажатие. Поэтому СНАЧАЛА
    /// строим ВСЕ события, и только если построились ВСЕ — постим и разрешаем глотать. Любой сбой →
    /// false, вызывающий не глотает и падает на прежний асинхронный путь.
    /// F5: `IsSecureEventInputEnabled()` стоит до ~44мс на холодную — в колбэке его НЕ зовём,
    /// вызывающий проверяет заранее (Engine держит поллер secure input).
    @discardableResult
    static func replaceInline(deleteCount n: Int, with text: String, post: (CGEvent) -> Void) -> Bool {
        guard n >= 0, let src = inlineSource else { return false }
        var batch: [CGEvent] = []
        batch.reserveCapacity(n * 2 + 6)
        // Та же подсказка Spotlight, что и в асинхронном пути (см. killSpotlightSuggestion) — здесь
        // Delete-вперёд просто становится первой парой событий пакета.
        if SpotlightWatch.isOpen, n > 0 {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: forwardDeleteKey, keyDown: down) else { return false }
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
                batch.append(e)
            }
        }
        for _ in 0..<n {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: backspaceKey, keyDown: down) else { return false }
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
                batch.append(e)
            }
        }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 12, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { return false }
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
                chunk.withUnsafeBufferPointer {
                    e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                batch.append(e)
            }
            i += 12
        }
        guard !batch.isEmpty else { return false }
        for e in batch { post(e) }   // всё построено — отправляем разом
        return true
    }

    /// `mods` — модификаторы для отправки (авто-Enter: разные приложения шлют по разным сочетаниям).
    /// Пустые по умолчанию: это же postKey используют Backspace'ы, которым модификаторы противопоказаны.
    private static func postKey(_ key: CGKeyCode, source: CGEventSource?, mods: CGEventFlags = []) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = mods
            down.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)   // «это наше»
            down.post(tap: .cghidEventTap)
        }
        usleep(900)   // короткое «удержание» down→up — некоторые поля не видят мгновенный тап
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = mods
            up.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Печать строки как Unicode. Лимит ~20 UTF-16 единиц на событие → бьём по 12.
    private static func typeUnicode(_ string: String, source: CGEventSource?) {
        let units = Array(string.utf16)
        guard !units.isEmpty else { return }
        var i = 0
        let chunkSize = 12
        while i < units.count {
            let chunk = Array(units[i..<min(i + chunkSize, units.count)])
            postUnicodeChunk(chunk, keyDown: true, source: source)
            postUnicodeChunk(chunk, keyDown: false, source: source)
            i += chunkSize
            usleep(800)
        }
    }

    private static func postUnicodeChunk(_ chunk: [UniChar], keyDown: Bool, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)   // «это наше»
        chunk.withUnsafeBufferPointer { buf in
            event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        event.post(tap: .cghidEventTap)
    }
}
