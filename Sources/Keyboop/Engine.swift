import Foundation
import AppKit
import CoreGraphics
import Carbon

/// Центральный движок: связывает event tap, буфер, раскладку и замену текста.
final class Engine: EventTapHandler {
    let layout = LayoutManager()
    private let buffer = KeystrokeBuffer()
    private let eventTap = EventTap()
    private let settings = AppSettings.shared

    /// Пока true — игнорируем входящие события (это наша же синтетика).
    private var muted = false

    /// «Дренаж» после постинга синтетики, перед снятием muted. Синтетика отыгрывает на serial-очереди
    /// и проходит через session-tap за единицы мс; этого хватает, чтобы хвостовые синтетические события
    /// успели пройти. Раньше было 0.18–0.25с — это мёртвое окно, где РЕАЛЬНЫЕ нажатия пользователя
    /// (быстрый набор следующего слова) тоже глотались (handleKeyDown под muted → return) → буфер
    /// рассинхронивался с экраном → следующее слово «иногда не переключалось» (баг 15.06, Иван).
    private let muteDrain: TimeInterval = 0.08

    /// Валидатор «целевое слово есть в RU-словаре» — для smartConvert (концевые б/ю/ж: «yj;»→«нож»
    /// конвертим целиком, а не срезаем как пунктуацию). Передаём в Keymap, чтобы он не тянул LayoutData.
    private static let ruWordValidator: (String) -> Bool = { LayoutData.shared.wordsRu.contains($0) }

    /// Колбэк для UI — обновить индикатор после переключения.
    var onLayoutMaybeChanged: (() -> Void)?

    private var didSetup = false

    func start() -> Bool {
        if !didSetup {
            eventTap.handler = self
            // Смена активного приложения → контекст слова больше не достоверен.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.buffer.clear()
            }
            // Точная таблица символов из реальной раскладки (кавычки, Shift-ряд и т.д.).
            DynamicKeymap.rebuild()
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                object: nil, queue: .main
            ) { _ in DynamicKeymap.rebuild() }
            // Голосовая вставка завершилась → чистим буфер, чтобы надиктованное не попало в группу (G3).
            NotificationCenter.default.addObserver(
                forName: .keyboopVoiceInserted, object: nil, queue: .main
            ) { [weak self] _ in self?.buffer.clear() }
            // Прогреть языковые данные в фоне, чтобы первый авто-свап не лагал.
            DispatchQueue.global(qos: .utility).async { _ = LayoutData.shared.isLoaded }
            didSetup = true
        }
        return eventTap.start()
    }

    // MARK: - EventTapHandler

    func handleContextReset() {
        // Клик/навигация двигает курсор — групповая история недействительна даже под muted (G10):
        // нашу синтетику мы шлём только с клавиатуры, mouse-down — всегда намерение пользователя.
        buffer.invalidateGroupHistory()
        if muted { return }
        buffer.clear()
        UndoLearner.shared.resetContext()   // клик/навигация → кандидат на откат и session-защита неактуальны
    }

    // Голосовой ввод (hold-to-talk) — делегируем оркестратору.
    func handleVoiceBegin() { VoiceController.shared.begin() }
    func handleVoiceEnd() { VoiceController.shared.end() }

    func handleKeyDown(keyCode: Int64, characters: String, flags: CGEventFlags) {
        // ВАЖНО: больше НЕ гейтим реальный ввод по muted — наша синтетика отсеивается тегом в EventTap
        // (kbSyntheticMarker), а реальные нажатия должны копиться в буфер ВСЕГДА, даже пока летит наша
        // конверсия (иначе буфер рассинхронивался с экраном при быстром наборе — корень №2 аудита).
        // muted сохранён только как guard от пере-входа в конверсию (maybeLiveFix/convertFromBuffer).
        // Поле пароля (Secure Input) — НЕ копим ввод (приватность; см. docs/SECURITY.md).
        if IsSecureEventInputEnabled() { buffer.clear(); return }

        let optOrCmd = flags.contains(.maskAlternate) || flags.contains(.maskCommand)
        let cmdOrCtrl = flags.contains(.maskCommand) || flags.contains(.maskControl)

        switch keyCode {
        case 51: // Backspace
            // ⌥⌫ / ⌘⌫ стирают слово или строку целиком — мы не знаем сколько, сбрасываем контекст.
            if optOrCmd {
                buffer.clear()
                UndoLearner.shared.resetContext()    // ⌥⌫/⌘⌫ стёрли слово/строку — контекст потерян
            } else {
                buffer.backspace()
                UndoLearner.shared.observe(current: buffer.currentWord)   // U2: следим за стиранием нашего вывода
            }
        case 49, 48, 36: // Space, Tab, Return
            let ws = keyCode == 48 ? "\t" : (keyCode == 36 ? "\n" : " ")
            buffer.boundary(ws)
            // Авто-раскладка срабатывает только по разрешённым клавишам-триггерам.
            var autoTrigger = (keyCode == 49 && settings.triggerSpace)
                           || (keyCode == 36 && settings.triggerEnter)
                           || (keyCode == 48 && settings.triggerTab)
            // Режим разработчика: в IDE/терминалах авто не трогаем (но ⌥⇧ вручную — работает).
            if settings.developerMode && Engine.frontmostIsDevApp() { autoTrigger = false }
            // Программа-исключение: "off" — совсем не трогаем; "soft" — мягко (см. convertFromBuffer).
            let appMode = Engine.frontmostAppMode()
            if appMode == "off" { autoTrigger = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self = self else { return }
                if self.expandSnippetIfMatch() { return }            // сниппеты — на любой границе
                if autoTrigger && self.settings.autoEnabled { self.convertFromBuffer(manual: false, soft: appMode == "soft") }
            }
        case 123, 124, 125, 126: // стрелки
            buffer.invalidateGroupHistory()   // стрелка двигает курсор → группа печатала бы вслепую (G2)
            // Опция: стрелка отменяет авто-переключение текущего слова.
            if settings.arrowsCancel { buffer.clear(); UndoLearner.shared.resetContext() }
        case 53, 117, 115, 116, 119, 121:
            // Esc, Fwd-Delete, Home/End/PageUp/PageDown → навигация, всегда сбрасываем контекст
            buffer.clear()
            UndoLearner.shared.resetContext()
        default:
            if cmdOrCtrl { buffer.clear(); return } // это шорткат, не текст
            if let scalar = characters.unicodeScalars.first, isPrintable(scalar) {
                buffer.append(characters)
                UndoLearner.shared.observe(current: buffer.currentWord)   // U2: перенабор оригинала = откат
                // «На лету»: как только сочетание стало невозможным в текущем языке — чиним сразу.
                if settings.liveFixEnabled && settings.autoEnabled {
                    DispatchQueue.main.async { [weak self] in self?.maybeLiveFix() }
                }
            }
        }
    }

    private var liveFixLast = ""
    /// Мид-слово конверсия: переключаем раскладку ДО ретайпа (анти-гонка), печатаем Unicode-ом.
    private func maybeLiveFix() {
        guard !muted else { return }
        let word = buffer.currentWord
        guard word.count >= 4, word != liveFixLast else { return }
        if settings.developerMode && Engine.frontmostIsDevApp() { return }
        // Обучение на отмене: не трогаем слово, которое юзер прямо сейчас восстанавливает, и то,
        // что он уже восстановил в этом контексте (анти-«драка»).
        if UndoLearner.shared.shouldSuppress(current: word) || UndoLearner.shared.isSessionProtected(word) { return }
        guard case .convert(let toCyr) = LayoutDetector.liveDecide(word: word) else { return }
        let converted = Keymap.smartConvert(word, toCyrillic: toCyr, isValidTarget: Self.ruWordValidator)
        guard converted != word else { return }
        muted = true
        layout.selectLayout(cyrillic: toCyr)            // раскладка — раньше ретайпа
        // Снятие muted — в completion (после async-постинга синтетики на serial-очереди), а не по
        // фикс-таймеру: иначе размьютит до того, как backspace+ретайп отыграют → re-entrancy.
        TextReplacer.replace(deleteCount: word.count, with: converted) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.muted = false }
        }
        buffer.applyConversion(converted: converted)
        UndoLearner.shared.noteConversion(original: word, converted: converted)   // кандидат на откат
        settings.rescuedCount += 1                       // мид-слово тоже считаем
        onLayoutMaybeChanged?()
        playSound()                                     // звук конвертации (как в обычном переключении)
        liveFixLast = converted
        kbLog("live-fix: \(word.count)→\(converted.count) симв.")   // контент в лог не пишем (приватность)
    }

    func handleSwitchHotkey() {
        DispatchQueue.main.async { [weak self] in
            self?.convertFromBuffer(manual: true)
        }
    }

    func handleTranslateHotkey() {
        kbLog("translate: хоткей нажат")
        DispatchQueue.main.async { [weak self] in self?.translateSelection() }
    }

    /// Перевод выделенного текста (Apple Translation, macOS 15+). Буфер НЕ трогаем (принцип №1):
    /// читаем выделение через AX, пишем обратно через AX/печать. Направление — по содержимому.
    private func translateSelection() {
        guard !muted else { return }
        guard #available(macOS 15.0, *) else { kbLog("translate: нужна macOS 15"); NSSound.beep(); return }
        #if canImport(Translation)
        muted = true                                  // глушим синтетический Cmd+C от readViaClipboard
        let sel = SelectionText.read()
        muted = false
        guard let (text, writeBack) = sel else { kbLog("translate: выделение не прочитано"); NSSound.beep(); return }
        playTranslateSound()                          // отдельный звук перевода — подтверждение, что действие пошло
        let dir = TranslateDirection.of(text)
        kbLog("translate: \(text.count) симв. \(dir.from)→\(dir.to)…")
        Task { @MainActor in
            guard let t = await TranslationEngine.shared.translate(text, from: dir.from, to: dir.to),
                  t != text else { kbLog("translate: пусто/без изменений"); return }
            self.muted = true
            if !(writeBack?(t) ?? false) {
                TextReplacer.insert(t) { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.muted = false }
                }
            } else {   // запись через AX (синтетику не постим) — снимаем muted по таймеру как раньше
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.muted = false }
            }
            self.buffer.clear()
        }
        #endif
    }

    // MARK: - Конвертация

    /// Конвертация ВЫДЕЛЕННОГО текста (нативные приложения, через AX). true — если выделение
    /// было и сконвертировано. Направление — по содержимому. Буфер обмена НЕ трогаем (принцип №1).
    private func convertSelection() -> Bool {
        muted = true                                  // глушим синтетический Cmd+C от readViaClipboard
        let sel = SelectionText.read()
        guard let (text, writeBack) = sel else {
            muted = false
            kbLog("convert-selection: выделение не прочитано — падаю на последнее слово")
            return false
        }
        // Защита от «Cmd+C при пустом выделении копирует целую строку/абзац» (редакторы, терминалы,
        // VS Code): многострочный текст — почти наверняка авто-копия, а не намеренное выделение для
        // смены раскладки. И для clipboard-fallback (writeBack==nil, не можем проверить) — кап по длине.
        let isClipboard = (writeBack == nil)
        if text.contains("\n") || text.contains("\r") || (isClipboard && text.count > 80) {
            muted = false
            kbLog("convert-selection: отклонено (\(text.count) симв., многострочн=\(text.contains("\n")), clipboard=\(isClipboard)) — вероятно авто-копия строки, падаю на слово")
            return false
        }
        let toCyrillic: Bool
        if text.hasCyrillic { toCyrillic = false }
        else if text.hasLatinLetter { toCyrillic = true }
        else { muted = false; return false }          // нет букв — нечего переключать
        let converted = Keymap.convert(text, toCyrillic: toCyrillic)
        guard converted != text else { muted = false; return false }
        let usedSynth = !(writeBack?(converted) ?? false)
        if usedSynth {
            TextReplacer.insert(converted) { [weak self] in   // печатаем поверх выделения (Unicode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.muted = false }
            }
        }
        // выделение могло быть из нескольких слов — считаем по словам
        settings.rescuedCount += max(1, text.split(separator: " ").count)
        layout.selectLayout(cyrillic: toCyrillic)
        onLayoutMaybeChanged?()
        buffer.clear()
        playSound()                                   // звук конвертации — подтверждение действия
        kbLog("convert-selection: \(text.count) симв. → \(toCyrillic ? "RU" : "EN")")
        if !usedSynth {   // запись через AX — снимаем muted по таймеру
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.muted = false }
        }
        return true
    }

    /// Групповая конвертация нескольких слов сессии набора одним хоткеем (эксперимент, groupConvert).
    /// КЛЮЧЕВОЕ (по docs/IDEAS.md → H): конвертируем ПОСЛОВНО только те слова, что LayoutDetector
    /// помечает как .convert — валидные слова в группе НЕ трогаем («hello ghbdtn» → «hello привет»).
    /// Печатаем Unicode напрямую (Backspace + set), буфер обмена НЕ трогаем (принцип №1).
    private func convertGroup() -> Bool {
        guard let g = buffer.groupForConversion() else { return false }
        var out = ""
        var anyConverted = false
        var convertedN = 0            // сколько слов реально починили (для счётчика спасённых)
        var lastToCyrillic = false
        var prevWord: String? = nil   // бежит по группе: предыдущее слово-РЕЗУЛЬТАТ (для контекста)
        for (word, tail) in g.words {
            switch LayoutDetector.decide(word: word, exceptions: ExceptionStore.shared, prev: prevWord) {
            case .convert(let toCyr):
                // smartConvert бережёт концевую пунктуацию, длина символов сохраняется (1:1) →
                // out.count == deleteCount, удаление Backspace'ами совпадает с напечатанным.
                let conv = Keymap.smartConvert(word, toCyrillic: toCyr, isValidTarget: Self.ruWordValidator)
                out += conv + tail
                anyConverted = true
                convertedN += 1
                lastToCyrillic = toCyr
                prevWord = conv
            case .keep:
                out += word + tail                     // валидное слово — оставляем как набрано
                prevWord = word
            }
        }
        // Все слова валидны (нечего конвертировать): группа «съедает» хоткей как no-op и возвращает
        // true — НЕ падаем на single-word логику, иначе она force-конвертнула бы валидное последнее
        // слово в кашу (G5: «hello world» → beep + «world»→«цщкдв»). Без beep — текст корректен.
        guard anyConverted else { return true }
        // Инвариант длины: smartConvert/keep строго 1:1 по символам → out.count == deleteCount.
        // Если вдруг разошлось (будущие не-1:1 преобразования) — НЕ печатаем вслепую (защита от порчи).
        guard out.count == g.deleteCount else {
            kbLog("convert-group: длина out(\(out.count)) ≠ deleteCount(\(g.deleteCount)) — отказ")
            return true
        }

        muted = true
        kbLog("convert-group(хоткей): \(g.words.count) слов, \(g.deleteCount) симв.")   // без контента
        // Синтетика — async на serial-очереди (не морозим main с активным tap'ом). Снятие muted — в
        // completion: оно сработает РОВНО после постинга, поэтому length-scaling задержки больше не нужен
        // (раньше масштабировали под время синхронного постинга на main, G4) — хватает дренаж-константы.
        TextReplacer.replace(deleteCount: g.deleteCount, with: out) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.muted = false }
        }
        settings.rescuedCount += convertedN            // вся группа разом — по числу починенных слов
        buffer.clear()                                 // состояние слов изменилось — начинаем сессию заново
        layout.selectLayout(cyrillic: lastToCyrillic)  // раскладку — по последнему сконвертированному
        onLayoutMaybeChanged?()
        playSound()
        return true
    }

    private func convertFromBuffer(manual: Bool, soft: Bool = false) {
        guard !muted else { return }
        // ПОРЯДОК ВАЖЕН (фикс бага #39): если буфер НЕ пуст (только что печатали) — чиним именно
        // набранное слово, выделение НЕ трогаем. Иначе Cmd+C в редакторах/терминалах при ПУСТОМ
        // выделении копирует ЦЕЛУЮ СТРОКУ → раньше конвертило 150 символов вместо последнего слова.
        // Выделение пробуем только когда буфер пуст (клик/мышь чистят буфер = намеренное выделение).
        if manual, buffer.wordForConversion() == nil, convertSelection() { return }
        // Экспериментально: групповая конвертация нескольких слов сессии (если включено и слов ≥2).
        // ТОЛЬКО при ВЫКЛЮЧЕННОМ авто-переключении: при авто sessionWords рассинхронятся с экраном
        // (авто чинит каждое слово на лету, не обновляя sessionWords) → группа испортила бы текст.
        // При авто группа к тому же бессмысленна. UI делает тумблер серым при авто — это страхует логику.
        // Падает на одно-словную логику ниже, если группы нет (groupForConversion вернул nil).
        if manual, settings.groupConvert, !settings.autoEnabled, convertGroup() { return }
        guard let item = buffer.wordForConversion() else {
            // Нечего конвертировать (буфер пуст), но нажат хоткей — просто переключаем язык RU↔EN.
            if manual {
                let toCyr = !layout.currentIsCyrillic()
                layout.selectLayout(cyrillic: toCyr)
                onLayoutMaybeChanged?()
                playSound()
            }
            return
        }
        let word = item.word

        let toCyrillic: Bool
        if manual {
            // Явный хоткей — направление по содержимому; если в слове только символы/
            // цифры/кавычки (букв нет) — по текущей системной раскладке.
            if word.hasCyrillic {
                toCyrillic = false
            } else if word.hasLatinLetter {
                toCyrillic = true
            } else {
                toCyrillic = !layout.currentIsCyrillic()
            }
        } else {
            // Обучение на отмене: слово, которое юзер только что восстановил в этом контексте, —
            // не конвертируем повторно (анти-«драка»), даже если порог обучения ещё не достигнут.
            if UndoLearner.shared.isSessionProtected(word) { return }
            // Авто — двусторонний детектор (словарь + триграммы + force-swap + исключения)
            // + контекст фразы: предыдущее слово разрешает короткие коллизии (yt↔не) и
            // классификаторы (vitamin d). Стоимость — чтение последнего элемента массива, O(1).
            let prevW = buffer.contextWord(forCurrent: !buffer.currentWord.isEmpty)
            switch LayoutDetector.decide(word: word, exceptions: ExceptionStore.shared, prev: prevW) {
            case .keep:
                return
            case .convert(let c):
                // Мягкий фильтр: не трогаем одиночные/короткие/повторяющиеся буквы — только
                // очевидные слова (анти-Punto: C/V/B + пробел не должны конвертиться).
                // Включается (а) для программ-исключений в режиме «Мягкий», (б) ГЛОБАЛЬНО при
                // режиме разработчика: переменные c/d/i и команды живут не только в IDE —
                // в Slack, заметках, доках (просьба Ивана 2026-06-09). Обычным людям без
                // dev-режима одиночные предлоги (d→в, c→с) чинятся как прежде.
                if soft || settings.developerMode {
                    let core = Keymap.core(of: word).lowercased()
                    if core.count <= 2 || Set(core).count == 1 { return }
                }
                toCyrillic = c
            }
        }

        // Ручной хоткей переключает ВСЁ (буквы + знаки + кавычки); авто бережёт
        // концевую пунктуацию ("ghbdtn." → "привет.", а не "приветю").
        let converted = manual
            ? Keymap.convert(word, toCyrillic: toCyrillic)
            : Keymap.smartConvert(word, toCyrillic: toCyrillic, isValidTarget: Self.ruWordValidator)
        guard converted != word else {
            if manual { NSSound.beep() }
            return
        }

        muted = true
        kbLog("convert-word\(manual ? "(хоткей)" : "(авто)"): \(item.deleteCount) симв. → \(toCyrillic ? "RU" : "EN")")   // без контента
        // Снятие muted — в completion (после async-постинга), а не фикс-таймером (см. live-fix выше).
        TextReplacer.replace(deleteCount: item.deleteCount, with: converted + item.tail) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.muted = false }
        }
        buffer.applyConversion(converted: converted)
        // Обучение на отмене: авто-конверсия → кандидат на откат; ручной ре-флип, отменяющий нашу
        // недавнюю авто-конверсию (U1), — засчитываем как откат.
        if manual { UndoLearner.shared.noteManualConvert(from: word, to: converted) }
        else      { UndoLearner.shared.noteConversion(original: word, converted: converted) }
        settings.rescuedCount += 1                      // зверёк расколдовал ещё одно слово
        layout.selectLayout(cyrillic: toCyrillic)
        onLayoutMaybeChanged?()
        playSound()
        // muted снимается в completion TextReplacer выше (после постинга синтетики).
    }

    /// Режем управляющие символы из раскрытия сниппета (кроме \n и \t) — см. docs/SECURITY.md.
    private static func sanitizeSnippet(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }))
    }

    private func playSound() {
        guard settings.soundEnabled, !settings.soundName.isEmpty else { return }
        let s = NSSound(named: settings.soundName)
        s?.volume = Float(max(0, min(1, settings.soundVolume)))   // регулируемая громкость
        s?.play()
    }

    private var translateCue: NSSound?   // удерживаем синтез-звук, иначе оборвётся
    /// Звук перевода: "keyboop" = наш синтез-трезвучие, "" = тишина, иначе системный звук по имени.
    private func playTranslateSound() {
        guard settings.translateSoundEnabled else { return }
        let name = settings.translateSoundName
        guard !name.isEmpty else { return }
        let vol = Float(max(0, min(1, settings.translateSoundVolume)))
        if name == "keyboop" {
            translateCue?.stop()
            translateCue = NSSound(data: CueSynth.translateData)
            translateCue?.volume = vol
            translateCue?.play()
        } else {
            let s = NSSound(named: name); s?.volume = vol; s?.play()
        }
    }

    /// Приложения-разработчика: IDE и терминалы, где авто-переключение лишнее при кодинге.
    static let devApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.warp.Warp", "dev.zed.Zed",
        "sh.cursor.Cursor", "com.exafunction.windsurf", "com.panic.Nova", "com.github.atom",
        "com.sublimetext.4", "com.sublimetext.3", "org.vim.MacVim", "io.alacritty",
        "net.kovidgoyal.kitty", "com.apple.Console",
        "com.mitchellh.ghostty", "co.zeit.hyper", "org.tabby", "com.github.wez.wezterm"
    ]
    static func frontmostIsDevApp() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return devApps.contains(bid) || bid.hasPrefix("com.jetbrains")
    }
    /// Режим-исключение текущего приложения: "off" | "soft" | "" (обычный).
    static func frontmostAppMode() -> String {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return "" }
        return ExceptionStore.shared.appMode(bid)
    }

    /// Автозамена сниппета: если последнее слово совпало с триггером — развернуть.
    private func expandSnippetIfMatch() -> Bool {
        guard !muted else { return false }
        guard let item = buffer.wordForConversion() else { return false }
        guard let expansion = SnippetStore.shared.expansion(forTyped: item.word) else { return false }
        muted = true
        TextReplacer.replace(deleteCount: item.deleteCount, with: Self.sanitizeSnippet(expansion) + item.tail) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.muted = false }
        }
        buffer.applyConversion(converted: expansion)
        buffer.invalidateGroupHistory()   // сниппет изменил длину экрана не 1:1 → группа недействительна (G1)
        playSound()
        return true
    }

    private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        // отсекаем управляющие символы
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }
}
