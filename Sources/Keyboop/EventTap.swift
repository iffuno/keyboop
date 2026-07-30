import Foundation
import CoreGraphics
import AppKit
import QuartzCore

protocol EventTapHandler: AnyObject {
    /// Возвращает true, если клавишу нужно ПРОГЛОТИТЬ (не пускать в приложение) — напр. граница слова,
    /// раскрывшая сниппет автозамены (разделитель печатаем сами, чтобы не удалять свежий пробел).
    /// `post` — постинг ВНУТРИ колбэка (event.tapPostEvent(proxy)); nil, если путь недоступен.
    /// Возврат true = клавишу проглотить (сниппет раскрыт / inline-замена уже отправлена).
    func handleKeyDown(keyCode: Int64, characters: String, flags: CGEventFlags,
                       post: ((CGEvent) -> Void)?) -> Bool
    func handleSwitchHotkey()
    /// ТОЛЬКО смена языка (RU↔EN), без конвертации набранного — действие клавиши 🌐/Fn.
    func handleLayoutSwitchOnly()
    func handleContextReset()
    func handleVoiceBegin()
    func handleVoiceEnd()
    func handleTranslateHotkey()
}

/// Глобальный наблюдатель клавиатуры (CGEventTap, АКТИВНЫЙ `.defaultTap` — нужен Accessibility,
/// НЕ listen-only/Input Monitoring) + настраиваемый хоткей. Active-tap обязателен, чтобы ГЛОТАТЬ
/// хоткеи (диктовка/перевод), иначе их клавиши печатаются.
/// Три режима: combo (⌥⇧), modkey (одна клавиша-модификатор — правый ⌥/⌘ и т.п.), key (клавиша+модификаторы).
final class EventTap {
    weak var handler: EventTapHandler?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?

    private var comboArmed = false
    private var otherKeyDuringCombo = false
    private var modkeyArmed = false
    private var lastModTap: CFTimeInterval = 0
    private var otherKeyBetweenTaps = false
    private var voiceActive = false
    private var voiceComboArmed = false             // комбинация модификаторов диктовки сейчас зажата целиком
    private var voiceKeyArmed = false
    private var lastVoiceToggle: TimeInterval = 0   // debounce toggle (не зависит от keyUp)
    private var deadState: UInt32 = 0               // состояние мёртвых клавиш для UCKeyTranslate-фолбэка
    private var cacheFallbackCount = 0              // сколько раз CG-строка была пуста (диагностика 23.07)
    /// 🌐/Fn взведена: было нажатие, ждём «чистого» отпускания. Любая другая клавиша между ними
    /// снимает взвод (Fn+F1, Fn+стрелки = Home/End — это КОМБИНАЦИИ, а не тап по 🌐).
    private var fnArmed = false
    /// Один раз предупредили про сохранённую голую клавишу мгновенного переключения (не спамим лог).
    private var warnedBareInstantSwitch = false

    /// ПАРНОСТЬ ГЛОТАНИЙ. keyCode'ы, у которых мы проглотили keyDown → обязаны проглотить и keyUp.
    ///
    /// Зачем (репорты #13/#22/#30, 27.07: «приложение блокирует пробел», «перестал работать ⌘+пробел
    /// и пробел в Finder, лечится только выходом из программы»): раньше keyUp диктовки глотался по
    /// ГОЛОМУ совпадению keyCode — без voiceEnabled, без модификаторов и без памяти о том, глотали ли
    /// мы парный keyDown. Хоткей ⌥` при нажатии одного `` ` `` пропускался (символ печатался), а его
    /// keyUp съедался → система считала клавишу зажатой, и обычный пробел начинал вести себя как
    /// ⌘Space. Правило было записано в комментарии ниже (ветка F3), но применялось только к
    /// inline-замене.
    ///
    /// Самоизлечение: обычное (непроглоченное) нажатие той же клавиши УБИРАЕТ её из набора — поэтому
    /// потерянный keyUp (переключились из приложения с зажатой клавишей) не отравляет следующий ввод.
    private var swallowedDownKeyCodes = Set<Int64>()

    /// Проглотить keyDown, запомнив клавишу: её keyUp тоже нельзя пускать в приложение.
    private func swallowDown(_ keyCode: Int64) -> Unmanaged<CGEvent>? {
        swallowedDownKeyCodes.insert(keyCode)
        return nil
    }

    func start() -> Bool {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            // «non-nil tap is not a healthy tap»: enable не оживил порт (система его прибила
            // и не пере-enable'нула) → сносим и пересоздаём ниже. Иначе вернули бы true для мёртвого.
            teardown()
        }
        // .defaultTap (active, не listen-only): нужен, чтобы ГЛОТАТЬ voice/перевод-хоткеи, иначе их
        // клавиши печатаются. Глотаем ТОЛЬКО эти события, всё остальное проходит насквозь.
        // ВАЖНО: возврат tapCreate — это ЖИВОЙ детектор доступа: не-nil ровно тогда, когда
        // Accessibility реально выдан СЕЙЧАС (без TCC-кэша, в отличие от залипающего AXIsProcessTrusted).
        let mask = bit(.keyDown) | bit(.flagsChanged) | bit(.keyUp)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        // Живой пробник для AppHealth: «работает ли движок ПРЯМО СЕЙЧАС», а не «стартовал когда-то».
        AppHealth.isEngineLive = { [weak self] in
            guard let t = self?.tap else { return false }
            return CGEvent.tapIsEnabled(tap: t)
        }
        // mouseMonitor ставим один раз (переживает пересоздание tap).
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in self?.handler?.handleContextReset() }
        }
        return true
    }

    /// Снести невалидный порт перед пересозданием (mouseMonitor НЕ трогаем — он независим).
    /// Набор парности чистим: пока тап был мёртв, отпускания прошли мимо нас, и висящие записи
    /// съели бы keyUp у следующих честных нажатий.
    private func teardown() {
        swallowedDownKeyCodes.removeAll()
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        runLoopSource = nil
        tap = nil
    }

    /// Всё «тяжёлое» из колбэка — на main. `kCGEventTapDisabledByTimeout` меряется по round-trip
    /// «WindowServer → mach-порт → ответ», поэтому любая работа тут приближает отключение тапа
    /// системой, а с ним — «ввод не проходит нигде» (инцидент 21.07).
    @inline(__always) private func onMain(_ b: @escaping () -> Void) { DispatchQueue.main.async(execute: b) }

    fileprivate func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        // Инструментовка: если колбэк вдруг стал медленным — увидим это ДО того, как система вырубит
        // тап, а не по факту потерянных нажатий.
        let tapT0 = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - tapT0) * 1000
            if ms > 15 { kbLog("МЕДЛЕННЫЙ колбэк tap: \(String(format: "%.1f", ms)) мс — риск таймаута") }
        }
        // НАША СИНТЕТИКА (Backspace+Unicode из TextReplacer) помечена маркером в .eventSourceUserData.
        // Пропускаем её НАСКВОЗЬ, не трогая буфер/хоткей-состояние. Это надёжная замена временно́му
        // фильтру muted: реальный ввод пользователя теперь НИКОГДА не глотается (даже во время нашей
        // конверсии) → буфер не рассинхронивается с экраном (аудит 15.06, корни №1/№2).
        // ПУСТЫШКА ПАУЗНОЙ ПРАВКИ (#19) — проверяем ПЕРВОЙ, до пропуска печатающей синтетики: у неё
        // своя метка и противоположный смысл (её надо СЪЕСТЬ и выполнить по ней замену).
        // Она существует ради одного: дать себе КОЛБЭК. Burst, отправленный отсюда через
        // tapPostEvent, встаёт в поток ДО любой реальной клавиши, нажатой после, — вклиниться в
        // замену нечему (тот же принцип, что inline-путь). Обрабатываем до handleKeyDown/handleFlags:
        // пустышка не должна трогать буфер и взводы хоткеев. keyUp у неё нет (мы его не шлём),
        // поэтому глотание не нарушает инвариант парности.
        if type == .keyDown,
           event.getIntegerValueField(.eventSourceUserData) == kbPauseFixMarker {
            (handler as? Engine)?.handlePauseFixMarker(post: { $0.tapPostEvent(proxy) })
            return nil
        }
        if (type == .keyDown || type == .keyUp),
           event.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let s = AppSettings.shared
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // ДИАГНОСТИКА «под нагрузкой конверсия не срабатывает» (баг-репорт): macOS САМА
            // глушит tap, если наш колбэк не успел вернуться вовремя (byTimeout) — а runloop tap'а
            // живёт на ГЛАВНОМ потоке, поэтому любой затык main (сборка окна настроек, своп при
            // большом footprint) может его вырубить. Мы включаем обратно, но нажатия за этот
            // промежуток ПОТЕРЯНЫ → «звук был, а текст не переключился». Раньше это происходило
            // молча и в логе не было ни следа. Теперь видно.
            kbLog("tap ОТКЛЮЧЁН системой (\(type == .tapDisabledByTimeout ? "таймаут колбэка" : "ввод пользователя")) — включаю обратно; нажатия за этот промежуток потеряны")
            // Пока тап был мёртв, отпускания прошли мимо нас: висящие записи парности съели бы keyUp
            // у следующих ЧЕСТНЫХ нажатий. Чистим здесь, а не только в teardown() — этот путь
            // оживления тапа его не зовёт.
            swallowedDownKeyCodes.removeAll()
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // F5 (ревью 25.07): при таймауте WindowServer перестаёт нас ждать и выпускает накопленную
            // очередь ВОКРУГ уже отправленного пакета — то есть ровно та рванина, от которой inline и
            // придуман, но уже без защиты. Один такой случай → inline выключаем до перезапуска.
            if type == .tapDisabledByTimeout { (handler as? Engine)?.disableInlineAfterTapTimeout() }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // УЧЁТ ДЛЯ МОДИФИКАТОРНЫХ ЖЕСТОВ — ДО всех ранних return'ов. Раньше он жил в конце
            // ветки, и клавиши, проглоченные выше (голосовой ⌥`, мгновенное переключение, перевод),
            // его ПРОПУСКАЛИ: взведённое комбо ⌥⇧ не узнавало, что между нажатием и отпусканием
            // была другая клавиша → отпускание ⌥ честно «срабатывало» конверсией. Ровно так у
            // автора 24.07 старт диктовки (⇧ остался с набора, накатом ⌥, затем `) дал ещё и звук
            // конвертации по пустому буферу.
            if comboArmed { otherKeyDuringCombo = true }
            modkeyArmed = false
            otherKeyBetweenTaps = true
            fnArmed = false   // Fn+клавиша = комбинация (F1/стрелки/яркость), а не тап по 🌐
            // ЗАПИСЬ КОМБИНАЦИИ В НАСТРОЙКАХ: пропускаем нажатие насквозь, не перехватывая свои
            // хоткеи. Иначе tap глотал ровно то, что человек пытается назначить (уже назначенную
            // комбинацию), запускал СТАРОЕ действие, а окно настроек не получало событие —
            // «нажимаю переназначить, ничего не происходит» (репорты пользователей 25.07).
            if HotkeyRecording.active { return Unmanaged.passUnretained(event) }
            // Escape во время диктовки — отмена (если включено). Глотаем Esc, чтобы он не
            // улетел в активное приложение.
            if keyCode == 53, s.escCancelsDictation, VoiceController.shared.isRecording {
                onMain { VoiceController.shared.cancel() }
                if s.voiceHoldMode == "toggle" { voiceKeyArmed = false } else { voiceActive = false }
                return swallowDown(keyCode)
            }
            // Мгновенное переключение языка комбинацией (⌘Space/⌃Space/своя): ГЛОТАЕМ, чтобы не
            // сработало то, что висит на ней в системе (Spotlight и пр.) — иначе всплывут оба.
            // ⚠️ Гард !isEmpty обязателен: это был ЕДИНСТВЕННЫЙ наш хоткей без него (у перевода и у
            // конверсии ниже он есть). Без него при mods=0 условие «relevantMods(flags) == []»
            // выполняется на КАЖДОМ голом нажатии этой клавиши — и мы глотали её у всей системы.
            // Исключение — функциональные клавиши: F13 без модификаторов это осмысленный хоткей,
            // и напечатать её как текст нельзя, так что вреда нет (28.07).
            if s.instantSwitchEnabled, s.instantSwitchMode == "key",
               keyCode == Int64(s.instantSwitchKeyCode),
               !isAssignableBare(keyCode, CGEventFlags(rawValue: s.instantSwitchMods)) {
                // Сохранённая «голая» клавиша больше не перехватывается — иначе она мертва во всей
                // системе. Но молчать об этом нельзя: человек увидит «переключение перестало
                // работать» и не поймёт почему. Пишем один раз на запуск, не на каждое нажатие.
                if !warnedBareInstantSwitch {
                    warnedBareInstantSwitch = true
                    kbLog("мгновенное переключение: сохранена клавиша без модификаторов (keyCode \(keyCode)) — не перехватываю, назначь комбинацию заново")
                }
            } else if s.instantSwitchEnabled, s.instantSwitchMode == "key",
               keyCode == Int64(s.instantSwitchKeyCode),
               relevantMods(event.flags) == relevantMods(CGEventFlags(rawValue: s.instantSwitchMods)) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    onMain { [weak self] in self?.handler?.handleLayoutSwitchOnly() }
                }
                return swallowDown(keyCode)
            }
            // Caps Lock-режим мгновенного переключения: физический Caps РЕМАПНУТ на LANG1
            // (keyCode 104) через hidutil — см. CapsRemap, почему flagsChanged-путь невозможен
            // (капс-замок включается ниже session-тапа). LANG1 глотаем целиком.
            if s.instantSwitchEnabled, s.instantSwitchMode == "modkey", s.instantSwitchKeyCode == 57,
               keyCode == CapsRemap.lang1KeyCode {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    onMain { [weak self] in self?.handler?.handleLayoutSwitchOnly() }
                }
                return swallowDown(keyCode)
            }
            // Диагностика допущения «LANG1 = keyCode 104»: если при активном caps-режиме прилетает
            // сосед по диапазону экзотических кодов — это ремапнутый Caps под другим номером.
            if s.instantSwitchEnabled, s.instantSwitchMode == "modkey", s.instantSwitchKeyCode == 57,
               (100...110).contains(Int(keyCode)) {
                kbLog("caps-режим: keyDown keyCode=\(keyCode), ожидаем LANG1=\(CapsRemap.lang1KeyCode) — если Caps «молчит», настоящий код таков")
            }
            // Voice hold-хоткей (диктовка) — перехватываем и ГЛОТАЕМ (вкл. autorepeat),
            // чтобы клавиша (⌥`) не печаталась во время записи.
            if isVoiceHotkey(keyCode, event.flags) {
                // autorepeat зажатой клавиши НЕ должен дёргать toggle (иначе держишь хоткей чуть
                // дольше → повтор делает СТОП сразу после старта → запись отменяется как короткая,
                // «ничего не произошло» — баг 1-к-8). Реагируем только на ПЕРВОЕ нажатие.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    if s.voiceHoldMode == "toggle" {
                        // Debounce по времени: надёжнее armed-флага (не застрянет, если keyUp потерян).
                        let now = CACurrentMediaTime()
                        if now - lastVoiceToggle > 0.3 { lastVoiceToggle = now; toggleVoice() }
                    } else if !voiceActive {
                        voiceActive = true
                        VoiceGate.set(true)          // синхронно: следующий тап сразу видит активность
                        onMain { [weak self] in self?.handler?.handleVoiceBegin() }
                    }
                }
                return swallowDown(keyCode)   // глотаем ВСЕГДА (вкл. autorepeat) — чтобы клавиша не печаталась
            }
            // Перевод выделенного по хоткею (по умолчанию ⌃⌥T). Глотаем, чтобы 'T' не печаталась.
            if s.translateEnabled, keyMatches(keyCode, s.translateHotkeyKeyCode) {
                let want = relevantMods(CGEventFlags(rawValue: s.translateHotkeyModifiers))
                if !want.isEmpty, relevantMods(event.flags) == want {
                    onMain { [weak self] in self?.handler?.handleTranslateHotkey() }
                    return swallowDown(keyCode)
                }
            }
            // key-режим: обычная клавиша + модификаторы.
            if s.hotkeyMode == "key", s.hotkeyKeyCode >= 0, keyMatches(keyCode, s.hotkeyKeyCode) {
                let target = relevantMods(CGEventFlags(rawValue: s.hotkeyModifiers))
                if !target.isEmpty, relevantMods(event.flags) == target {
                    onMain { [weak self] in self?.handler?.handleSwitchHotkey() }
                    return swallowDown(keyCode)   // глотаем: символ хоткея не должен печататься
                }
            }
            // (Учёт для модификаторных жестов перенесён в НАЧАЛО ветки — см. выше: ранние
            //  return'ы проглоченных клавиш не должны его пропускать.)
            // БЕЗ AppKit (см. KeyboardLayoutCache): NSEvent(cgEvent:).characters стоил ~74 мкс
            // в колбэке и деградировал под давлением на память — ровно там, где нас глушила система.
            // ЕДИНСТВЕННЫЙ ИСТОЧНИК ПЕРЕВОДА — НАШ КЭШ РАСКЛАДКИ (архитектурное решение 24.07,
            // финал дня фантомов). CG-строка события переводится из снапшота WindowServer, который
            // после НАШЕГО TISSelect отстаёт до секунд, а при быстром чередовании слов (тест автора:
            // «привет hello привет» — переключение каждым словом) не догоняет ВООБЩЕ: 50 расхождений
            // за 15с. Приложения при этом строку события ИГНОРИРУЮТ и переводят keyCode сами
            // (документировано в CGEvent.h) — то есть экран живёт переводом, к которому CG-строка
            // отношения не имеет. Поэтому декодируем так же, как приложение: keyCode × данные
            // раскладки, которую МЫ считаем текущей (кэш заряжается из объекта, выбранного нашим же
            // selectLayout, и по TIS-уведомлению о внешней смене — стейл-чтений нет вовсе).
            // CG-строка остаётся фолбэком для источников без layout-блоба (CJK-IM и пр.).
            let chars: String
            let cached = KeyboardLayoutCache.characters(keyCode: keyCode, flags: event.flags, deadState: &deadState)
            if !cached.isEmpty {
                chars = cached
            } else {
                var uniLen = 0
                var u16 = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &uniLen, unicodeString: &u16)
                chars = uniLen > 0 ? String(utf16CodeUnits: u16, count: uniLen) : ""
                cacheFallbackCount += 1
                if cacheFallbackCount == 1 || cacheFallbackCount % 200 == 0 {
                    kbLog("chars: кэш пуст → CG-строка события (всего \(cacheFallbackCount))")
                }
            }
            // sink живёт РОВНО на время колбэка: proxy валиден только здесь (Apple: использовать
            // его после возврата нельзя). Engine принимает его как обычное замыкание и не хранит.
            let post: (CGEvent) -> Void = { $0.tapPostEvent(proxy) }
            if handler?.handleKeyDown(keyCode: keyCode, characters: chars, flags: event.flags, post: post) == true {
                // Здесь НЕ регистрируем парность: за inline-замену учёт ведёт Engine
                // (inlineSwallowedKeyCode → consumeInlineSwallowedKeyUp), и двойной учёт съел бы
                // keyUp дважды. ⚠️ Но handleKeyDown возвращает true из ТРЁХ мест, а метку ставит
                // только путь inline-замены: раскрытие сниппета и проглоченный Enter метки не
                // ставят, и их keyUp уходит в приложение непарным. Это не регрессия (так было и до
                // введения парности), но при следующей правке этой ветки не считай инвариант
                // «true ⇒ Engine пометил» верным — он неверен.
                return nil   // клавиша проглочена: раскрытие сниппета ИЛИ inline-замена уже отправлена
            }
            // Клавиша уходит в приложение как обычно. Снимаем возможную «протухшую» пару: если её
            // keyUp когда-то потерялся (переключение из приложения с зажатой клавишей), запись в
            // наборе съела бы отпускание СЛЕДУЮЩЕГО, честного нажатия. Так набор самоизлечивается.
            swallowedDownKeyCodes.remove(keyCode)
        case .keyUp:
            // F3: keyDown этой клавиши мы проглотили inline-заменой → её keyUp тоже нельзя пускать,
            // иначе Chromium/Qt/игры получают непарное «отпускание» клавиши, которую не нажимали.
            if let h = handler as? Engine,
               h.consumeInlineSwallowedKeyUp(event.getIntegerValueField(.keyboardEventKeycode)) {
                return nil
            }
            // ⚠️ Отдельной ветки «глотаем keyUp у LANG1» здесь больше нет (28.07): она глотала
            // отпускание ПО УСЛОВИЮ НАСТРОЕК, а не по факту того, что мы глотали нажатие. Стоило
            // caps-режиму включиться между нажатием и отпусканием — и приложение получало клавишу,
            // которую нажали и никогда не отпустили. Теперь этот путь идёт через общую парность:
            // проглотили нажатие — проглотим и отпускание, не проглотили — пропустим оба.
            // Voice key-режим: в hold отпускание = стоп; в toggle keyUp лишь снимает armed.
            // ⚠️ Условия выровнены с keyDown-путём (isVoiceHotkey): раньше здесь не было ни
            // voiceEnabled, ни keyMatches — и состояние диктовки дёргалось на чужой клавише.
            // Само ГЛОТАНИЕ отсюда убрано: им теперь ведает парность (ниже). Если keyDown прошёл в
            // приложение (нажали `` ` `` без ⌥), то и keyUp обязан пройти — иначе система считает
            // клавишу зажатой, и у человека умирает пробел (репорты #13/#22/#30).
            let upKey = event.getIntegerValueField(.keyboardEventKeycode)
            if s.voiceEnabled, s.voiceHotkeyMode == "key", keyMatches(upKey, s.voiceHotkeyKeyCode) {
                voiceKeyArmed = false
                if s.voiceHoldMode != "toggle", voiceActive {
                    voiceActive = false
                    VoiceGate.set(false)
                    onMain { [weak self] in self?.handler?.handleVoiceEnd() }
                }
            }
            // ПАРНОСТЬ: глотаем отпускание ровно тех клавиш, чьё нажатие проглотили мы сами.
            if swallowedDownKeyCodes.remove(upKey) != nil { return nil }
        case .flagsChanged:
            if handleFlags(event.flags, keyCode: event.getIntegerValueField(.keyboardEventKeycode)) {
                return nil   // событие 🌐 проглочено — системному обработчику его не видать
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func handleFlags(_ flags: CGEventFlags, keyCode: Int64) -> Bool {
        if HotkeyRecording.active { return false }   // идёт запись комбинации — не перехватываем (см. keyDown)
        let s = AppSettings.shared
        // ⚠️ SECURE INPUT ПРЯЧЕТ keyDown, НО НЕ ПРЯЧЕТ flagsChanged (разбор 29.07, репорт #46).
        // Все четыре жеста «чистый тап» доказывают свою чистоту ОТСУТСТВИЕМ обычной клавиши между
        // нажатием и отпусканием — а именно эти события macOS от нас и скрывает, пока держится
        // Secure Input. Замерено по 46 отчётам: внутри таких окон сработало 77 действий по
        // модификаторам и НОЛЬ строк, приходящих от нажатий клавиш.
        // Для человека это выглядело так: мгновенное переключение висело на левом ⇧, он жал ⇧,
        // печатал заглавную (мы её не видим), отпускал ⇧ — и мы считали это чистым тапом и меняли
        // язык. Ровно его слова «переключает после первой буквы». Выключение автопереключения не
        // помогало: этот путь его не проверяет вовсе.
        // Решение честное: раз доказать чистоту нельзя, считаем, что клавиша БЫЛА. Взвод снимаем,
        // «между тапами что-то было» ставим — и все четыре машины отказываются стрелять сами,
        // без правок на местах срабатывания.
        // Значение берём из кэша (опрос раз в 2.5с в Engine): холодный IsSecureEventInputEnabled()
        // стоит до ~44 мс, а мы внутри колбэка тапа — там этого нельзя.
        // Удержание диктовки НЕ трогаем: оно срабатывает по точному совпадению маски, а не по
        // отсутствию посторонней клавиши, и этой дырой не задето. Гасить его здесь означало бы
        // оставить запись включённой навсегда, потому что отпускание мы бы уже не обработали.
        if AppHealth.secureInputOn {
            // Пишем в лог ТОЛЬКО когда взвод действительно был: otherKey*-флаги в спокойном
            // состоянии и так false, и проверка по ним дала бы строку почти на каждое событие.
            if fnArmed || modkeyArmed {
                kbLog("жест по модификатору снят со взвода: держится Secure Input, обычные клавиши от нас скрыты")
            }
            fnArmed = false
            modkeyArmed = false
            otherKeyBetweenTaps = true    // «между тапами что-то было» — доказать обратное нечем
            otherKeyDuringCombo = true    // то же для комбинации
        }
        // ⚠️ Гасим взвод одиночного модификатора ПЕРВЫМ ДЕЛОМ (ревью 28.07 — репорт #17 был закрыт
        // лишь наполовину). Если вторая клавиша комбинации это клавиша мгновенного переключения,
        // её flagsChanged уходит в `return true` ниже и до ветки «другой модификатор вмешался» не
        // доходит — взвод оставался, и отпускание первого модификатора всё равно конвертировало
        // слово. У репортёра было ровно так: конверсия на левом ⌥, мгновенное на левом ⇧.
        if keyCode != Int64(s.hotkeyKeyCode) {
            modkeyArmed = false
        }
        // 🌐 может быть занята НАМИ двумя способами: мгновенная смена языка (ниже) ИЛИ ручной
        // хоткей конверсии (обрабатывается в switch hotkeyMode). В обоих случаях событие надо
        // ПРОГЛОТИТЬ, иначе системное действие клавиши сработает параллельно с нашим.
        let globeIsOurHotkey = (keyCode == 63 && s.hotkeyMode == "modkey" && s.hotkeyKeyCode == 63)

        // МГНОВЕННОЕ ПЕРЕКЛЮЧЕНИЕ ЯЗЫКА — модификаторные режимы: 🌐/Fn и одиночный модификатор
        // (правый ⌥ и т.п.). Событие глотаем, чтобы приложения не видели «голый» модификатор.
        // Срабатываем по ЧИСТОМУ тапу: нажал-отпустил, ничего между.
        // Caps Lock (57) обрабатывается НЕ здесь: его flagsChanged бесполезно глотать (замок
        // включается в HID-драйвере ниже тапа — 24.07 у пользователя капс загорался, язык молчал);
        // caps-режим живёт через hidutil-ремап на LANG1 в keyDown-ветке (см. CapsRemap).
        // Прим.: «9 переключений „→EN" подряд» 23-24.07 оказались НЕ живучестью системного
        // обработчика, а багом стейл-чтения TIS (см. LayoutManager.opinionCyr).
        if s.instantSwitchEnabled,
           s.instantSwitchMode == "globe" || (s.instantSwitchMode == "modkey" && s.instantSwitchKeyCode != 57),
           keyCode == Int64(s.instantSwitchKeyCode) {
            let mask: CGEventFlags = s.instantSwitchMode == "globe"
                ? .maskSecondaryFn : CGEventFlags(rawValue: s.instantSwitchMods)
            let down = !flags.intersection(mask).isEmpty
            if down {
                // Та же защита, что у хоткея конверсии (репорт #17): наш модификатор в составе
                // чужой комбинации — не наш тап. Для 🌐 проверка не нужна (Fn отдельный флаг,
                // его снимает строка ниже), но для одиночного модификатора обязательна.
                fnArmed = s.instantSwitchMode == "globe"
                    || relevantMods(flags).subtracting(relevantMods(mask)).isEmpty
            } else if fnArmed {
                fnArmed = false
                onMain { [weak self] in self?.handler?.handleLayoutSwitchOnly() }
            }
            return true   // не отдаём системе — гасим её собственное действие этой клавиши
        }
        // Fn отпущен в составе комбинации — взвод снимаем.
        if !flags.contains(.maskSecondaryFn) { fnArmed = false }
        // ⚠️ …либо к зажатому Fn ДОБАВИЛИ модификатор (28.07). Взвод 🌐 ставился безусловно, а
        // снимался только другой КЛАВИШЕЙ (keyDown) — модификатор клавишей не считается. Значит
        // Fn+⌃/⌥/⇧/⌘ отпускались как «чистый тап по 🌐» и меняли язык посреди чужого сочетания.
        // Это тот же класс, что репорт #17 для одиночного модификатора, только в ветке 🌐, где мы
        // сочли проверку ненужной: у Fn отдельный флаг, но соседей по нему это не отменяет.
        else if !relevantMods(flags).isEmpty { fnArmed = false }
        // Voice modkey-hold (напр. удержание правого ⌥ = keyCode 61): зажал → запись, отпустил → стоп.
        if s.voiceEnabled, s.voiceHotkeyMode == "modkey", keyCode == Int64(s.voiceHotkeyKeyCode) {
            let mask = CGEventFlags(rawValue: s.voiceHotkeyModifiers)
            let down = !flags.intersection(mask).isEmpty
            if s.voiceHoldMode == "toggle" {
                if down { toggleVoice() }   // нажал → старт/стоп; отпускание игнорируем
            } else {
                if down && !voiceActive {
                    voiceActive = true; VoiceGate.set(true)
                    onMain { [weak self] in self?.handler?.handleVoiceBegin() }
                } else if !down && voiceActive {
                    voiceActive = false; VoiceGate.set(false)
                    onMain { [weak self] in self?.handler?.handleVoiceEnd() }
                }
            }
            return false
        }
        // Voice combo (напр. ⌥⌘) — режима не существовало до 29.07, поэтому записать сочетание из
        // двух модификаторов было нельзя в принципе: рекордер предлагал одиночную клавишу, а движок
        // и такую комбинацию не понял бы. Репорт #21 (0.2.69) и повтор #44/#45 на 0.3.0.
        // Семантика ровно как у modkey, только вместо одной клавиши — точное совпадение маски:
        // «удерживать» = зажал комбинацию целиком → запись, разжал любой из них → стоп;
        // «переключать» = тап по набору комбинации.
        // ⚠️ НЕ ВЫХОДИТЬ ИЗ ФУНКЦИИ ПОСЛЕ ЭТОГО БЛОКА (фикс 30.07, репорт #55 на 0.3.3).
        // Здесь стоял `return false`, и он делал недостижимым ВЕСЬ разбор хоткея конверсии ниже:
        // достаточно было назначить диктовке комбинацию, и ручное переключение слова умирало молча.
        // В репорте это выглядело как конфликт ⌥ с ⌥⌘, но дело не в пересечении — сломался бы любой
        // modkey-хоткей конверсии, хоть правый ⌘. Баг живёт с 29.07, когда появился режим combo.
        //
        // Пересечение при этом разруливается само и правильно: на нажатии одиночного ⌥ взводится
        // modkeyArmed, а пришедший следом ⌘ имеет другой keyCode и гасит взвод в ветке else ниже.
        // То есть ⌥⌘ не порождает ложной конверсии, а одиночный ⌥ работает как задумано.
        if s.voiceEnabled, s.voiceHotkeyMode == "combo",
           case let target = relevantMods(CGEventFlags(rawValue: s.voiceHotkeyModifiers)), !target.isEmpty {
            if relevantMods(flags) == target {
                // Взводим один раз на набор: flagsChanged приходит на каждую клавишу комбинации,
                // а совпадение с маской наступает только на последней.
                if !voiceComboArmed {
                    voiceComboArmed = true
                    if s.voiceHoldMode == "toggle" { toggleVoice() }
                    else if !voiceActive {
                        voiceActive = true; VoiceGate.set(true)
                        onMain { [weak self] in self?.handler?.handleVoiceBegin() }
                    }
                }
            } else if voiceComboArmed {
                voiceComboArmed = false
                if s.voiceHoldMode != "toggle", voiceActive {
                    voiceActive = false; VoiceGate.set(false)
                    onMain { [weak self] in self?.handler?.handleVoiceEnd() }
                }
            }
            // Провал ВНИЗ, к хоткею конверсии. См. предупреждение над блоком.
        }
        switch s.hotkeyMode {
        case "modkey":
            // Конкретная клавиша-модификатор (правый ⌥ = keyCode 61 и т.п.) — tap по отпусканию.
            let mask = CGEventFlags(rawValue: s.hotkeyModifiers)
            guard !mask.isEmpty else { return false }
            if keyCode == Int64(s.hotkeyKeyCode) {
                let down = !flags.intersection(mask).isEmpty
                if down {
                    // ⚠️ Взводим ТОЛЬКО если наш модификатор нажат в ОДИНОЧКУ (репорт #17, 27.07:
                    // «в удалённом сеансе жму левый Alt+Shift, срабатывает и переключение раскладки»).
                    // Ветка ниже гасит взвод, если другой модификатор пришёл ПОСЛЕ нашего, но
                    // обратный порядок она не ловила: зажал ⇧, потом ⌥ — и мы считали это тапом.
                    // Alt+Shift и Ctrl+Shift это системные переключатели раскладки, их жмут все, кто
                    // работает с Windows-машиной по RDP.
                    modkeyArmed = relevantMods(flags).subtracting(relevantMods(mask)).isEmpty
                } else if modkeyArmed {
                    onMain { [weak self] in self?.handler?.handleSwitchHotkey() }
                    modkeyArmed = false
                }
            } else {
                modkeyArmed = false // другой модификатор вмешался
            }
        case "doubletap":
            // Двойное нажатие модификатора (напр. 2× Shift) в окне ~300 мс без других клавиш.
            let mask = CGEventFlags(rawValue: s.hotkeyModifiers)
            guard !mask.isEmpty else { return false }
            let pressed = !flags.intersection(mask).isEmpty
            if keyCodeMatchesMask(keyCode, mask) && pressed {
                let now = CACurrentMediaTime()
                if now - lastModTap < 0.30 && !otherKeyBetweenTaps {
                    onMain { [weak self] in self?.handler?.handleSwitchHotkey() }
                    lastModTap = 0
                } else {
                    lastModTap = now
                }
                otherKeyBetweenTaps = false
            }
        case "combo":
            let target = relevantMods(CGEventFlags(rawValue: s.hotkeyModifiers))
            guard !target.isEmpty else { return false }
            let now = relevantMods(flags)
            if now == target {
                comboArmed = true
                otherKeyDuringCombo = false
            } else if comboArmed {
                if !otherKeyDuringCombo { onMain { [weak self] in self?.handler?.handleSwitchHotkey() } }
                comboArmed = false
            }
        default:
            break
        }
        // 🌐 как наш хоткей конверсии — обработали выше в switch, теперь глотаем.
        return globeIsOurHotkey
    }

    /// toggle-режим: нажал → старт, нажал ещё раз → стоп.
    /// ИСТОЧНИК ИСТИНЫ — реальное состояние записи (VoiceController.isRecording), НЕ локальный
    /// флаг voiceActive: он рассинхронивался, если begin() молча не стартовал (busy / микрофон
    /// занят / нет модели) — тогда «нажал, ничего, нажал ещё — пошло» (баг 1-к-8, 2026-06-09).
    private func toggleVoice() {
        // Решение start/stop — СИНХРОННОЕ и атомарное (VoiceGate.flip), иначе быстрый второй тап
        // видел устаревшее состояние: «нажал — ничего, нажал ещё — пошло» (баг 1-к-8, 09.06).
        // А сами begin/end тянут аудио-teardown, NSSound и RMS-свёртку — их на main (см. VoiceGate).
        let wasActive = VoiceGate.flip()
        if wasActive { onMain { [weak self] in self?.handler?.handleVoiceEnd() } }
        else         { onMain { [weak self] in self?.handler?.handleVoiceBegin() } }
        voiceActive = !wasActive
    }

    /// Совпадает ли событие с voice-хоткеем диктовки (клавиша + модификаторы).
    private func isVoiceHotkey(_ keyCode: Int64, _ flags: CGEventFlags) -> Bool {
        let s = AppSettings.shared
        // keyDown-путь — только для режима "key" (клавиша+модификаторы, напр. ⌥`).
        guard s.voiceEnabled, s.voiceHotkeyMode == "key", keyMatches(keyCode, s.voiceHotkeyKeyCode) else { return false }
        let want = relevantMods(CGEventFlags(rawValue: s.voiceHotkeyModifiers))
        guard !want.isEmpty else { return false }
        return relevantMods(flags) == want
    }

    /// Совпадение keyCode хоткея с учётом РАЗНЫХ клавиатур. Грейв-клавиша (`` ` ``/`~`) имеет разный keyCode
    /// на ANSI и ISO: ANSI grave=50; ISO — под Esc § (keyCode 10), а грейв уезжает к левому Shift (тоже 50).
    /// Пользователь жмёт «где ожидает тильду» (под Esc) → на ISO это 10. Считаем 10 и 50 взаимозаменяемыми,
    /// чтобы хоткей на `` ` `` срабатывал на ЛЮБОЙ клавиатуре (research 01.07). Прочие клавиши — строго ==.
    private func keyMatches(_ pressed: Int64, _ stored: Int) -> Bool {
        if pressed == Int64(stored) { return true }
        let grave: Set<Int> = [10, 50]
        return grave.contains(Int(pressed)) && grave.contains(stored)
    }

    /// Можно ли реагировать на эту клавишу с ТАКИМ набором модификаторов.
    /// Голая клавиша без модификаторов перехватывалась бы у всей системы — в пределе человек
    /// остаётся без пробела во всех программах, пока не выйдет из Keyboop (репорты #13/#22/#30).
    /// Исключений нет: белый список F13…F20 был реализован наполовину и убран (см. HotkeyKeys).
    private func isAssignableBare(_ keyCode: Int64, _ mods: CGEventFlags) -> Bool {
        !relevantMods(mods).isEmpty
    }

    /// keyCode принадлежит модификатору из mask (левый ИЛИ правый).
    private func keyCodeMatchesMask(_ kc: Int64, _ mask: CGEventFlags) -> Bool {
        if mask.contains(.maskShift) && (kc == 56 || kc == 60) { return true }
        if mask.contains(.maskAlternate) && (kc == 58 || kc == 61) { return true }
        if mask.contains(.maskCommand) && (kc == 55 || kc == 54) { return true }
        if mask.contains(.maskControl) && (kc == 59 || kc == 62) { return true }
        return false
    }

    private func relevantMods(_ flags: CGEventFlags) -> CGEventFlags {
        var m: CGEventFlags = []
        for f: CGEventFlags in [.maskAlternate, .maskShift, .maskCommand, .maskControl] {
            if flags.contains(f) { m.insert(f) }
        }
        return m
    }
    private func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event, proxy: proxy)
}
