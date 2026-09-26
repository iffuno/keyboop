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
    /// Убить подсказку автодополнения, дописанную ВЫДЕЛЕНИЕМ справа от каретки: иначе наш первый
    /// Backspace гасит выделение вместо символа, и слева остаётся ровно один непеределанный знак.
    ///
    /// ⚠️ ГЕЙТ БОЛЬШЕ НЕ «ТОЛЬКО SPOTLIGHT» (14.08.2026, отзывы #103, #104, #107 с видео: то же самое
    /// в адресной строке Chrome). Раньше выбор стоял между «чинить везде и рисковать съесть чужой
    /// символ у человека, который кликнул в середину строки» и «не чинить нигде, кроме Spotlight».
    /// Разбор снял этот размен: `AXScreenCheck.hasSelection()` отвечает ровно на тот вопрос, от
    /// которого зависит безопасность delete-вперёд. Есть выделение — оно и есть подсказка, гасим.
    /// Нет выделения — справа живой текст, не трогаем. AX молчит (Electron, веб) — ведём себя как
    /// раньше, то есть чиним только в Spotlight, где это проверено временем.
    private static func killSpotlightSuggestion(source src: CGEventSource?) {
        // ⚠️ В SPOTLIGHT ГАСИМ БЕЗУСЛОВНО, КАК И ДО 14.08 (регресс, пойман автором 16.08).
        // Вчера я добавил сюда ранний выход «выделения нет, значит гасить нечего» и этим сломал
        // ровно тот случай, ради которого функция и написана: в Spotlight `AXScreenCheck` про
        // выделение отвечает не всегда, и на его «нет» мы переставали слать delete-вперёд. Первая
        // буква снова оставалась, а в логе это выглядит невинно: «convert-word(хоткей): 3 симв.» и
        // «synth: replace −3+3», то есть мы честно заменили три символа, просто один Backspace
        // съела подсказка.
        //
        // Правильная роль проверки выделения — РАСШИРЯТЬ починку за пределы Spotlight, а не сужать
        // её внутри. Поэтому: в Spotlight гасим всегда (там каретка в конце по построению, лишний
        // delete-вперёд безвреден), в остальных приложениях только когда выделение доказано.
        let selected = AXScreenCheck.hasSelection()
        guard SpotlightWatch.isOpen || selected == true else { return }
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

    /// КУДА ОТПРАВЛЯЕМ СИНТЕТИКУ. Не `.cghidEventTap`, и это принципиально (11.09.2026).
    ///
    /// Перехватчики клавиатуры в macOS стоят цепочкой: HID → session → annotated → приложение.
    /// `CGEventPost` кладёт событие ПЕРЕД перехватчиками той ступени, которую назвали, и дальше оно
    /// идёт вниз через всех (CGEvent.h: «posts the specified event immediately before any event taps
    /// instantiated for that location, and the event passes through any such taps»). Мы годами
    /// отправляли с самой верхней ступени, то есть предъявляли каждый свой символ ВСЕМ чужим
    /// перехватчикам в системе. Пока сосед по классу был один (Punto, и того мы просим закрыться),
    /// это ничего не стоило.
    ///
    /// 11.09.2026 замерено, чего это стоит на самом деле. На машине автора параллельно работал второй
    /// переключатель раскладки с АКТИВНЫМ фильтром на ступени session (проверено `CGGetEventTapList`:
    /// tapPoint = session, options = default, слушает всю систему). Активный фильтр вправе вернуть
    /// NULL и УДАЛИТЬ событие (CGEventTypes.h: «or NULL if the event is to be deleted»). Из 34 вставок
    /// диктовки три потеряли по 1, 1 и 6 кусков целиком: пассивный слушатель, поставленный на
    /// последнюю ступень, их не увидел вовсе, хотя мы их отправили. Плюс сосед дописывал поверх свой
    /// перенабор латиницей и обгрызал хвосты Backspace'ами. Ни пауза, ни повтор, ни другой источник
    /// событий против удаления не помогают — помогает только войти в поток НИЖЕ чужого фильтра.
    ///
    /// `.cgAnnotatedSessionEventTap` это ступень ПОСЛЕ session: перехватчики, стоящие на HID и
    /// session, наших событий больше не видят, а приложение получает их как обычно, вместе со
    /// строкой из `keyboardSetUnicodeString`. Так делают те, кто уже наступал на эти грабли:
    /// viet-ime (там это записано прямо: отправляем на annotated, чтобы обойти собственный тап),
    /// skhd (`synthesize_text`), Clipy и Quicksilver для своего ⌘V.
    ///
    /// ⚠️ ЦЕНА, КОТОРУЮ НАДО ПОМНИТЬ. Наш СОБСТВЕННЫЙ тап стоит на session и тоже перестаёт видеть
    /// эти события. Для печатающей синтетики это ровно то же самое, что было раньше: тап и так
    /// пропускал её насквозь по маркеру. НО пустышка паузной правки (`kbPauseFixMarker`,
    /// `Engine.pauseFixTick`) живёт наоборот — она существует РАДИ того, чтобы наш тап её поймал и
    /// проглотил. Её отправка обязана остаться на `.cghidEventTap`, иначе паузная правка умрёт
    /// молча. Там это написано у места отправки; если будешь двигать точки отправки дальше, начни
    /// с вопроса «а кто должен это событие УВИДЕТЬ».
    ///
    /// Замер после правки — тем же способом: `scratchpad/evtap.swift` (слушатель на annotated,
    /// listenOnly, tailAppend — события, отправленные НА annotated, он видит) плюс сверка текста
    /// истории диктовки с тем, что доехало.
    /// ⚠️ ВЫБОР СТУПЕНИ ТЕПЕРЬ УСЛОВНЫЙ, И ЭТО ИСПРАВЛЕНИЕ СЛОМАННОГО ВЫПУСКА (12.09.2026).
    ///
    /// Утром 12.09 сюда встала безусловная `.cgAnnotatedSessionEventTap`: она спасает от соседа,
    /// чей активный тап съедал куски нашей вставки. Через несколько часов выяснилось, чем это
    /// оплачено: в Spotlight конверсия перестала работать совсем. События на annotated идут тому
    /// приложению, которое система считает передним, а Spotlight передним не становится. В логе всё
    /// выглядело исправным («convert-word(авто): 7 симв. LAT → RU», «synth: replace −7+7»), а текст
    /// не доезжал. Опыт, снявший все сомнения: одну и ту же строку отправили в открытый Spotlight
    /// дважды, с hid она появилась, с annotated нет.
    ///
    /// Поэтому: ниже чужого тапа уходим ТОЛЬКО когда сосед реально есть, и никогда — когда открыт
    /// Spotlight, где «переднее приложение» врёт. Во всех остальных случаях отправляем как раньше,
    /// с самой ранней ступени.
    private static var synthPostTap: CGEventTapLocation {
        (RivalTapWatch.present && !SpotlightWatch.isOpen) ? .cgAnnotatedSessionEventTap : .cghidEventTap
    }

    /// Активен «секретный ввод» (поле пароля, системный диалог аутентификации). Синтетику в этот
    /// момент постить НЕЛЬЗЯ: текст ушёл бы в невидимое поле пароля, а Backspace/Return могли бы
    /// подтвердить чужой диалог (инцидент 23.07.2026 — диалог пароля украл фокус в конце диктовки).
    /// Carbon-флаг глобален и честен для всей системы. Проверяем в момент ПОСТИНГА (на synthQueue),
    /// а не постановки в очередь — окно гонки минимально.
    ///
    /// ⚠️ САМ ПО СЕБЕ ЭТОТ ФЛАГ БОЛЬШЕ НЕ РЕШАЕТ, ПИСАТЬ ИЛИ НЕТ (25.08.2026). Он сессионный, и его
    /// поднимает любая программа на своём поле пароля, делая нас мёртвыми во всех остальных сразу.
    /// Решение принимает `SecureInputPolicy.canWrite`, которая спрашивает САМО ПОЛЕ под кареткой.
    /// Здесь остался сырой признак — он ещё нужен там, где вопрос именно «флаг поднят?».
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
            guard SecureInputPolicy.canWrite("insert \(text.count) симв.") else {
                kbLog("synth: писать нельзя — insert(\(text.count) симв.) пропущен")
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
        // Spotlight поверх собственного окна Keyboop: печатают в поиск, а «активны» по-прежнему мы.
        // Без этой проверки замена ушла бы в наше поле под панелью (ревью задачи 261, 26.09.2026).
        guard !SpotlightWatch.isOpen, NSApp?.isActive == true,
              let responder = NSApp?.keyWindow?.firstResponder else { return false }
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
            guard SecureInputPolicy.canWrite("replace -\(deleteCount)+\(text.count)") else {
                // Глотаем ВСЁ задание, включая thenReturn: синтетический Enter в диалог
                // аутентификации мог бы его подтвердить — потерянный Enter безопаснее.
                kbLog("synth: писать нельзя — replace(-\(deleteCount)+\(text.count)) пропущен")
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            // privateState — чтобы не наследовать зажатые пользователем модификаторы (⌥⇧ хоткея).
            let src = CGEventSource(stateID: .privateState)
            // Жертва идёт ПЕРВОЙ, до Backspace: в Chromium съедается ровно первое событие задания,
            // и без неё пропадал бы первый Backspace — тот самый «gривет» из комментария ниже.
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
            down.post(tap: synthPostTap)
        }
        usleep(900)   // короткое «удержание» down→up — некоторые поля не видят мгновенный тап
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = mods
            up.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
            up.post(tap: synthPostTap)
        }
    }

    /// ⚠️ ЖЕРТВЕННОЕ ПЕРВОЕ СОБЫТИЕ ДЛЯ CHROMIUM/ELECTRON (Figma, отзыв @alpus, доказано 08.09.2026).
    ///
    /// Правило, установленное опытом в живой Figma: приложение СЪЕДАЕТ ПЕРВОЕ наше клавиатурное
    /// событие после срабатывания хоткея — целиком, каким бы оно ни было. Доказательства:
    ///  · кусок 12 → на экране «егодня» вместо «привет мир сегодня» (пропали первые 12 символов);
    ///  · кусок 6 → на экране « мир сегодня» (пропали первые 6). Значит теряется КУСОК, а не 12 знаков;
    ///  · пауза 40 мс перед первым куском не помогла — дело не в том, что мы спешим;
    ///  · пустышка `flagsChanged` не помогла — аппетит именно на клавишу, а не на любое событие;
    ///  · пустое Unicode-событие перед текстом помогло: «привет мир сегодня» доехало целиком.
    ///
    /// Тот же дефект много месяцев жил на пути `replace` под другим именем: «первый Backspace
    /// иногда теряется, и первый символ остаётся в старой раскладке („gривет")». Лечили паузой
    /// (`settleMicros`), и она помогала «иногда» — потому что лечила не то.
    ///
    /// Жертва — keyDown с ПУСТОЙ Unicode-строкой. Приложение, которое честно читает
    /// `keyboardSetUnicodeString` (а без этого у нас не работала бы вся печать вообще), вставит из
    /// неё ровно ничего. Поэтому включаем её ТОЛЬКО там, где доказана нужда: Chromium и Electron.
    /// Флаг ставит `Engine` на смене активного приложения — он и так считает `frontAppIsChromium`.
    /// Ставит `Engine` на смене активного приложения. Читается только в
    /// `sacrificeKeyAfterClipboardRead` — вне Chromium/Electron жертва не посылается.
    static var primeFirstKey = false

    /// ⛔️ ОТКЛЮЧЕНО В ТОТ ЖЕ ДЕНЬ, 08.09.2026, ПО ЖИВОЙ ЖАЛОБЕ ИВАНА. Оставлено кодом, потому что
    /// сама идея верна, а неверным было ровно одно допущение — и его надо помнить.
    ///
    /// Жертва посылалась как keyDown с ПУСТОЙ Unicode-строкой и виртуальным кодом 0. Я рассуждал
    /// так: приложение, которое честно читает `keyboardSetUnicodeString` (а без этого у нас не
    /// работала бы вся печать), из пустой строки вставит ровно ничего. На деле пустая строка — это
    /// для приложения «строки нет», и оно откатывается на КОД КЛАВИШИ. Код 0 — это «a» в латинской
    /// раскладке и «ф» в русской. автор получил лишнюю букву в начале каждой диктовки: «фво всех
    /// последних диктовках у меня почему-то в начале первая буква вставляется». Проверял я правку
    /// только на конверсии выделения в Figma, где лишний символ съедало само выделение, — и не
    /// проверил её на пути, ради которого `insert` вообще существует, на вставке диктовки.
    ///
    /// Что остаётся верным и доказанным: Chromium и Electron съедают ПЕРВОЕ наше клавиатурное
    /// событие после срабатывания хоткея (кусок 12 → пропали 12 символов, кусок 6 → пропали 6,
    /// пауза 40 мс не помогла, пустышка flagsChanged не помогла). Нужна жертва, которая не может
    /// породить символ НИ В КАКОЙ раскладке, и проверять её надо на всех трёх путях сразу:
    /// конверсия выделения, смена регистра, вставка диктовки.
    /// ЖЕРТВЕННАЯ КЛАВИША ПОСЛЕ НАШЕГО СИНТЕТИЧЕСКОГО ⌘C (11.09.2026, задача 249).
    ///
    /// Что происходит без неё. Figma съедает ПЕРВОЕ клавиатурное событие, пришедшее после нашего
    /// ⌘C (мы шлём его, когда читаем выделение через буфер, потому что Accessibility в этом
    /// приложении текст отдаёт не всегда). Съедает целиком, каким бы оно ни было: вставка из
    /// восемнадцати символов приезжала как «егодня», то есть ровно без первого куска в двенадцать
    /// символов, а короткое слово в один кусок не менялось вообще.
    ///
    /// ⚠️ ПРАВИЛО ПЕРЕПИСАНО ПО ОПЫТУ 11.09, ПРЕЖНЯЯ ФОРМУЛИРОВКА БЫЛА НЕВЕРНОЙ. В карточке 249
    /// с 08.09 стояло «Chromium съедает первое событие после хоткея». Опыт в живой Figma это
    /// опроверг: дело не в хоткее и не в точке отправки событий, а именно в ⌘C. Матрица из шести
    /// прогонов, одна и та же строка, одно и то же поле:
    ///   · чтение через ⌘C + старая точка отправки → 6 из 18 (потеря);
    ///   · чтение через ⌘C + новая точка отправки  → 6 из 18 (потеря);
    ///   · чтение через Accessibility + старая     → 18 из 18;
    ///   · чтение через Accessibility + новая      → 18 из 18.
    /// Отсюда же объяснение старой загадки «почему смена регистра в той же Figma не теряла ничего»:
    /// она читала выделение через Accessibility и ⌘C не посылала вовсе.
    ///
    /// Почему жертва именно такая. Пожирателю нужно НАЖАТИЕ: одиночное отпускание F18 без пары он
    /// пропустил мимо, и текст снова приехал обрезанным (проверено). Значит шлём пару нажатие плюс
    /// отпускание. Код F18 (79) выбран потому, что у него нет символа НИ В ОДНОЙ раскладке — в
    /// отличие от кода 0, которым была прежняя, отключённая жертва: пустая Unicode-строка означает
    /// для приложения «строки нет», оно откатывается на код клавиши, и человек получал лишнюю «ф»
    /// или «a» в начале каждой диктовки. F17 (64) проверен как запасной и работает так же.
    ///
    /// ⚠️ ОБЛАСТЬ ДЕЙСТВИЯ УЖЕ, ЧЕМ БЫЛА, И ЭТО ГЛАВНАЯ ЗАЩИТА ОТ ПОВТОРА ТОЙ ОШИБКИ. Жертва
    /// посылается ТОЛЬКО из пути чтения выделения через буфер и ТОЛЬКО в Chromium/Electron. Путь
    /// вставки диктовки ⌘C не шлёт вовсе, поэтому эта правка до него физически не дотягивается.
    ///
    /// Побочная польза: съеденной оказывается наша жертва, а не следующая клавиша ЧЕЛОВЕКА. Если он
    /// начнёт печатать сразу после конверсии, его первый символ больше не пропадёт.
    static func sacrificeKeyAfterClipboardRead() {
        guard primeFirstKey else { return }
        let src = CGEventSource(stateID: .privateState)
        postRawKey(sacrificeKey, keyDown: true, source: src)
        usleep(1200)
        postRawKey(sacrificeKey, keyDown: false, source: src)
        usleep(1200)
        kbLog("жертва после ⌘C отправлена (Chromium/Electron)")
    }

    /// F18. Ни в одной раскладке не даёт символа, по умолчанию в macOS ни на что не назначена.
    private static let sacrificeKey: CGKeyCode = 79

    /// Событие клавиши БЕЗ Unicode-строки: приложение переведёт код само. Для жертвы это и нужно —
    /// у F17…F20 нет символа ни в одной раскладке, поэтому вставить им нечего.
    private static func postRawKey(_ key: CGKeyCode, keyDown: Bool, source: CGEventSource?) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { return }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
        e.post(tap: synthPostTap)
    }

    /// ЗАМЕНИТЬ ТЕКСТ ВЫДЕЛЕННОГО ОБЪЕКТА НА ХОЛСТЕ (Figma, задача 249, 11.09.2026).
    ///
    /// Зачем отдельный путь. Когда выделен текстовый ОБЪЕКТ, а не текст внутри него, каретки нет,
    /// и печатать некуда: символы уходят в никуда. Именно это человек и описывает как «звучок есть,
    /// реакции никакой». Значит сначала надо войти внутрь текста, и только потом печатать.
    ///
    /// Как. Enter на выделенном текстовом объекте вводит Figma в режим правки и выделяет ВЕСЬ текст
    /// (замерено 11.09: сразу после Enter чтение выделения отдало все 18 символов). Печать поверх
    /// полного выделения заменяет его целиком, Escape возвращает обычное выделение объекта. Три
    /// события вместо одного, зато человек получает то, что просил.
    ///
    /// ⚠️ ВЫЗЫВАТЬ ТОЛЬКО ПРИ ПОЛОЖИТЕЛЬНОМ ПРИЗНАКЕ ХОЛСТА (`SelectionText.lastCopyLooksLikeCanvasNode`).
    /// Enter в приложении, где мы ошиблись состоянием, это не «ничего»: в мессенджере он отправит
    /// сообщение, в редакторе кода вставит перевод строки. Поэтому ветка включается не по имени
    /// приложения и не по форме текста, а по тому, что в буфере лежат данные объекта Figma.
    ///
    /// Всё задание идёт одним куском на synth-очереди: между Enter, печатью и Escape не может
    /// вклиниться ни реальное нажатие, ни чужая синтетика — тот же принцип, что у `thenReturn`.
    static func replaceCanvasObjectText(_ text: String, completion: (() -> Void)? = nil) {
        synthQueue.async {
            guard SecureInputPolicy.canWrite("замена текста объекта, \(text.count) симв.") else {
                kbLog("synth: писать нельзя — замена текста объекта пропущена")
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            let src = CGEventSource(stateID: .privateState)
            postKey(returnKey, source: src)     // войти в текст: выделяется всё содержимое
            usleep(60_000)                      // Figma перерисовывает поле; без паузы печать уходит мимо
            typeUnicode(text, source: src)
            usleep(20_000)
            postKey(escapeKey, source: src)     // выйти обратно на объект
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private static let escapeKey: CGKeyCode = 53

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
        event.post(tap: synthPostTap)
    }
}
