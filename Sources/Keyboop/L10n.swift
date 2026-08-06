import Foundation

extension Notification.Name {
    /// Сменили язык интерфейса в настройках — UI вне окна настроек (меню статус-бара) пересобирается.
    static let keyboopLanguageChanged = Notification.Name("keyboopLanguageChanged")
    /// История голосового набора изменилась — открытое окно истории перестраивается.
    static let keyboopVoiceHistoryChanged = Notification.Name("keyboopVoiceHistoryChanged")
    /// Проверка обновлений сорвалась (или снова заработала) — открытые настройки показывают это.
    static let updaterStatusChanged = Notification.Name("updaterStatusChanged")
    /// Caps-режим не смог включиться (или снова смог) — открытые настройки показывают причину.
    /// Ремап делается в фоне через hidutil, то есть уже ПОСЛЕ того, как человек щёлкнул тумблером,
    /// и без сигнала окно так и осталось бы с бодрым «Работает».
    static let capsRemapStatusChanged = Notification.Name("capsRemapStatusChanged")
    /// Голосовой ввод вставил текст — Engine чистит буфер, чтобы надиктованное не попало в
    /// групповую конвертацию (G3) и не считалось «набранным вручную».
    static let keyboopVoiceInserted = Notification.Name("keyboopVoiceInserted")
}

enum Lang: String { case ru, en }

/// Локализация ru/en. По умолчанию — язык системы; переключается в настройках.
/// RU не дословный перевод — тот же сухой вит в естественном русском (Boopster voice).
enum L10n {
    static var current: Lang {
        switch AppSettings.shared.language {
        case "ru": return .ru
        case "en": return .en
        default:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("ru") ? .ru : .en
        }
    }

    static func t(_ key: String) -> String {
        strings[key]?[current] ?? strings[key]?[.en] ?? key
    }

    /// Локализация единиц размера модели: каталог хранит EN («142 MB», «1.5 GB»),
    /// для RU меняем на «МБ/ГБ». Так EN-интерфейс корректен изначально, а не показывает кириллицу.
    static func size(_ s: String) -> String {
        guard current == .ru else { return s }
        return s.replacingOccurrences(of: "MB", with: "МБ").replacingOccurrences(of: "GB", with: "ГБ")
    }

    /// Подпись пункта длительности тёплого окна: «15 с», «30 с», «1 мин», «5 мин».
    static func warmDurTitle(_ seconds: Int) -> String {
        let ru = current == .ru
        if seconds < 60 { return ru ? "\(seconds) с" : "\(seconds)s" }
        let m = seconds / 60
        return ru ? "\(m) мин" : "\(m) min"
    }

    private static let strings: [String: [Lang: String]] = [
        "tagline":        [.ru: "wrong layout? keyboop.", .en: "wrong layout? keyboop."],

        "menu.edit":      [.ru: "Правка",       .en: "Edit"],
        "menu.undo":      [.ru: "Отменить",     .en: "Undo"],
        "menu.redo":      [.ru: "Повторить",    .en: "Redo"],
        "menu.cut":       [.ru: "Вырезать",     .en: "Cut"],
        "menu.copy":      [.ru: "Копировать",   .en: "Copy"],
        "menu.paste":     [.ru: "Вставить",     .en: "Paste"],
        "menu.selectAll": [.ru: "Выделить всё", .en: "Select All"],
        "menu.close":     [.ru: "Закрыть окно", .en: "Close Window"],
        "sec.switching":  [.ru: "Переключение", .en: "Switching"],
        "sec.exceptions": [.ru: "Исключения",   .en: "Exceptions"],
        "sec.snippets":   [.ru: "Автозамена",   .en: "Snippets"],
        "amb.title":  [.ru: "Кто побеждает",
                       .en: "Who wins"],
        "amb.sub":     [.ru: "Эти слова набираются одними и теми же клавишами и существуют в обоих языках. Мы не можем угадать за тебя: кто-то пишет «versus» каждый день, кто-то — «мы» в каждом втором предложении. Выбери, что должно получаться.",
                       .en: "These words are typed with the very same keys and exist in both languages. We can't guess for you: some people write “versus” daily, others write “мы” in every other sentence. Pick what should come out."],
        "amb.auto":    [.ru: "по контексту", .en: "by context"],
        "amb.rowTip":  [.ru: "«%@» и «%@» набираются одними клавишами. По контексту — решаем сами, по словарю и языку соседних слов.",
                       .en: "“%@” and “%@” are typed with the same keys. By context — we decide, using the dictionary and the language of neighbouring words."],
        "amb.back":    [.ru: "‹ Исключения", .en: "‹ Exceptions"],
        "amb.open":    [.ru: "Открыть список…", .en: "Open the list…"],
        "amb.openSub": [.ru: "Слова, которые набираются одними и теми же клавишами и существуют в обоих языках («vs» и «мы»). По умолчанию решает контекст — но можно закрепить победителя.",
                       .en: "Words typed with the very same keys that exist in both languages (“vs” and “мы”). Context decides by default — but you can pin a winner."],
        "amb.hint":    [.ru: "Выбор сильнее всех встроенных правил — он попадает в исключения. Слово, которого тут нет, всегда можно добавить вручную на странице «Исключения».",
                       .en: "Your choice outranks every built-in rule — it goes into exceptions. A pair that isn't listed can always be added by hand on the Exceptions page."],

        "sec.translate":  [.ru: "Перевод",      .en: "Translate"],
        "sec.privacy":    [.ru: "Приватность",  .en: "Privacy"],
        "sec.general":    [.ru: "Общие",        .en: "General"],
        "sec.updates":    [.ru: "Обновления",   .en: "Updates"],
        "sec.about":      [.ru: "О программе",   .en: "About"],

        // Быстрые действия по правому клику и пауза (задача 21, 05.08.2026)
        "quick.title":    [.ru: "Быстрое действие правым кликом", .en: "Quick action on right click"],
        "quick.sub":      [.ru: "Левый клик по значку открывает меню, правый сразу делает выбранное", .en: "Left click opens the menu, right click does the chosen thing at once"],
        "quick.copyVoice":[.ru: "Копировать последнюю диктовку", .en: "Copy the last dictation"],
        "quick.pause":    [.ru: "Помолчать", .en: "Keep quiet for a while"],
        "quick.dictate":  [.ru: "Начать диктовку", .en: "Start dictation"],
        "quick.history":  [.ru: "Открыть историю диктовок", .en: "Open the dictation history"],
        // Сниппеты как ОТДЕЛЬНЫЙ список (решение автора 06.08.2026)
        "snip.textsTitle":[.ru: "Сниппеты для вставки", .en: "Snippets to insert"],
        "snip.textsSub":  [.ru: "Отдельный список. Автозамена срабатывает сама по аббревиатуре, а это вставляется осознанно: длинные команды, реквизиты, шаблоны писем.", .en: "A separate list. Autoreplace fires by itself on an abbreviation; these are inserted deliberately: long commands, bank details, letter templates."],
        "snip.phName":    [.ru: "название", .en: "name"],
        "snip.phText":    [.ru: "текст для вставки", .en: "text to insert"],
        "snip.copyFrom":  [.ru: "Скопировать из автозамены", .en: "Copy from autoreplace"],
        "snip.copyFromHint":[.ru: "Список пуст. Если что-то подходящее уже лежит в автозамене, можно скопировать его сюда — там оно останется.", .en: "The list is empty. If something suitable already sits in autoreplace, copy it here; it stays there too."],
        "snip.pickOn":    [.ru: "Вставлять сниппет по сочетанию", .en: "Insert a snippet by shortcut"],
        "snip.pickCombo": [.ru: "Сочетание", .en: "Shortcut"],
        "snip.pickCustom":[.ru: "Назначить свою…", .en: "Set your own…"],
        // Выбор сниппета по хоткею (задача 17, 06.08.2026)
        "snip.pickHotkey":[.ru: "Вставить сниппет по сочетанию", .en: "Insert a snippet by shortcut"],
        "snip.pickHint":  [.ru: "Нажмите сочетание — появится список, дальше цифра 1-9. Удобно для того, что не хочется вешать на аббревиатуру: длинные команды, реквизиты, шаблоны писем.", .en: "Press the shortcut for a list, then a digit 1-9. Handy for what you would rather not bind to an abbreviation: long commands, bank details, letter templates."],
        "snip.pickOff":   [.ru: "Выключено", .en: "Off"],
        "snip.pickTip":   [.ru: "цифра вставит · Esc закроет", .en: "a digit inserts · Esc closes"],
        "snip.pickTipMore":[.ru: "цифра · ⇧цифра · ⌘цифра вставят, дальше мышью · Esc закроет", .en: "digit · ⇧digit · ⌘digit insert, the rest by mouse · Esc closes"],
        "snip.pickEmpty": [.ru: "Список автозамен пуст", .en: "The snippet list is empty"],
        "quick.action":   [.ru: "Действие", .en: "Action"],
        "quick.settings": [.ru: "Открыть настройки", .en: "Open settings"],
        "quick.help":     [.ru: "Правый клик по значку Keyboop в строке меню (рядом с часами) сразу делает выбранное, не открывая меню. Левый клик по-прежнему открывает меню.", .en: "Right-clicking the Keyboop icon in the menu bar (up by the clock) does the chosen thing at once, without opening the menu. Left click still opens the menu."],
        "quick.helpOff":  [.ru: "Сейчас недоступно: значок Keyboop убран из строки меню, а кликать не по чему. Верните значок или индикатор языка в разделе «Строка меню» выше.", .en: "Unavailable right now: the Keyboop icon is hidden from the menu bar, so there is nothing to click. Bring back the icon or the language badge in «Menu bar» above."],
        "quick.pauseLen": [.ru: "Сколько молчать", .en: "How long to keep quiet"],
        "quick.paused":   [.ru: "Молчу. Разбудите правым кликом", .en: "Keeping quiet. Right click to wake me"],
        "quick.resumed":  [.ru: "Снова на посту", .en: "Back on duty"],
        "menu.pausedUntil":[.ru: "На паузе до %@", .en: "Paused until %@"],
        "menu.resumeNow": [.ru: "Продолжить сейчас", .en: "Resume now"],
        "switch.title":   [.ru: "Переключение раскладки", .en: "Layout switching"],
        "switch.sub":     [.ru: "Бупни клавишу — кракозябры исчезнут.", .en: "Boop a key — the gibberish vanishes."],
        // ⚠️ ПРАВИЛО ИМЁН (T44, решение автора 30.07). Три настройки годами звучали как одно и то
        // же «переключение», и люди путали их в отчётах (#20 и не только). Различаются они двумя
        // вещами: правят ТЕКСТ или только РАСКЛАДКУ, и когда срабатывают. Поэтому:
        //   всё, что правит текст  → начинается с «Исправлять»
        //   всё, что меняет только раскладку → начинается с «Менять раскладку»
        // Тогда первые две читаются как родственники, а разница видна в хвосте. Держаться правила.
        "switch.auto":    [.ru: "Автоматическое исправление раскладки", .en: "Automatic layout correction"],
        "switch.autoSub": [.ru: "Двусторонне, RU ↔ EN. Слово исправляется, когда вы его дописали", .en: "Two-way, RU ↔ EN. The word is fixed once you finish it"],
        "switch.translate":[.ru: "Перевод выделенного · ⌃⌥T", .en: "Translate selection · ⌃⌥T"],
        "switch.translateSub":[.ru: "Выдели СВОЙ текст в поле ввода и нажми ⌃⌥T — он заменится переводом RU↔EN. Там, где печатаешь (письмо, чат, заметка), а не на чужой веб-странице. Локально, macOS 15+.",
                              .en: "Select YOUR text in an input field and press ⌃⌥T — it's replaced with the RU↔EN translation. Where you type (mail, chat, notes), not on a read-only web page. Local, macOS 15+."],
        "tr.title":       [.ru: "Перевод набранного", .en: "Translate what you typed"],
        "tr.sub":         [.ru: "Выдели свой текст в поле ввода — он ЗАМЕНИТСЯ переводом RU↔EN. Работает там, где можно печатать, а не с текстом на веб-странице «только для чтения». Прямо на твоём Mac.",
                           .en: "Select your text in an input field — it's REPLACED with the RU↔EN translation. Works where you can type, not with read-only web-page text. Right on your Mac."],
        "tr.enabled":     [.ru: "Включить перевод по хоткею", .en: "Enable translate hotkey"],
        "tr.enabledSub":  [.ru: "Направление определяется само по тексту (RU→EN или EN→RU). Нужна macOS 15+.",
                           .en: "Direction is auto-detected from the text (RU→EN or EN→RU). Needs macOS 15+."],
        "tr.hotkey":      [.ru: "Горячая клавиша", .en: "Hotkey"],
        "tr.how":         [.ru: "Перевод офлайн, через системный движок Apple. Если пакет не установлен — нажми «Скачать» выше: пакет RU↔EN загрузится прямо здесь (система разок спросит подтверждение). Звук перевода подтверждает, что всё сработало.",
                           .en: "Translation is offline, via Apple's system engine. If the pack isn't installed — tap “Download” above: the RU↔EN pack loads right here (the system asks for confirmation once). The translation sound confirms it fired."],
        "tr.packTitle":   [.ru: "Языковой пакет", .en: "Language pack"],
        "tr.packName":    [.ru: "Русский ↔ английский", .en: "Russian ↔ English"],
        "tr.checking":    [.ru: "Проверяю…", .en: "Checking…"],
        "tr.installed":   [.ru: "Установлен ✓", .en: "Installed ✓"],
        "tr.notInstalled":[.ru: "Не установлен — нужен для перевода", .en: "Not installed — required for translation"],
        "tr.download":    [.ru: "Скачать", .en: "Download"],
        "tr.openSys":     [.ru: "Системные настройки", .en: "System Settings"],
        "tr.dlTitle":     [.ru: "Загрузка языкового пакета", .en: "Downloading language pack"],
        "tr.dlBody":      [.ru: "Готовлю перевод RU↔EN. Если система спросит — подтверди загрузку. Окно закроется само.",
                            .en: "Preparing RU↔EN translation. If the system asks, confirm the download. This window closes itself."],
        "tr.needPackTitle":[.ru: "Нужен языковой пакет", .en: "Language pack needed"],
        "tr.needPackBody": [.ru: "Перевод RU↔EN включается один раз — скачаю прямо сейчас, если нажмёшь.",
                            .en: "RU↔EN translation turns on once — I'll download it right now if you tap."],
        "tr.sound":       [.ru: "Звук перевода", .en: "Translation sound"],
        "tr.soundVol":    [.ru: "Громкость звука", .en: "Sound volume"],
        "sound.keyboopTr": [.ru: "Keyboop", .en: "Keyboop"],   // звук ПЕРЕВОДА
        "switch.live":    [.ru: "Исправлять не дожидаясь пробела", .en: "Fix without waiting for a space"],
        // Подпись переписана вместе со сменой дефолта на ВКЛ (21.07): пометка «(агрессивно)» пугала
        // ровно там, где тумблер теперь включён из коробки. Объясняем пользу, а не пугаем.
        "switch.liveSub": [.ru: "Не ждать пробела: чиню прямо посреди слова, как только сочетание стало невозможным в этом языке", .en: "Don’t wait for the space: I fix mid-word as soon as the combo becomes impossible in this language"],
        "switch.dev":     [.ru: "Режим для разработчиков", .en: "Mode for developers"],
        "switch.devSub":  [.ru: "Бережёт код: одиночные буквы и короткие сочетания (переменные, команды) не трогаем нигде. В IDE и терминалах авто выключено целиком.",
                           .en: "Protects code: single letters and short combos (variables, commands) are left alone everywhere. In IDEs and terminals auto-switch is fully off."],
        "switch.manual":  [.ru: "Ручное переключение", .en: "Manual switch"],
        // ⚠️ ПОДПИСЬ И «i» ДОБАВЛЕНЫ 04.08.2026, ПОТОМУ ЧТО СТРОКА МОЛЧАЛА. У неё был только
        // заголовок и поле с комбинацией, то есть человек видел ЧТО назначено, но не ЗАЧЕМ. Двое
        // написали автору, что не разобрались, как переключить слово руками и как отменить автозамену.
        // Главное, чего никто не угадывал: переключает и отменяет ОДНА И ТА ЖЕ комбинация.
        // Коротко до предела: справа стоит поле с комбинацией, оно шире тумблера, и места под подпись
        // остаётся мало. Строки в настройках не переносятся принципиально (иначе едет вся сетка),
        // поэтому подпись обязана влезать целиком, а подробности живут в «i».
        "switch.manualSub":  [.ru: "Переключить последнее слово, ею же отменить",
                              .en: "Flip the last word, or undo with the same combo"],
        "switch.hkPrefix":[.ru: "Хоткей:  ", .en: "Hotkey:  "],
        "switch.hkRecord":[.ru: "Нажми комбинацию…  (Esc — отмена)", .en: "Press a combo…  (Esc to cancel)"],
        "hk.custom":      [.ru: "Свой…", .en: "Custom…"],
        "hk.press":       [.ru: "Нажми комбинацию…  (Esc)", .en: "Press a combo…  (Esc)"],
        // Окно записи комбинации (HotkeyRecorderPanel)
        // Состояния, в которых Keyboop не может работать (AppHealth). Пишем ЧТО не так и что делать,
        // без паники: человек и так уже видит, что ничего не происходит.
        "health.noAccessibility": [.ru: "не выдан доступ к Универсальному доступу",
                                   .en: "Accessibility permission not granted"],
        "health.engineDown":      [.ru: "движок не запущен", .en: "engine not running"],
        // Фрагмент в общем ряду со строками выше: система штормила отключениями тапа, и мы сняли
        // перехват сами, чтобы не держать ввод. Формулировка без терминов: человеку важно, что это
        // наше решение и что оно обратимо, а не что такое «event tap».
        "health.tapSuspended":    [.ru: "перехват снят: система его глушила, я приостановился",
                                   .en: "interception is off: the system kept killing it, so I stopped"],
        "health.secureInput":     [.ru: "включён Secure Input — macOS прячет клавиатуру от всех программ",
                                   .en: "Secure Input is on, macOS hides the keyboard from every app"],
        "health.secureInputHolder": [.ru: "включён Secure Input (держит %@) — macOS прячет клавиатуру",
                                     .en: "Secure Input is on (held by %@), macOS hides the keyboard"],
        "hkrec.title":    [.ru: "Новая комбинация", .en: "New shortcut"],
        "hkrec.for":      [.ru: "Для действия: %@", .en: "For: %@"],
        "hkrec.waiting":  [.ru: "нажмите клавиши", .en: "press keys"],
        // ⚠️ ПОДСКАЗКА ПРЯТАЛА ПОЛОВИНУ ВОЗМОЖНОСТЕЙ (отзыв, 04.08.2026). Было: «Держите модификаторы
        // и нажмите клавишу». Модификаторы во множественном числе, и обязательно «плюс клавиша», из
        // чего человек честно делал вывод, что одной клавишей обойтись нельзя, и просил добавить то,
        // что уже работало. Одиночный модификатор код принимает с самого начала: нажал, отпустил,
        // назначилось. Не было сказано только об этом. Пишем оба способа, второй с примером.
        // Короче на треть: текст переносится по ширине окна, и три строки мелким кеглем читаются
        // хуже двух. Про Esc не пишем, рядом стоит кнопка «Отмена» и она виднее.
        "hkrec.hint":     [.ru: "Держите модификаторы и нажмите клавишу. Либо просто нажмите и отпустите один модификатор.",
                           .en: "Hold modifiers and press a key. Or just press and release a single modifier."],
        "snip.needMods":  [.ru: "Нужен хотя бы один модификатор: одна клавиша отберёт обычный ввод", .en: "At least one modifier is needed: a bare key would steal ordinary typing"],
        "hkrec.warn.system":[.ru: "Это сочетание уже занято: %@. Назначить можно, но тогда системную функцию стоит отключить в настройках macOS, иначе сработают обе.",
                           .en: "This shortcut is already taken: %@. You can still assign it, but then turn the system function off in macOS settings, or both will fire."],
        "hk.sysGeneric":  [.ru: "системная функция macOS", .en: "a macOS system function"],
        "hkrec.assign":   [.ru: "Назначить", .en: "Assign"],
        // Предупреждения ВНУТРИ окна записи. Тон: понятно, без занудства, с лёгкой усмешкой.
        // ⚠️ Советов «добавьте ⌥ или ⌃» здесь нет намеренно (автор 28.07): объясняем, почему нельзя,
        // а что нажать вместо — человек решает сам. И про F13…F20 молчим: на маке они живут через
        // Fn, так почти никто не назначает, а оговорка только удлиняет текст.
        "hkrec.warn.busy": [.ru: "%@ система уже забрала себе. Отнимать не будем, вам же им пользоваться.",
                            .en: "%@ is already taken by the system. We won't fight it, you need it too."],
        "hkrec.warn.bare": [.ru: "Одна клавиша без модификаторов отнимется у всех программ сразу, включая ту, где вы сейчас читаете это.",
                            .en: "A key with no modifiers gets taken from every app at once, including the one you're reading this in."],
        "hkrec.warn.ours": [.ru: "Это сочетание у нас уже занято: %@. Две функции на одну комбинацию не уживутся.",
                            .en: "We already use this one for %@. Two actions on one shortcut never ends well."],
        "hkrec.cancel":   [.ru: "Отмена", .en: "Cancel"],
        "hkrec.what.switch": [.ru: "исправление раскладки по хоткею", .en: "fix layout by hotkey"],
        "hkrec.what.voice":  [.ru: "голосовой набор", .en: "dictation"],
        "hkrec.what.translate": [.ru: "перевод выделенного", .en: "translate selection"],
        "hkrec.what.instant":[.ru: "мгновенная смена языка", .en: "instant language switch"],

        // — 0.2.20: строки, ранее захардкоженные мимо L10n (ревизия локализации) —
        // Назначение хоткея (UIControls.displayHotkey / display)
        "hk.rOpt":        [.ru: "Правый ⌥",  .en: "Right ⌥"],
        "hk.lOpt":        [.ru: "Левый ⌥",   .en: "Left ⌥"],
        "hk.rCmd":        [.ru: "Правый ⌘",  .en: "Right ⌘"],
        "hk.lCmd":        [.ru: "Левый ⌘",   .en: "Left ⌘"],
        "hk.rShift":      [.ru: "Правый ⇧",  .en: "Right ⇧"],
        "hk.lShift":      [.ru: "Левый ⇧",   .en: "Left ⇧"],
        "hk.rCtrl":       [.ru: "Правый ⌃",  .en: "Right ⌃"],
        "hk.lCtrl":       [.ru: "Левый ⌃",   .en: "Left ⌃"],
        "hk.key":         [.ru: "клавиша",   .en: "key"],
        "hk.dblMod":      [.ru: "2× мод.",   .en: "2× mod."],
        // Алерты доступа/переноса/перезапуска (AppDelegate)
        "alert.ax.title": [.ru: "Keyboop нужен доступ к Accessibility", .en: "Keyboop needs Accessibility access"],
        "alert.ax.body":  [.ru: "Включи Keyboop в System Settings → Privacy & Security → Accessibility.\nКак включишь — переключение раскладки заработает сразу, перезапускать не нужно.",
                           .en: "Enable Keyboop in System Settings → Privacy & Security → Accessibility.\nOnce you do, layout switching works right away — no restart needed."],
        "alert.ax.open":  [.ru: "Открыть Accessibility", .en: "Open Accessibility"],
        "alert.later":    [.ru: "Позже", .en: "Later"],
        "alert.punto.title":[.ru: "Запущен Punto Switcher", .en: "Punto Switcher is running"],
        "alert.punto.body": [.ru: "Punto Switcher и Keyboop оба переключают раскладку — вместе они конфликтуют и мешают друг другу. Рекомендуем закрыть Punto. Чтобы он не запускался снова — убери его из «Объектов входа».",
                             .en: "Punto Switcher and Keyboop both switch the keyboard layout — together they conflict and fight each other. We recommend quitting Punto. To stop it launching again, remove it from Login Items."],
        "alert.punto.quit": [.ru: "Закрыть Punto", .en: "Quit Punto"],
        "alert.punto.login":[.ru: "Объекты входа…", .en: "Login Items…"],
        "alert.regrant.title":[.ru: "После обновления переразреши Keyboop", .en: "Re-grant Keyboop after the update"],
        "alert.regrant.body": [.ru: "Похоже, ты обновил Keyboop (%@ → %@). Из-за смены подписи доступ к Accessibility мог «протухнуть»: в списке он показан включённым, но не действует.\n\nПочини один раз: System Settings → Privacy & Security → Accessibility → выдели Keyboop, нажми «−» (убрать), затем добавь заново «+» (или перетащи Keyboop в список).\n\nЭто разовое — дальнейшие обновления доступ сохранят.",
                               .en: "Looks like you updated Keyboop (%@ → %@). Because the signature changed, Accessibility access may have gone stale: it shows as enabled but doesn't work.\n\nFix it once: System Settings → Privacy & Security → Accessibility → select Keyboop, press “−” (remove), then add it again with “+” (or drag Keyboop into the list).\n\nThis is one-time — future updates keep the access."],
        "alert.move.title":[.ru: "Перенеси Keyboop в «Программы»", .en: "Move Keyboop to Applications"],
        "alert.move.body": [.ru: "Keyboop запущен из временной папки (образа .dmg или «Загрузок»), поэтому macOS не сохранит за ним доступ к Accessibility, и переключение раскладки работать не будет.\n\nПеретащи Keyboop.app в «Программы» и запусти уже оттуда — тогда всё заработает и не слетит.",
                            .en: "Keyboop is running from a temporary folder (a .dmg image or Downloads), so macOS won't keep its Accessibility access and layout switching won't work.\n\nDrag Keyboop.app into Applications and launch it from there — then everything works and sticks."],
        "alert.move.reveal":[.ru: "Показать в Finder", .en: "Reveal in Finder"],
        "alert.relaunch.title":[.ru: "Перезапустить Keyboop?", .en: "Relaunch Keyboop?"],
        "alert.relaunch.body": [.ru: "Доступ к Accessibility выдан, но macOS не подхватил его для текущего сеанса (известная особенность системы). Один перезапуск Keyboop это чинит — перезагружать компьютер не нужно.",
                                .en: "Accessibility is granted, but macOS didn't pick it up for the current session (a known system quirk). One relaunch of Keyboop fixes it — no need to reboot."],
        "alert.relaunch.ok":[.ru: "Перезапустить", .en: "Relaunch"],
        "alert.relaunch.no":[.ru: "Не сейчас", .en: "Not now"],
        // Индикатор диктовки (VoiceIndicator) + a11y статусов меню-бара
        "voice.listening":[.ru: "Слушаю…", .en: "Listening…"],
        "voice.recognizing":[.ru: "Распознаю…", .en: "Recognizing…"],
        "a11y.recording": [.ru: "Запись", .en: "Recording"],
        // Хранение истории голоса (SettingsWindow)
        "ret.30m":        [.ru: "30 минут", .en: "30 minutes"],
        "ret.1h":         [.ru: "1 час",    .en: "1 hour"],
        "ret.2h":         [.ru: "2 часа",   .en: "2 hours"],
        "ret.4h":         [.ru: "4 часа",   .en: "4 hours"],
        "ret.8h":         [.ru: "8 часов",  .en: "8 hours"],
        "ret.never":      [.ru: "Не удалять", .en: "Keep all"],
        // Описания моделей Whisper (ModelDownloader.catalog хранит ключи)
        // ⚠️ ЧЕТЫРЕ ЧИСЛА НА КАЖДУЮ МОДЕЛЬ (задача автора 04.08.2026, повод — жалоба на память).
        // Подписи выше отвечают на «какая лучше», но не на «чем я за это плачу». Человек выбирал
        // самую точную, потому что «аккуратнее с пунктуацией», и получал полтора гигабайта в памяти,
        // о чём его никто не предупредил.
        //
        // Числа памяти ИЗМЕРЕНЫ 05.08.2026 на M-маке, а не прикинуты: без модели приложение занимает
        // ~285 МБ, с large-v3-turbo ~1885 МБ. Разница ровно в размер файла модели, поэтому для
        // остальных берём их размер: у whisper модель кладётся в память целиком.
        "model.memNote":    [.ru: "Пока модель загружена, она занимает в памяти примерно столько же, сколько весит на диске. Само приложение без модели это около 285 МБ. Модель выгружается после часа без диктовки, а если системе не хватает памяти, то раньше.",
                             .en: "While a model is loaded it takes roughly as much memory as it takes on disk. The app itself without a model is about 285 MB. A model is unloaded after an hour without dictation, and sooner if the system runs short of memory."],
        "model.base.help":  [.ru: "Самая маленькая и быстрая. 142 МБ на диске, столько же в памяти. Годится, если нужно просто разобрать короткую фразу и не жалко точности: длинные предложения и имена она путает заметно чаще остальных.\n\n%@",
                             .en: "The smallest and fastest. 142 MB on disk and about the same in memory. Fine if you just need a short phrase transcribed and can live with mistakes: it garbles long sentences and names noticeably more often.\n\n%@"],
        "model.small.help": [.ru: "Разумная середина. 466 МБ на диске и в памяти. Заметно точнее базовой на длинных фразах, при этом не съедает гигабайты. Хороший выбор, если Parakeet вам не подходит.\n\n%@",
                             .en: "The sensible middle. 466 MB on disk and in memory. Noticeably better than base on long sentences without eating gigabytes. A good choice if Parakeet does not suit you.\n\n%@"],
        "model.medium.help":[.ru: "Точнее средней, но платите вы дважды: 1.5 ГБ на диске, столько же в памяти, и распознавание идёт ощутимо дольше. Смысл есть, если диктуете сложные тексты и готовы ждать.\n\n%@",
                             .en: "More accurate than small, but you pay twice: 1.5 GB on disk, the same in memory, and recognition takes noticeably longer. Worth it if you dictate difficult texts and can wait.\n\n%@"],
        "model.large.help": [.ru: "Самая аккуратная с пунктуацией и связностью речи. 1.6 ГБ на диске и примерно столько же в памяти (замер: 1885 МБ против 285 МБ без модели), распознавание на 1–4 секунды дольше. Берите, если качество текста важнее скорости и памяти.\n\n%@",
                             .en: "The best at punctuation and phrasing. 1.6 GB on disk and about the same in memory (measured: 1885 MB against 285 MB with no model), recognition takes 1 to 4 seconds longer. Take it if text quality matters more than speed and memory.\n\n%@"],
        "voice.pkHelp":     [.ru: "Быстрая модель, считающая на нейродвижке Apple, а не на процессоре: поэтому она почти не греет мак и отвечает быстрее whisper. 465 МБ на диске и в памяти. Знает 25 языков, но есть честная оговорка: задать ей язык распознавания нельзя, это ограничение самой модели. Выбор языка у неё работает как фильтр письменности.\n\nТребует Apple Silicon: на процессорах Intel нейродвижка нет, и там её просто не существует.\n\n%@",
                             .en: "A fast model that runs on Apple’s neural engine rather than the CPU, so it barely heats the Mac and answers quicker than whisper. 465 MB on disk and in memory. It knows 25 languages, with one honest caveat: you cannot tell it which language to expect, that is a limit of the model itself. The language picker acts as a script filter.\n\nRequires Apple Silicon: Intel chips have no neural engine, so it does not exist there.\n\n%@"],
        "model.base.note":  [.ru: "быстрая, базовая точность", .en: "fast, basic accuracy"],
        "model.small.note": [.ru: "баланс качества и скорости", .en: "balance of quality and speed"],
        "model.medium.note":[.ru: "выше точность, медленнее", .en: "higher accuracy, slower"],
        "model.large.note": [.ru: "аккуратнее с пунктуацией и связностью, на 1–4 с медленнее", .en: "cleaner punctuation and phrasing, 1–4 s slower"],
        // Общие действия / подсказки (тултипы, a11y)
        "act.delete":     [.ru: "Удалить", .en: "Delete"],
        "act.close":      [.ru: "Закрыть", .en: "Close"],
        "snip.delRow":    [.ru: "Удалить строку", .en: "Delete row"],
        "hist.opacityHint":[.ru: "⌃-клик: настроить", .en: "⌃-click: configure"],
        "audio.micFallback":[.ru: "Микрофон", .en: "Microphone"],
        "switch.trig":    [.ru: "Срабатывание", .en: "Triggers"],
        "switch.trigAfter":[.ru: "После слова", .en: "After a word"],
        "key.space":      [.ru: "Пробел", .en: "Space"],
        "key.enter":      [.ru: "Enter",  .en: "Enter"],
        "key.tab":        [.ru: "Tab",    .en: "Tab"],
        // Заголовок переписан 28.07 по прямому вопросу из репорта #31: «Пункт "стрелка отменяет
        // переключение" — это про какую стрелку речь?». Старая формулировка не отвечала ни на
        // «какая стрелка», ни на «переключение чего», и у строки вдобавок не было подписи вовсе.
        "switch.arrows":  [.ru: "Стрелки сбрасывают набранное слово",
                           .en: "Arrow keys drop the current word"],
        "switch.arrowsSub": [.ru: "Нажали стрелку курсора — Keyboop забывает слово, которое вы печатали, и переключать его уже не будет. Удобно, если вы часто правите текст, двигая курсор",
                             .en: "Press a cursor arrow and Keyboop forgets the word you were typing, so it will not switch it any more. Handy if you often move the caret while writing"],
        "switch.soundOn": [.ru: "Звук при переключении", .en: "Sound on switch"],
        "switch.sound":   [.ru: "Звук", .en: "Sound"],
        "switch.soundVol":[.ru: "Громкость", .en: "Volume"],
        "switch.login":   [.ru: "Запускать при входе в систему", .en: "Launch at login"],
        "sound.none":     [.ru: "Без звука", .en: "No sound"],

        "exc.appsTitle":  [.ru: "Программы-исключения", .en: "App exceptions"],
        "exc.appsSub":    [.ru: "Где не переключать раскладку автоматически. «Мягкий» — только очевидные слова, одиночные/повторяющиеся буквы не трогаем (хоткеи целы). Слева от режима — раскладка, которую включать при входе в программу: EN спасает там, где хоткеи работают только на латинице.",
                           .en: "Where not to auto-switch the layout. “Soft” — only obvious words; single/repeated letters are left alone (hotkeys stay intact). Left of the mode is the layout to switch to when you enter the app: EN saves you where hotkeys only work in Latin."],
        "exc.appsEmpty":  [.ru: "Пока пусто. Добавь программу ниже.", .en: "Empty so far. Add an app below."],
        "exc.appsHint":   [.ru: "Перетаскивать не нужно — выбери из /Applications или из запущенных.", .en: "No dragging needed — pick from /Applications or from running apps."],
        "exc.off":        [.ru: "Выкл", .en: "Off"],
        "exc.soft":       [.ru: "Мягкий", .en: "Soft"],
        "exc.forceLayoutHelp": [.ru: "Всегда включать эту раскладку при переходе в программу. Нужно там, где горячие клавиши работают только на латинице (DaVinci Resolve и подобные). Переключаем на входе; если внутри вы сменили раскладку сами, спорить не будем. Прочерк — не трогать.",
                                .en: "Always switch to this layout when you go into the app. Handy where hotkeys only work in Latin (DaVinci Resolve and friends). We switch on entry; if you change the layout yourself inside, we leave it alone. Dash means do not touch."],
        "exc.addApp":     [.ru: "Добавить программу…", .en: "Add app…"],
        "exc.fromRunning":[.ru: "Из запущенных…", .en: "From running…"],
        "exc.title":      [.ru: "Исключения", .en: "Exceptions"],
        // ⚠️ ТЕКСТ ПЕРЕПИСАН 04.08.2026 ВМЕСТЕ С МЕХАНИКОЙ. Раньше слова назывались «образцом», хотя
        // на деле были декорацией: настоящая защита сидела в глобальном списке, и удаление чипа
        // ничего не меняло. Теперь это обычные исключения, и подпись говорит именно это.
        "exc.sub":        [.ru: "Слова, которые трогать не надо. Впиши и нажми Enter или «Добавить». «вк», «тг» и «vk» добавлены сразу: их раскладочная пара случайно совпадает со словом другого языка, и без исключения они ломались бы.",
                           .en: "Words to leave alone. Type one and press Enter or “Add”. «вк», «тг» and “vk” come pre-added: each one’s layout-swap happens to be a real word in the other language, so without an exception they would get mangled."],
        "exc.hint":       [.ru: "Удалить слово — крестик ✕ на нём. Удалите «вк» или «vk» — они снова начнут переключаться: это обычные исключения, без особых прав.",
                           .en: "Remove a word — the ✕ on it. Delete «вк» or “vk” and they start switching again: these are ordinary exceptions, with no special powers."],
        "exc.empty":      [.ru: "Пока пусто.", .en: "Empty so far."],
        "exc.addPlaceholder":[.ru: "Слово…", .en: "Word…"],
        "exc.addWord":    [.ru: "Добавить", .en: "Add"],
        "exc.builtinTitle":[.ru: "Уже бережём", .en: "Already protected"],
        "exc.builtinBody": [.ru: "Популярные сервисы, чья раскладка случайно совпадает с английским словом, не трогаем по умолчанию — например «вк», «тг». Список вшит и обновляется с приложением.",
                            .en: "Popular services whose layout-swap happens to be an English word are left alone by default — e.g. «вк», «тг». The list is built in and ships with updates."],
        "learn.title":    [.ru: "Учиться на отмене", .en: "Learn from undo"],
        "learn.sub":      [.ru: "Если сразу откатить переключение и вернуть слово как было — спрошу, добавить ли его в исключения. Скажешь «нет» — больше про него не спрошу.",
                           .en: "Undo a switch right away and restore the word as you typed it — I'll ask whether to add it to exceptions. Say no and I won't ask about it again."],
        "learn.askTitle": [.ru: "Оставить «%@» как есть?", .en: "Keep “%@” as is?"],
        "learn.askBody":  [.ru: "Добавить в исключения, чтобы Keyboop его больше не переключал?",
                           .en: "Add it to exceptions so Keyboop stops switching it?"],
        "learn.add":      [.ru: "Добавить", .en: "Add"],
        "learn.no":       [.ru: "Не надо", .en: "No thanks"],
        "learn.hint":     [.ru: "Выученные слова — ниже. Удалить — крестик ✕ на слове; «Очистить» убирает все.",
                           .en: "Learned words are below. Remove one — the ✕ on it; “Clear” removes all."],
        "learn.empty":    [.ru: "Пока ничего не выучено.", .en: "Nothing learned yet."],
        "learn.clear":    [.ru: "Очистить", .en: "Clear"],
        "learn.toast":    [.ru: "Запомнил: больше не трогаю «%@»", .en: "Got it — leaving «%@» alone from now on"],

        "snip.title":     [.ru: "Автозамена", .en: "Snippets"],
        "snip.expandOn":  [.ru: "Разворачивать по клавише", .en: "Expand on key"],
        "snip.disabled":  [.ru: "Автозамена отключена — не выбрана ни одна клавиша разворота.",
                           .en: "Snippets are off — no expansion key selected."],
        "snip.sub":       [.ru: "Набрал сокращение, нажал пробел — развернулось.",
                           .en: "Type a shortcut, hit space — it expands."],
        "snip.hint":      [.ru: "Раскладка и регистр не учитываются: !test = !TEST = !еуые. Разворачивается по пробелу или Enter.",
                           .en: "Layout and case are ignored: !test = !TEST = !еуые. Expands on space or Enter."],
        "snip.colTrigger":[.ru: "Что заменять", .en: "Replace"],
        "snip.colExpansion":[.ru: "На что", .en: "With"],
        "snip.phTrigger": [.ru: "напр. сув", .en: "e.g. br"],
        "snip.phExpansion":[.ru: "напр. С уважением, Алекс", .en: "e.g. Best regards, Alex"],
        "snip.add":       [.ru: "Добавить", .en: "Add"],

        "priv.title":     [.ru: "Не звонит домой", .en: "Doesn't phone home"],
        "priv.body":      [.ru: "Keyboop не следит за тобой. Ни телеметрии, ни аналитики, ни кейлоггинга — всё, что ты печатаешь и говоришь, остаётся на твоём Mac.",
                           .en: "Keyboop doesn't track you. No telemetry, no analytics, no keylogging — whatever you type and say stays on your Mac."],
        // ⚠️ ТЕКСТ РАСХОДИЛСЯ С САЙТОМ, И НЕ В ПОЛЬЗУ ЧЕСТНОСТИ (аудит, 05.08.2026). Здесь стояло «только
        // в двух случаях: модель и обновления», а страница приватности перечисляет ЧЕТЫРЕ повода. Не
        // хватало ровно того, где наружу уходит содержимое: отправки отзыва вместе с хвостом лога.
        // Обещание, сказанное двумя разными числами в двух местах, перестаёт быть обещанием.
        "priv.body2":     [.ru: "В сеть Keyboop выходит по четырём поводам, и три из них начинаешь ты: скачать языковую модель, открыть сайт или телеграм из меню, отправить отзыв (уходит ровно то, что видно в окне отправки). Четвёртый — проверка обновлений: она шлёт только твой IP и номер версии, как любой заход на сайт. Ни буквы из набранного или надиктованного. Всё выключается в Настройках → Обновления.",
                           .en: "Keyboop goes online for four reasons, and you start three of them: downloading a voice model, opening the site or Telegram from the menu, sending feedback (only what you see in the send window goes out). The fourth is the update check: it sends your IP and version number, the same as visiting any website. Not a letter of what you typed or dictated. All of it can be turned off in Settings → Updates."],
        "priv.update":    [.ru: "Обновления — на keyboop.com", .en: "Updates — at keyboop.com"],
        "priv.foot":      [.ru: "Спокойно. Всё остаётся на твоём Mac.", .en: "Calm. It all stays on your Mac."],
        "gen.title":      [.ru: "Общие", .en: "General"],
        "gen.sub":        [.ru: "Язык интерфейса, автозапуск и доступ к системе.",
                           .en: "Interface language, launch at login, and system access."],
        // ⚠️ ЗАГОЛОВОК НАЗЫВАЕТ ДЕЙСТВИЕ, А НЕ ВЫГОДУ (отзыв в Instagram Direct, 01.08.2026).
        // Женщина написала: «У меня до приложения клавиатура переключалась нажатием Caps Lock. Её же
        // я хотела установить клавишей переключения раскладки в приложении, но не получилось».
        // Функция у нас есть ровно эта. Она её не нашла, потому что строка называлась «Менять
        // раскладку БЕЗ ЗАДЕРЖКИ»: человек ищет «сменить клавишу переключения», а мы предлагали ему
        // скорость. Отсутствие задержки — приятное следствие, а не то, за чем сюда приходят, поэтому
        // оно уехало в подзаголовок, а в заголовок встала клавиша.
        // Правило имён T44 сохранено: настройка меняет только раскладку → начинается с «Менять
        // раскладку». Caps Lock назван в подзаголовке ДОСЛОВНО — именно это слово люди ищут глазами.
        "is.title":       [.ru: "Менять раскладку без задержки", .en: "Change layout without the delay"],
        "is.enable":      [.ru: "Менять раскладку без задержки", .en: "Change layout without the delay"],
        "is.enableSub":   [.ru: "У системного переключения есть заметная пауза. Здесь язык меняется сразу, своей клавишей: Caps Lock, 🌐 или любой комбинацией. Набранное не трогаем, это только раскладка, отдельно от ручного исправления слова.",
                           .en: "The system's own switch has a noticeable pause. This one changes the language at once, with a key of your choice: Caps Lock, 🌐 or any shortcut. Your text isn't touched, it's only the layout, separate from fixing a word by hand."],
        // Отказ Caps-режима, сказанный человеку. Без обвинений и без просьбы «удалите Karabiner»:
        // чужой ремап человек ставил осознанно, и ломать его молча мы не станем — об этом и пишем.
        "is.capsForeign": [.ru: "Caps Lock занят: на этом Mac уже настроен свой ремап клавиш (обычно это Karabiner или похожая утилита). Перебивать чужую настройку мы не будем — выберите другую клавишу выше, или снимите тот ремап и включите тумблер заново.",
                           .en: "Caps Lock is taken: this Mac already has its own key remapping (usually Karabiner or a similar tool). We won't override someone else's setup — pick a different key above, or remove that remapping and switch this back on."],
        "is.capsFailed":  [.ru: "Caps Lock не удалось перенастроить: система отклонила запрос. Выберите другую клавишу выше или напишите нам через «Сообщить о проблеме…», приложив лог.",
                           .en: "Caps Lock could not be remapped: the system refused the request. Pick a different key above, or write to us via “Report a problem…” and attach the log."],
        "is.combo":       [.ru: "Комбинация", .en: "Shortcut"],
        "is.offHint":     [.ru: "Выключено — клавиши работают как обычно, системные действия на месте.",
                           .en: "Off — the keys behave as usual, system actions untouched."],
        "is.onClean":     [.ru: "Работает. Выключите тумблер — и клавиша вернётся системе, ничего настраивать не нужно.",
                           .en: "Working. Turn the toggle off and the key goes back to the system — nothing to configure."],
        "is.onShadow":    [.ru: "Работает. Пока включено, эта комбинация больше не вызывает %@ — мы перехватываем её раньше. Выключите тумблер, и всё вернётся.",
                           .en: "Working. While it's on, this shortcut no longer triggers %@ — we intercept it first. Turn the toggle off and everything comes back."],
        "is.warn.title":  [.ru: "Комбинация перейдёт к Keyboop", .en: "The shortcut goes to Keyboop"],
        "is.warn.body":   [.ru: "Теперь она мгновенно меняет язык. Пока включено, %@ по этой комбинации работать не будет. Выключите тумблер — вернётся, системные настройки мы не трогаем.",
                           .en: "It will switch the language instantly. While it's on, %@ won't respond to this shortcut. Turn the toggle off and it returns — we don't touch system settings."],
        "is.warn.ok":     [.ru: "Забрать комбинацию", .en: "Take the shortcut"],
        "is.shadow.spotlight":[.ru: "Spotlight (поиск)", .en: "Spotlight (search)"],
        "is.shadow.inputSrc":[.ru: "системную смену языка", .en: "the system's language switch"],
        "is.shadow.caps": [.ru: "Caps Lock (заглавные)", .en: "Caps Lock (capitals)"],
        "is.shadow.globe":[.ru: "системное действие клавиши 🌐", .en: "the 🌐 key's system action"],
        "is.busy.title":  [.ru: "Комбинация уже занята", .en: "Shortcut already taken"],
        "is.busy.body":   [.ru: "На неё в Keyboop назначено: %@. Выберите другую — иначе два действия подрались бы за одно нажатие.",
                           .en: "In Keyboop it's already used for: %@. Pick another one — otherwise two actions would fight over one press."],
        "is.busy.convert":[.ru: "исправление слова (ручной хоткей)", .en: "fixing a word (manual hotkey)"],
        "is.busy.voice":  [.ru: "голосовой набор", .en: "voice typing"],
        "is.busy.translate":[.ru: "перевод выделенного", .en: "translating the selection"],
        "is.busy.instant":[.ru: "мгновенная смена языка", .en: "instant language switch"],
        "is.noShift":     [.ru: "Shift не подойдёт: он нажимается перед каждой заглавной буквой, и язык начнёт переключаться сам собой. Выберите другую клавишу.",
                           .en: "Shift will not work: you press it before every capital letter, so the language would start switching on its own. Pick another key."],
        "is.beta":        [.ru: "Бета: функция новая, перехватывает системные комбинации. Если заметите странности — напишите через «Сообщить о проблеме…», это очень поможет.",
                           .en: "Beta: this is new and it intercepts system shortcuts. If anything acts up, tell us via “Report a problem…” — it really helps."],
        "globe.title":    [.ru: "Клавиша 🌐", .en: "The 🌐 key"],
        "globe.enable":   [.ru: "🌐 переключает язык мгновенно", .en: "🌐 switches language instantly"],
        "globe.enableSub":[.ru: "Клавиша 🌐 (она же Fn, слева внизу) меняет язык без задержки — набранное не трогаем, это просто смена раскладки. Комбинации Fn+F1, Fn+стрелки работают как раньше.",
                           .en: "The 🌐 key (a.k.a. Fn, bottom-left) switches language with no delay — your text isn't touched, it's just the layout. Fn+F1 and Fn+arrows keep working as before."],
        "globe.ours":     [.ru: "Клавиша 🌐 сейчас за Keyboop — переключает язык мгновенно. Выключите тумблер, и системное действие вернётся.",
                           .en: "The 🌐 key belongs to Keyboop now — instant language switching. Turn the toggle off and the system action comes back."],
        "globe.retaken":  [.ru: "⚠︎ Похоже, системное действие на 🌐 вернули в Настройках системы — сейчас сработают оба. Переключите тумблер выключить-включить, и мы заберём клавишу обратно.",
                           .en: "⚠︎ Looks like the system action on 🌐 was restored in System Settings — both will fire now. Toggle this off and on again and we'll take the key back."],
        "globe.nowSystem":[.ru: "Сейчас на 🌐 работает системное действие: %@.", .en: "Right now 🌐 does the system action: %@."],
        "globe.busy.lang":[.ru: "смена языка (с задержкой)", .en: "input source switching (delayed)"],
        "globe.busy.emoji":[.ru: "палитра эмодзи", .en: "the emoji picker"],
        "globe.busy.dictation":[.ru: "диктовка", .en: "dictation"],
        "globe.busy.nothing":[.ru: "ничего", .en: "nothing"],
        "globe.warn.title":[.ru: "Клавиша 🌐 перейдёт к Keyboop", .en: "The 🌐 key will go to Keyboop"],
        "globe.warn.body":[.ru: "Теперь она будет мгновенно переключать язык. Прежнее действие этой клавиши — %@ — при этом отключится. Вернуть его можно, выключив этот тумблер.",
                           .en: "It will switch the language instantly. The key's previous action — %@ — will be turned off. Turning this toggle off brings it back."],
        "globe.warn.bodyFree":[.ru: "Теперь она будет мгновенно переключать язык. Сейчас на неё ничего не назначено, так что ничего не потеряется.",
                               .en: "It will switch the language instantly. Nothing is assigned to it right now, so nothing gets lost."],
        "globe.warn.ok":  [.ru: "Забрать клавишу", .en: "Take the key"],
        "globe.freeFail": [.ru: "Не вышло изменить системную настройку. Откройте Настройки системы → Клавиатура и выберите «При нажатии 🌐 → Ничего не делать».",
                           .en: "Couldn't change the system setting. Open System Settings → Keyboard and choose “Press 🌐 key to → Do Nothing”."],
        "gen.theme":      [.ru: "Оформление", .en: "Appearance"],
        "gen.theme.system":[.ru: "Как в системе", .en: "System"],
        "gen.theme.light":[.ru: "Светлое", .en: "Light"],
        "gen.theme.dark": [.ru: "Тёмное", .en: "Dark"],
        // 🍺 Пасхалка про пиво живёт в SettingsWindow литералом: эмодзи не переводится, и ключи
        // в словаре ей ни к чему.
        "gen.themeHelp":  [.ru: "«Как в системе» означает, что Keyboop переоденется вместе с macOS, когда та переключится на светлую или тёмную тему. Светлое и тёмное закрепляют вид независимо от системы: удобно, если ночью система темнеет сама, а вам привычнее одно и то же. Всплывающие плашки (диктовка, обновление) остаются тёмными при любом выборе: они и в системе такие, как поиск Spotlight.",
                           .en: "“System” means Keyboop changes clothes together with macOS when it switches between light and dark. Light and dark pin the look regardless of the system, which helps if macOS darkens itself at night but you prefer one constant look. Floating panels (dictation, updates) stay dark whatever you pick: they are dark in the system too, like Spotlight."],
        "gen.icon":       [.ru: "Строка меню", .en: "Menu bar"],
        "gen.iconPick":   [.ru: "Значок", .en: "Icon"],
        "gen.iconLang":   [.ru: "Показывать язык рядом (RU/EN)", .en: "Show language next to it (RU/EN)"],
        "gen.icon.brand": [.ru: "Фирменный знак", .en: "Brand mark"],
        "gen.icon.flag":  [.ru: "Флаг языка", .en: "Language flag"],
        "voice.others":   [.ru: "Другие модели", .en: "Other models"],
        "voice.sizeNote": [.ru: "Чем крупнее модель, тем дольше она думает — и, скорее всего, точнее. Скорее всего.",
                          .en: "The bigger the model, the longer it thinks — and probably the more accurate it is. Probably."],

        "gen.icon.keyboard":[.ru: "Клавиатура", .en: "Keyboard"],
        "gen.icon.hidden":[.ru: "Без значка", .en: "No icon"],
        "gen.iconHint":   [.ru: "Как выглядит Keyboop рядом с часами. Индикатор языка (RU/EN) — заодно подсказка, какая раскладка активна.",
                           .en: "How Keyboop looks by the clock. The language tag (RU/EN) doubles as a hint of the active layout."],
        "gen.iconHidden": [.ru: "⚠︎ Без значка и без языка в строке меню ничего не видно. Окно настроек тогда открывается повторным запуском Keyboop из папки «Программы» — работающая копия сама покажет настройки. Переключение раскладки и голос при этом работают как обычно.",
                           .en: "⚠︎ With no icon and no language, nothing shows in the menu bar. Then open Settings by launching Keyboop again from Applications — the running copy brings up Settings. Layout switching and voice keep working as usual."],
        "gen.iconHiddenLang":[.ru: "Значок скрыт, но индикатор языка (RU/EN) остаётся в строке меню — по клику на него открывается меню Keyboop и настройки. Совсем убрать всё — выключите ещё и «Показывать язык».",
                              .en: "The icon is hidden, but the language tag (RU/EN) stays in the menu bar — click it to open Keyboop's menu and settings. To remove everything, also turn off “Show language”."],
        "gen.access":     [.ru: "Доступ", .en: "Access"],
        "gen.accessHint": [.ru: "Нужен, чтобы Keyboop видел нажатия и переключал раскладку. Без него не работает ни авто-переключение, ни голос.",
                           .en: "Needed so Keyboop sees keystrokes and switches the layout. Without it neither auto-switch nor voice works."],
        "gen.mic":        [.ru: "Доступ к микрофону…", .en: "Microphone access…"],
        "gen.micOk":      [.ru: "Микрофон: доступ есть ✓", .en: "Microphone: granted ✓"],
        "gen.micHint":    [.ru: "Нужен для голосового набора. Запрашивается сам при первом запуске; если промпт не появился или доступ отозвали — запроси здесь.",
                           .en: "Needed for voice typing. Requested automatically on first launch; if the prompt didn't show or access was revoked — request it here."],
        "about.title":    [.ru: "О программе", .en: "About"],
        // Тоже упоминаем обе фичи: раньше «О программе» обещала только раскладку (см. wel.tagline).
        "about.tagline":  [.ru: "Keyboop — бесплатно и с открытым кодом. Сделано, чтобы раскладка больше не отвлекала, а печатать можно было голосом.",
                           .en: "Keyboop — free & open source. Made so the layout never trips you up, and so you can type with your voice."],
        "about.support":  [.ru: "Поддержать проект  ₽", .en: "Support the project  ₽"],
        "about.version":  [.ru: "Версия", .en: "Version"],
        "about.license":  [.ru: "Лицензия", .en: "License"],
        "about.rescued":  [.ru: "Расколдовано кракозябр", .en: "Gibberish un-garbled"],
        "about.dictated": [.ru: "Надиктовано голосом", .en: "Dictated by voice"],
        "about.licenseVal":[.ru: "Бесплатно · open source", .en: "Free · open source"],
        "about.fbTitle":  [.ru: "Есть что сказать?", .en: "Got something to say?"],
        "about.fbBody":   [.ru: "Поймал баг, бесит мелочь или придумал фичу — напиши. Я правда читаю: Keyboop растёт на ваших отзывах, а не на фокус-группах.",
                           .en: "Caught a bug, annoyed by some detail, or dreamed up a feature — write. I actually read these: Keyboop grows on your feedback, not focus groups."],
        "about.fbBtn":    [.ru: "Написать разработчику", .en: "Email the developer"],
        "about.logHint":  [.ru: "Форма сама приложит хвост лога (галочка «диагностика») — так баг ловится быстрее. Хочешь посмотреть глазами — кнопка рядом откроет полный лог в «Консоли»: он локальный, без текста ввода, речи и перевода.",
                           .en: "The form attaches the log tail itself (the “diagnostics” checkbox) — it makes bugs far easier to catch. Want to see it with your own eyes — the button next door opens the full log in Console: it's local, with no typed text, speech or translation."],
        "about.whatsNew": [.ru: "Что нового", .en: "What’s new"],
        "about.welcome":  [.ru: "Знакомство", .en: "Welcome tour"],
        "about.updTitle": [.ru: "Узнавать о новых функциях", .en: "Hear about new features"],
        "about.updBody":  [.ru: "Keyboop сам находит новые версии и предлагает обновиться (настраивается в «Общие → Обновления»). А что нового появляется и зачем — рассказываем в телеграм-канале. Без спама.",
                           .en: "Keyboop finds new versions on its own and offers to update (configurable in General → Updates). What's new and why — we tell in the Telegram channel. No spam."],
        "about.updTg":    [.ru: "Телеграм-канал @keyboop", .en: "Telegram channel @keyboop"],
        "about.foot":     [.ru: "Из семьи boop.", .en: "From the boop family."],
        "about.credits":  [.ru: "Распознавание речи: Whisper (OpenAI) · Parakeet (NVIDIA, CC-BY-4.0) через FluidAudio (Apache-2.0).",
                           .en: "Speech recognition: Whisper (OpenAI) · Parakeet (NVIDIA, CC-BY-4.0) via FluidAudio (Apache-2.0)."],

        // ── Окно-приветствие (онбординг) ──
        "wel.hi":         [.ru: "Привет. Я Keyboop.", .en: "Hi. I’m Keyboop."],
        // Обе главные фичи — в ПЕРВОЙ же строке (раньше здесь была только раскладка, и голос
        // всплывал лишь ниже по онбордингу — пользователь мог его вовсе не заметить).
        "wel.tagline":    [.ru: "Печатаешь не в той раскладке — я молча расколдовываю кракозябры. А печатать лень — проговори вслух, наберу за тебя. Тихо, без слежки, всё на твоём Mac.",
                           .en: "Type in the wrong layout — I quietly un-garble the gibberish. Too lazy to type — say it out loud and I’ll type it for you. Quietly, no spying, all on your Mac."],
        "wel.menubar":    [.ru: "Живу в строке меню — вверху справа, рядом с часами. Окна не занимаю.",
                           .en: "I live in the menu bar — top right, by the clock. No window in your way."],
        "wel.permTitle":  [.ru: "Доступы", .en: "Permissions"],
        "wel.permBody":   [.ru: "Без них главное не заработает. Выдать — минута.",
                           .en: "Without these the main thing won’t work. Granting takes a minute."],
        "wel.permAxT":    [.ru: "Универсальный доступ", .en: "Accessibility"],
        "wel.permAxS":    [.ru: "Чтобы чинить раскладку и слышать хоткеи. Без него авто-переключение не работает.",
                           .en: "To fix the layout and hear hotkeys. Auto-switching won’t work without it."],
        "wel.permMicT":   [.ru: "Микрофон", .en: "Microphone"],
        "wel.permMicS":   [.ru: "Только для голосового набора. Не диктуешь — можно пропустить.",
                           .en: "Only for voice typing. Skip it if you won’t dictate."],
        "wel.allow":      [.ru: "Разрешить", .en: "Allow"],
        "wel.canTitle":   [.ru: "Что я умею", .en: "What I do"],
        "wel.can1":       [.ru: "Сам чиню раскладку: ghbdtn → привет, пока ты не заметил.", .en: "Fix the layout myself: ghbdtn → привет, before you notice."],
        "wel.can2":       [.ru: "Голос → текст: нажал хоткей, проговорил — готово. Локально, без интернета.", .en: "Voice → text: press the hotkey, speak — done. Local, no internet."],
        "wel.can3":       [.ru: "Промахнулся — переключу последнее слово вручную по хоткею.", .en: "Missed one — I’ll switch the last word by hotkey."],
        "wel.can4":       [.ru: "Автозамена: короткое сокращение разворачивается в целую фразу.", .en: "Snippets: a short trigger unfolds into a whole phrase."],
        "wel.keysTitle":  [.ru: "Горячие клавиши", .en: "Hotkeys"],
        "wel.key1v":      [.ru: "Диктовка — нажал старт, нажал ещё стоп", .en: "Dictation — press to start, press to stop"],
        "wel.key2v":      [.ru: "Переключить последнее слово / раскладку", .en: "Switch the last word / layout"],
        "wel.key1short":  [.ru: "Диктовка", .en: "Dictation"],
        "wel.key2short":  [.ru: "Переключить раскладку", .en: "Switch layout"],
        "wel.keysNote":   [.ru: "Меняй прямо тут — или потом в настройках.", .en: "Change them right here — or later in settings."],
        "wel.practiceTitle":[.ru: "Песочница", .en: "Sandbox"],
        // %@ — реальный хоткей из настроек (подставляется в WelcomeWindow), чтобы пользователь
        // запоминал СВОЮ комбинацию, а не абстрактное «нажми хоткей».
        "wel.practiceHint":[.ru: "Печатай прямо здесь. Набери ghbdtn и пробел — увидишь фокус вживую.",
                            .en: "Type right here. Enter ghbdtn and a space — watch the trick live."],
        "wel.practiceVoice":[.ru: "Голос тоже можно попробовать не выходя отсюда: поставь курсор в поле выше, нажми %@ и продиктуй пару фраз — текст появится сам.",
                            .en: "You can try your voice without leaving this window: click the field above, press %@ and dictate a couple of sentences — the text types itself."],
        "wel.practiceTr":  [.ru: "И перевод тут же: выдели введённый текст и нажми %@ — поменяю на месте.",
                            .en: "And translation too: select the text you typed and press %@ — I’ll swap it in place."],
        "wel.trTitle":     [.ru: "Перевод", .en: "Translate"],
        "wel.trBody":      [.ru: "Выдели текст в любом поле, нажми хоткей — переведётся прямо на месте. Русский ↔ английский, направление ловлю сам по тексту. Офлайн, на твоём Mac, без отправки наружу.",
                            .en: "Select text in any field, press the hotkey — it gets translated in place. Russian ↔ English, I pick the direction myself. Offline, on your Mac, nothing leaves it."],
        "wel.trKeyShort":  [.ru: "Перевести выделенное", .en: "Translate selection"],
        "wel.trPackNote":  [.ru: "Один раз нужно поставить языковой пакет — его качает сама система, кнопкой ниже. Без него переводить нечем.",
                            .en: "You’ll need the language pack once — the system downloads it, button below. Without it there’s nothing to translate with."],
        "wel.trSandbox":   [.ru: "Можно сразу попробовать в песочнице ниже: выдели введённый текст и нажми %@.",
                            .en: "Try it right in the sandbox below: select the text you typed and press %@."],
        "wel.trNeedOS":    [.ru: "Перевод работает на macOS 15 и новее. У тебя постарше — эта часть пока пропускается, остальное в силе.",
                            .en: "Translation needs macOS 15 or newer. Yours is older — this part sits out for now, the rest still works."],
        "wel.voiceTitle": [.ru: "Голос", .en: "Voice"],
        "wel.voiceBody":  [.ru: "Для диктовки нужна модель распознавания. Рекомендуем основную — Parakeet: быстрая (текст почти сразу), целиком офлайн, не зацикливается на длинных фразах. Позже, если захочешь аккуратнее с пунктуацией, в настройках есть Whisper Turbo. Качается один раз, дальше всё на твоём Mac.",
                           .en: "Dictation needs a recognition model. We recommend the default — Parakeet: fast (text almost instantly), fully offline, and it won’t loop on long phrases. Later, if you want cleaner punctuation, Settings has Whisper Turbo. One download, then it all stays on your Mac."],
        "wel.voiceDownload":[.ru: "Скачать Parakeet · ~465 МБ", .en: "Download Parakeet · ~465 MB"],
        "wel.voiceReady": [.ru: "Голос готов ✓", .en: "Voice ready ✓"],
        "wel.histSafety": [.ru: "Не туда вставилось? Всё надиктованное хранится в истории — меню значка → «История». Двойной клик — скопировать.",
                           .en: "Went to the wrong place? Everything you dictated is in History — menu icon → 'History'. Double-click to copy."],
        "wel.settings":   [.ru: "Настройки", .en: "Settings"],
        "wel.go":         [.ru: "Поехали", .en: "Let’s go"],
        "wel.foot":       [.ru: "Из семьи boop. Бупаем клавиши.", .en: "From the boop family. We boop keys."],
        "priv.perm":      [.ru: "Доступ к Accessibility…", .en: "Accessibility access…"],
        "priv.lang":      [.ru: "Язык интерфейса:", .en: "Interface language:"],
        "lang.auto":      [.ru: "По умолчанию", .en: "Default"],
        "lang.ru":        [.ru: "Русский", .en: "Russian"],
        "lang.en":        [.ru: "English", .en: "English"],

        "sec.voice":      [.ru: "Голосовой набор", .en: "Voice input"],
        "voice.title":    [.ru: "Голосовой набор", .en: "Voice input"],
        "voice.sub":      [.ru: "Нажми хоткей, проговори — текст впечатается. Распознавание локальное, без интернета.",
                           .en: "Press the hotkey, speak — the text is typed in. Recognition is local, offline."],
        "voice.on":       [.ru: "Голосовой ввод", .en: "Voice input"],
        "voice.hotkey":   [.ru: "Хоткей диктовки", .en: "Dictation hotkey"],
        "voice.hkTest":   [.ru: "Проверить", .en: "Test"],
        "voice.hkTestPrompt": [.ru: "Нажми свой хоткей диктовки…", .en: "Press your dictation hotkey…"],
        "voice.hkTestOk": [.ru: "✓ Хоткей работает", .en: "✓ Hotkey works"],
        "voice.hkTestFail": [.ru: "✗ Не совпадает", .en: "✗ Mismatch"],
        "voice.hkTestDisabled": [.ru: "Голосовой ввод отключён — включи его выше", .en: "Voice input is off — enable it above"],
        "voice.hkTestCancel": [.ru: "Закрыть", .en: "Close"],
        "voice.mode":     [.ru: "Режим", .en: "Mode"],
        // ⚠️ ВТОРОЙ ЗАХОД НА ЭТУ СТРОКУ (автор, 02.08.2026). 29.07 он сказал, что «Переключать»
        // непонятно, и тогда мы добавили подпись, объясняющую только его. Не помогло: непонятной
        // остаётся сама пара, потому что «переключать» описывает НЕ ЖЕСТ, а внутреннее устройство
        // («переключить режим записи»). Человек читает кнопку и не понимает, что ему делать пальцем.
        //
        // Теперь обе кнопки названы одинаковой формой и обе про жест: удерживать против нажимать.
        // Разница у них ровно одна — чем запись КОНЧАЕТСЯ: отпусканием клавиши или вторым нажатием.
        //
        // ⚠️ ПОДПИСЬ ОБЪЯСНЯЕТ ТОЛЬКО ВТОРОЙ ВАРИАНТ, и это осознанно. Я сначала написал сюда оба
        // («Удерживать — пока держите клавишу. Нажимать — от нажатия до нажатия»), посмотрел рендер
        // и увидел, что строка обрезается ровно на «Нажимать — от нажа…», то есть отрезается именно
        // то, ради чего подпись существует. Строки настроек у нас не переносятся, поэтому в них
        // помещается одна мысль. «Удерживать» понятно из самого слова, объяснять надо второй.
        // Полное сравнение обоих — под кнопкой «i» (voice.modeHelp).
        "voice.modeSub":  [.ru: "Нажимать — нажали, сказали, нажали ещё раз",
                           .en: "Press — press, speak, press again"],
        "voice.modeHold": [.ru: "Удерживать", .en: "Hold"],
        "voice.modeToggle":[.ru: "Нажимать", .en: "Press"],
        "voice.modeHelp": [.ru: "Удерживать: зажали клавишу диктовки, говорите, отпустили — речь распознаётся и текст встаёт в поле. Хорошо для коротких фраз: палец всё время помнит, что запись идёт, и забыть её выключить невозможно.\n\nНажимать: нажали один раз, говорите сколько нужно, нажали второй раз — и появится текст. Хорошо для длинных мыслей и когда руки нужны свободными; следите только за индикатором, запись ждёт второго нажатия сколько угодно.\n\nРазница между ними ровно одна: чем заканчивается запись — отпусканием клавиши или вторым нажатием. Клавиша в обоих случаях та же, что выбрана выше.",
                           .en: "Hold: press and hold the dictation key, speak, let go — your speech is recognised and the text lands in the field. Good for short phrases: your finger keeps reminding you that recording is on, so you cannot forget to stop it.\n\nPress: press once, speak for as long as you need, press again — and the text appears. Good for longer thoughts and when your hands are busy; just watch the indicator, because recording waits for that second press as long as it takes.\n\nThe only difference is what ends the recording: releasing the key, or a second press. The key itself is the same one you picked above."],
        "voice.needModelTitle":[.ru: "Нужна модель распознавания", .en: "A recognition model is needed"],
        "voice.needModelBody": [.ru: "Чтобы я понимал речь, скачай модель — один раз, дальше всё локально, без интернета. Открыть настройки?",
                                .en: "To understand speech I need a model — once, then it’s all local, no internet. Open settings?"],
        "voice.needModelOpen": [.ru: "Открыть настройки", .en: "Open settings"],
        "voice.needModelLater":[.ru: "Не сейчас", .en: "Not now"],
        "voice.escCancel":[.ru: "Escape отменяет диктовку", .en: "Escape cancels dictation"],
        "voice.escCancelSub": [.ru: "Запись обрывается, ничего не вставляется",
                          .en: "Recording is dropped and nothing is inserted"],
        "voice.escSave":  [.ru: "Отменённую всё равно сохранять", .en: "Keep cancelled dictations"],
        "voice.escSaveSub":[.ru: "В поле не вставим, но в историю положим",
                            .en: "Nothing is inserted, but it lands in the history"],
        "voice.escSaveHelp":[.ru: "Escape отменяет вставку, но речь к этому моменту уже записана. С этой настройкой она всё равно распознаётся и попадает в историю диктовок, откуда её можно скопировать. Пригодится, если Escape нажимается случайно или если вы передумали в последний момент, а сказанное жалко. Выключено по умолчанию: Escape означает «не надо», и сохранять вопреки этому мы не станем без вашего согласия. История и её срок хранения настраиваются ниже.",
                             .en: "Escape cancels the insertion, but by then your speech is already recorded. With this on it is still recognised and lands in the dictation history, where you can copy it from. Useful if Escape gets pressed by accident, or if you changed your mind at the last moment and the words were worth keeping. Off by default: Escape means “no”, and we will not save against that without your say-so. The history and how long it is kept are configured below."],
        "voice.escSaved": [.ru: "Отменено, но сохранено в историю", .en: "Cancelled, but saved to history"],
        "voice.warm":     [.ru: "Мгновенный старт (тёплый микрофон)", .en: "Instant start (warm mic)"],
        // Было «Мгновенный повтор. Оранжевая точка записи горит, пока окно тёплое» — жаргон
        // («окно тёплое») и главное не сказано: микрофон ОСТАЁТСЯ ВКЛЮЧЁННЫМ какое-то время после
        // диктовки. Замечание автора 29.07. Про оранжевую точку — в подсказку «i» (шаг 6), она важна
        // как сигнал приватности, но в одну строку вместе с сутью не помещается.
        "voice.warmSub":  [.ru: "Микрофон остаётся включённым после диктовки, чтобы следующая началась сразу",
                           .en: "The mic stays on after you finish, so the next dictation starts instantly"],
        "voice.warmDur":  [.ru: "Окно прогрева", .en: "Warm window"],
        // Регистр не задаём: sectionTitle сам поднимает через eyebrowLabel(t.uppercased()).
        "voice.grpMic":       [.ru: "Микрофон", .en: "Microphone"],
        "voice.grpDictation": [.ru: "Диктовка", .en: "Dictation"],
        "voice.grpHistory":   [.ru: "История", .en: "History"],
        "voice.outputGroup": [.ru: "Как вставлять текст", .en: "How the text is inserted"],
        "voice.outputOpen":  [.ru: "Настроить", .en: "Configure"],
        "voice.othersN":     [.ru: "Показать все модели (%d)", .en: "Show all models (%d)"],
        "voice.outputHelp":  [.ru: "Эти правила применяются к УЖЕ распознанному тексту, поэтому работают одинаково на любой модели: сменив Parakeet на Whisper, вы получите тот же результат. Всё, что настраивается внутри самой модели, живёт в разделе «Модель распознавания».",
                              .en: "These rules apply to the FINISHED text, so they behave the same on every model: switching Parakeet for Whisper changes nothing here. Anything tuned inside the model itself lives under «Recognition model»."],
        // Сводка в строке: человек видит текущее состояние, не раскрывая группу.
        "voice.sumDefault":  [.ru: "Как распознала модель", .en: "As the model produced it"],
        "voice.sumNoCap":    [.ru: "без заглавной", .en: "no capital"],
        "voice.sumNoDot":    [.ru: "без точки", .en: "no period"],
        "voice.sumEnter":    [.ru: "с отправкой", .en: "auto-send"],
        "voice.sumNoSpace":  [.ru: "без пробела", .en: "no space"],
        // Подсказки «i». Пишем ТО, ЧЕГО НЕТ в подписи: подпись это тизер, подсказка это ответ.
        "voice.soundHelp":   [.ru: "Два коротких сигнала: один в начале записи, другой в конце. Нужны, чтобы не гадать, слушает вас Keyboop или уже нет, особенно когда индикатор скрыт. Громкость настраивается строкой ниже, а ноль на ползунке выключает сигнал совсем.",
                              .en: "Two short cues: one when recording starts, one when it stops. They exist so you never have to guess whether Keyboop is still listening, especially with the indicator hidden. Volume is the row below, and zero turns the cue off entirely."],
        "voice.warmHelp":    [.ru: "После диктовки микрофон не выключается сразу, а ждёт заданное время. Следующая диктовка в этом окне начинается мгновенно, без паузы на запуск устройства. Пока микрофон включён, macOS показывает оранжевую точку в строке меню — это системный индикатор, а не наш: он горит у любого приложения с открытым микрофоном.",
                              .en: "After you finish, the mic stays on for the time you set instead of shutting down. The next dictation within that window starts instantly, with no device warm-up. While the mic is on, macOS shows an orange dot in the menu bar. That indicator is the system's, not ours: it appears for any app holding the microphone open."],
        "voice.escHelp":     [.ru: "Escape во время записи обрывает её, и ничего не вставляется — сказанное просто пропадает. Выключите, если Escape нужен самой программе, в которой вы диктуете: тогда он уйдёт туда, а диктовку останавливайте тем же сочетанием, которым начали.",
                              .en: "Escape during recording drops it and inserts nothing — what you said is discarded. Turn it off if the app you dictate into needs Escape itself: it will pass through, and you stop dictation with the same shortcut you started it with."],
        "voice.streamHelp":  [.ru: "Распознанное показывается прямо на плашке «Слушаю», пока вы говорите, а в документ вставляется один раз, в конце. Печатать по ходу речи мы намеренно не стали: модель переписывает уже сказанное, когда понимает фразу лучше, и в чужом тексте это выглядело бы как буквы, которые сами себя стирают. Работает только с движком Parakeet и требует отдельной небольшой модели.",
                              .en: "What is recognised shows up right on the “Listening” panel while you speak, and goes into your document once, at the end. We deliberately do not type as you go: the model rewrites what it already said once it understands the phrase better, and inside your own text that would look like letters erasing themselves. Works only with the Parakeet engine and needs a separate small model."],

        "voice.outputGroupNote": [.ru: "Эти правила применяются к уже распознанному тексту, поэтому работают одинаково на любой модели.",
                                  .en: "These rules apply to the finished text, so they work the same on every model."],
        "voice.noCapital":[.ru: "Не начинать с заглавной", .en: "No leading capital"],
        "voice.noCapitalSub": [.ru: "Удобно, когда диктуете в середину уже начатого предложения. Аббревиатуры вроде «МФЦ» не трогаем",
                               .en: "Handy when you dictate into the middle of a sentence. Acronyms like «NASA» are left alone"],
        "voice.noPeriod": [.ru: "Не ставить точку в конце", .en: "No trailing period"],
        "voice.noPeriodSub": [.ru: "Для мессенджеров и полей поиска, где точка в конце лишняя. Вопрос, восклицание и многоточие остаются",
                              .en: "For chats and search fields where a final period is noise. Question marks, exclamations and ellipses stay"],
        "voice.autoEnter": [.ru: "Отправлять сразу", .en: "Send right away"],
        "voice.autoEnterKey": [.ru: "Чем отправлять", .en: "Send with"],
        "voice.autoEnterSub": [.ru: "После вставки нажимается Enter. Для чатов; в текстовом редакторе это будет перенос строки, а не отправка",
                               .en: "Enter is pressed after the insert. Meant for chats; in a text editor it will be a line break, not a send"],
        "voice.trailSpace": [.ru: "Пробел после вставки", .en: "Space after the insert"],
        "voice.trailSpaceSub": [.ru: "Чтобы следующая фраза не слиплась с этой. В поле поиска бывает лишним",
                                .en: "So the next phrase does not stick to this one. In a search field it can be excess"],
        "voice.sound":    [.ru: "Звук записи", .en: "Recording sound"],
        "voice.soundSub": [.ru: "Короткий сигнал в начале и в конце записи",
                          .en: "A short cue when recording starts and stops"],
        "voice.soundVol": [.ru: "Громкость звука", .en: "Sound volume"],
        "voice.streaming":   [.ru: "Потоковый набор — очень экспериментально",
                              .en: "Streaming dictation — very experimental"],
        "voice.streamingSub": [.ru: "Показывает речь на плашке, пока вы говорите",
                          .en: "Shows your speech on the panel as you talk"],
        // Условие, о котором тумблер раньше молчал: на whisper он включался и не делал НИЧЕГО.
        "voice.streamNeedsPk":[.ru: "Нужен движок Parakeet — выберите его в списке моделей выше",
                               .en: "Needs the Parakeet engine — pick it in the model list above"],
        "voice.streamDlTitle":[.ru: "Скачать модель потокового набора?",
                               .en: "Download the streaming dictation model?"],
        "voice.streamDlSub": [.ru: "Это отдельная модель (~120 МБ), едет один раз. Без неё потоковый набор не заведётся — пока качается, диктовка работает по-старому.",
                              .en: "It's a separate model (~120 MB), downloaded once. Streaming won't run without it — meanwhile dictation works the old way."],
        "voice.streamDlGo":  [.ru: "Скачать", .en: "Download"],
        "voice.streamDlOk":  [.ru: "Готово — потоковый набор включён. Нажми хоткей диктовки и говори.",
                              .en: "Done — streaming dictation is on. Press the dictation hotkey and talk."],
        "voice.streamDlFail":[.ru: "Не вышло скачать модель. Проверь сеть и попробуй ещё раз.",
                              .en: "Couldn't download the model. Check your connection and try again."],
        // ⚠️ Было «Хранить историю» — ДОСЛОВНО как voice.history строкой ниже по разделу, и обе
        // строки стояли в одной карточке. Два разных контрола с одинаковым заголовком: тумблер
        // «хранить или нет» и выпадающий «сколько хранить». Найдено дизайн-разбором 28.07.
        "voice.retention":[.ru: "Срок хранения", .en: "Keep for"],
        "voice.ret3":     [.ru: "3 дня", .en: "3 days"],
        "voice.ret7":     [.ru: "7 дней", .en: "7 days"],
        "voice.ret30":    [.ru: "30 дней", .en: "30 days"],
        "voice.retForever":[.ru: "Без удаления", .en: "Forever"],
        "sound.keyboop":  [.ru: "Keyboop", .en: "Keyboop"],
        "voice.log":      [.ru: "Системный лог", .en: "System log"],
        "voice.logHint":  [.ru: "Если диктовка вдруг не сработала — открой лог (локальный, без текста распознавания) и пришли его на hi@keyboop.com.",
                           .en: "If dictation ever misfires — open the log (local, without recognized text) and send it to hi@keyboop.com."],
        "voice.securePwd": [.ru: "Поле пароля — печатать не буду. Текст сохранён в истории.",
                            .en: "Password field — won't type here. Your text is saved to history."],
        "voice.deadBundle": [.ru: "Файлы Keyboop изменились на диске — перезапусти приложение, и микрофон вернётся.",
                             .en: "Keyboop's files changed on disk — relaunch the app to get the mic back."],
        "voice.deadMic":  [.ru: "Микрофон отдаёт тишину. Загляни в Настройки → Звук → Вход.",
                           .en: "The microphone yields silence. Check System Settings → Sound → Input."],
        "voice.stuck":    [.ru: "Распознавание застряло — бросил. Попробуй ещё раз.",
                           .en: "Recognition got stuck — dropped it. Try again."],
        "voice.intelNote": [.ru: "Intel-Mac: распознавание идёт на процессоре — медленнее, чем на M-серии, и греет. Для быстрого отклика выбирай модели small или base. Parakeet требует Neural Engine и на Intel недоступен.",
                            .en: "Intel Mac: recognition runs on the CPU — slower than on M-series, and warm. For snappy response pick the small or base models. Parakeet needs the Neural Engine and isn't available on Intel."],
        "voice.dlStalledShort": [.ru: "застряло…", .en: "stalled…"],
        "voice.dlStalledTip":   [.ru: "Скачивание замерло на %d%% — сеть до Hugging Face бывает капризной. Перезапусти Keyboop и нажми «Скачать» ещё раз: продолжит с того же места.",
                                 .en: "The download froze at %d%% — the connection to Hugging Face can be moody. Relaunch Keyboop and hit Download again: it resumes where it left off."],
        "voice.lang":     [.ru: "Язык распознавания", .en: "Recognition language"],
        "voice.langAuto": [.ru: "Авто (по речи)", .en: "Auto (detect)"],
        // ⚠️ ПОДПИСЬ СУЖЕНА ПО ИТОГАМ ИССЛЕДОВАНИЯ ДВИЖКОВ (03.08.2026).
        // Раньше здесь стояло «„Авто“ понимает смешанную речь», и это обещало больше, чем движки
        // умеют: на смешанной речи Parakeet как раз и ломается, записывая английские слова
        // кириллицей («Дидю коммит энд пуш»). Обещать то, что не выполняется, хуже, чем молчать.
        "voice.langSub":  [.ru: "Выберите язык, если диктуете на одном",
                           .en: "Pick a language if you dictate in just one"],
        "voice.langHelp": [.ru: "«Авто» определяет язык по самой речи. Выбирать конкретный стоит, если вы диктуете на нём одном, и это заметно надёжнее: у Parakeet один общий словарь на 25 языков, и, решив что речь русская, он записывает кириллицей даже английские слова, отчего «Did you commit and push» превращается в «Дидю коммит энд пуш». Выбранный язык такую подмену отсекает.\n\nЧестная оговорка про Parakeet: сам язык распознавания ему задать нельзя, это ограничение модели, а не настройки. Выбор здесь задаёт письменность, которой можно писать, а не язык, который надо услышать. У Whisper выбор работает как обычно, целиком.",
                           .en: "“Auto” picks the language from the speech itself. Choosing a specific one helps if you dictate in that language only, and it is noticeably more reliable: Parakeet has a single shared vocabulary for 25 languages, so once it decides the speech is Russian it writes even English words in Cyrillic, turning “Did you commit and push” into a phonetic transliteration. A chosen language cuts that off.\n\nAn honest caveat about Parakeet: you cannot tell the model which language to expect, that is a limit of the model and not of this setting. Here the choice constrains the script it may write in, not the language it must hear. With Whisper the choice works fully, as usual."],
        "voice.model":    [.ru: "Модель распознавания", .en: "Recognition model"],
        "voice.engine":   [.ru: "Движок распознавания", .en: "Recognition engine"],
        "voice.soon":     [.ru: "Скоро", .en: "Soon"],
        "voice.pkName":   [.ru: "Parakeet v3", .en: "Parakeet v3"],
        "voice.pkMeta":   [.ru: "~465 МБ  ·  Apple Neural Engine, быстрее всех", .en: "~465 MB  ·  Apple Neural Engine, fastest"],
        "voice.pkDesc":   [.ru: "Neural Engine — быстрее всех, текст почти сразу. Пунктуацию иногда ставит вольно.", .en: "Neural Engine — fastest, text almost instantly. Punctuation can get a little loose."],
        "voice.pkDownload":[.ru: "Скачать", .en: "Download"],
        "voice.pkReady":  [.ru: "Модель загружена ✓", .en: "Model ready ✓"],
        "voice.engineNow":[.ru: "Сейчас активен", .en: "Currently active"],
        "voice.pkNote":   [.ru: "Распознавание на Apple Neural Engine — самое быстрое, текст появляется почти сразу, легко по памяти, всё локально. Иногда вольно расставляет знаки препинания: если пунктуация важнее скорости — попробуй Whisper Turbo (он на 1–4 с медленнее). Модель качается один раз, по кнопке.",
                           .en: "Recognition on the Apple Neural Engine — the fastest, text shows up almost instantly, light on memory, all local. Punctuation can get a little loose: if punctuation matters more than speed, try Whisper Turbo (1–4 s slower). The model downloads once, on tap."],
        "voice.installed":[.ru: "установлена", .en: "installed"],
        "voice.download": [.ru: "Скачать", .en: "Download"],
        "voice.use":      [.ru: "Использовать", .en: "Use"],
        "voice.active":   [.ru: "используется", .en: "in use"],
        "voice.modelsTitle":[.ru: "Модель распознавания", .en: "Recognition model"],
        "voice.modelsNote":[.ru: "Parakeet — за скорость (Neural Engine, почти мгновенно), Whisper Turbo — за чистоту пунктуации и связность (на 1–4 с медленнее). Скачай любую, активируй одну; ненужные удали, чтобы не занимали место.",
                            .en: "Parakeet for speed (Neural Engine, near-instant), Whisper Turbo for cleaner punctuation and phrasing (1–4 s slower). Download any, activate one; delete the ones you don't need to free space."],
        "voice.delete":   [.ru: "Удалить", .en: "Delete"],
        "voice.deleting": [.ru: "Удаляю…", .en: "Deleting…"],
        "voice.delConfirm":[.ru: "Удалить модель «%@»?", .en: "Delete the “%@” model?"],
        "voice.delConfirmSub":[.ru: "Файлы модели удалятся с диска. Скачать заново можно в любой момент.",
                               .en: "The model files will be removed from disk. You can download it again anytime."],
        "common.cancel":  [.ru: "Отмена", .en: "Cancel"],
        "single.title":   [.ru: "Keyboop уже работает", .en: "Keyboop is already running"],
        "single.sub":     [.ru: "Одного зверька достаточно — он уже сидит в строке меню. Вторая копия только дралась бы за клавиши, так что эту я закрою.",
                           .en: "One critter is plenty — it's already up in the menu bar. A second copy would just fight over your keys, so I'll close this one."],
        "gen.silent":     [.ru: "Звуки", .en: "Sounds"],
        "gen.silentSub":  [.ru: "Выключите — и приложение замолчит целиком: переключение, перевод, диктовка и служебные сигналы. Громкости запомнятся",
                           .en: "Turn it off and the app goes completely silent: switching, translation, dictation and system beeps. Volumes are remembered"],
        "upd.title":      [.ru: "Обновления", .en: "Updates"],
        "upd.sub":        [.ru: "Keyboop сам находит новые версии — всегда свежий.", .en: "Keyboop finds new versions on its own — always current."],
        "upd.check2":     [.ru: "Проверять обновления", .en: "Check for updates"],
        "upd.check2Sub":  [.ru: "Скачивает новые версии в фоне; перед установкой спросим",
                           .en: "Downloads new versions in the background; we'll ask before installing"],
        "upd.silent":     [.ru: "Ставить сразу, без вопросов", .en: "Install right away, no questions"],
        "upd.silentSub":  [.ru: "Тихо ставит в простое, когда ты отошёл — не дёргая вопросом",
                           .en: "Installs quietly while you're away, without asking"],
        "upd.beta":       [.ru: "Ставить бета-версии", .en: "Install beta versions"],
        "upd.betaSub":    [.ru: "Свежие сборки раньше всех, ещё до обкатки",
                           .en: "New builds before everyone else, straight off the bench"],
        // Подсказки «i» вне раздела «Голос». Пишем то, чего НЕТ в подписи.
        "upd.check2Help": [.ru: "Keyboop раз в сутки спрашивает сайт, нет ли версии новее, и качает её в фоне. Запрос отправляет ровно то же, что любой заход на сайт: ваш IP и номер версии. Ничего о наборе, речи или том, как вы пользуетесь программой, не уходит.",
                           .en: "Once a day Keyboop asks the site whether a newer version exists and downloads it in the background. The request sends exactly what visiting a website sends: your IP and the version number. Nothing about your typing, speech or usage leaves the Mac."],
        "upd.silentHelp": [.ru: "Обычно мы спрашиваем перед установкой: программа читает клавиатуру, и молча подменять её у всех подряд неправильно. С этой настройкой обновление ставится само, но только когда вы отошли: не идёт диктовка, не качается модель, не открыто ни одно окно.",
                           .en: "Normally we ask before installing: this app reads your keyboard, and silently swapping it under everyone would be wrong. With this on it installs itself, but only while you are away: no dictation running, no model downloading, no window open."],
        "upd.betaHelp":   [.ru: "Бета это та же сборка, что получат все, только раньше. Обычно она лежит день-два, пока не станет ясно, что ничего не сломалось. Взамен вы иногда ловите свежие ошибки первым — о них очень помогает написать через «Сообщить о проблеме».",
                           .en: "A beta is the same build everyone will get, just earlier. It usually sits for a day or two until it is clear nothing broke. In exchange you sometimes hit fresh bugs first — reporting them via «Report a problem» helps a lot."],
        "switch.autoHelp": [.ru: "Keyboop следит за набранным словом и, если оно не могло быть набрано в текущей раскладке, переключает его сам. Работает в обе стороны, RU и EN. Если слово нужно оставить как есть, верните его как было, и Keyboop предложит запомнить исключение.",
                            .en: "Keyboop watches the word you are typing and, if it could not have been typed in the current layout, switches it. Works both ways, RU and EN. If a word should stay as is, type it back and Keyboop will offer to remember an exception."],
        "switch.liveHelp": [.ru: "Обычно слово чинится на границе, по пробелу или Enter. С этой настройкой оно чинится прямо посреди набора, как только сочетание букв стало невозможным в текущей раскладке. Замена происходит в тот же момент, когда вы нажимаете клавишу, поэтому следующий символ в неё не вклинивается.",
                            .en: "Normally a word is fixed at its boundary, on space or Enter. With this on it is fixed mid-word, as soon as the letter combination becomes impossible in the current layout. The replacement happens at the exact moment you press the key, so your next character cannot slip into it."],
        "switch.devHelp": [.ru: "В коде полно коротких сочетаний, которые выглядят как опечатка, но опечаткой не являются: имена переменных, флаги, команды. Режим оставляет их в покое — одиночные буквы и короткие сочетания не трогаются. В программах из списка исключений он не нужен, там правило и так отключено.",
                           .en: "Code is full of short sequences that look like typos but are not: variable names, flags, commands. This mode leaves them alone — single letters and short sequences are not touched. Apps on your exceptions list do not need it, the rule is already off there."],
        "switch.chatter":    [.ru: "Глотать дребезг клавиши", .en: "Swallow key chatter"],
        "switch.chatterSub": [.ru: "Одно нажатие, одна буква", .en: "One press, one letter"],
        "switch.chatterHelp": [.ru: "У изношенных клавиатур контакт иногда срабатывает дважды с одного нажатия, и в тексте появляется лишняя буква. Мы отбрасываем повтор той же клавиши, если он пришёл быстрее чем через 30 миллисекунд. Настоящие двойные буквы это не задевает: даже у быстрых машинисток на «сс» в «ссоре» уходит вдвое больше. Зажатую клавишу тоже не трогаем, автоповтор работает как обычно. Сочетания с ⌘, ⌃ и ⌥ проходят мимо фильтра целиком: пропущенная команда заметна сильнее, чем лишняя. Выключено по умолчанию, потому что это перехват ввода, а не исправление текста.",
                               .en: "On worn keyboards a contact sometimes fires twice from a single press, and an extra letter shows up. We drop a repeat of the same key if it arrives sooner than 30 milliseconds. Genuine double letters are untouched: even fast typists need twice that for the pair in “class”. Holding a key is unaffected too, autorepeat works as usual. Shortcuts with ⌘, ⌃ or ⌥ bypass the filter entirely: a command that never fired hurts more than one that fired twice. Off by default, because this intercepts your typing rather than correcting text."],
        "switch.twoCaps":    [.ru: "Две заглавные подряд", .en: "Two leading capitals"],
        "switch.twoCapsSub": [.ru: "«КОгда» превращается в «Когда»", .en: "“WHen” becomes “When”"],
        "switch.twoCapsHelp": [.ru: "Так выходит, когда Shift отпущен на миг позже, чем нажата вторая буква. Keyboop чинит только этот случай: ровно две первые буквы заглавные, третья строчная, и в слове одни буквы. Слова целиком заглавными, вроде ГОСТ или USB, а также короткие «ДА» и «ОК» не трогаются. Выключено по умолчанию, потому что это правка самого текста, а не раскладки.",
                              .en: "This happens when Shift is released a moment after the second letter is pressed. Keyboop fixes only that case: exactly the first two letters capital, the third lowercase, and nothing but letters in the word. All-caps words like USB, and short ones like OK, are left alone. Off by default, because this edits your text rather than its layout."],
        // ⚠️ КОРОТКО НАМЕРЕННО (автор, 04.08.2026). Первый вариант был вдвое длиннее: туда попало и
        // обучение на отмене, и почему не помогает стереть слово и набрать заново. Всё это правда, но
        // подсказка у строки отвечает на один вопрос — что делает ЭТА комбинация. Длинный текст в
        // маленьком поповере путает ровно того, кто уже не разобрался, а именно ради него он и писан.
        "switch.manualHelp": [.ru: "Переключает последнее набранное слово в другую раскладку, ждать пробела не нужно. Если Keyboop переключил слово сам и зря, эта же комбинация вернёт его как было. А когда ничего не набрано, просто меняется язык, как обычным переключателем раскладки.",
                              .en: "Flips the last word you typed into the other layout, no need to wait for a space. If Keyboop flipped a word by itself and got it wrong, the same combo puts it back. And when nothing is typed, it simply switches the language, like the system layout switcher."],
        "switch.arrowsHelp": [.ru: "Речь о четырёх клавишах курсора. Пока вы печатаете слово, Keyboop держит его в памяти, чтобы починить. Стрелка означает, что курсор уехал и слово, скорее всего, уже не то — поэтому память сбрасывается. Выключите, если часто двигаете курсор посреди слова и хотите, чтобы починка всё равно сработала.",
                              .en: "This is about the four cursor keys. While you type a word, Keyboop keeps it in memory so it can fix it. An arrow means the caret moved and the word is probably no longer the one you meant, so the memory is dropped. Turn this off if you often move the caret mid-word and still want the fix."],
        "hist.lockHelp":  [.ru: "Окно истории будет спрашивать пароль при каждом открытии. Сам пароль хранится в связке ключей macOS, а записи шифруются — мы их не видим и восстановить не сможем. Защита от того, кто сядет за ваш незаблокированный Mac, а не от кражи диска.",
                           .en: "The history window will ask for a password every time it opens. The password lives in the macOS keychain and the entries are encrypted — we cannot see them and cannot recover them. This guards against someone sitting down at your unlocked Mac, not against a stolen disk."],
        "is.enableHelp":  [.ru: "Обычная смена языка в macOS идёт с задержкой: система ждёт, не окажется ли нажатие началом сочетания. Мы перехватываем клавишу раньше и меняем язык сразу. Набранное при этом не трогаем — это именно смена раскладки, а не починка слова.",
                           .en: "Switching language in macOS has a delay: the system waits to see whether your press is the start of a combination. We intercept the key earlier and switch immediately. Nothing you typed is touched — this is a layout switch, not a word fix."],
        "upd.check":      [.ru: "Проверить сейчас", .en: "Check now"],
        // Кнопки плашки об апдейте. Обе ставят СРАЗУ, поэтому «сейчас» из левой убрано: оно
        // подразумевало, что правая поставит когда-нибудь потом, а она тоже ставит сейчас.
        "upd.now":        [.ru: "Обновить", .en: "Update"],
        "upd.auto":       [.ru: "Обновлять автоматически", .en: "Update automatically"],
        "upd.autoShort":  [.ru: "Обновлять автоматически", .en: "Update automatically"],
        "upd.notifyTitle":[.ru: "Keyboop %@ готов", .en: "Keyboop %@ is ready"],
        // ⚠️ Не длиннее двух строк: в плашке у подписи maximumNumberOfLines = 2, и длинный текст
        // обрывался на полуслове (видно на dev-рендере KEYBOOP_BANNERSHOT).
        "upd.notifyBody": [.ru: "Любая кнопка поставит сразу.",
                           .en: "Either button installs it now."],
        // Строка о сорванных проверках обновлений (жалоба 03.08.2026). Формулировка намеренно НЕ
        // обвиняет ни нас, ни человека: причина почти всегда снаружи (сеть, VPN, фильтр, антивирус,
        // запуск не из «Программ»), и наша задача сказать факт, а не поставить диагноз.
        "upd.problem":       [.ru: "Обновления не проверяются", .en: "Updates are not being checked"],
        "upd.problemUnknown":[.ru: "Последняя проверка не дошла до сервера. Обычно виноваты сеть, VPN, корпоративный фильтр или антивирус, а ещё запуск приложения не из папки «Программы».",
                              .en: "The last check never reached the server. Usually the network, a VPN, a corporate filter or antivirus is in the way, and sometimes it is the app running from outside the Applications folder."],
        "upd.problemReport": [.ru: "Сообщить", .en: "Report"],
        "upd.foot":       [.ru: "Проверка шлёт только твой IP и номер версии — как любой заход на сайт. Ничего из набранного.",
                           .en: "The check sends only your IP and version number — like any website visit. Nothing you type."],
        "upd.onboard":    [.ru: "Keyboop сам находит новые версии и спрашивает, ставить ли, — одной кнопкой. Что-то не так — напиши, починим.",
                           .en: "Keyboop finds new versions and asks to install with one tap. If something's off, write to us and we'll fix it."],
        "voice.history":  [.ru: "Хранить историю", .en: "Keep history"],
        "voice.historySub":[.ru: "Зашифровано, остаётся на этом Mac", .en: "Encrypted, stays on this Mac"],
        "voice.histClear":[.ru: "Очистить историю", .en: "Clear history"],
        "voice.showHistory":[.ru: "Показать историю…", .en: "Show history…"],
        "hist.title":     [.ru: "История голосового набора", .en: "Dictation history"],
        "hist.copy":      [.ru: "Скопировать", .en: "Copy"],
        "hist.hint":      [.ru: "Двойной клик по записи — скопировать.", .en: "Double-click an entry to copy."],
        "hist.search":    [.ru: "Поиск по истории", .en: "Search history"],
        "hist.empty":     [.ru: "Пока пусто. Зажми хоткей и продиктуй.", .en: "Empty so far. Hold the hotkey and dictate."],
        "hist.pin":       [.ru: "Поверх всех окон", .en: "Keep on top"],
        "hist.translucent":[.ru: "Полупрозрачность окна", .en: "Window translucency"],
        "hist.rec":       [.ru: "Записать", .en: "Record"],
        "hist.recStop":   [.ru: "Стоп", .en: "Stop"],
        "hist.del":       [.ru: "Удалить", .en: "Delete"],
        "hist.settings":  [.ru: "Настройки голосового набора", .en: "Voice settings"],
        "hist.lock.toggle":   [.ru: "Пароль на историю", .en: "History password"],
        "hist.lock.toggleSub": [.ru: "Спрошу пароль при открытии окна истории",
                          .en: "I will ask for a password when the history window opens"],
        "hist.lock.title":    [.ru: "История под паролем", .en: "History is locked"],
        "hist.lock.msg":      [.ru: "Введи пароль, чтобы открыть историю диктовок.", .en: "Enter the password to open your dictation history."],
        "hist.lock.open":     [.ru: "Открыть", .en: "Open"],
        "hist.lock.forgot":   [.ru: "Забыл пароль…", .en: "Forgot password…"],
        "hist.lock.wrong":    [.ru: "Не подошло. Попробуй ещё раз.", .en: "That's not it. Try again."],
        "hist.lock.forgot.title":  [.ru: "Пароль не восстановить", .en: "The password can't be recovered"],
        "hist.lock.forgot.confirm":[.ru: "Единственный выход — стереть историю и снять пароль. Записи не вернуть. Стереть?",
                                    .en: "The only way out is to erase the history and remove the password. Entries can't be brought back. Erase?"],
        "hist.lock.forgot.wipe":   [.ru: "Стереть и снять пароль", .en: "Erase and remove password"],
        "hist.lock.set.title":  [.ru: "Пароль на историю", .en: "History password"],
        "hist.lock.set.msg":    [.ru: "Будет запрашиваться при открытии окна истории. Восстановления нет — только стереть историю.",
                                 .en: "You'll be asked for it when opening the history window. There's no recovery — only erasing the history."],
        "hist.lock.set.ok":     [.ru: "Установить", .en: "Set"],
        "hist.lock.set.p1":     [.ru: "Пароль", .en: "Password"],
        "hist.lock.set.p2":     [.ru: "Ещё раз", .en: "Once more"],
        "hist.lock.set.short":  [.ru: "Хотя бы 4 символа.", .en: "At least 4 characters."],
        "hist.lock.set.mismatch":[.ru: "Пароли не совпали.", .en: "The passwords don't match."],
        "menu.report":    [.ru: "Сообщить о проблеме…", .en: "Report a problem…"],
        "fb.title":       [.ru: "Написать разработчику", .en: "Write to the developer"],
        "fb.placeholder": [.ru: "Что сломалось, что бесит, чего не хватает…", .en: "What broke, what annoys you, what's missing…"],
        "fb.contact":     [.ru: "Телеграм или почта — необязательно",
                           .en: "Telegram or email — optional"],
        // Мотивация оставить контакт. ⚠️ Обещание «напишу лично» убрано 30.07 по просьбе автора: он
        // отвечает не всем, а там, где это действительно нужно, и обещать личный ответ каждому —
        // значит расставлять ожидания, которые он не собирается выполнять. Осталась честная причина.
        "fb.contactWhy":  [.ru: "Без него я прочитаю, но ответить будет некуда.",
                           .en: "Without it I'll still read this, but I'll have nowhere to reply."],
        "fb.diag":        [.ru: "Приложить диагностику (версия, настройки, хвост лога)",
                           .en: "Attach diagnostics (version, settings, log tail)"],
        "fb.diagShow":    [.ru: "показать, что уйдёт", .en: "see what's sent"],
        "fb.diagTitle":   [.ru: "Что уйдёт вместе с отзывом", .en: "What goes along with your feedback"],
        "fb.hint":        [.ru: "Улетает на keyboop.com и разработчику в Telegram. Текст ввода и речь в диагностику не попадают — там только версии, настройки и служебный лог.",
                           .en: "Goes to keyboop.com and straight to the developer's Telegram. Your typing and speech never enter the diagnostics — only versions, settings and the service log."],
        "fb.send":        [.ru: "Отправить", .en: "Send"],
        "fb.sending":     [.ru: "Отправляю…", .en: "Sending…"],
        "fb.fail":        [.ru: "Сеть не отвечает. Можно почтой:", .en: "Network isn't answering. Email works:"],
        "fb.mail":        [.ru: "Отправить почтой", .en: "Send by email"],
        "fb.tg":          [.ru: "Через Telegram", .en: "Via Telegram"],
        "fb.tgTip":       [.ru: "Сохраним отчёт файлом и откроем чат с ботом. Вы увидите, что именно отправляете, и отправите сами",
                           .en: "Saves the report to a file and opens the bot chat. You see exactly what you are sending, and you send it yourself"],
        "fb.tgReady":     [.ru: "Файл в «Загрузках», перетащите его боту",
                           .en: "File is in Downloads, drop it to the bot"],
        "fb.tgSaved":     [.ru: "Отчёт сохранён в «Загрузки»", .en: "Report saved to Downloads"],
        "fb.tgHowTitle":  [.ru: "Отчёт готов, осталось отправить",
                           .en: "The report is ready, one step left"],
        // %@ — имя файла. Называем его прямо: в «Загрузках» у человека сотни файлов.
        "fb.tgHowBody":   [.ru: "Сейчас откроются два окна: чат с ботом Keyboop и папка «Загрузки», где уже лежит файл %@\n\n1. Перетащите этот файл в чат (или приложите скрепкой).\n2. Можно дописать пару слов о том, что случилось.\n3. Отправьте.\n\nНичего не уходит само: отчёт отправляете вы, и видите, что именно отправляете.",
                           .en: "Two windows are about to open: the Keyboop bot chat and your Downloads folder, where the file %@ is already waiting.\n\n1. Drag that file into the chat (or attach it with the paperclip).\n2. Add a couple of words about what happened, if you like.\n3. Send.\n\nNothing goes anywhere on its own: you send the report, and you see exactly what you send."],
        "fb.tgHowGo":     [.ru: "Открыть Telegram", .en: "Open Telegram"],
        "fb.tgHowCancel": [.ru: "Не сейчас", .en: "Not now"],
        "fb.tgFileFail":  [.ru: "Не получилось сохранить файл", .en: "Could not save the file"],
        "fb.doneTitle":   [.ru: "Улетело", .en: "Off it goes"],
        "fb.doneWithContact": [.ru: "Спасибо. Прочитаю всё до последней буквы, и если понадобится уточнить — напишу вам сам.",
                              .en: "Thank you. I'll read every word, and if I need details I'll get in touch."],
        "fb.doneNoContact":   [.ru: "Спасибо. Прочитаю всё до последней буквы. Контакта вы не оставили, так что ответить будет некуда — но на разбор это никак не влияет.",
                              .en: "Thank you. I'll read every word. You left no contact, so there's nowhere to reply — that doesn't affect anything else."],
        "fb.doneClose":   [.ru: "Закрыть", .en: "Close"],
        "fb.tooShort":    [.ru: "Напиши хоть пару слов )", .en: "Give me at least a couple of words )"],
        "menu.voiceHistory":[.ru: "История голосового набора…", .en: "Dictation history…"],
        "menu.copyLast":  [.ru: "Скопировать последнюю диктовку", .en: "Copy last dictation"],
        "voice.grpDuck":  [.ru: "Пока вы диктуете", .en: "While you dictate"],
        "voice.duck":     [.ru: "Приглушать звук на время диктовки", .en: "Turn the volume down while dictating"],
        "voice.duckSub":  [.ru: "Музыка и видео не будут перекрикивать", .en: "Music and video stop talking over you"],
        "voice.duckHelp": [.ru: "Пока идёт запись, громкость системы плавно убавляется, а после неё так же плавно возвращается на прежнее место. Если вы покрутите её сами во время диктовки, мы не станем спорить и оставим ваше значение. Паузу медиа мы намеренно не жмём: клавиша паузы уходит в то приложение, которое система считает главным, а когда открыты вкладка с видео, музыка и созвон, угадать это нельзя.",
                           .en: "While recording, the system volume fades down, and afterwards it fades back to where it was. If you change it yourself mid-dictation, we won't argue and will leave your value. We deliberately don't press pause: the pause key goes to whichever app the system considers primary, and with a video tab, music and a call all open, that is a coin toss."],
        "voice.duckLevel":[.ru: "Громкость во время диктовки", .en: "Volume while dictating"],
        "voice.duckMute": [.ru: "тишина", .en: "silent"],
        // Коротко: сначала что делает, потом потолок, потом шутка. Не расписывать (автор 30.07).
        "voice.duckLevelHelp": [.ru: "Во время диктовки громкость опустится до этого уровня, потом вернётся. Выше 77% не поднимается. Просто потому что.",
                                 .en: "While you dictate the volume drops to this level, then comes back. It will not go above 77%. Just because."],
        "voice.retentionSub": [.ru: "По нему же пропадает копирование из меню",
                               .en: "Also drops copy-from-menu"],
        "voice.retentionHelp": [.ru: "Через это время записи удаляются, и вместе с ними пропадает пункт «Скопировать последнюю диктовку» в меню: копировать ему становится нечего. Если диктуете подолгу и возвращаетесь к сказанному через час, ставьте срок побольше. «Не удалять» хранит последние 50 записей, пока вы сами их не сотрёте.",
                                .en: "After this time entries are deleted, and the menu item “Copy last dictation” goes with them: there is nothing left for it to copy. If you dictate over long sessions and come back to what you said an hour later, pick a longer period. “Keep” holds the last 50 entries until you erase them yourself."],
        "menu.copyLastDone": [.ru: "Скопировано", .en: "Copied"],
        // Редкий случай: срок хранения истёк между открытием меню и кликом. В остальных ситуациях
        // пункта в меню просто нет, поэтому объяснять «история выключена» здесь уже не нужно.
        "menu.copyLastEmpty": [.ru: "Последняя диктовка уже удалена по сроку хранения",
                               .en: "The last dictation is gone, its retention time ran out"],
        "voice.foot":     [.ru: "Аудио и распознавание не покидают Mac. История шифруется и остаётся только у вас.",
                           .en: "Audio and recognition never leave the Mac. History is encrypted and stays only on this device."],
        "voice.hkRopt":   [.ru: "Правый ⌥  (right Option)", .en: "Right ⌥  (right Option)"],
        "voice.hkRcmd":   [.ru: "Правый ⌘  (right Command)", .en: "Right ⌘  (right Command)"],
        "voice.hkTilde":  [.ru: "⌥`  (Option + ё/`)", .en: "⌥`  (Option + backtick)"],
        "voice.mic":      [.ru: "Микрофон", .en: "Microphone"],
        "voice.micSystem":[.ru: "По умолчанию (система)", .en: "Default (system)"],
        // ⚠️ Было «Открыть настройки звука…», и это читалось как наш собственный звук записи,
        // стоявший парой строк ниже. На деле кнопка открывает СИСТЕМНУЮ панель, то есть уровень
        // входа микрофона. Слово «звук» убрано, коллизия исчезает вместе с ним.
        "voice.micSettings":[.ru: "Уровень входа в настройках macOS…", .en: "Input level in macOS Settings…"],

        "exp.groupConvert":   [.ru: "Переключать несколько слов", .en: "Convert multiple words"],
        "exp.groupConvertSub":[.ru: "Хоткеем чинит сразу всю набранную фразу, а не одно слово.",
                               .en: "One hotkey fixes the whole typed phrase, not just one word."],
        "exp.groupConvertAutoOff":[.ru: "Доступно при выключенном авто-переключении — иначе оно само чинит на лету.",
                                   .en: "Available when auto-switch is off — otherwise it fixes things on the fly."],
        "exp.title":          [.ru: "Эксперименты", .en: "Experimental"],

        // Заголовок меню теперь строится в коде из версии (MenuBarController), слоган убран.
        "menu.autoOff":   [.ru: "авто выкл", .en: "auto off"],
        "menu.auto":      [.ru: "Авто-переключение", .en: "Auto-switch"],
        "menu.checkUpdates": [.ru: "Проверить обновления…", .en: "Check for Updates…"],
        "menu.settings":  [.ru: "Настройки…", .en: "Settings…"],
        "menu.quit":      [.ru: "Выйти", .en: "Quit"],
        // Без «⚠︎» в тексте: с 30.07 у пункта есть цветной значок-треугольник (MenuBarController.icon).
        // ⚠️ ДВА РАЗНЫХ ПУНКТА ВМЕСТО ОДНОГО (репорт #71). Раньше здесь был единственный
        // «Нужен доступ (Accessibility)…», и человеку с выданным Accessibility он врал в лицо.
        // Названия совпадают с тем, как разделы называются в системных Настройках, чтобы человек
        // искал глазами ровно ту строчку, которую прочитал у нас.
        "menu.permInput": [.ru: "Нужен доступ: Мониторинг ввода…", .en: "Needs access: Input Monitoring…"],
        "menu.permAX":    [.ru: "Нужен доступ: Универсальный доступ…", .en: "Needs access: Accessibility…"],
        "menu.permMove":  [.ru: "…и перенесите Keyboop в «Программы»", .en: "…and move Keyboop to Applications"],
        // ⚠️ menu.perm оставлен НАМЕРЕННО, хотя меню его больше не зовёт: ключи локализации живут
        // дольше кода, и удалить строку дешевле, чем однажды обнаружить пустой пункт меню у того,
        // у кого сборка старше словаря. Если через пару релизов он так и не понадобится — убрать.
        "menu.perm":      [.ru: "Нужен доступ (Accessibility)…", .en: "Needs access (Accessibility)…"],
        "menu.switchWord":[.ru: "Переключить слово:  %@", .en: "Switch word:  %@"],
        "menu.mic":       [.ru: "Микрофон", .en: "Microphone"],
        "menu.micDefault":[.ru: "По умолчанию (система)", .en: "Default (system)"],
        "menu.quitConfirm":[.ru: "Выйти из Keyboop?", .en: "Quit Keyboop?"],
        "menu.quitBody":  [.ru: "Тогда раскладка снова на тебе: авто-переключение и голосовой ввод отключатся, пока не запустишь Keyboop заново.",
                           .en: "Then the layout is on you again — auto-switch and dictation turn off until you launch Keyboop next time."],
        "menu.stay":      [.ru: "Остаться", .en: "Stay"],

        // About — развёрнутое описание (что это, что умеет, нюансы)
        "about.whatTitle":[.ru: "Что это", .en: "What it is"],
        "about.what":     [.ru: "Keyboop сам исправляет неверную раскладку: напечатал «ghbdtn» — молча стало «привет». Двусторонне, RU↔EN, по словарю и контексту. Не угадал — поправь сам хоткеем %@.",
                           .en: "Keyboop fixes the wrong layout for you: type “ghbdtn” and it quietly becomes “привет”. Both ways, RU↔EN, by dictionary and context. Missed one? Fix it yourself with %@."],
        "about.canTitle": [.ru: "Что умеет", .en: "What it can do"],
        "about.can":      [.ru: "• Авто-переключение раскладки на пробеле/Enter/Tab.\n• Ручной хоткей %@ — переключить последнее слово (или просто язык, если ничего не набрано).\n• Голосовой набор: проговорил по хоткею — текст на месте (локально, без интернета).\n• Автозамена: сокращение → фраза (раскладка и регистр не важны).\n• Исключения: программы, где переключать не нужно.",
                           .en: "• Auto-switch layout on space/Enter/Tab.\n• Manual %@ — switch the last word (or just the language if nothing’s typed).\n• Voice typing: press the hotkey and speak — text appears (local, no internet).\n• Snippets: shortcut → phrase (layout and case don’t matter).\n• Exceptions: apps where switching isn’t wanted."],
        "about.nuanceTitle":[.ru: "Нюансы", .en: "Good to know"],
        "about.nuance":   [.ru: "Работает в фоне (значок у часов). При исправлении слов не трогает буфер обмена — печатает символы напрямую. Из твоего ввода и голоса наружу не уходит ничего; в сеть — только за моделями и обновлениями. Нужен доступ к «Универсальному доступу» (Accessibility), чтобы видеть и исправлять ввод.",
                           .en: "Runs in the background (menu-bar icon). Doesn’t touch the clipboard when fixing words — it types characters directly. Nothing from your input or voice ever leaves the Mac; the network is used only for models and updates. Needs Accessibility access to see and fix input."]
    ]
}
