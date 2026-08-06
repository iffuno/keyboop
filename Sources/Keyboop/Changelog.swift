import Foundation

/// Журнал изменений для пользователя («Что нового»). Дописывать сверху при заметных правках.
/// Кратко, в нашем тоне — не дев-журнал.
enum Changelog {
    /// `announce` / `announceEnd` — личные вступление и концовка ТОЛЬКО для анонса в Telegram: в окне
    /// «Что нового» они не показываются. Раньше анонс был дословно списком изменений
    /// (announce-telegram.sh берёт верхнюю запись отсюда), и живому «сижу ночами и чиню» просто негде
    /// было находиться: в приложении оно неуместно, а второго источника не было. Порядок в посте:
    /// announce → список изменений → announceEnd. Пусто — анонс уходит как раньше, одним списком.
    struct Release {
        let version: String
        let ru: [String]
        let en: [String]
        var announce: String? = nil
        var announceEnd: String? = nil
    }

    /// ИМЕНА ВЕРСИЙ (решение автора 30.07). Как macOS называет релизы местами в Калифорнии, так мы
    /// называем их мелкими безобидными зверями — той же породы, что наш маскот. Имя привязано к
    /// ДЕСЯТКУ, а не к патчу: все 0.3.x живут под именем Pika, меняется оно семь раз за всю дорогу
    /// до 1.0. Каждое имя проверено на непересечение с Ubuntu: у них двадцать лет на этой теме,
    /// и Quokka с Numbat заняты их свежими релизами, а Pangolin, Meerkat, Koala и Narwhal — старыми.
    ///
    /// Не переводить: имя одинаковое во всех языках интерфейса, как Sonoma или Sequoia.
    /// Незнакомая версия (например будущая 1.1) вернёт nil — шапка меню просто покажет номер.
    private static let codenames: [String: String] = [
        "0.3": "Pika",        // пищуха: пискнула один раз и спряталась — собственно, звук «буп»
        "0.4": "Axolotl",     // аксолотль: всегда улыбается и отращивает обратно потерянное
        "0.5": "Kinkajou",    // кинкажу: ночной, язык 12 см, интересуется только мёдом
        "0.6": "Binturong",   // бинтуронг: пахнет попкорном, и это правда
        "0.7": "Kakapo",      // какапо: нелетающий попугай, при опасности замирает и ждёт
        "0.8": "Olinguito",   // олингито: сто лет лежал в музеях под чужим именем — зверь с не той раскладкой
        "0.9": "Aye-aye",     // ай-ай: стучит по дереву одним длинным пальцем, буквально бупает
        "1.0": "Capybara",    // капибара: ничего не делает и всем нравится, потому что уже всё работает
    ]

    /// Имя релиза по номеру версии («0.3.1» → «Pika»). nil, если имени для десятка нет.
    /// Суффиксы третьего разряда не мешают: «0.3.2-dev» тоже даёт «Pika», потому что смотрим десяток.
    static func codename(for version: String) -> String? {
        let p = version.split(separator: ".")
        guard p.count >= 2 else { return nil }
        return codenames["\(p[0]).\(p[1])"]
    }

    /// «0.3.2 · Pika» — версия вместе с именем. ЕДИНЫЙ формат для всех мест, где мы показываем версию:
    /// шапка меню, низ левого списка настроек, «О программе». Через один помощник, чтобы разделитель и
    /// порядок не разъехались по трём файлам. Имени для десятка нет — вернётся просто номер.
    static func versionWithName(_ version: String) -> String {
        codename(for: version).map { "\(version) · \($0)" } ?? version
    }

    static let releases: [Release] = [
        // 0.3.15 — БЕТА. Две новые функции (сниппеты по сочетанию и быстрое действие правым
        // кликом) плюс проверка занятости сочетаний, выросшая из вопроса «а не занято ли ⌃⌥V».
        Release(version: "0.3.15",
            ru: [
                "Сниппеты стали отдельным списком и вставляются по сочетанию. Автозамена срабатывает сама по аббревиатуре, а эти вставляются осознанно: нажали сочетание, увидели список, выбрали цифрой или мышью. Сюда просится то, что на аббревиатуру вешать страшно: длинные команды, реквизиты, шаблоны писем.",
                "У значка в строке меню появилось быстрое действие по правому клику. Левый по-прежнему открывает меню, правый сразу делает выбранное: копирует последнюю диктовку, начинает диктовку, открывает историю или настройки.",
                "Keyboop можно попросить помолчать. Пауза на 15 минут, час, три или пять часов: всё это время он не трогает ни текст, ни сочетания, а потом возвращается к работе сам. Тем и отличается от выключенного тумблера, про который забывают на неделю.",
                "При назначении сочетания видно, если оно уже занято. Критичные вроде ⌘C и ⌘V не отдадим никогда, а про системные функции macOS предупредим и всё равно дадим назначить: это ваш Mac и ваш выбор.",
                "Две настройки назвали понятнее. «Исправлять слово после пробела» стало «Автоматическое исправление раскладки», а «Менять раскладку своей клавишей» стало «Менять раскладку без задержки». Со второй заодно снята пометка «бета».",
                "Сообщение «Скопировано» выглядит как остальные плашки. Раньше текст в нём был выкрашен в чужой зелёный цвет.",
            ],
            en: [
                "Snippets are a separate list now and get inserted by a shortcut. Autoreplace fires by itself on an abbreviation; these are inserted deliberately: press the shortcut, see the list, pick with a digit or the mouse. This is the place for what you would rather not bind to an abbreviation: long commands, bank details, letter templates.",
                "The menu bar icon gained a quick action on right click. Left click still opens the menu, right click does the chosen thing at once: copies the last dictation, starts dictation, opens the history or the settings.",
                "You can ask Keyboop to keep quiet. A pause for 15 minutes, an hour, three or five: it touches neither text nor shortcuts for that long, then comes back on its own. That is what makes it different from a switch you turn off and forget for a week.",
                "Assigning a shortcut now shows when it is already taken. Critical ones like ⌘C and ⌘V we will never give away, and about macOS system functions we warn but still let you assign: it is your Mac and your call.",
                "Two settings got clearer names. «Fix the word after a space» became «Automatic layout correction», and «Change layout with your own key» became «Change layout without the delay». The latter also dropped its «beta» tag.",
                "The «Copied» message looks like the rest of the panels. Its text used to be painted in a stray green.",
            ],
            announce: """
                Длинный ровный день за кодом, без съёмок и без пожаров. Такие я люблю больше всего: \
                садишься утром, а к вечеру в приложении две новые функции.
                """,
announceEnd: """
                Приедет тем, у кого включены бета-версии. Остальным как обкатается.

                Спасибо всем, кто заходит на keyboop.com/tips. И если приложение пригодилось, \
                поставьте звезду на GitHub: это ускоряет попадание в Homebrew, а по-человечески \
                приятно видеть, что нас не двое.
                """),

        // 0.3.14 — БЕТА. Четыре правки, и ни одна не была той задачей, за которую садились: клик с
        // модификатором вылез из проверки чужой просьбы, Spotlight из слияния дублей, а имя раскладки
        // «U.S.» из трассировки совсем другой починки.
        Release(version: "0.3.14",
            ru: [
                "Клик мышью с зажатым модификатором больше не переключает язык. Если на переключение назначен одиночный модификатор (правый ⌘, ⌥, ⌃, Caps Lock или 🌐), то ⌘-клик по ссылке или ⌥-клик читались как чистое нажатие. Раскладка менялась сама по себе несколько раз в день, и связать это с мышью было невозможно: мы слушали только клавиатуру.",
                "В Spotlight больше не портится запрос. Его подсказка дополняет строку выделенным хвостом, и наш первый Backspace гасил выделение вместо буквы, из-за чего «ghjdthrf» превращалось в «gпров». Заодно к Spotlight наконец применяются его собственные настройки: по ⌘Space система не считает его активной программой, поэтому ни привязка языка, ни исключения для него не работали никогда.",
                "Значок языка в строке меню перестал угадывать. Английская раскладка записана в системе как «U.S.», и мы разбирали это имя неправильно. Про русский индикатор отвечал честно, а про английский показывал последнее, что запомнил, и потому отставал от реальности.",
                "Если система не применила переключение, приложение это заметит. Раньше команда считалась выполненной по факту отправки, и дальше мы верили себе, даже когда раскладка осталась прежней. Теперь результат сверяется, и одна поправка делается сама.",
            ],
            en: [
                "Clicking the mouse with a modifier held no longer switches the language. When switching is bound to a single modifier (right ⌘, ⌥, ⌃, Caps Lock or 🌐), a ⌘-click on a link or an ⌥-click read as a clean tap. The layout changed by itself several times a day, and nobody could connect it to the mouse: we were listening to the keyboard only.",
                "Spotlight queries no longer get mangled. Its suggestion completes the line with a selected tail, so our first Backspace killed the selection instead of a character and «ghjdthrf» became «gпров». Spotlight also finally obeys its own settings: on ⌘Space the system does not treat it as the frontmost app, so neither the forced layout nor the exceptions ever applied to it.",
                "The language badge in the menu bar stopped guessing. The English layout is stored in the system as “U.S.”, and we parsed that name wrongly. The badge was honest about Russian and showed the last thing it remembered about English, so it lagged behind reality.",
                "If the system does not apply a layout switch, the app notices. The command used to count as done the moment it was sent, and we kept trusting ourselves even when the layout had not changed. The result is now verified, and a single correction happens automatically.",
            ],
            announce: """
                Второе обновление за сегодня. День вышел плотный: с утра немного поработал, днём был \
                на съёмке, вечером сел за ошибки и даже в зал успел зайти.

                Забавное про этот релиз: ни одна из четырёх правок не была той задачей, за которую я \
                садился. Все четыре вылезли сбоку, пока разбирался с чем-то другим.
                """,
            announceEnd: """
                Приедет тем, у кого включены бета-версии. Остальным как обкатается.

                Самая полезная находка дня: если приложение переключило раскладку и не проверило \
                результат, оно потом уверенно врёт. Теперь проверяет.

                Берегите себя и не болейте. Я вот сегодня даже до зала дошёл, так что имею полное \
                моральное право это советовать. Спасибо всем, кто пишет, и отдельно тем, кто \
                заходит на keyboop.com/tips.
                """),

        // 0.3.13 — БЕТА. Две правки первого класса (микрофон и буфер обмена) и разбор мелочей,
        // найденных аудитом умолчаний. Обе крупные нашлись не по жалобе на них, а сбоку: микрофон
        // через аудит, буфер через отзыв «вставляется шифром», где первая догадка была «это не мы».
        Release(version: "0.3.13",
            ru: [
                "Микрофон больше не включается сам. Если хоткей диктовки это одиночный модификатор (по умолчанию правый ⌥), он срабатывал и внутри чужого сочетания: нажали ⌥⇧ правым Option, и попутно пошла запись. То же ловило hyper-клавишу на Caps Lock. Теперь жест засчитывается только чистым нажатием, а начатая по ошибке запись обрывается.",
                "Копирование больше не портит буфер обмена. Когда мы читаем выделение, мы снимаем буфер и возвращаем на место, и в этом возврате терялся порядок форматов. Из-за него текст, скопированный из Telegram, мог вставиться в Заметки нечитаемой кашей, а в другие программы нормально.",
                "«вк», «тг» и «vk» стали настоящими исключениями. Раньше они показывались в списке, но крестик на них ничего не менял: защита сидела глубже. Теперь удалили — снова переключаются, как интерфейс и обещает. Заодно латинское «vk» перестало превращаться в «мл»: на русской раскладке это миллилитр, и детектор честно его чинил.",
                "Окно записи комбинации стало вдвое компактнее. Оно раздувалось под длину подсказки, а подсказка к тому же умалчивала, что один модификатор тоже можно назначить: достаточно нажать и отпустить. Теперь про это написано, а ⌃ добавлен в готовые варианты.",
                "Проверка хоткея диктовки больше не зависает на экране. У окошка не было ни кнопки закрытия, ни Esc, ни времени жизни, и оно могло остаться висеть до перезапуска. Плюс оно не замечало модификаторы, то есть для настройки по умолчанию не могло завершиться в принципе.",
                "Плашка диктовки не исчезает посреди речи. Короткое сообщение поверх неё гасило её своим таймером, даже если запись продолжалась.",
                "Перевод выделенного больше не отбирает ⌃⌥T на macOS 13 и 14. Там его не существует (нужна macOS 15), но сочетание мы перехватывали и отвечали гудком. Теперь раздел честно говорит, что нужна система новее.",
                "История диктовок чистится по сроку, а не только при новой записи. Продиктовали один раз и ушли — запись всё равно исчезнет вовремя.",
                "Поле «Слово…» в исключениях переехало над списком. Раньше вы печатали внизу, а слово появлялось выше того места, куда вы смотрите.",
                "Раздел «Приватность» перестал недоговаривать. Он называл два повода выхода в сеть, а их четыре: не хватало как раз отправки отзыва, то есть единственного случая, когда наружу уходит кусок лога. На сайте было написано верно, в приложении нет.",
                "Капсулы клавиш в окне записи комбинации больше не теряются при смене темы. Заливка бралась один раз, а подпись перекрашивалась, и получалось тёмное по тёмному.",
                "Модель распознавания больше не занимает память впустую. Она грелась при запуске, чтобы первая диктовка не тормозила, но срок её жизни заводился только после первой диктовки. То есть у того, кто просто держит Keyboop запущенным, полтора гигабайта висели бессрочно. Теперь модель уходит из памяти после часа простоя в любом случае.",
                "У каждой модели появилась кнопка «i». Там написано, сколько она занимает на диске и в памяти, насколько быстрая и для чего годится. Раньше выбор выглядел как «какая точнее», а чем за это платят, человек узнавал из монитора системы.",
            ],
            en: [
                "The microphone no longer switches itself on. When the dictation hotkey is a single modifier (right ⌥ by default), it also fired inside somebody else's chord: press ⌥⇧ with the right Option and recording started too. The same caught a hyper key on Caps Lock. The gesture now counts only as a clean tap, and a recording started by mistake is aborted.",
                "Copying no longer damages the clipboard. When we read a selection we snapshot the clipboard and put it back, and that restore lost the order of formats. Because of it, text copied from Telegram could paste into Notes as unreadable garbage while other apps were fine.",
                "«вк», «тг» and “vk” are real exceptions now. They used to be shown in the list, but the cross on them changed nothing: the protection sat deeper. Delete one and it switches again, exactly as the interface promises. Latin “vk” also stopped turning into «мл», which on a Russian layout is a millilitre, so the detector was honestly fixing it.",
                "The shortcut recorder window is half the size. It used to stretch to fit the hint, and the hint failed to mention that a single modifier can be assigned too: press and release it. Now it says so, and ⌃ is among the ready-made choices.",
                "The dictation hotkey test no longer hangs on screen. The little window had no close button, no Esc and no lifetime, so it could stay up until a restart. It also ignored modifiers, so with the default hotkey it could never finish.",
                "The dictation panel no longer vanishes mid-speech. A short message shown over it used to hide it on its own timer even while recording continued.",
                "Translating a selection no longer takes ⌃⌥T on macOS 13 and 14. Translation does not exist there (macOS 15 is required), yet we intercepted the shortcut and answered with a beep. The section now says plainly that a newer system is needed.",
                "Dictation history is pruned by its retention time, not only when a new entry arrives. Dictate once and walk away, and the entry still disappears on schedule.",
                "The “Word…” field in exceptions moved above the list. You used to type at the bottom while the word appeared above where you were looking.",
                "The Privacy section stopped understating. It named two reasons for going online while there are four: the missing one was sending feedback, the single case where a piece of the log leaves the machine. The website had it right, the app did not.",
                "Key caps in the shortcut recorder no longer get lost when the theme changes. The fill was taken once while the glyph kept repainting, so it went dark on dark.",
                "The recognition model no longer holds memory for nothing. It was warmed up at launch so the first dictation would not lag, but its lifetime was armed only after the first dictation. So anyone simply keeping Keyboop running held a gigabyte and a half indefinitely. The model now leaves memory after an hour of idling in any case.",
                "Every model got an “i” button. It says how much space it takes on disk and in memory, how fast it is and what it is good for. The choice used to look like “which one is more accurate”, while the price only showed up in Activity Monitor.",
            ],
            announce: """
                Ночью чинил, утром выпускаю, днём на съёмку. Планировать такое я не умею, просто \
                два бага оказались из тех, с которыми не ложатся спать.

                Один включал микрофон сам. Второй портил буфер обмена. Оба ровно про то, чем \
                Keyboop вообще отличается от предшественника, так что выбора не было.
                """,
            announceEnd: """
                Приедет тем, у кого включены бета-версии. Остальным как обкатается.

                Обе серьёзные правки нашлись не там, где искали: микрофон вылез при разборе \
                настроек, а буфер из письма, где я сперва подумал, что это не мы.

                Спасибо всем, кто пишет и кто заходит на keyboop.com/tips. С вами ночные правки \
                заметно веселее.
                """),

        // 0.3.12 — БЕТА. Пять правок, четыре из них по отзывам, и одна старая: светлая тема наконец
        // побеждена по-настоящему (в 0.3.10 мы дали выбор оформления, но режим «как в системе»
        // оставался сломанным: причин было две, и вторая сидела в самом инструменте проверки).
        Release(version: "0.3.12",
            ru: [
                "Светлая тема больше не разъезжается. Если оформление стоит «как в системе», окно теперь целиком светлое в светлой теме и целиком тёмное в тёмной, и переключение на лету не оставляет половин. Раньше правая часть оставалась тёмной, а подписи на ней почти не читались.",
                "Выбранный язык диктовки наконец работает. Он передавался не до конца, и Parakeet, решив что речь русская, писал кириллицей даже английские слова: «Did you commit and push» превращалось в «Дидю коммит энд пуш». Выбор языка такую подмену отсекает.",
                "Приложение скажет, если обновления перестали приходить. Проверка могла молча не доходить до сервера месяцами: мешают сеть, VPN, корпоративный фильтр или антивирус. Теперь в «Обновлениях» появляется честная строка и кнопка отправить отчёт.",
                "Escape с модификатором больше не отменяет диктовку. Тильда и Escape соседи, и промах мимо ⌥` гасил запись без объяснений. Обычный Escape отменяет как отменял.",
                "Отменённая диктовка больше не портит следующую. Пометка «только в историю» оставалась висеть, если запись не дошла до расшифровки, и доставалась уже следующей записи: человек диктовал в поле, а текст молча уезжал в историю.",
            ],
            en: [
                "The light theme no longer splits the window. With appearance set to “system”, the window is now light all the way through under a light theme and dark under a dark one, and switching on the fly leaves no halves. The right-hand side used to stay dark with labels on it barely readable.",
                "The dictation language you picked finally works. It was not passed all the way through, so Parakeet, having decided the speech was Russian, wrote even English words in Cyrillic: “Did you commit and push” came out as a phonetic transliteration. Choosing a language cuts that off.",
                "The app now says when updates stopped arriving. A check could silently fail to reach the server for months, blocked by the network, a VPN, a corporate filter or antivirus. Updates settings now show an honest line and a button to send a report.",
                "Escape with a modifier no longer cancels dictation. Tilde and Escape are neighbours, and missing ⌥` killed the recording with no explanation. Plain Escape cancels exactly as before.",
                "A cancelled dictation no longer spoils the next one. The “history only” mark stayed behind when a recording never reached transcription, and the next recording inherited it: you dictated into a field and the text quietly went to history instead.",
            ],
            announce: """
                Пишете вы много, и в основном спасибо. Я к такому не готовился и теперь хожу \
                довольный: оказывается, делать полезное приятно, кто бы мог подумать.

                Этот релиз из мелочей, которые давно пора было доделать. Крупное тоже растёт, \
                просто оно поедет в 0.4, там ему просторнее.
                """,
            announceEnd: """
                Приедет тем, у кого включены бета-версии. Остальным попозже, когда обкатается.

                Три правки из пяти пришли прямо из ваших писем.

                И отдельно. Сутки не работала касса на keyboop.com/tips: банк сменил сертификаты и \
                забыл предупредить. Если вы в эти дни хотели закинуть монету и получили отказ, \
                криво было у меня, а не у вас. Уже починил.
                """),
        // 0.3.8 — БЕТА. Одна функция, по конкретной просьбе конкретного человека.
        // 0.3.11 — БЕТА. Один сюжет целиком: приложение просило не тот доступ и вело не туда.
        // Пришёл с Intel-мака (репорт #71), но касается всех: Мониторинг ввода это отдельная
        // галочка, про которую человек узнаёт, только если ему её назвать.
        Release(version: "0.3.11",
            ru: [
                "Двойное нажатие модификатора больше не срабатывает внутри чужого сочетания. Если у вас конверсия висит на двойном Shift, а в другой программе вы жмёте ⌘⇧⇧, Keyboop раньше считал это своим жестом и лез менять слово. Проверка «а не было ли других клавиш» видела только обычные клавиши, а ⌘ для неё был невидим.",
                "Keyboop больше не просит не тот доступ. Раньше он в любом случае писал «Нужен доступ (Accessibility)» и вёл в раздел Универсального доступа. Если там уже было разрешено, а не хватало Мониторинга ввода, человек видел галочку на месте и решал, что приложение сломано. Теперь называем ту дверь, в которую надо, и открываем именно её.",
                "Если Keyboop запущен не из «Программ», он это скажет. Доступы macOS привязывает к месту, откуда приложение работает: у копии в «Загрузках» они не держатся, а обновления не ставятся вовсе. Раньше мы предупреждали только про запуск прямо из образа, теперь про любое неподходящее место.",
                "В отчёт об ошибке добавилась строка о том, откуда приложение запущено. Без неё половину таких писем нечем было проверить. Полный путь не отправляется, только «Программы» или «не Программы»: в пути бывает ваше имя.",
            ],
            en: [
                "A double-tap shortcut no longer fires inside somebody else's combination. If conversion sits on a double Shift and you press ⌘⇧⇧ in another app, Keyboop used to treat that as its own gesture and went off to change a word. The “was there another key” check only ever saw ordinary keys; ⌘ was invisible to it.",
                "Keyboop no longer asks for the wrong permission. It used to always say “Needs access (Accessibility)” and open the Accessibility pane. If that was already granted and Input Monitoring was the missing one, people saw the checkbox in place and concluded the app was broken. We now name the right door and open that one.",
                "If Keyboop runs from outside Applications, it says so. macOS ties permissions to the place an app runs from: a copy in Downloads does not keep them, and updates cannot install at all. We used to warn only about launching straight from the disk image; now about any unsuitable place.",
                "The bug report now says where the app was launched from. Without it half of these letters could not be checked. The full path is not sent, only “Applications” or “not Applications”: paths contain your name.",
            ],
            announce: """
                Утро, снова за ноутбуком до выезда на съёмку.

                Вчера друг проверил Keyboop на стареньком Intel-маке и прислал отчёт. Оказалось, \
                приложение годно врало людям в лицо, и я даже знаю, скольким.
                """,
            announceEnd: """
                Приедет тем, у кого включены бета-версии. Спасибо всем, кто пишет: этот релиз \
                целиком из ваших писем.

                Сегодня кто-то заходил на keyboop.com/tips дважды, чтобы точно дошло. Сумма \
                скромная, десять рублей, а история хорошая. Спасибо всем, кто туда заходит.

                И просьба, если кому не лень. Звёзд на GitHub набралось столько, что Keyboop \
                теперь можно предложить в Homebrew. Сам себя подать не могу: там правила устроены \
                так, что автору это втрое дороже. Если умеете и хотите, буду должен.
                """),
        // 0.3.10 — БЕТА. Почти целиком из отзывов: четыре правки пришли от людей, две из них про
        // окно настроек, которое на macOS 26 вело себя странно у всех.
        //
        // ⚠️ ГДЕ 0.3.9. Она существовала: собрана, нотаризована и выложена в бета-канал 02.08, но
        // анонса не получила. Через час после выпуска выяснилось, что светлую тему мы не сломали, а
        // выключили своей же затычкой, и автор попросил вернуть её В ЭТОТ ЖЕ релиз. Перевыпустить под
        // тем же номером нельзя (Sparkle сравнивает версии, и у скачавших сборка осталась бы старой
        // навсегда), поэтому номер сдвинут, а пункты слиты сюда целиком: у человека должен быть один
        // связный список, а не два, из которых один он никогда не видел.
        Release(version: "0.3.10",
            ru: [
                "Оформление приложения теперь можно выбрать. В «Общих» появился переключатель: как в системе, светлое или тёмное. По умолчанию как в системе, то есть Keyboop переоденется вместе с macOS. Раньше выбора не было вовсе, и в светлой теме окно настроек разъезжалось: боковое меню светлело, а правая часть оставалась тёмной.",
                // ⚠️ ПЕРВАЯ ФРАЗА КАЖДОГО ПУНКТА — КОРОТКАЯ И САМОДОСТАТОЧНАЯ: именно она уходит в
                // подпись анонса, а длинные первые фразы скрипт выбрасывает целиком (канон в CLAUDE.md).
                "Окно настроек больше не уезжает вбок. На macOS 26 боковое меню стало плавающей панелью поверх содержимого, а мы считали, что оно по-прежнему отнимает ширину. Страницу можно было утащить в сторону, и текст прятался под меню.",
                "Подавление дребезга больше не съедает ⌘C и ⌘V. Фильтр смотрел только на клавишу и время, поэтому команду под зажатым ⌘ принимал за дребезг и глотал. Сочетания с ⌘, ⌃ и ⌥ теперь идут мимо него: пропущенная команда заметнее лишней буквы.",
                "Одиночная буква больше не меняется после клика мышью. Если поправить одну букву внутри уже написанного слова, мы видели только её и могли перевернуть обратно, отменив ваше же исправление. После переноса каретки одиночные буквы теперь не трогаем.",
                "Диктовка перестала занимать все производительные ядра. Потоки считались по всем ядрам сразу, и звуку в других программах оставались только экономичные, отсюда заикание музыки во время распознавания.",
                "Клавишу переключения стало видно в настройках. Строка называлась по выгоде, а не по действию, и люди не находили, где назначить себе Caps Lock. Теперь это «Менять раскладку своей клавишей», а если перенастроить клавишу не вышло, приложение честно говорит почему.",
                "У режима диктовки появилась подсказка. «Переключать» переименовано в «Нажимать», а под кнопкой «i» написано, чем два режима отличаются и когда какой удобнее.",
                "Потоковый набор убран из настроек. Он обещал показывать речь на плашке и этого не делал. Вернётся в 0.4, уже с показом.",
            ],
            en: [
                "You can now choose how the app looks. General settings got a picker: system, light or dark. System is the default, so Keyboop changes clothes together with macOS. There was no choice at all before, and under a light theme the settings window split in half: the sidebar went light while the right side stayed dark.",
                "The settings window no longer slides sideways. On macOS 26 the sidebar became a floating panel over the content, while we still assumed it took width away. The page could be dragged aside and the text hid under the menu.",
                "Chatter suppression no longer swallows ⌘C and ⌘V. The filter looked only at the key and the timing, so a command under a held ⌘ counted as chatter. Shortcuts with ⌘, ⌃ and ⌥ now bypass it: a command that never fired hurts more than one extra letter.",
                "A single letter is no longer swapped after you click with the mouse. Fixing one letter inside an existing word left us seeing only that letter, and we could flip it back, undoing your own correction. After the caret moves we now leave single letters alone.",
                "Dictation stopped taking every performance core. Threads were counted across all cores, so audio in other apps was left with the efficiency ones, which is why music stuttered while speech was being recognised.",
                "The layout key is now findable in settings. The row was named after the benefit rather than the action, so people could not find where to assign Caps Lock. It is now “Change layout with your own key”, and if the key could not be remapped the app says why.",
                "The dictation mode row got an explanation. “Toggle” is now “Press”, and the “i” button explains how the two modes differ and when each is nicer.",
                "Streaming dictation is gone from settings. It promised to show your speech on the panel and did not. It returns in 0.4, with the display it was missing.",
            ],
            announce: """
                Сейчас у меня съёмочные дни, поэтому разработка переехала на утро. Встаю и сразу за \
                ноутбук, вернулся со съёмки, снова за ноутбук.

                Этот релиз почти весь вырос из ваших писем. А заодно у приложения наконец можно \
                выбрать оформление, светлое или тёмное, чего раньше не было вовсе.
                """,
            announceEnd: """
                Приедет тем, кто включил «Ставить бета-версии». Через день-два, если будет тихо, \
                поедет всем остальным.

                Спасибо всем, кто закинул на keyboop.com/tips. Отдельно тем, кто перевёл заметно \
                больше обычного: я такие переводы вижу, и они здорово держат на плаву эти утренние \
                часы до выезда.
                """),
        Release(version: "0.3.8",
            ru: [
                // ⚠️ Без длинного тире: пункт целиком уходит в подпись анонса, когда та влезает в
                // лимит, а в тексте анонсов тире запрещено. И покороче: там он стоит между двумя
                // абзацами про то же самое, длинный дублировал их стеной.
                "Программе можно назначить раскладку. В «Исключениях» рядом с каждой программой появился выбор языка: при переходе в неё Keyboop включит именно его. Переключаем на входе и не спорим дальше: если внутри вы сменили язык сами, так и оставим.",
            ],
            en: [
                "You can pin a layout to an app. In Exceptions, each app now has a language picker: enter the app and Keyboop switches to it. Useful where hotkeys only work in Latin — the famous case being DaVinci Resolve, where half the shortcuts simply do not fire on a Cyrillic layout. We switch on entry and then stay out of your way: if you change the language yourself inside, it stays changed.",
            ],
            announce: """
                Сделал одну функцию специально для Жени из BigGeek. Респект ему за заявку.

                В DaVinci Resolve при русской раскладке горячие клавиши не работают. Совсем. \
                Поэтому там живут по правилу «переключись, потом делай», и однажды забываешь.
                """,
            announceEnd: """
                Зашёл в DaVinci, включился английский. Вышел, всё как было. В обратную сторону \
                тоже работает, если вам нужен русский.

                Это бета, приедет тем, кто включил «Ставить бета-версии». Спасибо всем, кто \
                держит проект на keyboop.com/tips.

                Продолжение следует.
                """),
        // 0.3.7 — БЕТА. Целиком про живучесть: ни одной новой функции, только то, что мешало
        // приложению тихо ломаться. Выпущено в бета-канал сознательно: предохранитель — новое
        // поведение в самом чувствительном месте, и его надо обкатать на добровольцах.
        Release(version: "0.3.7",
            ru: [
                // ⚠️ ПЕРВАЯ ФРАЗА КАЖДОГО ПУНКТА — КОРОТКАЯ И САМОДОСТАТОЧНАЯ. Именно она уходит в
                // подпись анонса (announce-telegram.sh → first_sentence), и если она длинная, скрипт
                // выбрасывает пункт целиком. В 0.3.6 так вылетели все четыре. См. CLAUDE.md → канон
                // структуры анонса.
                "Keyboop больше не может подвесить ввод. Перехват клавиатуры устроен так, что система ждёт нашего ответа на каждое нажатие, и если мы задумались, встаёт не только клавиатура, но и мышь. Раньше мы в такой ситуации бесконечно включались обратно и попадали в тот же капкан снова. Теперь после трёх срывов за минуту Keyboop снимает перехват сам и честно пишет об этом в меню, а через пять минут пробует вернуться: лучше временно не работать, чем держать компьютер в заложниках.",
                "Движок научился оживать сам. Если перехват умирал уже после запуска (отозвали и вернули доступ, система его закрыла), приложение молча переставало работать до ручного перезапуска, и догадаться об этом было нельзя. Теперь оно замечает и поднимается заново, с нарастающими паузами и потолком, чтобы не долбиться в закрытую дверь.",
                "Правка на лету больше не выключается на весь день. Одной случайной заминки системы хватало, чтобы отключить самый аккуратный способ замены до перезапуска. Теперь это пауза на три минуты, а насовсем только если срывы идут раз за разом.",
                "Автозамена сокращений теперь уважает исключения. Раньше сниппет разворачивался даже там, где Keyboop сознательно не трогает ничего: в терминале, в видеоредакторах. Системные настройки и поиск Spotlight добавлены в исключения по умолчанию, в первых вводят пароли, во втором наша замена промахивалась на символ из-за подсказок поиска. Обе записи видны в списке, их можно убрать.",
                "Модель распознавания речи проверяется по контрольной сумме. Раньше скачанный архив принимался на веру: оборванная загрузка или сбой на зеркале прошли бы насквозь, прямо в распаковку.",
            ],
            en: [
                "Keyboop can no longer stall input on your Mac. A keyboard interceptor works by making the system wait for our answer on every keystroke, so if we stop to think, the keyboard and the mouse both stop with us. Previously we would re-enable ourselves forever and walk straight back into the same trap. Now, after three stalls in a minute, Keyboop switches the interception off by itself and says so in the menu: better to pause than to hold your computer hostage.",
                "The engine now revives itself. If interception died after startup — access revoked and granted again, or the system closed it — the app went quiet until you restarted it by hand, with no way to tell. It now notices and starts over, with growing pauses and a ceiling so it does not hammer a closed door.",
                "On-the-fly correction is no longer switched off for the whole day. A single hiccup of the system was enough to disable the most careful replacement path until restart. Now it is a three-minute pause, and permanent only if the hiccups keep coming.",
                "Snippet expansion now respects your exception list. It used to expand even where Keyboop deliberately touches nothing: terminals, video editors. System Settings and Spotlight are excluded by default — passwords are typed in one, and in the other our replacement missed by a character because of search suggestions. Both entries are visible in the list and can be removed.",
                "The downloaded speech model is verified against a checksum before it is unpacked. The archive used to be taken on trust, so a broken download or a mirror glitch would have gone straight through.",
            ],
            announce: """
                Сегодня снова был на съёмке, пришёл домой и сразу сел за ваши отзывы. Ближайшие \
                дни тоже съёмки, но про вас не забываю, доделываю по вечерам.

                А днём случился сюрприз: про Keyboop рассказали в biggeek, в инстаграме и \
                телеграме, сами и в своей манере. Я не просил, тем приятнее.

                Выкатил бету 0.3.7. Она целиком про живучесть: новых функций нет, зато приложение \
                больше не умеет ломаться молча.
                """,
            announceEnd: """
                Приедет только тем, кто включил «Ставить бета-версии» в настройках. Через день-два, \
                если будет тихо, поедет всем остальным.

                Спасибо всем, кто пишет и присылает логи: половина этого списка началась с чьего-то \
                «а у меня вот так». И тем, кто закинул на keyboop.com/tips: вы оплачиваете мне \
                вечера после съёмок, и это не фигура речи.
                """),
        Release(version: "0.3.6",
            ru: [
                "Приглушение звука на время диктовки стало плавным: громкость съезжает вниз по мягкой кривой и так же мягко возвращается, без щелчка в начале и в конце. Уровень теперь задаётся ползунком, а не выбором из нескольких значений, потому что на слух его подбирают, а не выбирают.",
                "Whisper перестал подписывать вашу речь чужими титрами. На тишине и шуме он иногда выдавал обрывки из обучающих данных, вроде «Субтитры создавал…» или «Продолжение следует», и это уезжало прямо в текст. Теперь такие фразы отсекаются, но только когда стоят отдельным предложением: живую речь мы не режем, даже если вы правда сказали «спасибо за просмотр».",
                "Отменённую по Escape диктовку можно всё-таки сохранять. В поле по-прежнему не вставляется ничего, но текст распознаётся и ложится в историю, откуда его можно забрать. Выключено по умолчанию: Escape означает «не надо», и сохранять вопреки этому без вашего согласия мы не станем. Плашка «Распознаю» при этом не показывается: вы нажали отмену, и мелькать на экране после этого нечему.",
                "Потоковый набор переехал в бета-канал. Фича экспериментальная, и её место у тех, кто сам включил «Ставить бета-версии» и готов встретить свежую ошибку раньше остальных. Ваш выбор сохранён: включите бета-канал, и настройка вернётся на место.",
            ],
            en: [
                "Ducking the volume while you dictate is now smooth: it slides down along a soft curve and comes back the same way, with no click at either end. The level is set with a slider rather than a short list, because it is something you tune by ear.",
                "Whisper stopped signing your speech with someone else's credits. On silence and noise it sometimes produced fragments from its training data, and they went straight into your text. Those phrases are now stripped, but only when they stand as a sentence of their own: live speech is never cut, even if you really did say thank you for watching.",
                "A dictation cancelled with Escape can still be kept. Nothing is inserted into your text, but it is recognised and lands in the history, where you can pick it up. Off by default: Escape means no, and we will not save against that without your say-so. The “Recognising” panel no longer appears either: you pressed cancel, so there is nothing left to flash on screen.",
                "Streaming dictation moved to the beta channel. It is experimental, and it belongs with the people who turned on “Install beta versions” and are happy to meet a fresh bug before everyone else. Your choice is kept: switch the beta channel on and the setting comes back.",
            ],
            announce: """
                Диктуй, кайфуй!

                Звук во время диктовки теперь убавляется плааааавно, по мягкой кривой, и так же \
                мягко возвращается. Раньше музыка прыгала ступенькой, теперь просто уходит на \
                второй план, пока вы говорите.
                """,
            announceEnd: """
                И Whisper перестал подписывать вашу речь чужими титрами. Кто ловил «Субтитры \
                создавал DimaTorzok» посреди своего текста, тот поймёт.

                Привет старому знакомому, который написал, что значок Keyboop у него самый \
                широкий в строке меню. Ты не подписался, так что отвечаю через канал: у значка \
                есть режимы, буквы языка убираются, сам значок прячется, можно вообще всё сразу. \
                А имя всё-таки пришли, интрига мучает.

                Дальше живём так: 0.3.x доводит до ума то, что уже есть, а 0.4 привезёт крупное. \
                Копаю оба сразу, потому что усидеть на одном не выходит.

                И спасибо всем, кто закинул на keyboop.com/tips. Это правда мотивирует: времени \
                на Keyboop уходит прилично, и видеть, что он кому-то нужен, дорогого стоит.
                """),
        Release(version: "0.3.5",
            ru: [
                "Кнопки в уведомлении об обновлении наконец нажимаются. Работал только крестик, поэтому обновиться из плашки было нельзя вовсе: у безрамочной кнопки macOS считает зону нажатия по нарисованному тексту, а не по всей цветной пилюле, и клик рядом с буквами уходил в пустоту. Теперь ловится вся площадь кнопки.",
                "Сама плашка стала аккуратнее: кнопки ниже и у́же, поля ровные со всех сторон, ширина подстраивается под текст, а не прибита к одной цифре. Раньше правая кнопка упиралась в край, а на английском справа зияла пустота.",
                "В меню «История голосового набора» встала выше «Скопировать последнюю диктовку».",
            ],
            en: [
                "The buttons in the update notification can finally be pressed. Only the close cross worked, so updating from the banner was impossible: for a borderless button macOS measures the click area by the drawn text rather than the whole coloured pill, so a click next to the letters went nowhere. The entire button now responds.",
                "The banner itself got tidier: shorter and narrower buttons, even padding on every side, and a width that follows the text instead of being nailed to one number. The right button used to touch the edge, and in English there was dead space beside it.",
                "In the menu, “Dictation history” now sits above “Copy last dictation”.",
            ],
            announce: """
                Срочная заплатка, и стыдная. Во вчерашней плашке «доступно обновление» кнопки не \
                нажимались: работал только крестик. То есть я выкатил обновление, которое нельзя \
                поставить кнопкой из уведомления об обновлении.

                Причина обидная: у кнопки без рамки macOS считает зону нажатия по самим буквам, а не \
                по цветному прямоугольнику вокруг них. Попасть можно было буквально по тексту.
                """,
            announceEnd: """
                Спасибо, что написали сразу, а не махнули рукой. Заодно причесал саму плашку: \
                кнопки поменьше, поля ровные, ширина по тексту.
                """),
        Release(version: "0.3.4",
            ru: [
                "Починено ручное переключение слова у тех, кто назначил диктовке сочетание из двух модификаторов, например ⌥⌘. Оно переставало работать полностью: разбор хоткея конверсии до него просто не доходил. Спасибо @denis_kuprienko за точный отчёт, по нему это нашлось за минуту.",
                "Пока вы диктуете, звук можно приглушать. Музыка и видео перестают перекрикивать, а после диктовки громкость возвращается на прежнее место. Насколько убавлять, выбираете сами, вплоть до полной тишины. Если вы сами покрутите громкость во время диктовки, мы не станем спорить и оставим ваше значение. Выключено по умолчанию, включается в настройках голоса.",
                "Потоковый набор перестал молчать. Он показывает распознанное прямо на плашке «Слушаю», пока вы говорите, а в документ текст по-прежнему попадает один раз, в конце. Печатать по ходу речи мы намеренно не стали: модель переписывает уже сказанное, и в вашем тексте это выглядело бы как буквы, которые сами себя стирают. Заодно настройка теперь честно пишет, что ей нужен движок Parakeet: раньше на другом движке тумблер включался и не делал ничего.",
                "Обновление стало на одно нажатие короче. Раньше в уведомлении надо было нажать «Обновить», а потом ещё раз то же самое в отдельном окне. Теперь любая из двух кнопок ставит версию и перезапускает приложение сразу. Правая заодно включает автоматические обновления, чтобы это уведомление больше не появлялось.",
            ],
            en: [
                "Fixed manual word switching for anyone who assigned a two-modifier combination to dictation, such as ⌥⌘. It stopped working entirely: the conversion hotkey was never even examined. Thanks to @denis_kuprienko for a report precise enough to find it in a minute.",
                "The volume can now duck while you dictate. Music and video stop talking over you, and the level returns afterwards. How far down is your choice, all the way to silence. If you change the volume yourself mid-dictation, we won't argue and keep your value. Off by default, switched on in the voice settings.",
                "Streaming dictation stopped being invisible. It shows what it recognises right on the “Listening” panel while you speak, while the text still lands in your document once, at the end. We deliberately do not type as you go: the model rewrites what it already said, and in your text that would look like letters erasing themselves. The setting now also admits that it needs the Parakeet engine, where before it switched on and did nothing.",
                "Updating is one click shorter. The notification used to ask you to press “Update”, then ask again in a separate window. Now either button installs the version and relaunches straight away. The right one also turns on automatic updates, so the notification stops appearing.",
            ],
            announce: """
                Быстрая заплатка. Если вы ставили диктовку на сочетание вроде ⌥⌘, у вас молча \
                переставало работать ручное переключение слова. Ломалось это с 29 июля, то есть \
                ровно с того дня, как я добавил сочетания по вашей же просьбе. Извините.

                И ещё раз для тех, у кого версия старше 0.3: она сама не обновится. Нажмите \
                «Проверить обновления» в меню, а если в ответ тишина или бодрое «у вас всё свежее», \
                не верьте и скачайте с keyboop.com. Дальше всё поедет само.
                """,
            announceEnd: """
                Нашлось за минуту, потому что человек прислал отчёт с логом прямо из приложения. \
                Это лучший способ мне помочь: «Сообщить о проблеме», и всё видно.
                """),
        Release(version: "0.3.3",
            ru: [
                "«Скопировать последнюю диктовку» теперь появляется в меню, только когда копировать действительно есть что. Пункт брал текст из истории диктовок, другого источника у него нет, поэтому при выключенной истории он был мёртвым, а после истечения срока хранения обещал то, чего уже не существует. Теперь он просто исчезает.",
                "Срок хранения истории перестал умалчивать о последствиях: под ним написано, что вместе с записями пропадает и копирование последней диктовки из меню.",
                "Первая диктовка после смены движка в настройках больше не теряется. Parakeet при первом запуске готовит модель под нейродвижок Mac, и это занимает больше полуминуты, а ждали мы пятнадцать секунд и выбрасывали готовый результат. Теперь новый движок прогревается сразу при выборе, а ожидание считается честно.",
                "В форме «Сообщить о проблеме» появился второй способ отправки, через Telegram. Отчёт сохраняется файлом, открывается чат с ботом, дальше вы отправляете сами. Видно ровно то, что уходит, и ничего не уходит без вашего участия. Прежняя кнопка осталась на месте.",
                "Keyboop больше не трогает текст в собственных окнах. Раньше он обрабатывал форму отзыва и настройки как любое чужое приложение: копил слово и на границе мог его «починить», стерев набранное. Отсюда и жалобы, что в форме обратной связи не видно, что печатаешь.",
                "Появилось исправление двух заглавных подряд: «КОгда» становится «Когда». Так выходит, когда Shift отпущен на миг позже, чем нажата вторая буква. Слова целиком заглавными, вроде ГОСТ и USB, не трогаются. Выключено по умолчанию, включается в настройках переключения: это правка самого текста, а не раскладки.",
                "Имя версии теперь видно везде, где показан её номер: в меню, внизу списка настроек и в «О программе».",
                "Меню в строке меню обновляется в момент открытия. Раньше список микрофонов и предупреждения о неполадках показывали состояние на момент последней смены раскладки.",
            ],
            en: [
                "“Copy last dictation” now appears in the menu only when there is something to copy. The item reads from the dictation history and has no other source, so with history off it was dead, and once the retention time ran out it promised something that no longer existed. Now it simply disappears.",
                "The history retention setting stopped hiding its consequence: it now says that copying the last dictation from the menu goes away together with the entries.",
                "The first dictation after switching engines in settings is no longer lost. On its first run Parakeet prepares its model for the Mac's neural engine, which takes over half a minute, while we waited fifteen seconds and threw away the finished result. The new engine is now warmed up the moment you pick it, and the wait is counted honestly.",
                "“Report a problem” has a second way to send, via Telegram. The report is saved to a file, the bot chat opens, and you send it yourself. You see exactly what is leaving, and nothing leaves without you. The old button stays where it was.",
                "Keyboop no longer touches text in its own windows. It used to treat the feedback form and the settings like any other app: it collected the word and could “fix” it at the boundary, erasing what you had typed. That is where the reports about not seeing what you type in the feedback form came from.",
                "Two leading capitals can now be fixed: “WHen” becomes “When”. That happens when Shift is released a moment after the second letter. All-caps words like USB are left alone. Off by default, switched on in the layout settings, because it edits your text rather than its layout.",
                "The version name is now visible everywhere the number is: in the menu, at the bottom of the settings list, and in About.",
                "The menu-bar menu refreshes when it opens. The microphone list and the “something is wrong” warnings used to show whatever was true at the last layout change.",
            ],
            announce: """
                Если вы читаете это со сборки старше 0.3, ваше приложение, скорее всего, не умеет \
                обновляться само. И виновато не оно, а я: в старых версиях проверка обновлений \
                залипала намертво, а починка уехала в следующую версию, скачать которую залипший \
                апдейтер уже не мог. Идеальное преступление, жертва я же.

                Лечится за пять секунд руками: значок Keyboop в строке меню, «Проверить обновления». \
                Если он бодро скажет, что у вас всё свежее, а версия при этом старше 0.3, он врёт, \
                берите с keyboop.com. Дальше всё поедет само, честное слово.
                """,
            announceEnd: """
                И повторю, потому что это единственное, что правда важно в этом посте: если у вас \
                старая версия, обновитесь руками. Всё, что я тут чиню по ночам, до вас иначе просто \
                не доедет, и мы оба зря стараемся.

                Спасибо всем, кто пишет. Половину этого списка нашли вы.
                """),
        Release(version: "0.3.2",
            ru: [
                "В меню появился пункт «Скопировать последнюю диктовку». Раньше за последней расшифровкой приходилось открывать окно истории, теперь она уезжает в буфер обмена одним нажатием. Если на историю поставлен пароль, он спросится и здесь: отдавать последнюю фразу мимо пароля было бы странно.",
                "Меню перебрано. Язык распознавания уехал в настройки, где он и так был, «Проверить обновления» и «Сообщить о проблеме» встали рядом внизу, и у каждого пункта теперь свой значок.",
                "Окно настроек больше не разворачивается на весь экран. Зелёная кнопка вместо этого подгоняет его по высоте экрана, что для длинного списка настроек куда полезнее.",
                "Настройка языка распознавания перестала молчать о подвохе. Если выбрать конкретный язык, речь на другом распознаётся заметно хуже, а иногда не распознаётся совсем. Теперь это написано прямо под настройкой, а «Авто» честно назван тем, что понимает смешанную речь.",
                "Обновления проверяются раз в два часа вместо раза в сутки. И если с обновлением что-то пойдёт не так, теперь это можно разобрать: приложение записывает в свой лог, что именно ответил сервер обновлений. Раньше там было пусто, и на жалобу «у меня не обновляется» ответить было нечем.",
                // Сухо и по делу: шутка про пищуху живёт в анонсе (announce), здесь она была бы повтором.
                "У версий появились имена. Текущее видно в шапке меню, меняться оно будет раз в десяток версий.",
            ],
            en: [
                "The menu now has “Copy last dictation”. Getting the last transcript used to mean opening the history window; now it goes to the clipboard in one click. If you put a password on the history, it is asked here too: handing out the last phrase around your own password would be odd.",
                "The menu was rearranged. Recognition language moved to Settings, where it already lived, “Check for Updates” and “Report a problem” now sit together at the bottom, and every item has an icon.",
                "The settings window no longer goes full screen. The green button fits it to the height of your display instead, which is far more useful for a long list of settings.",
                "The recognition-language setting stopped hiding its catch. Pin a specific language and speech in another one comes out noticeably worse, sometimes not at all. That is now written right under the setting, and “Auto” is honestly described as the one that handles mixed speech.",
                "Updates are checked every two hours instead of once a day. And if something goes wrong with an update, it can now be traced: the app writes down what the update server actually answered. That log used to be empty, which left “it never updates” impossible to answer.",
                "Versions have names now. The current one shows in the menu header and changes once per decimal.",
            ],
            announce: """
                У версий теперь есть имена, и вам с этим жить.

                Каждый десяток получает своё. Сейчас идёт Pika, пищуха: маленькая, пискнула один раз \
                и спряталась. По-моему, довольно точный портрет приложения. Имя видно в шапке меню, \
                до 1.0 их будет семь.
                """,
            announceEnd: """
                Сижу ночами и чиню всё, до чего дотягиваюсь. Сегодня уже засыпаю над клавиатурой, \
                но очень хочется доделать.

                Спасибо всем, кто пишет и присылает баги. Половину этого списка нашли вы.
                """),
        Release(version: "0.3.1",
            ru: [
                "Язык больше не переключается сам после первой заглавной буквы. Если мгновенная смена языка висела на Shift, могло получаться «Cнова» вместо «Снова»: первая буква в одной раскладке, остальные в другой. Причина не в тексте, а в том, что macOS иногда прячет от программ нажатия клавиш (это защита полей ввода, и её умеет залипать чужой процесс). Модификаторы при этом видны, обычные клавиши нет, и мы принимали «Shift нажали и отпустили, а между ними ничего» за осознанный жест, хотя между ними была заглавная буква. Теперь, когда клавиши от нас скрыты, жесты по модификаторам просто молчат.",
                "Заодно Shift больше нельзя назначить на мгновенную смену языка, а у кого он уже стоял, функция выключена. Shift нажимают перед каждой заглавной, и держать на нём переключение языка означает подписаться на ложные срабатывания.",
                "Хоткей диктовки наконец принимает сочетания из нескольких клавиш. Раньше при попытке задать ⌃⌥ записывалась только одна из них, а кнопка «Назначить» оставалась серой. Caps Lock через HyperKey теперь тоже подходит. Спасибо за скринкаст, по нему это нашлось за минуту.",
                "Отправка по Enter стала безопаснее. Мы доделывали слишком много работы прямо в момент нажатия, и в худших случаях система за это могла на время отключить нас от клавиатуры, теряя набранное. Лишнее убрано в сторону.",
                "Мелочи: в отчёт об ошибке больше не сыплются десятки одинаковых строк про смену микрофона, а почта для связи теперь одна и та же везде, hi@keyboop.com.",
            ],
            en: [
                "The language no longer switches by itself after the first capital letter. If instant switching was bound to Shift, you could get «Cнова» instead of «Снова»: the first letter in one layout, the rest in another. The cause was not in the text. macOS sometimes hides key presses from apps (it protects password fields, and a stray process can leave that stuck). Modifiers stay visible, ordinary keys do not, so «Shift pressed and released with nothing in between» looked like a deliberate gesture when in fact a capital letter was typed in between. Now, while keys are hidden from us, modifier gestures simply stay quiet.",
                "Shift can no longer be assigned to instant switching, and if you already had it, the feature is off. Shift comes before every capital letter, and hanging a language switch on it means signing up for false triggers.",
                "The dictation hotkey finally accepts combinations of several keys. Trying to set ⌃⌥ used to record only one of them and leave «Assign» greyed out. Caps Lock through HyperKey works now too. Thanks for the screencast, it took a minute to find with it.",
                "Sending with Enter got safer. We were finishing too much work at the very moment of the keypress, and at worst the system could cut us off from the keyboard for a while, losing what you typed. The extra work moved aside.",
                "Small things: bug reports no longer fill up with dozens of identical lines about the microphone changing, and there is now one contact address everywhere, hi@keyboop.com.",
            ]),
        Release(version: "0.3.0",
            ru: [
                "Настройки наконец разложены по полкам. Раньше в голосовом наборе было двенадцать разных строк подряд в одной куче: микрофон стоял в начале, а его же прогрев где-то в середине, между чужими пунктами. Теперь всё собрано по смыслу, а параметры, которые нужны не всем, прячутся под своими переключателями и выезжают, только когда вы их включаете.",
                "У пунктов появились подсказки. Кружок с буквой «i» рядом с настройкой открывает нормальное объяснение: что именно произойдёт, чем это грозит и когда это стоит включать. Раньше объяснение обрывалось на середине, потому что не влезало по ширине.",
                "Светлая тема перестала выглядеть вывернутой наизнанку. У macOS страница светлая, а блоки настроек чуть темнее; у нас было ровно наоборот. В тёмной теме всё совпадало, поэтому мы это годами не замечали. Спасибо тому, кто показал скриншотом.",
                "Окно настроек стало шире, а подписи под пунктами перестали обрезаться на полуслове.",
                "Диктовка научилась подстраиваться под то, куда вы пишете. Можно не начинать с заглавной буквы, не ставить точку в конце и отправлять сообщение сразу после диктовки. Отправку можно повесить на Enter или на ⌘Enter, потому что в разных программах это разные клавиши.",
                "И починка, которую поймал Стас (привет!). Если выделить слово мышью и нажать хоткей, соседнее слово могло исчезнуть вместе с пробелом. Причина оказалась обидной: после клика мы забывали, что выделение вообще есть, и стирали ровно столько символов, сколько было в выделенном слове, но начиная не оттуда.",
                "Плюс мелочи: звук записи больше не пропадает при быстром наборе, микрофон следует за тем, что выбрано в системе (AirPods наконец подхватываются), а логотип не появляется в строке меню, если вы его выключили.",
            ],
            en: [
                "Settings are finally sorted into groups. Voice input used to be twelve unrelated rows in a single pile: the microphone at the top, its own warm-up somewhere in the middle with other things in between. Everything is grouped by meaning now, and the options not everyone needs hide under their own switches and slide out only when you turn them on.",
                "Rows got proper help. The small «i» next to a setting opens a real explanation: what exactly happens, what it costs you and when it is worth turning on. Before, the explanation was cut off mid-sentence because it did not fit the width.",
                "Light theme stopped looking inside out. macOS uses a light page with slightly darker setting blocks; ours was exactly the other way round. In dark theme everything matched, which is why we missed it for so long. Thanks to whoever sent the screenshot.",
                "The settings window is wider, and the descriptions under each row no longer break off mid-word.",
                "Dictation now adapts to where you are writing. You can skip the leading capital, skip the trailing period, and send the message right after dictating. Sending can be Enter or ⌘Enter, because different apps use different keys.",
                "And a fix caught by Стас (hi!). Selecting a word with the mouse and pressing the hotkey could make the neighbouring word disappear along with its space. The cause was embarrassing: after a click we forgot the selection existed and deleted exactly as many characters as the selected word had, only starting from the wrong place.",
                "Plus smaller things: the recording cue no longer goes missing while you type fast, the microphone follows your system choice (AirPods finally get picked up), and the logo no longer shows in the menu bar if you turned it off.",
            ]),
        Release(version: "0.2.70",
            ru: [
                "Это обновление почти целиком собрано по вашим письмам. Я разобрал всё, что пришло через форму отзыва, сгруппировал по симптомам и починил то, что чинилось. Ниже честно: что было сломано и как это выглядело с вашей стороны.",
                "Самое неприятное. У части из вас переставал работать пробел, а иногда и другие клавиши, причём сразу во всех программах, и лечилось это только выходом из Keyboop. Виноват был Keyboop: он перехватывал отпускание клавиши, нажатие которой не трогал, и система оставалась в уверенности, что клавиша всё ещё зажата. Теперь правило жёсткое: перехватили нажатие, значит перехватим и отпускание. Не перехватили, значит не трогаем ни то, ни другое.",
                "Мгновенная смена языка работала в одну сторону. Уходило в русский и обратно не возвращалось. Оказалось, латинскую раскладку я искал по признаку «английская», а у ABC-AZERTY, QWERTZ, испанской, чешской и польской первым языком записан вовсе не английский. Теперь ищем по способности набирать латиницу, а не по названию.",
                "Назначение своей комбинации переехало в отдельное окно. Видно, что вы нажимаете, прямо в момент нажатия. Если сочетание занято системой или уже занято другой функцией Keyboop, окно скажет об этом на месте, а не выкинет поверх себя предупреждение, которое перекрывало всё и обрывало запись. И оно больше не закрывается само, пока вы перебираете варианты.",
                "Хоткей из одного модификатора больше не срабатывает внутри чужого сочетания. Кто работает с Windows-машиной по удалённому доступу и жмёт там Alt+Shift, у того Keyboop заодно менял язык на своей стороне.",
                "Автообновления чинились. После первой скачанной версии проверки прекращались совсем, то есть приложение тихо застревало на ней навсегда. Если вы давно не видели предложения обновиться, дело было в этом.",
                "Keyboop научился признаваться, что не работает. Раньше он мог молчать: система забрала клавиатуру в защищённый режим, доступ к клавиатуре отозвали, микрофон не отдаёт звук. Снаружи это выглядело как «просто перестало работать». Теперь причина написана прямо в меню.",
                "Ещё по мелочи: окно «Что нового» больше не падает при втором открытии, а форма отзыва теперь показывает, что письмо ушло, и ждёт, пока вы сами её закроете, а не исчезает через секунду.",
            ],
            en: [
                "This update is built almost entirely from your messages. I went through everything that came in via the feedback form, grouped it by symptom and fixed what could be fixed. Below, honestly: what was broken and how it looked from your side.",
                "The worst one. For some of you the Space key stopped working, sometimes other keys too, across every app at once, and only quitting Keyboop helped. Keyboop was to blame: it intercepted the release of a key whose press it had let through, so the system kept believing the key was still held down. The rule is strict now: if we intercept a press, we intercept its release. If we don't, we touch neither.",
                "Instant language switching worked one way only. It went into Russian and never came back. It turned out I looked for the Latin layout by the mark «English», while ABC-AZERTY, QWERTZ, Spanish, Czech and Polish list something else as their first language. Now we look for the ability to type Latin, not for the name.",
                "Assigning your own shortcut moved into its own window. You can see what you're pressing as you press it. If the combination is taken by the system, or already taken by another Keyboop function, the window says so in place instead of throwing a warning on top of itself, covering everything and cutting the recording short. And it no longer closes on its own while you're trying options.",
                "A single-modifier shortcut no longer fires inside somebody else's combination. If you work with a Windows machine over remote access and press Alt+Shift there, Keyboop used to switch the language on your side as well.",
                "Auto-updates got fixed. After the first downloaded version, checks stopped entirely, so the app quietly got stuck on it forever. If you haven't seen an update offer in a while, that was why.",
                "Keyboop learned to admit when it isn't working. It used to stay silent: the system put the keyboard into secure mode, keyboard access was revoked, the microphone returned no sound. From the outside it just looked like «it stopped working». The reason is now written right in the menu.",
                "Smaller things: the «What's new» window no longer crashes on a second open, and the feedback form now shows that your message went out and waits for you to close it, instead of vanishing after a second.",
            ]),
        Release(version: "0.2.69",
            ru: [
                "Ваши предложения доезжают до сборки быстрее, чем вы думаете: почти всё в этом обновлении пришло из ваших писем. Пишете — я беру в работу сразу, а не «когда-нибудь в бэклоге».",
                "Появились «Спорные слова» — раздел для тех случаев, где Keyboop честно не может угадать. Есть слова, которые набираются одними и теми же клавишами и существуют в обоих языках: «vs» и «мы», «here» и «руку», «gj» и «по». Кто-то пишет «versus» каждый день, кто-то — «мы» в каждом втором предложении, и правильного ответа на всех не существует. Теперь у каждой такой пары три положения: оставить английское, оставить русское или (по умолчанию) не вмешиваться и решать по контексту. Настройки → Исключения → «Спорные слова».",
                "В строке меню теперь может жить флаг языка — как в Punto. Тем, кто привык коситься в правый верхний угол, так быстрее: Настройки → Общие → значок в строке меню → «Флаг языка».",
                "В голосовом наборе перестали вываливать на вас весь список моделей. Сверху — две, которыми пользуется большинство: Parakeet за скорость и Whisper Turbo за пунктуацию. Остальные никуда не делись, они за ссылкой «Другие модели».",
                "В «О программе» комбинации клавиш перестали врать. Раньше там был зашит текст с сочетаниями по умолчанию — и если вы их поменяли, описание жило своей жизнью. Теперь показывает ваши.",
                "Мелочь про мгновенное переключение языка: пока сама функция выключена, комбинацию к ней больше нельзя выбрать. Незачем настраивать то, что не работает.",
                "И последнее, совсем коротко. Несколько человек спросили, как автора можно поблагодарить. Я подумал — почему бы и нет, и сделал страницу: keyboop.com/tips. Приложение было и остаётся бесплатным, платных функций там не появится; это просто способ сказать «работает, спасибо». В настройках внизу теперь есть тихая ссылка туда же.",
            ],
            en: [
                "Your suggestions reach a build faster than you'd think: almost everything in this update came from your messages. You write — I start on it right away, not «someday, from the backlog».",
                "Meet «Ambiguous words» — a section for the cases where Keyboop honestly cannot guess. Some words are typed with the exact same keys and exist in both languages: «vs» and «мы», «here» and «руку», «gj» and «по». Some people write «versus» daily, others use «мы» in every other sentence, and there is no single right answer. Each such pair now has three positions: keep the English one, keep the Russian one, or (the default) stay out of it and decide by context. Settings → Exceptions → «Ambiguous words».",
                "The menu bar can now show a language flag, Punto-style. If you're used to glancing at the top-right corner, it's faster: Settings → General → menu-bar icon → «Language flag».",
                "Dictation no longer dumps the whole model list on you. The top two are what most people use: Parakeet for speed, Whisper Turbo for punctuation. The rest are still there, behind the «Other models» link.",
                "In «About», the shortcuts stopped lying. The description used to have the default combinations hard-coded, so if you changed them, it went on living its own life. Now it shows yours.",
                "A small thing about instant language switching: while the feature itself is off, you can no longer pick a shortcut for it. No point configuring something that isn't running.",
                "Last one, very briefly. A few people asked how they could thank the author. I thought — why not, and made a page: keyboop.com/tips. The app was and stays free, no paid features will appear there; it's just a way to say «it works, thanks». Settings now has a quiet link to the same place at the bottom.",
            ]),
        Release(version: "0.2.68",
            ru: [
                "Исправление на лету стало по-настоящему мгновенным. Раньше слово чинилось с небольшой задержкой, и при быстром наборе могло порваться: «yнормаmyj» вместо «нормально». Мы провели исследование и нашли решение — теперь замена происходит ровно в тот момент, когда вы нажимаете клавишу, и ваш следующий символ физически не может вклиниться в неё. Не «стало реже», а «больше не может произойти». Заодно раскладка чинится на лету снова по умолчанию — ради этого всё и переделывалось.",
                "Своя комбинация клавиш наконец назначается. Некоторые из вас писали, что нажимаете «назначить свою» — и ничего не происходит. Виноваты были мы: Keyboop перехватывал нажатие раньше, чем оно доходило до настроек, и вместо записи запускал старое действие. Теперь на время записи он вежливо отходит в сторону.",
                "И больше нельзя случайно занять ⌘C. Раньше это удавалось — после чего каждое копирование запускало перевод, а перевод снова просил копию: получался круг с бесконечным звуком. Системные сочетания (⌘C, ⌘V, ⌘Z и родня) теперь не принимаются, а Keyboop объясняет, почему и что нажать вместо них. Сам круг мы тоже разорвали — на уровне механики, для любых хоткеев.",
                "В звуках переключения появился свой — короткий двойной, сухой, без звона. По умолчанию всё как было (системный Pop), но если он вам примелькался, наш лежит первым в списке: Настройки → Общие → звук.",
                "Первый запуск больше не спорит сам с собой: окно приветствия не выскакивает поверх системного запроса доступа. Сначала знакомство, доступ — по кнопке, когда вы к нему готовы.",
                "«Вы» наконец чинится. Слово «ds» мы пропускали, потому что в английском словаре есть такое сокращение — а это, между прочим, основное вежливое обращение в русском (спасибо тому, кто написал). Заодно починили «при». Правило теперь простое: частое русское слово важнее нишевой английской аббревиатуры, а если вам нужно наоборот — добавьте слово в исключения, они всегда сильнее наших списков.",
                "В форме обратной связи подписали, зачем оставлять телеграм: без него письмо прочитаю, но ответить будет некуда. С ним — напишу лично, что починил.",
                "Мелочь в настройках: строка «Назначить свою…» теперь на месте всегда, даже когда своя комбинация уже назначена (раньше было непонятно, куда нажать, чтобы сменить).",
            ],
            en: [
                "Fix-as-you-type is now genuinely instant. A word used to be corrected with a small delay, and fast typing could tear it apart — «yнормаmyj» instead of «нормально». We ran a study and found the fix: the replacement now happens at the exact moment you press the key, and your next character physically cannot slip into the middle of it. Not «less often» — «can no longer happen». Fixing the layout on the fly is back on by default, which is what the whole rebuild was for.",
                "Custom shortcuts finally record. Some of you wrote that you press «assign your own» and nothing happens. That was on us: Keyboop grabbed the keypress before it reached Settings and ran the old action instead of recording it. Now it politely steps aside while you're recording.",
                "And you can no longer grab ⌘C by accident. You could before — after which every copy triggered a translation, and the translation asked for a copy again: an endless loop with a rhythmic beep. System shortcuts (⌘C, ⌘V, ⌘Z and family) are refused now, with an explanation of what to press instead. We also broke the loop itself at the mechanism level, for any hotkey.",
                "The switch-sound list now has one of ours — a short double click, dry, no ringing. The default is unchanged (the system Pop), but if you are tired of it, ours sits first in the list: Settings → General → sound.",
                "First launch no longer argues with itself: the welcome window doesn't pop up on top of the system permission request. Introduction first, access by button when you're ready.",
                "«Вы» finally gets fixed. We used to skip «ds» because English has such an abbreviation — while it happens to be the main polite form of address in Russian (thanks to whoever wrote in). «при» is fixed too. The rule now: a frequent Russian word outweighs a niche English abbreviation — and if you need the opposite, add the word to exceptions; they always beat our lists.",
                "The feedback form now says why leaving a Telegram handle helps: without it I'll read your message but have nowhere to reply. With it — I'll write you personally about what got fixed.",
                "A small settings fix: the «Assign your own…» row is now always there, even once you've set a custom shortcut (previously it wasn't clear where to click to change it).",
            ]),
        Release(version: "0.2.67",
            ru: [
                "Срочная починка: у части людей приложение вообще не запускалось. Значок не появлялся, окно не открывалось, двойной клик будто уходил в пустоту — и никакого сообщения об ошибке. Виноваты мы: библиотека распознавания собралась с расчётом на самую свежую macOS и на выходе требовала деталь, которой в macOS 14 (Sonoma) просто нет. Система молча закрывала приложение ещё до первой строки нашего кода — поэтому и сказать было нечему. Пересобрали правильно: теперь запускается на Sonoma, как и обещали.",
                "Спасибо тем, кто не поленился написать и прислать вывод из Терминала — по одной строчке ошибки нашли причину за полчаса. Без вас искали бы неделю.",
            ],
            en: [
                "Emergency fix: for some people the app simply wouldn't launch. No menu-bar icon, no window, a double-click that went nowhere — and no error message at all. That was on us: the recognition library got built against the newest macOS and ended up demanding a piece that doesn't exist on macOS 14 (Sonoma). The system quietly killed the app before our first line of code ran — which is why it couldn't say anything. Rebuilt properly: it launches on Sonoma now, as promised.",
                "Thanks to everyone who bothered to write in and paste the Terminal output — one line of that error found the cause in half an hour. Without you we'd still be guessing.",
            ]),
        Release(version: "0.2.66",
            ru: [
                "День большой охоты. Со вчерашнего вечера переключение могло фантомить: слово перепечатывалось само в себя со звуком, а иногда конверсия просто молчала. Мы разобрали это до винтиков — и нашли не свой баг, а устройство macOS: перевод нажатия, который система кладёт в событие, и перевод, которым рисует буквы само приложение, — два разных перевода на двух разных часах. После смены раскладки первый отстаёт на секунды. Теперь Keyboop не спрашивает систему вовсе: раскладку он помнит сам и переводит клавиши так же, как это делает приложение на экране. По нашим тестам фантомы ушли.",
                "«Чинить на лету» стало опцией, а не умолчанием. Перепечатка слова прямо под быстрые пальцы усиливала любую мелкую рассинхронизацию до слышимой. Конверсия по пробелу и Enter — как работала, так и работает; кому нравится мид-слово — тумблер на месте, и он теперь срабатывает на паузе набора, а не наперегонки с вами.",
                "Мгновенное переключение языка (бета) довели до ума: 🌐 действительно отключает системное действие на время режима (и честно возвращает при выключении или выходе), а Caps Lock переключает язык, не зажигая капс — старым способом это было невозможно в принципе, пришлось спуститься на уровень ниже.",
                "Страховка от чужих глюков: если что-то в системе держит «безопасный ввод пароля» (бывает — браузер или диалог не отпускают), Keyboop слеп не по своей воле. Теперь он хотя бы записывает в служебный журнал, кто именно держал и сколько, — по «Сообщить о проблеме…» мы это увидим.",
                "Диалоги обновлений заговорили по-русски. «You're up to date» в русском интерфейсе смущало — теперь «У вас последняя версия», как и положено.",
            ],
            en: [
                "A day of big-game hunting. Since last night, switching could phantom: a word retyped into itself with a sound, and sometimes conversion just went silent. We took it apart down to the screws — and found not our bug but a macOS design: the translation the system puts into a key event and the translation the app on screen draws with are two different translations on two different clocks. After a layout switch the first one lags by seconds. Keyboop no longer asks the system at all: it remembers the layout itself and translates keys the same way the on-screen app does. In our tests the phantoms are gone.",
                "“Fix as you type” is now an option, not the default. Retyping a word right under fast fingers amplified any tiny desync into an audible one. Conversion on Space and Enter works as it always did; if you like the mid-word fix, the toggle is still there — and it now fires when your fingers pause, not in a race with them.",
                "Instant language switching (beta), done properly: 🌐 genuinely disables the system action while the mode is on (and honestly restores it on disable or quit), and Caps Lock switches language without lighting up caps — impossible the old way, we had to go one level deeper.",
                "Insurance against other apps' quirks: if something in the system holds “secure password input” (happens — a browser or a dialog won't let go), Keyboop is blind through no fault of its own. Now it at least records in the service log who held it and for how long — “Report a problem…” will show us.",
                "Update dialogs now speak Russian. “You're up to date” in a Russian interface was awkward — now it's «У вас последняя версия», as it should be.",
            ]),
        Release(version: "0.2.65",
            ru: [
                "Мгновенная смена языка — по любой удобной комбинации (бета). Системное переключение раскладки всегда идёт с задержкой: macOS ждёт, не окажется ли это началом комбинации. Мы не ждём — меняем язык сразу, как только клавишу отпустили. Включается в Настройках → Переключение, по умолчанию выключено. Комбинацию выбираете сами: 🌐 (на новых маках), ⌘Space, ⌃Space, Caps Lock — или записываете свою.",
                "Ничего не подерётся за одно нажатие. Если выбранная комбинация уже занята в самой системе (например, ⌘Space открывает Spotlight), мы честно предупредим, что именно перестанет работать, — и перехватим клавишу так, что второе действие не сработает. Выключите тумблер — и всё вернётся как было: системные настройки мы не трогаем вообще. А если комбинация уже занята другой функцией Keyboop, просто не дадим её назначить.",
                "Клавишу 🌐 можно повесить и на ручное исправление слова — она появилась в списке горячих клавиш вместе с привычными ⌥⇧ и двойным Shift.",
                "Мелочь, которая раздражала: при выключенном авто-переключении тумблер «чинить на лету» теперь тоже гаснет и становится недоступным — он ведь всё равно не работал бы. Включите авто обратно — вернётся ровно таким, каким вы его оставили.",
            ],
            en: [
                "Instant language switching — on whatever shortcut suits you (beta). The system's own layout switch always lags: macOS waits to see whether a combination is coming. We don't wait — the language changes the moment you release the key. Enable it in Settings → Switching; it's off by default. Pick your shortcut: 🌐 (on newer Macs), ⌘Space, ⌃Space, Caps Lock — or record your own.",
                "Nothing will fight over a single keypress. If the shortcut you picked is already taken by the system (⌘Space opens Spotlight, say), we'll tell you exactly what will stop working — and intercept the key so the second action never fires. Turn the toggle off and everything returns: we don't touch system settings at all. And if the shortcut is already used by another Keyboop function, we simply won't let you assign it.",
                "The 🌐 key can also be bound to fixing a word by hand — it joined the hotkey list alongside the familiar ⌥⇧ and double-Shift.",
                "A small annoyance fixed: with auto-switching off, the “fix as you type” toggle now goes dim and unavailable — it wouldn't have worked anyway. Turn auto back on and it returns exactly as you left it.",
            ]),
        Release(version: "0.2.64",
            ru: [
                "Работа над ошибками. Честно: в такой ответственный день мы немного перемудрили — в сегодняшних версиях переключение раскладки могло чудить: лишний звук конверсии на уже правильном слове, а местами слово не переключалось вовсе. Простите. Ловили весь вечер — нашли гонку в обработке раскладки (кэш обновлялся по запаздывающему системному уведомлению, а мы переключаем раскладку при каждой конверсии), закрыли, и по нашим тестам всё снова стабильно.",
                "Чтобы такое больше не тянулось вечерами, движок теперь ведёт подробный служебный дневник своих решений: кто сконвертировал, кто промолчал и почему. Ни текста, ни содержимого — только события. Если что-то ещё заметите, «Сообщить о проблеме…» привезёт разгадку вместе с жалобой.",
                "Модели распознавания теперь качаются с нашего зеркала keyboop.com — сервер в Москве, так что «застряло на 2%» уходит в историю. Не получилось с зеркала — сами тихо переключимся на прежний источник. Целостность файлов проверяется как и раньше.",
                "Значок в строке меню — теперь по-настоящему: выбор с живым превью (фирменный знак / клавиатура / совсем скрыть) плюс отдельная галка «показывать язык (RU/EN)». Любая комбинация. Спрятали всё — настройки откроются повторным запуском Keyboop из «Программ».",
                "Пояснили перевод: он заменяет ВАШ набранный текст в поле ввода — в письме, чате, заметке. Текст на чужой веб-странице ему заменить негде — для этого есть переводчик браузера.",
            ],
            en: [
                "Fixing our own mess. Honestly: on such a big day we got a bit too clever — in today's builds layout switching could act up: a phantom conversion sound on an already-correct word, and sometimes a word wouldn't switch at all. Sorry. We hunted all evening — found a race in layout handling (the cache refreshed on a lagging system notification while we switch layouts on every conversion), closed it, and our tests are stable again.",
                "So this never eats another evening, the engine now keeps a detailed service journal of its decisions: who converted, who stayed silent and why. No text, no content — events only. If you spot anything else, “Report a problem…” brings the answer along with the complaint.",
                "Recognition models now download from our mirror at keyboop.com — a Moscow server, so “stuck at 2%” is history. If the mirror fails, we quietly fall back to the original source. File integrity is verified as before.",
                "The menu bar icon, done properly this time: a live-preview picker (brand mark / keyboard / hidden entirely) plus a separate “show language (RU/EN)” toggle. Any combination. Hidden everything? Settings open by launching Keyboop again from Applications.",
                "Clarified translation: it replaces YOUR typed text in an input field — mail, chat, notes. It can't replace text on someone else's web page — that's what the browser translator is for.",
            ]),
        Release(version: "0.2.63",
            ru: [
                "Keyboop научился жить на компьютерах Intel и на более старых версиях macOS. Раньше приложение требовало Mac на Apple Silicon и macOS 14 — и у части людей просто не запускалось с сухим «эта версия не подходит». Теперь на Intel-маках (от macOS 13) работает переключение раскладки, автозамена и голосовой набор через Whisper. Единственное, чего там нет, — движок Parakeet: он живёт на нейропроцессоре Apple, которого в Intel-маках не существует. Распознавание на Intel идёт на обычном процессоре: медленнее и чуть теплее, поэтому в настройках подскажем выбрать модель полегче.",
                "Значок в строке меню теперь настраивается. В «Настройки → Общие» появился выбор: фирменный знак Keyboop, буква K, только индикатор языка (RU/EN), классическая клавиатура — или совсем спрятать значок, если он мешает. Спрятали? Настройки всё равно под рукой: просто запустите Keyboop ещё раз из папки «Программы», и работающая копия сама откроет окно настроек.",
            ],
            en: [
                "Keyboop learned to live on Intel Macs and older macOS. It used to require Apple Silicon and macOS 14 — and for some people it simply refused to launch with a dry “this version isn't supported.” Now on Intel Macs (from macOS 13) you get layout switching, snippet expansion, and voice typing via Whisper. The one thing missing there is the Parakeet engine: it runs on Apple's Neural Engine, which Intel Macs don't have. Recognition on Intel runs on the regular CPU — slower and a touch warmer, so settings will nudge you toward a lighter model.",
                "The menu bar icon is now customizable. Settings → General offers a choice: the Keyboop brand mark, the letter K, the language tag only (RU/EN), the classic keyboard — or hide the icon entirely if it's in your way. Hidden it? Settings are still one step away: just launch Keyboop again from Applications, and the running copy opens Settings for you.",
            ]),
        Release(version: "0.2.62",
            ru: [
                "Диктовка снова стартует мгновенно — всегда. Причин у «задержки в полсекунды-секунду» оказалось две. Первая: зажав хоткей, Keyboop честно ждал, пока крупная модель распознавания поднимется с диска (у Large V3 Turbo — около секунды), и только потом включал микрофон. Теперь запись начинается сразу, а модель догружается параллельно и успевает, пока ты говоришь.",
                "Вторая причина тоньше: крупная модель сама создавала то давление на память, по которому мы её же и выгружали — карусель «выгрузили-загрузили» каждые полчаса, и каждая первая диктовка после неё платила за перезагрузку. Теперь при активной работе модель остаётся в памяти; выгружаем её только в простое или когда системе действительно критично.",
                "Сторож распознавания научился учитывать холодную загрузку модели — долгая первая загрузка больше не может быть принята за зависание. И в образе установки теперь первой строкой написаны требования (Apple Silicon, macOS 14+) — чтобы никаких сюрпризов после скачивания.",
            ],
            en: [
                "Dictation starts instantly again — every time. The “half-second-to-second delay” turned out to have two causes. First: on the hotkey press, Keyboop dutifully waited for the large recognition model to rise from disk (about a second for Large V3 Turbo) and only then opened the microphone. Recording now starts immediately, and the model loads in parallel — it's ready by the time you finish talking.",
                "The second cause was subtler: the large model itself created the memory pressure we were unloading it for — an unload-reload carousel every half hour, with every first dictation paying the reload toll. The model now stays in memory while you're actively working; it's only released when you're idle or the system is genuinely struggling.",
                "The recognition watchdog now accounts for cold model loads — a long first load can no longer be mistaken for a hang. And the installer image now states the requirements up front (Apple Silicon, macOS 14+) — no surprises after downloading.",
            ]),
        Release(version: "0.2.61",
            ru: [
                "Сегодня я впервые рассказал о Keyboop большой аудитории — и быстро понял, что хочу слышать вас, а не догадываться. Поэтому в меню у часов появилось «Сообщить о проблеме…» (та же форма — за кнопкой в «О программе»): пишешь, что сломалось, что бесит или чего не хватает, по желанию оставляешь контакт для ответа. Галочка прикладывает диагностику — версия, настройки, служебный лог; текста ввода и речи там нет, и всё это можно посмотреть глазами до отправки. Мне такие письма прилетают мгновенно — сегодняшние фиксы родились ровно из ваших сообщений. Без сети — фолбэк на почту. Делитесь опытом: Keyboop растёт на ваших отзывах, а не на фокус-группах.",
                "И первая идея уже приехала из комментариев: на историю диктовок теперь можно повесить пароль. По умолчанию выключено; включается в Настройках → Голосовой набор, рядом с историей. Пароль спрашивается при открытии окна истории — это защита от любопытных глаз за твоим же Mac (на диске история и так зашифрована). Восстановления пароля нет — есть честная кнопка «стереть историю и снять пароль». Так и задумано.",
            ],
            en: [
                "Today I told a big audience about Keyboop for the first time — and quickly realized I'd rather hear from you than guess. So the menu by the clock got “Report a problem…” (the same form sits behind the About button): write what broke, what annoys you or what's missing, and leave a contact for a reply if you like. A checkbox attaches diagnostics — version, settings, the service log; no typed text or speech in there, and you can inspect it all before sending. These land on my desk instantly — today's fixes were born exactly from your messages. No network — the email fallback still works. Share your experience: Keyboop grows on your feedback, not focus groups.",
                "And the first idea has already arrived from the comments: you can now put a password on your dictation history. Off by default; enabled in Settings → Voice, right next to the history toggle. The password is asked when opening the history window — it keeps curious eyes at your own Mac out (on disk the history is encrypted anyway). There's no password recovery — there's an honest “erase history and remove password” button instead. That's by design.",
            ]),
        Release(version: "0.2.60",
            ru: [
                "Переписали захват микрофона. Самая коварная беда звучала так: «выбран внешний микрофон, подключены AirPods — и тишина»: macOS втихую открывала не то устройство, а формат записи «протухал» при смене наушников. Теперь Keyboop прибивает запись к выбранному микрофону напрямую и сам объявляет нужный формат — капризные связки устройств больше не превращаются в молчание, а старт диктовки стал быстрее.",
                "Если микрофон всё же отдаёт тишину (устройство уснуло, система приглушила) — Keyboop больше не молчит в ответ: сам пробует системный вход, затем встроенный микрофон, а если не помогло — честно пишет на экране, что случилось и куда посмотреть. Раньше это выглядело как «меня не слышит», без объяснений.",
                "«Распознаю» больше не может зависнуть навечно. У распознавания появился сторож: если движок застрял, плашка убирается, Keyboop сухо признаётся «распознавание застряло — бросил» и готов к новой попытке. Заодно выход из приложения больше не блокируется зависшим распознаванием — перезагружать Mac не придётся (спасибо за репорт!).",
                "Поля паролей неприкосновенны. Если во время диктовки фокус вдруг украл системный диалог с паролем, надиктованное больше не печатается в него — текст сохраняется в истории, а на экране появляется подсказка. И сама «связка ключей» больше никогда не спросит пароль от имени Keyboop: ключ истории обслуживается без диалогов.",
                "Переключение раскладки стало устойчивее под нагрузкой: перехват клавиш заметно облегчили (тяжёлая работа ушла с горячего пути в фон), так что системе реже хочется его отключать в моменты, когда Mac занят.",
                "Живое исправление — чинить слово прямо во время набора, не дожидаясь пробела — теперь включено по умолчанию. Не понравится — выключается в настройках одним тумблером.",
                "Мелочи со вкусом: в меню у часов теперь видна версия приложения; новости переехали в телеграм-канал @keyboop (кнопка — в «О программе»); знакомство при первом запуске научилось рассказывать про голосовой набор и показывает настоящие хоткеи.",
            ],
            en: [
                "Rebuilt microphone capture. The nastiest bug read like this: “external mic selected, AirPods connected — silence”: macOS quietly opened the wrong device, and the recording format went stale when headphones changed. Keyboop now pins recording to the chosen microphone directly and declares the format itself — capricious device combos no longer turn into silence, and dictation starts faster.",
                "If the microphone still yields silence (device fell asleep, system muted it) — Keyboop no longer answers with silence of its own: it tries the system input, then the built-in microphone, and if that doesn't help, it honestly tells you on screen what happened and where to look. This used to look like “it doesn't hear me”, with no explanation.",
                "“Recognizing” can no longer hang forever. Recognition got a watchdog: if the engine gets stuck, the badge goes away, Keyboop dryly admits “recognition got stuck — dropped it” and is ready for another take. Quitting the app is no longer blocked by a stuck recognition either — no Mac reboots required (thanks for the report!).",
                "Password fields are sacred. If a system password dialog steals focus mid-dictation, your words are no longer typed into it — the text is saved to history and a hint appears on screen. And the keychain will never again ask for a password on Keyboop's behalf: the history key is handled without dialogs.",
                "Layout switching got sturdier under load: key interception went on a diet (the heavy lifting moved off the hot path into the background), so the system feels the urge to switch it off far less often when your Mac is busy.",
                "Live fixing — correcting the word as you type it, without waiting for the space — is now on by default. Not your thing? One toggle in settings turns it off.",
                "Tasteful trifles: the menu by the clock now shows the app version; news moved to the @keyboop Telegram channel (button in About); the first-launch tour learned to talk about voice typing and shows your actual hotkeys.",
            ]),
        Release(version: "0.2.59",
            ru: [
                "Починили вчерашнюю оплошность. В 0.2.58 мы научили Keyboop отдавать полтора гигабайта памяти после простоя — но поставили таймер на 5 минут, и при обычном ритме «диктовка каждые полчаса» модель перегружалась почти на каждую сессию: диктовка вызывалась заметно дольше. Теперь по-умному: модель выгружается тогда, когда системе реально не хватает памяти (macOS сама сообщает об этом), плюс страховка на действительно долгий простой — час, а не пять минут. И память отдаём, и скорость не страдает.",
                "Убрали редкий вылет при выходе из приложения. Если закрыть Keyboop сразу после диктовки (пока модель ещё в памяти), внутренняя проверка движка распознавания могла уронить приложение прямо на выходе. Теперь модель аккуратно освобождается перед завершением — и проверке не на что ругаться.",
            ],
            en: [
                "Fixed yesterday's misstep. In 0.2.58 we taught Keyboop to give back a gigabyte and a half after idling — but set the timer to 5 minutes, so with a normal “dictate every half hour” rhythm the model was reloading on nearly every session: dictation took noticeably longer to start. Now it's done properly: the model unloads when the system actually runs low on memory (macOS tells us itself), plus a safety timer for genuinely long idles — an hour, not five minutes. Memory gets returned, speed doesn't suffer.",
                "Removed a rare crash on quit. If you closed Keyboop right after dictating (while the model was still in memory), an internal check in the recognition engine could take the app down on its way out. The model is now released properly before exit — leaving the check nothing to complain about.",
            ]),
        Release(version: "0.2.58",
            ru: [
                "Keyboop перестал держать полтора гигабайта памяти просто так. Модель распознавания речи загружалась один раз и оставалась в памяти до перезапуска приложения — фоновая утилита в строке меню занимала под два гигабайта и давила на память всей системы, отчего подтормаживал не только Keyboop. Теперь модель выгружается после пяти минут простоя и подгружается снова, когда понадобится: файл остаётся в кэше системы, так что задержки почти не видно. Если памяти много и дороже каждая миллисекунда — поведение настраивается.",
                "Появился счётчик надиктованного — рядом с «Расколдовано кракозябр» в разделе «О программе». Видно, сколько символов и слов вы наговорили голосом за всё время. Чисто для удовольствия.",
                "Настройки стали спокойнее внутри. В macOS 26 системные переключатели и списки переехали на SwiftUI, и каждая перерисовка раздела теперь обходится дороже. Мы убрали лишние: раздел «Голос» больше не пересобирается при каждом возврате к окну, а только когда на диске реально что-то изменилось. Заодно это снижает риск редких вылетов, которые мы сейчас расследуем.",
                "Добавили тихую диагностику: если система на мгновение отключает наш перехват клавиатуры под нагрузкой (это её штатное поведение, когда всё занято), теперь это видно в логе. Так мы наконец поймаем редкий случай «раскладка не переключилась, хотя должна была».",
            ],
            en: [
                "Keyboop no longer holds on to a gigabyte and a half of memory for no reason. The speech recognition model was loaded once and stayed in memory until you quit the app — a menu-bar utility sitting on nearly two gigabytes, squeezing the whole system, so it wasn't only Keyboop that felt slow. The model now unloads after five minutes of idling and loads again when needed: the file stays in the system cache, so you'll barely notice. If you have memory to spare and value every millisecond, it's configurable.",
                "There's a dictation counter now — next to “Gibberish un-garbled” in the About section. It shows how many characters and words you've spoken over all time. Purely for the fun of it.",
                "Settings got quieter under the hood. In macOS 26 the system switches and lists moved to SwiftUI, so every redraw of a section costs more than it used to. We removed the unnecessary ones: the Voice section no longer rebuilds every time you come back to the window, only when something actually changed on disk. It also lowers the risk of the rare crashes we're currently investigating.",
                "Added quiet diagnostics: when the system briefly switches off our keyboard interception under load (that's its normal behaviour when everything is busy), it now shows up in the log. That should finally let us catch the rare “the layout didn't switch when it should have” case.",
            ]),
        Release(version: "0.2.57",
            ru: [
                "Настройки теперь честнее показывают, какие модели распознавания реально лежат на диске. Если удалить файл модели вручную (через Finder, чтобы освободить место), Keyboop раньше мог продолжать показывать «Установлена» — статус строился один раз и не пересчитывался. Теперь он освежается при каждом открытии окна настроек и при возврате к нему, так что «Установлена / Скачать» всегда соответствует реальности. Сама диктовка и раньше не путалась — честно проверяла файл и предлагала скачать, если его нет; подтянулась именно надпись.",
            ],
            en: [
                "Settings now show more honestly which recognition models are actually on disk. If you deleted a model file by hand (via Finder, to free up space), Keyboop could keep showing “Installed” — the status was built once and never re-checked. It now refreshes every time you open the settings window and when you return to it, so “Installed / Download” always matches reality. Dictation itself was never fooled — it honestly checked the file and offered to download if missing; it's the label that caught up.",
            ]),
        Release(version: "0.2.56",
            ru: [
                "Enter больше не обгоняет исправление. Раньше было так: набрал «nbgf», нажал Enter — мессенджер отправляет сообщение мгновенно, а исправление приходит на долю секунды позже, в уже пустую строку. В чат улетала абракадабра, а исправленное слово сиротливо оставалось в поле ввода (спасибо за скриншот, Женя!). Теперь Keyboop придерживает Enter на пару десятых, чинит слово прямо в строке — и отпускает. В чат уходит уже «типа», а не «nbgf». Работает и в редакторах: сначала починка, потом перенос строки. Если слово в порядке — Enter проходит как обычно, без малейшей задержки.",
            ],
            en: [
                "Enter no longer outruns the fix. Here's how it used to go: you type “nbgf”, hit Enter — the messenger sends instantly, and the correction arrives a split second later into an already empty field. The gibberish flew into the chat, and the corrected word sat orphaned in the input line (thanks for the screenshot, Zhenya!). Now Keyboop holds Enter for a fraction of a second, fixes the word right in the line — and lets go. The chat receives the fixed word, not the gibberish. Works in editors too: fix first, then the newline. If the word is fine, Enter passes through instantly as always.",
            ]),
        Release(version: "0.2.55",
            ru: [
                "Whisper перестал глотать знаки препинания. Прошлая диагностика (0.2.52) показала: примерно каждая третья диктовка на Whisper приходила сплошняком, без единого знака — причём аудио чистое, так что дело не в тихом хвосте, как думали сперва. Whisper — авторегрессионная модель и на «холодном» старте иногда залипает в режиме без пунктуации. Дали ему короткую натуральную фразу-затравку со знаками (вы её не видите — она лишь настраивает модель на «пиши со знаками»), подобранную под язык распознавания. Знаки вернулись. Parakeet эта правка не касается — у него с пунктуацией и так был порядок.",
            ],
            en: [
                "Whisper stopped swallowing punctuation. Our earlier diagnostics (0.2.52) showed roughly one in three Whisper dictations arriving as one solid block with no punctuation at all — on clean audio, so it wasn't about quiet tails after all. Whisper is an autoregressive model and on a “cold” start it sometimes gets stuck in a no-punctuation mode. We now hand it a short, natural seed phrase with punctuation (you never see it — it just nudges the model toward “write with punctuation”), matched to the recognition language. The marks are back. This doesn't touch Parakeet — its punctuation was already fine.",
            ]),
        Release(version: "0.2.54",
            ru: [
                "Починили периодические подтормаживания. В прошлой версии (добавили переключение микрофона на лету) в путь старта диктовки просочилась тяжёлая работа с аудио-устройствами, а реакция на смену входа могла зациклиться — отсюда «диктовка началась не сразу» и редкие задержки, порой заметные и на переключении раскладки. Убрали тяжёлую часть с горячего пути (теперь она в фоне) и поставили предохранитель от зацикливания. Снова шустро.",
            ],
            en: [
                "Fixed periodic sluggishness. The previous version (on-the-fly microphone switching) leaked some heavy audio-device work into the dictation-start path, and reacting to an input change could loop — hence “dictation didn't start right away” and occasional stalls, sometimes even on layout switching. We moved the heavy part off the hot path (it's in the background now) and added a guard against the loop. Snappy again.",
            ]),
        Release(version: "0.2.53",
            ru: [
                "Диктовка больше не глохнет при подключении наушников. Воткнул EarPods или подключил гарнитуру — macOS переключает микрофон, а запись раньше молча оставалась на старом устройстве (или вовсе останавливалась) — получалась тишина. Теперь Keyboop замечает смену входа: в простое — тихо пересаживается на новое устройство, а прямо во время записи — переключается на лету, не теряя уже надиктованное. В лог теперь пишется, с какого микрофона идёт запись.",
                "Про значок «Консоль» в Доке: кнопка «Системный лог» открывает лог-файл в штатной macOS-программе «Консоль» — это нормально, не вирус. Подписали это прямо в настройках, чтобы не пугало.",
            ],
            en: [
                "Dictation no longer goes silent when you plug in headphones. Connect EarPods or a headset and macOS switches the microphone — recording used to silently stay on the old device (or stop entirely), producing dead air. Keyboop now notices the input change: when idle it quietly moves to the new device, and mid-recording it switches on the fly without losing what you've already dictated. The log now shows which microphone the recording uses.",
                "About the “Console” icon in the Dock: the “System log” button opens the log file in the stock macOS Console app — that's normal, not a virus. It now says so right in Settings.",
            ]),
        Release(version: "0.2.52",
            ru: [
                "Разбираемся, почему диктовка иногда приходит «сплошняком», без единого знака препинания (бывает на обеих моделях). Изучили причину по источникам (у Whisper это авторегрессионный «режим без пунктуации» на тихих хвостах, у Parakeet — своя механика) и добавили тихую диагностику в лог — только счётчики, без текста, — чтобы точно поймать, когда и почему это случается. Само лечение будет следующим шагом.",
            ],
            en: [
                "We're digging into why dictation sometimes arrives as one solid block with no punctuation at all (it happens on both models). We researched the cause (for Whisper it's an autoregressive “no-punctuation mode” on quiet tails; Parakeet has its own mechanics) and added quiet diagnostics to the log — counters only, no text — to pin down exactly when and why it happens. The fix itself is the next step.",
            ]),
        Release(version: "0.2.51",
            ru: [
                "В настройках голосового набора честно объяснили разницу между движками распознавания. Parakeet (по умолчанию) — самый быстрый: текст появляется почти сразу, работает на Neural Engine, но пунктуацию иногда ставит вольно. Whisper Turbo — аккуратнее с пунктуацией и связностью, но на 1–4 секунды медленнее. Выбирай по вкусу: скорость или чистота текста. (Мы проверили это по источникам — разница реальная и упирается в архитектуру движков.)",
            ],
            en: [
                "Settings → Voice now honestly explains the difference between the recognition engines. Parakeet (default) is the fastest — text shows up almost instantly, runs on the Neural Engine — but its punctuation can get a little loose. Whisper Turbo has cleaner punctuation and phrasing, but lands 1–4 seconds later. Pick your trade-off: speed or tidier text. (We checked this against the sources — the difference is real and rooted in the engines' architecture.)",
            ]),
        Release(version: "0.2.50",
            ru: [
                "Технический лог больше не разрастается без предела. Keyboop ведёт локальный служебный лог (без текста ввода, речи и перевода — только счётчики и события), и за месяцы использования файл мог раздуться и занимать место на диске. Теперь он держится в пределах ~1 МБ: при переполнении самые старые строки удаляются, а свежие (которые и нужны, если что-то чинить) остаются. Уже раздувшийся лог подчистится сам при первом запуске этой версии.",
            ],
            en: [
                "The technical log no longer grows without bound. Keyboop keeps a local diagnostic log (no typed text, speech or translation — just counters and events), and over months of use the file could balloon and eat disk space. Now it stays within ~1 MB: when it fills up, the oldest lines are dropped and the recent ones (the ones you need when something needs fixing) are kept. An already-bloated log cleans itself up on the first launch of this version.",
            ]),
        Release(version: "0.2.49",
            ru: [
                "При старте вместе с системой (автозагрузка) Keyboop больше не открывает окно настроек — тихо садится в строку меню, как и положено фоновому помощнику. А если запустить приложение вручную (из Finder или Spotlight) — настройки откроются: так до них можно добраться, даже если потерял значок в тесной строке меню. Различаем по тому, КАК система запустила приложение (логин или твой двойной клик), а не по флагу автозапуска.",
            ],
            en: [
                "When Keyboop starts with your system (login item), it no longer opens the settings window — it quietly sits in the menu bar, as a background helper should. But launch it by hand (Finder or Spotlight) and settings open — so you can reach them even if you lost the icon in a crowded menu bar. We tell the two apart by HOW the system launched the app (login vs your double-click), not by the autostart toggle.",
            ]),
        Release(version: "0.2.48",
            ru: [
                "«не» теперь чинится даже после латинского слова. Раньше после английского слова или бренда «yt» бережно оставляли как есть — вдруг это «yt» = YouTube. Но «не» — одно из самых частых слов в русском, и «instagram не работает», набранное в неверной раскладке, застревало как «instagram yt работает». Теперь «yt» всегда превращается в «не». (Если ты правда имел в виду английское «yt» — верни хоткеем.)",
            ],
            en: [
                "«не» now gets fixed even after a Latin word. Before, after an English word or a brand, «yt» was kept as-is in case it meant YouTube. But «не» is one of the most common words in Russian, and «instagram не работает» typed in the wrong layout got stuck as «instagram yt работает». Now «yt» always becomes «не». (If you really did mean English «yt», switch it back with the hotkey.)",
            ]),
        Release(version: "0.2.47",
            ru: [
                "Починили зависание при удалении модели распознавания. В Настройки → Голосовой набор нажатие на корзину у модели могло намертво подвесить окно — вплоть до «Завершить принудительно». Причина: тяжёлая работа (освобождение модели и удаление ~465 МБ файлов) шла в главном потоке и морозила интерфейс. Теперь удаление уходит в фон, окно остаётся живым, а кнопка на время показывает «Удаляю…».",
            ],
            en: [
                "Fixed a freeze when deleting a recognition model. In Settings → Voice, clicking the trash icon on a model could hang the window solid — up to a Force Quit. Cause: the heavy work (releasing the model and removing ~465 MB of files) ran on the main thread and locked the UI. Now deletion runs in the background, the window stays alive, and the button briefly shows “Deleting…”.",
            ]),
        Release(version: "0.2.46",
            ru: [
                "Языковой пакет для перевода теперь скачивается прямо в приложении. Раньше надо было уйти в Системные настройки и догадаться, куда там нажать, — совсем неочевидно. Теперь в Настройки → Перевод есть кнопка «Скачать»: пакет RU↔EN загрузится на месте (система разок спросит подтверждение), окно закроется само.",
                "Нажал перевод, а пакет ещё не установлен — теперь всплывает подсказка с кнопкой «Скачать» прямо в ней. Один тап — и перевод настроен, без похода в дебри системных настроек. И, разумеется, никакой «тихой» конвертации раскладки вместо перевода.",
                "Кнопка «Системный лог» переехала из «Голосового набора» в «О программе», к «Написать разработчику». Лог всегда был про всё приложение, а не только про диктовку, — теперь он там, где его логично искать.",
                "Всплывающие плашки (уведомление об обновлении, «запомнил слово», подсказки) больше не сливаются в светлой теме системы. Фон у них всегда тёмный, а цвет текста по ошибке брался из системной темы — в светлой выходил тёмным по тёмному, еле читаемо. Теперь плашки читаются при любой теме macOS.",
            ],
            en: [
                "The translation language pack now downloads right inside the app. Before, you had to leave for System Settings and guess where to tap — not obvious at all. Now Settings → Translate has a “Download” button: the RU↔EN pack loads on the spot (the system asks once to confirm), and the window closes itself.",
                "Press translate with the pack not yet installed and a hint now pops up with a “Download” button right in it. One tap and translation is set up — no expedition into System Settings. And, of course, no more silent layout conversion in place of a translation.",
                "The “System log” button moved from “Voice” to “About”, next to “Email the developer”. The log was always about the whole app, not just dictation — now it lives where you’d look for it.",
                "Pop-up cards (update notice, “learned a word”, hints) no longer blend into the background in the system’s light theme. Their background is always dark, but the text colour mistakenly followed the system theme — in light mode it came out dark-on-dark, barely legible. Now the cards are readable whatever your macOS theme.",
            ]),
        Release(version: "0.2.45",
            ru: [
                "Хоткей на клавише «`» теперь срабатывает на любой клавиатуре — и ANSI (US), и ISO (европейские/российские). На ISO эта клавиша физически в другом месте и с другим кодом: раньше из-за этого хоткей мог не сработать, а вместо тильды набирался «§». Теперь распознаём обе.",
                "Перевод: если для него не установлен языковой пакет, честно подсказываем «нужен языковой пакет → Настройки → Перевод», а не молчим. И звук подтверждения теперь звучит только когда перевод реально случился.",
            ],
            en: [
                "The hotkey on the “`” key now works on any keyboard — both ANSI (US) and ISO (European). On ISO that key sits in a different spot with a different code: the hotkey used to miss and “§” typed instead of a tilde. Now we recognize both.",
                "Translation: if the language pack isn’t installed, we now say so plainly (“language pack needed → Settings → Translate”) instead of staying silent. And the confirmation sound now plays only when a translation actually happened.",
            ]),
        Release(version: "0.2.44",
            ru: [
                "Плашка «Слушаю» теперь появляется у текстового курсора, а не у курсора мыши — в нативных полях (Notes, Mail, Pages, поля Safari). В web- и Electron-приложениях (Chrome, VS Code, Slack), где macOS не отдаёт позицию курсора, она остаётся у мыши. Заодно плашка стала по ширине текста, а не наугад, с живым waveform по громкости голоса.",
                "Перевод теперь описан в онбординге: как это работает (выдели текст → нажми хоткей), можно попробовать прямо в песочнице. И честно показано, что нужен одноразовый языковой пакет — его ставит система, кнопкой; без него переводить нечем.",
                "Подпись хоткея больше не путает: клавиша «`» теперь так и подписана, а не буквой «ё» (её на Mac-клавиатуре там нет — она на «\\»). Раньше при записи на русской раскладке подпись бралась не с той стороны.",
                "Запускаешь Keyboop, когда он уже работает — просто открываются настройки (и иконка появляется в Доке, чтобы вернуться в приложение, если в строке меню тесно), а не сообщение «уже запущено». Закрыл окно — иконка из Дока уходит.",
                "Кнопку «Показать лог» переименовали в «Системный лог» — чтобы не путать её с историей диктовки.",
                "В строке меню во время диктовки — наш значок-клавиша с живым waveform по громкости голоса, вместо микрофона с точкой.",
                "Провели полный аудит безопасности и подтянули приватность: ключ шифрования истории диктовки переехал в Keychain (а не в файле рядом), скачанные модели проверяются по контрольной сумме, а в полях пароля Keyboop не читает выделение. Ничего о тебе по-прежнему не покидает Mac.",
            ],
            en: [
                "The “Listening” pill now shows up at the text caret, not the mouse cursor — in native fields (Notes, Mail, Pages, Safari fields). In web/Electron apps (Chrome, VS Code, Slack), where macOS doesn’t expose the caret, it stays at the mouse. The pill is now sized to its text, with a live waveform driven by your voice level.",
                "Translation is now explained in onboarding: how it works (select text → press the hotkey), and you can try it right in the sandbox. It’s honest about the one-time language pack — the system installs it via a button; without it there’s nothing to translate with.",
                "The hotkey label no longer confuses: the “`” key now reads as “`”, not the letter “ё” (which isn’t there on a Mac keyboard — it’s on “\\”). Recording on a Russian layout used to grab the label from the wrong side.",
                "Launch Keyboop while it’s already running and it simply opens Settings (and shows a Dock icon so you can get back to it if the menu bar is crowded), instead of an “already running” message. Close the window and the Dock icon goes away.",
                "Renamed the “Show log” button to “System log” — so it isn’t confused with the dictation history.",
                "In the menu bar during dictation — our keycap mark with a live waveform driven by your voice level, instead of a mic-and-dot.",
                "Ran a full security audit and tightened privacy: the dictation-history encryption key moved to the Keychain (no longer a file next to the data), downloaded models are verified by checksum, and Keyboop won’t read a selection in password fields. As always, nothing about you leaves your Mac.",
            ]),
        Release(version: "0.2.43",
            ru: [
                "Перестали превращать окончание слова в кашу. Если поправить хвост слова (стереть пару букв, набрать заново), а в этот момент мигнёт фокус (уведомление, баннер) — Keyboop больше не «забывает» начало слова и не дёргает раскладку у одного окончания (был баг: «…ть» вдруг становилось «…nm»). Теперь короткие русские окончания (ть, ся, сь, ет) не уезжают в латиницу, а английские слова, набранные на русской раскладке (the, so, no, can…), по-прежнему чинятся.",
            ],
            en: [
                "Stopped turning a word's ending into gibberish. If you fix the tail of a word (delete a couple letters, retype) and the focus flickers at that moment (a notification, a banner), Keyboop no longer “forgets” the start of the word and flips the layout of just the ending (there was a bug where “…ть” suddenly became “…nm”). Short Russian endings (ть, ся, сь, ет) no longer slide into Latin, while English words typed on the Russian layout (the, so, no, can…) are still fixed.",
            ]),
        Release(version: "0.2.42",
            ru: [
                "Починили «переключилось только окончание». Если набрать слово, поправить опечатку в конце (стереть пару букв и набрать заново) и продолжить — раньше слово могло застрять наполовину в одной раскладке, наполовину в другой («привtn», «приdет»). Теперь Keyboop собирает такие слова целиком: на пробеле он видит всё слово и, если его конверсия даёт настоящее слово из словаря, чинит целиком. Намеренно двуязычные штуки (API-ключ, C++код, x-ray) при этом не трогаются — они не складываются в словарное слово, значит так и задумано.",
            ],
            en: [
                "Fixed “only the ending switched layout.” If you typed a word, fixed a typo at the end (delete a couple letters, retype) and kept going, the word could get stuck half in one layout, half in the other (“привtn”, “приdет”). Keyboop now reassembles the whole word: at the space it sees the full token and, if converting it yields a real dictionary word, fixes the whole thing. Intentionally bilingual bits (API-ключ, C++код, x-ray) are left alone — they don't form a dictionary word, so they're meant to be that way.",
            ]),
        Release(version: "0.2.41",
            ru: [
                "Раскладка больше не «залипает» в быстром циклическом переключении. В редких случаях авто-переключение могло войти в петлю и замелькать туда-сюда (RU↔EN) десятки раз в секунду. Добавили предохранитель: как только Keyboop замечает такую осцилляцию, он на пару секунд замораживает авто-переключение и разрывает цикл. Ручное переключение по хоткею работает как обычно.",
            ],
            en: [
                "The layout no longer gets stuck flipping back and forth. In rare cases auto-switching could enter a loop and flicker RU↔EN dozens of times per second. We added a circuit breaker: the moment Keyboop notices such oscillation, it freezes auto-switching for a couple of seconds and breaks the cycle. Manual hotkey switching works as usual.",
            ]),
        Release(version: "0.2.40",
            ru: [
                "Рядом с хоткеем диктовки появилась кнопка «Проверить». Нажми — приложение попросит нажать хоткей и покажет, что реально поймал tap и совпадает ли с тем, что записано в настройках. Помогает понять, почему хоткей «не срабатывает».",
            ],
            en: [
                "A 'Test' button now appears next to the dictation hotkey. Press it — the app asks you to press your hotkey and shows exactly what the tap detected vs. what's saved. Helps diagnose why a hotkey 'doesn't work'.",
            ]),
        Release(version: "0.2.39",
            ru: [
                "Онбординг теперь сразу рекомендует Parakeet по имени: объясняет, что модель офлайн и не зацикливается на длинных фразах. Кнопка скачивания стала заметнее — акцентный цвет. Просто нажми один раз, дальше всё на твоём Mac.",
                "Горячая клавиша переключения в режиме «клавиша + модификатор» (например, ⌥`) больше не печатает случайный символ в поле после переключения раскладки.",
            ],
            en: [
                "Onboarding now recommends Parakeet by name: explains it's offline and won't loop on long phrases. The download button is now accent-coloured — hard to miss. One tap, then it all stays on your Mac.",
                "Layout switch hotkey in 'key + modifier' mode (e.g. ⌥`) no longer types a stray character into the field after switching.",
            ]),
        Release(version: "0.2.38",
            ru: [
                "Диктовка на длинных текстах больше не зацикливается. Whisper иногда повторял одно слово или фразу много раз подряд — вернули штатный механизм, который такие срывы распознаёт и переписывает. (А движок по умолчанию, Parakeet, этим вообще не страдает — он другой архитектуры.)",
                "Автозамена: теперь можно выбрать, по каким клавишам разворачивать сокращение — Пробел, Enter, Tab (любая комбинация). Снимешь все галочки — автозамена отключена, так и подписано.",
                "Диктовка для новых пользователей теперь по умолчанию «переключение»: нажал — начал, нажал ещё — остановил. Кто уже настроил под себя — не трогаем. Поменять можно в Настройки → Голосовой набор.",
                "Иконка Keyboop теперь появляется в Доке, пока открыты настройки — чтобы вернуться в приложение, даже если в строке меню тесно и нашей иконки не видно.",
                "Онбординг: системный запрос микрофона больше не выскакивает поверх приветствия — анимацию видно полностью.",
                "Если запущен Punto Switcher — предупреждаем о конфликте (он тоже переключает раскладку) и предлагаем его закрыть прямо из Keyboop.",
                "Final Cut: если установлены две версии, теперь в исключения попадают обе (раньше цеплялась только одна).",
            ],
            en: [
                "Dictation no longer gets stuck on long text. Whisper would sometimes repeat one word or phrase over and over — we brought back the built-in mechanism that catches and rewrites those breakdowns. (The default engine, Parakeet, doesn't suffer from this at all — different architecture.)",
                "Snippets: you can now choose which keys expand a shortcut — Space, Enter, Tab (any combination). Uncheck them all and snippets are off, as labelled.",
                "Dictation now defaults to “toggle” for new users: press to start, press again to stop. If you already set your preference, we leave it. Change it in Settings → Voice.",
                "The Keyboop icon now appears in the Dock while Settings are open — so you can get back to the app even when the menu bar is crowded and our icon isn't visible.",
                "Onboarding: the system microphone prompt no longer pops over the welcome animation — you get to see it in full.",
                "If Punto Switcher is running, we now warn about the conflict (it also switches layouts) and offer to quit it right from Keyboop.",
                "Final Cut: if two versions are installed, both now land in exceptions (only one used to stick).",
            ]),
        Release(version: "0.2.37",
            ru: [
                "Починили редактор автозамены. Кнопка удаления (корзина) больше не прячется за правым краем — всё умещается в окне, без горизонтального скролла. Ячейки теперь редактируются по первому клику (раньше нужен был двойной). Введённое сохраняется при любом действии — по Tab, по клику в другую ячейку, не только по Enter. И добавление строки снизу больше не глючит (текст не пропадает).",
            ],
            en: [
                "Fixed the autoreplace editor. The delete (trash) button no longer hides past the right edge — everything fits in the window, no horizontal scroll. Cells now edit on the first click (a double-click used to be needed). What you type is saved on any action — Tab, clicking another cell, not just Enter. And adding a row at the bottom no longer glitches (text doesn't vanish).",
            ]),
        Release(version: "0.2.36",
            ru: [
                "Перестали «переключать» слово, когда правишь опечатку. Если стереть букву внутри слова и допечатать заново, Keyboop больше не дёргает раскладку посреди слова (раньше из-за этого хвост слова мог уехать в чужую раскладку, типа «пройдём» + «ся»→«cz»). Финальная проверка всё равно отрабатывает на пробеле.",
                "Левый ⌥ и левый ⌃ теперь есть прямо в списке горячих клавиш переключения — выбрал и готово, без «Свой…».",
                "Дефисные термины: «e-ink», «wi-fi», «t-shirt», «x-ray» и т.п. теперь переключаются целиком (по списку известных терминов). Обычные русские слова через дефис — «из-за», «что-то», «по-русски» — мы по-прежнему не трогаем.",
            ],
            en: [
                "Stopped “switching” a word while you fix a typo. Delete a letter inside a word and retype it — Keyboop no longer flips the layout mid-word (which used to send the tail into the wrong layout, like «пройдём» + «ся»→«cz»). The final check still runs on the space.",
                "Left ⌥ and left ⌃ are now in the switch-hotkey list directly — pick and go, no “Custom…” needed.",
                "Hyphenated terms: «e-ink», «wi-fi», «t-shirt», «x-ray» and friends now switch as a whole (from a known-terms list). Regular hyphenated Russian words — «из-за», «что-то», «по-русски» — are still left untouched.",
            ]),
        Release(version: "0.2.35",
            ru: ["Починили назначение своей горячей клавиши переключения. Раньше при выборе «Свой…» одиночный модификатор (например левый Option) не записывался — поле «висело» в режиме записи, и любое нажатие воспринималось не так. Теперь нажми и отпусти один модификатор (левый/правый Option, Cmd…) — он и станет переключателем; Esc — отмена записи."],
            en: ["Fixed assigning your own switch hotkey. Before, picking “Custom…” and pressing a single modifier (e.g. left Option) didn't register — the field stayed stuck in recording mode and any keypress misbehaved. Now press and release one modifier (left/right Option, Cmd…) and it becomes the switcher; Esc cancels recording."]),
        Release(version: "0.2.34",
            ru: ["«tot» теперь переключается в «ещё». Одно из самых частых русских слов раньше застревало латиницей, потому что «tot» — ещё и английское слово (малыш / «tot up»), и мы его берегли. Решили: «ещё» важнее — теперь форсим (если вдруг печатаешь английское «tot» — переключи хоткеем обратно)."],
            en: ["«tot» now switches to «ещё». One of the most common Russian words used to get stuck as Latin because «tot» is also an English word, and we protected it. We decided «ещё» wins — now we force it (if you do type English «tot», switch it back with the hotkey)."]),
        Release(version: "0.2.33",
            ru: ["Обучение на отмене больше не пристаёт после каждой отмены. Теперь Keyboop предлагает добавить слово в исключения, только если ты отменял его переключение ТРИ раза (счётчик копится между сессиями и со временем сбрасывается). Одиночные отмены — молча, слово просто не трогается в этой сессии."],
            en: ["Learn-on-undo no longer nags after every undo. Keyboop now offers to add a word to exceptions only after you've undone its switch THREE times (the count builds up across sessions and decays over time). One-off undos stay silent — the word is just left alone for that session."]),
        Release(version: "0.2.32",
            ru: ["Поправил раскладку слова сам (хоткеем) — следующий пробел больше не перекинет его обратно «не туда». Раньше авто-переключение могло тут же отменить твою ручную правку: исправляешь, жмёшь пробел — а оно снова не туда."],
            en: ["Fix a word's layout yourself (hotkey) and the next space won't flip it back. Before, auto-switching could instantly undo your manual fix — you'd correct it, press space, and it'd go wrong again."]),
        Release(version: "0.2.31",
            ru: ["Раскладка переключается умнее в обе стороны. Чаще ловится «ну» (раньше застревало латиницей как «ye»), английские сокращения с апострофом (i'm, don't, let's, that's, can't…) и английские i/u/a на русской раскладке. По нашему фразовому тесту промахов стало вдвое меньше — и при этом верный текст по-прежнему не трогаем (точность не просела)."],
            en: ["Smarter layout switching both ways. Better at catching «ну» (it used to get stuck as Latin «ye»), English apostrophe contractions (i'm, don't, let's, that's, can't…), and single i/u/a typed on the Russian layout. Our phrase test shows ~half as many misses — while correct text is still left untouched (precision unchanged)."]),
        Release(version: "0.2.30",
            ru: ["Английский, набранный по ошибке на РУССКОЙ раскладке, теперь переключается заметно лучше: одиночные i/u/a и частые сокращения (idk, tbh, ngl, pls, brb, wtf…). Раньше английский-на-кириллице ловился слабо — теперь в полтора раза меньше промахов, и при этом верный текст по-прежнему не трогаем."],
            en: ["English typed by mistake on the RUSSIAN layout now switches much better: single i/u/a and common abbreviations (idk, tbh, ngl, pls, brb, wtf…). English-on-Cyrillic used to be caught poorly — now ~1.5× fewer misses, while correct text is still left untouched."]),
        Release(version: "0.2.29",
            ru: ["Частые двухбуквенные слова теперь переключаются даже когда они стоят отдельно или первыми: «да», «но», «на», «по», «от», «он». Раньше такие коротыши чинились только в середине фразы."],
            en: ["Common two-letter words now switch even when they stand alone or come first: «да», «но», «на», «по», «от», «он». Before, such short ones only got fixed mid-phrase."]),
        Release(version: "0.2.28",
            ru: ["«ща» (разговорное «сейчас») больше не превращается в «of» — добавили в словарь-исключение."],
            en: ["“ща” (Russian shorthand for “now”) is no longer turned into “of” — added to the keep-list."]),
        Release(version: "0.2.27",
            ru: ["Всплывающие баннеры (вроде «Запомнил…») теперь закрываются по-человечески: крестик работает, баннер сам уходит через 5 секунд, можно смахнуть вправо или просто кликнуть. И вид аккуратнее — компактный, по ширине текста, логотип слева с ровными полями."],
            en: ["Pop-up banners (like “Got it…”) now dismiss properly: the close button works, the banner auto-hides after 5 seconds, and you can swipe it right or just click it. Tidier look too — compact, sized to the text, with the logo left and even margins."]),
        Release(version: "0.2.26",
            ru: ["Две копии Keyboop больше не запустятся одновременно. Раньше вторая копия дралась с первой за каждую клавишу — выходила мешанина (дубли букв, латинские огрызки). Теперь вторая тихо уступает: один зверёк на клавиатуру.",
                 "Появился ЭКСПЕРИМЕНТАЛЬНЫЙ потоковый набор (Настройки → Голос): текст печатается по мере речи, не дожидаясь конца фразы. Очень экспериментально, по умолчанию выключено, нужна отдельная модель."],
            en: ["Two copies of Keyboop can no longer run at once. Before, a second copy fought the first over every keystroke — producing garbled text (doubled letters, stray Latin). Now the second one quietly steps aside: one critter per keyboard.",
                 "Added EXPERIMENTAL streaming dictation (Settings → Voice): text types as you speak, without waiting for you to finish. Very experimental, off by default, needs a separate model."]),
        Release(version: "0.2.25",
            ru: ["Ручное переключение раскладки последнего слова больше не выдаёт мешанину вроде «лоkjrfyj» и не «теряется». Отмена, нажатая пока зверёк дочиняет предыдущее слово, теперь не пропадает, а ждёт своей очереди; а слово, у которого начало уже перескочило в кириллицу, само доводится до конца — без полусырых хвостов."],
            en: ["Manually switching the last word's layout no longer spits out a mash-up like “лоkjrfyj” or quietly does nothing. An undo pressed while the critter is still finishing the previous word no longer vanishes — it waits its turn; and a word whose start already flipped to Cyrillic now finishes the job itself, no half-raw tails left behind."]),
        Release(version: "0.2.24",
            ru: ["Устранено зависание системы при первом нажатии диктовки после старта. Загрузка модели Whisper теперь идёт в фоне — мышь и клавиатура не замерзают пока модель грузится с диска."],
            en: ["Fixed a system-wide freeze that hit on the first dictation press after launch. The Whisper model now loads in the background — mouse and keyboard stay responsive while it warms up."]),
        Release(version: "0.2.23",
            ru: ["Первый запуск стал тише: теперь Keyboop не выводит несколько уведомлений о доступе к Accessibility подряд. Пока открыт онбординг — он ведёт тебя через все разрешения, дополнительные диалоги не появляются."],
            en: ["First launch is quieter now: Keyboop no longer fires multiple Accessibility permission prompts one after another. While onboarding is open, it handles all the permissions itself — no extra dialogs pop up."]),
        Release(version: "0.2.22",
            ru: ["Окно истории диктовки теперь почти непрозрачное по умолчанию (80%) — было слишком «стеклянным». Настраивается правым кликом или длинным удержанием на окне.",
                 "В онбординге появилась подсказка про историю как страховку: если надиктованное не попало куда надо — оно в «Истории» из меню значка, двойной клик скопирует. На help-странице — отдельный Q&A на этот случай."],
            en: ["The dictation history window is now nearly opaque by default (80%) — it was too 'glassy' before. Adjust with a right-click or a long-press on the window.",
                 "Onboarding now mentions history as a safety net: if your dictation missed the target, it's in History (menu icon), double-click to copy. The help page has a dedicated Q&A for this."]),
        Release(version: "0.2.21",
            ru: ["Конец «щёлканью» на словах-исключениях. Раньше при наборе слова из словаря/исключений (например «гифки») переключение «на лету» дёргало его на 4-й букве в латиницу, а на границе возвращало обратно. Теперь, пока ты дописываешь слово-исключение, на лету его не трогаем вовсе — никаких метаний туда-сюда."],
            en: ["No more flicker on dictionary/exception words. Before, typing a word like “гифки” made the on-the-fly switch flip it to Latin at the 4th letter, then flip back at the word boundary. Now, while you're still typing an exception word, we don't touch it on the fly at all — no more back-and-forth."]),
        Release(version: "0.2.20",
            ru: ["Полная ревизия локализации: причесали интерфейс на обоих языках. Места, где у англоязычных пользователей ещё проскакивал русский — диалоги доступа, назначение хоткея, индикатор диктовки «Слушаю…», список хранения истории, описания моделей и тултипы — теперь корректно переключаются RU/EN."],
            en: ["Full localization pass: tidied the interface in both languages. Spots that still showed Russian to English users — permission dialogs, the hotkey assignment, the “Listening…” dictation indicator, the history-retention list, model descriptions and tooltips — now switch RU/EN correctly."]),
        Release(version: "0.2.19",
            ru: ["Автозамена больше не оставляет хвостов: триггер всегда стирается целиком — без «прилипшего» символа в конце и без лишнего «длинного» пробела. Раньше при быстром наборе (и особенно в русской раскладке) стирание гналось с приложением: триггер мог остаться, а раскрытие «всплыть» после него. Теперь клавиша-граница (пробел/Tab/Enter), раскрывающая сниппет, обрабатывается нами целиком — гонки нет."],
            en: ["Autoreplace no longer leaves leftovers: the trigger is always fully removed — no stray character at the end, no extra “long” space. Previously, fast typing (especially on the Russian layout) raced the deletion against the app: the trigger could survive and the expansion appear after it. Now the boundary key (space/Tab/Enter) that fires a snippet is handled entirely by us — no race."]),
        Release(version: "0.2.18",
            ru: ["«Учиться на отмене» теперь работает по-человечески: откатил переключение слова — Keyboop спросит баннером в правом верхнем углу, добавить ли его в исключения. Нажал «Не надо» — больше про это слово не спросит. (Раньше пытался запоминать молча после нескольких откатов, но это почти не срабатывало.)",
                 "«гифки» больше не улетает в латиницу — добавили слово и его формы в словарь."],
            en: ["“Learn from undo” now works properly: undo a word's switch and Keyboop asks — with a banner in the top-right — whether to add it to exceptions. Tap “No thanks” and it won't ask about that word again. (It used to try to memorize silently after several undos, which almost never fired.)",
                 "“гифки” no longer gets flung into Latin — added the word and its forms to the dictionary."]),
        Release(version: "0.2.17",
            ru: ["Автозамена: сниппеты теперь сохраняются в том порядке, как ты их добавлял (раньше пересортировывались по алфавиту) — новые просто встают вниз. Вернули кнопку удаления строки (в прошлой версии она пропадала) и кнопку «+»; добавлять можно и просто кликом по пустой строке. Заполненные строки сразу встают наверх по порядку, без пустых дыр между ними."],
            en: ["Snippets: entries now keep the order you added them in (they used to get re-sorted alphabetically) — new ones just go to the bottom. Restored the row delete button (it went missing last version) and the “+” button; you can also add a row by clicking an empty one. Filled rows tidy up to the top right away, with no empty gaps between them."]),
        Release(version: "0.2.16",
            ru: ["Автозамена стала удобнее: строки добавляются прямо кликом по пустому полю (или кнопкой «+»), а в поля наконец работает вставка из буфера (Cmd+V, как и копирование/вырезание/выделить всё/отмена) — раньше в них ничего не вставлялось. Заодно текст в полях выровнялся по высоте, список стал выше, а кнопка-корзина — компактнее. Заполненные строки сами поднимаются наверх, пустые остаются снизу.",
                 "Окно знакомства больше не уползает вправо, когда меняешь его высоту."],
            en: ["Snippets got friendlier: add rows by clicking an empty field (or the “+” button), and pasting finally works in the fields (Cmd+V, plus copy/cut/select-all/undo) — they used to ignore it. Text in the fields is vertically aligned now, the list is taller, and the trash button is slimmer. Filled rows float to the top, empty ones stay at the bottom.",
                 "The welcome window no longer drifts to the right when you resize its height."]),
        Release(version: "0.2.15",
            ru: ["Программы-исключения теперь предзаполняются сами: при запуске Keyboop находит установленные видеоредакторы, терминалы и код-редакторы и сразу заносит их в список (видеоредакторы и терминалы — выключено, код-редакторы — мягкий режим). Всё видно в Настройках → Исключения, любую программу можно переключить или убрать — твой выбор приоритетнее, удалённую не вернём."],
            en: ["App exceptions now pre-populate themselves: on launch Keyboop finds your installed video editors, terminals and code editors and adds them to the list (editors and terminals — off, code editors — soft). It's all visible in Settings → Exceptions; change or remove any of them — your choice wins, and removed ones won't come back."]),
        Release(version: "0.2.14",
            ru: ["Починили потерю первой буквы: в Spotlight и поиске на сайтах первый символ больше не оставался в старой раскладке («adguard» → «adguard», а не «фdguard»).",
                 "Видеоредакторы (Final Cut, Premiere, DaVinci…) и терминалы теперь по умолчанию не трогаются вовсе, а код-редакторы (VS Code, Xcode…) — в мягком режиме. Раньше это надо было настраивать руками, и в Final Cut Keyboop мог мешать. Свои программы по-прежнему добавляются в Настройки → Исключения.",
                 "«Проверить обновления» теперь показывает окно со статусом (проверяю → есть обновление / актуальная версия), а не молчит."],
            en: ["Fixed a dropped first letter: in Spotlight and on-site search the first character no longer stayed in the wrong layout (“adguard” → “adguard”, not “фdguard”).",
                 "Video editors (Final Cut, Premiere, DaVinci…) and terminals are now left alone by default, and code editors (VS Code, Xcode…) run in soft mode. This used to need manual setup, and Keyboop could interfere in Final Cut. Add your own apps in Settings → Exceptions.",
                 "“Check for Updates” now shows a status window (checking → update available / up to date) instead of staying silent."]),
        Release(version: "0.2.13",
            ru: ["Мелочь для глаза: пункт «Проверить обновления…» в меню у часов встал ровно по левому краю, как остальные (раньше съезжал вправо из-за системной иконки у «Настройки»)."],
            en: ["A small visual fix: the “Check for Updates…” item in the menu now lines up flush-left like the others (it used to drift right because of the system gear on “Settings”)."]),
        Release(version: "0.2.12",
            ru: ["Обновления переехали в отдельный раздел настроек «Обновления» — раньше прятались в «Общих», их не находили. И логичнее: «Ставить сразу без вопросов» теперь сам включает «Проверять обновления» и блокирует его (без проверки тихая установка невозможна).",
                 "Чиним слова, набранные с концевой буквой б/ю/ж: «yj;» → «нож» (раньше выходило «но;» — терялась буква), «[kt,» → «хлеб».",
                 "Чиним слова с цифрой на конце: «ghbdtn2» → «привет2». Короткие технические токены (gj1, h2o) не трогаем."],
            en: ["Updates moved to their own “Updates” settings section — they used to hide under “General” and people couldn't find them. Also smarter: “Install right away” now turns on “Check for updates” and locks it (silent install is impossible without checking).",
                 "Words ending in б/ю/ж now fix correctly: “yj;” → “нож” (was “но;”, a lost letter), “[kt,” → “хлеб”.",
                 "Words with a trailing digit get fixed: “ghbdtn2” → “привет2”. Short technical tokens (gj1, h2o) are left alone."]),
        Release(version: "0.2.11",
            ru: ["В меню у часов появился пункт «Проверить обновления…» — удобно глянуть свежую версию вручную."],
            en: ["The menu by the clock now has a “Check for Updates…” item — handy to look for a fresh version manually."]),
        Release(version: "0.2.10",
            ru: ["Чиним слова со скобкой/кавычкой/тире перед ними: «(tckb» теперь превращается в «(если», а раньше упрямо оставалось как есть. Раньше любой символ перед словом (скобка, кавычка, дефис) ломал распознавание целиком."],
            en: ["Words with a bracket/quote/dash stuck to them now get fixed: \"(tckb\" turns into \"(если\" — before, any character in front of a word (bracket, quote, dash) broke detection entirely."]),
        Release(version: "0.2.9",
            ru: ["Главное: авто-переключение стало НАДЁЖНЫМ при быстром сплошном наборе. Раньше при печати без пауз часть слов чинилась, часть нет, а иногда первые буквы оставались в старой раскладке («gпривет»). Причина — приложение путало собственные нажатия с твоими по таймеру; теперь оно метит свой ввод и не теряет ни одной твоей буквы.",
                 "Стыдный недосмотр: у новых пользователей авто-переключение было выключено из коробки. Теперь включено по умолчанию.",
                 "Enter теперь тоже чинит слово — «ghbdtn» + Enter в чате превратится в «привет» перед отправкой."],
            en: ["Big one: automatic switching is now RELIABLE when you type fast and continuously. Before, some words got fixed and some didn't, and sometimes the first letters stayed in the wrong layout (\"gпривет\"). The cause: the app told its own keystrokes from yours by timing; now it tags its own input and never drops a letter of yours.",
                 "An embarrassing oversight: for new users, auto-switching was off out of the box. It's on by default now.",
                 "Enter now fixes the word too — \"ghbdtn\" + Enter in a chat becomes \"привет\" before it sends."]),
        Release(version: "0.2.8",
            ru: ["Знакомство теперь открывается заставкой во весь экран: на тёмном фоне K собирается из чертежа, затем плавно растворяется — и появляется приветствие. Коротко, один раз, без звука.",
                 "Пересмотреть можно когда угодно — пункт «Знакомство…» в меню у часов."],
            en: ["The intro now opens full-window: on a dark backdrop the K assembles itself from a blueprint, then gently dissolves into the welcome screen. Short, once, silent.",
                 "Revisit it anytime — “Welcome…” in the menu by the clock."]),
        Release(version: "0.2.6",
            ru: ["Баннер обновления довели до ума: крупный логотип, ровные поля со всех сторон, а коралловая кнопка «Обновить сейчас» теперь надёжно заметна в любом окружении (раньше в живом окне могла тускнеть до серой)."],
            en: ["The update banner is properly polished now: a larger logo, even padding all around, and the coral “Update now” button is reliably vivid everywhere (it could dim to grey in the live window before)."]),
        Release(version: "0.2.5",
            ru: ["Маленькая пасхалка в тему: теперь Keyboop находится в Spotlight, даже если набрать его имя вслепую на русской раскладке — «лунищщз». А ещё по «punto», «раскладка», «switcher»."],
            en: ["A fitting little easter egg: Keyboop now turns up in Spotlight even if you type its name in the wrong layout — “лунищщз”. Also by “punto”, “switcher”."]),
        Release(version: "0.2.4",
            ru: ["Баннер обновления стал аккуратнее: тёмный фон, кнопка «Обновить сейчас» теперь коралловая и заметная, больше воздуха, текст короче."],
            en: ["The update banner is tidier now: dark background, a clear coral “Update now” button, more breathing room, shorter text."]),
        Release(version: "0.2.3",
            ru: ["Песочница в окне знакомства теперь на две строки — удобнее попробовать целую фразу.",
                 "Высоту окна знакомства можно менять под себя."],
            en: ["The sandbox in the welcome window is now two lines — handier for trying a whole phrase.",
                 "The welcome window height is now resizable."]),
        Release(version: "0.2.2",
            ru: ["Про обновление теперь спрашивает наш собственный аккуратный баннер у часов («Обновить сейчас» / «Обновлять автоматически») — вместо системного уведомления. Никаких лишних разрешений на уведомления."],
            en: ["The \"update ready\" prompt is now our own tidy banner near the clock (\"Update now\" / \"Update automatically\") instead of a system notification. No extra notification permissions."]),
        Release(version: "0.2.1",
            ru: ["Причесали подзаголовки в настройках и окне знакомства — читаемые, ровные, в фирменном коралловом стиле (раньше были мелкие, серые и с кривым отступом).",
                 "В окне знакомства разъехались слипшиеся ряды выбора горячих клавиш — стало просторнее."],
            en: ["Tidied up section headers in Settings and the welcome window — readable, aligned, in the coral brand style (they used to be tiny, grey and oddly indented).",
                 "Welcome-window hotkey rows are no longer cramped — more breathing room."]),
        Release(version: "0.2.0",
            ru: ["Keyboop теперь сам находит новые версии. Когда выйдет новая — покажет уведомление с кнопкой «Обновить сейчас». Надоест нажимать каждый раз — там же кнопка «Обновлять автоматически»: дальше ставим тихо, в простое, когда ты отошёл, не мешая. Всё настраивается/выключается в Настройках → Обновления.",
                 "Обновления подписаны и проверяются — подсунуть поддельную сборку под видом апдейта не выйдет. Проверка «есть ли новее?» отправляет только твой IP и номер версии, как любой заход на сайт. Ничего из того, что ты печатаешь или диктуешь."],
            en: ["Keyboop now finds new versions on its own. When one ships, it shows a notification with an \"Update now\" button. Tired of clicking each time? There's an \"Update automatically\" button right there — after that we install quietly while you're away. All configurable in Settings → Updates.",
                 "Updates are signed and verified — no one can slip you a fake build disguised as an update. The \"is there a newer one?\" check sends only your IP and version number, like any website visit. Nothing you type or dictate."]),
        Release(version: "0.1.75",
            ru: ["Хоткей диктовки по умолчанию теперь — правый ⌥: зажал, говоришь, отпустил. Его (как и хоткей раскладки) можно поменять прямо в окне знакомства или в настройках.",
                 "Доступ к раскладке подхватывается на лету: выдал «Универсальный доступ» — переключение включается сразу, перезапуск не нужен. А если Keyboop запущен из образа или Загрузок — подскажем перетащить его в «Программы».",
                 "Модели распознавания — теперь в одном списке: любую можно скачать, активировать и удалить, чтобы не занимала место (переключатель Whisper/Parakeet убрали — меньше путаницы).",
                 "Хоткей перевода теперь тоже меняется в настройках."],
            en: ["Default dictation hotkey is now the right ⌥: hold, speak, release. It (and the layout hotkey) can be changed right in the welcome window or in settings.",
                 "Accessibility is picked up on the fly: grant it and switching turns on immediately — no restart. And if Keyboop is running from the disk image or Downloads, we'll nudge you to move it into Applications.",
                 "Recognition models are now in a single list: download, activate, or delete any of them to free up space (the Whisper/Parakeet switch is gone — less confusion).",
                 "The translation hotkey is now editable in settings too."]),
        Release(version: "0.1.59",
            ru: ["Предлоги-буквы теперь чинятся даже после английского слова: «room d новой» → «room в новой».",
                 "Но английские маркеры бережём по контексту: «vitamin d», «plan b», «gen z», «type o» остаются целыми.",
                 "Выбор движка распознавания: статус «используется» теперь стоит прямо напротив активной модели — и у Whisper, и у Parakeet.",
                 "Подсказки в настройках всплывают только у длинных подписей, которые не умещаются."],
            en: ["Letter-prepositions now get fixed even after an English word where they should.",
                 "But English markers are preserved by context: “vitamin d”, “plan b”, “gen z”, “type o” stay intact.",
                 "Recognition engine picker: the “in use” status now sits right next to the active model — for both Whisper and Parakeet.",
                 "Settings hints now appear only for long captions that don't fit."]),
        Release(version: "0.1.56",
            ru: ["Режим для разработчиков стал умнее: одиночные буквы и короткие сочетания (переменные, команды) не переключаются нигде — не только в IDE. Подпись в настройках теперь об этом говорит.",
                 "Без него предлоги-буквы чинятся как обычно: «d» → «в», «z» → «я» — кроме английского контекста («vitamin d» цел)."],
            en: ["Developer mode got smarter: single letters and short combos (variables, commands) are left alone everywhere — not just in IDEs. The settings caption now says so.",
                 "Without it, letter-prepositions are fixed as usual: “d” → “в” — except in English context (“vitamin d” stays intact)."]),
        Release(version: "0.1.55",
            ru: ["Детектор поумнел на коротких словах: смотрит на язык предыдущего слова. «привет yt» → «привет не», а «смотрю tv» и «Спартак vs Зенит» не трогает.",
                 "Одиночная «c» в английском тексте больше не превращается в «с»."],
            en: ["Smarter short-word detection: the previous word's language is taken into account. Mixed-in English tokens like “tv” or “vs” are left alone.",
                 "A lone “c” in English text no longer turns into “с”."]),
        Release(version: "0.1.54",
            ru: ["Длинные подсказки в настройках больше не теряются: текст усечён, а полный — во всплывающей подсказке (появляется почти сразу)."],
            en: ["Long hints in settings no longer get lost: text is trimmed, the full version shows in a tooltip (appears almost instantly)."]),
        Release(version: "0.1.53",
            ru: ["Переключение нескольких слов сразу одним хоткеем — теперь в основных настройках, сразу после ручного хоткея. Недоступно при авто-переключении, чтобы не конфликтовать. Под капотом — защита от порчи текста.",
                 "Свой звук для перевода: можно выбрать наш, системный или выключить, и настроить громкость.",
                 "Точнее с короткими словами: «c» → «с». «net» больше не трогаем — это английское слово, а не «нет».",
                 "История диктовок корректно переносится со старых версий."],
            en: ["Convert several words at once with one hotkey — now in the main settings, right after the manual hotkey. Disabled while auto-switch is on so they don't clash. Under the hood — guards against text corruption.",
                 "A dedicated translation sound: pick ours, a system one, or off, and set its volume.",
                 "Smarter on short words: “c” → “с”. “net” is left alone now — it's the English word, not “нет”.",
                 "Dictation history migrates correctly from older versions."]),
        Release(version: "0.1.52",
            ru: ["Выбор микрофона — прямо в настройках голосового набора.",
                 "Автозамена: кнопка-корзина у каждой строки, кнопка «Добавить» для удобства.",
                 "Исключения: кнопка «Добавить слово» переводит фокус на поле ввода.",
                 "История хранится в минутах (30 мин / 1 ч / 2 ч / 4 ч / 8 ч).",
                 "«с» и «tot» теперь корректно переключаются на русский."],
            en: ["Microphone selector — right in Voice settings.",
                 "Snippets: per-row trash button, Add button for convenience.",
                 "Exceptions: Add Word button focuses the input field.",
                 "History retention in minutes (30 min / 1 h / 2 h / 4 h / 8 h).",
                 "\"с\" and \"tot\" now correctly switch to Russian."]),
        Release(version: "0.1.18",
            ru: ["Длинная диктовка больше не теряет хвост — распознаётся целиком.",
                 "Под капотом подготовлен новый движок распознавания Parakeet (точнее на русском) — скоро."],
            en: ["Long dictation no longer drops the tail — it’s transcribed in full.",
                 "Groundwork for a new recognition engine, Parakeet (better Russian) — coming soon."]),
        Release(version: "0.1.15",
            ru: ["История диктовок: живое обновление, прокрутка к последней, настраиваемая прозрачность окна.",
                 "Срок хранения истории — на выбор (3 / 7 / 30 дней)."],
            en: ["Dictation history: live updates, scroll-to-latest, adjustable window translucency.",
                 "History retention is configurable (3 / 7 / 30 days)."]),
        Release(version: "0.1.12",
            ru: ["После голосового ввода ставится пробел — следующая фраза не слипается.",
                 "Отдельные настройки звука записи: вкл/выкл и громкость."],
            en: ["A space is added after dictation — the next phrase won’t stick together.",
                 "Separate recording-sound settings: toggle and volume."]),
        Release(version: "0.1.9",
            ru: ["Свои звуки старта/окончания записи.",
                 "В «О программе» — кнопка обратной связи и подписка на обновления (почта + Telegram)."],
            en: ["Custom start/stop recording sounds.",
                 "In About — a feedback button and update subscription (email + Telegram)."]),
        Release(version: "0.1.8",
            ru: ["Умнее с раскладкой: не переключаем короткие «не-слова» (например «тк»), добавлены русские сокращения."],
            en: ["Smarter layout handling: short non-words (like “тк”) aren’t switched; Russian abbreviations added."]),
        Release(version: "0.1.2",
            ru: ["Хоткей диктовки по умолчанию — ⌥` , режим «нажал-старт / нажал-стоп».",
                 "Доступ к микрофону спрашивается сам; автозапуск при входе включён."],
            en: ["Default dictation hotkey is ⌥`, toggle mode (press-start / press-stop).",
                 "Microphone access is requested automatically; launch-at-login is on."]),
    ]
}
