import Foundation
import ServiceManagement
import CoreGraphics
import AppKit   // NSAppearance для appAppearance (оформление приложения)

/// Настройки в UserDefaults.
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum Key {
        static let auto = "autoEnabled"
        static let sound = "soundEnabled"
        static let soundName = "soundName"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyMods = "hotkeyModifiers"
        static let triggerSpace = "triggerSpace"
        static let triggerEnter = "triggerEnter"
        static let triggerTab = "triggerTab"
        static let arrowsCancel = "arrowsCancel"
    }

    private init() {
        // ⌥⇧ по умолчанию (modifier-only: keyCode = -1).
        let defaultMods = Int(CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue)
        d.register(defaults: [
            // Авто-переключение раскладки — флагманская фича, ВКЛ по умолчанию. Без регистрации
            // d.bool(forKey:) отдавал false → у нового пользователя авто было ВЫКЛЮЧЕНО из коробки
            // (кракозябры не чинились — баг, замечен новым юзером 15.06). Существующим, кто уже
            // трогал тумблер, register не меняет их значение.
            Key.auto: true,
            // Чинить на лету — деф. ВКЛ (25.07). История: ВЫКЛ → ВКЛ 21.07 → ВЫКЛ 24.07 (рвало
            // слова под быстрый набор) → ВКЛ 25.07, когда замена переехала ВНУТРЬ колбэка тапа
            // (inlineLiveFix): пока мы в колбэке, клавиша пользователя пройти не может, поэтому
            // вклиниваться в замену нечему — гонка закрыта по построению, а не по вероятности.
            // Кто выключал руками — у того останется выключено (register явные значения не трогает).
            "liveFixEnabled": true,
            Key.sound: true,
            // Звук переключения — по умолчанию СИСТЕМНЫЙ Pop (решение автора 25.07: свой звук есть
            // в списке как опция, но дефолт остаётся привычным — он у людей уже «в руках»).
            Key.soundName: "Pop",
            "soundVolume": 0.6,
            Key.hotkeyKeyCode: -1,
            Key.hotkeyMods: defaultMods,
            Key.triggerSpace: true,
            // Enter — такая же граница слова, как пробел: «ghbdtn»+Enter (отправка в Telegram/Slack
            // без финального пробела) теперь чинится. dev-приложения/режимы off-soft уже защищены.
            Key.triggerEnter: true,
            Key.triggerTab: false,
            // Enter-pre: чинить слово ДО пропуска Enter в приложение — иначе чат отправляет
            // неисправленное, а замена печатается в уже пустое поле (репорт 11.07). Скрытый
            // аварийный рубильник без UI: defaults write ru.keyboop.app enterPreConvert -bool NO.
            "enterPreConvert": true,
            Key.arrowsCancel: true,
            "voiceSoundEnabled": true,
            "voiceSoundVolume": 0.6,
            "translateSoundEnabled": true,
            "translateSoundName": "keyboop",   // "keyboop" = наш синтез-звук, "" = без звука, иначе системный
            "translateSoundVolume": 0.6,
            "voiceWinOpacity": 0.8,
            // ВАЖНО: voiceHistoryMinutes НЕ регистрируем здесь — иначе object(forKey:) всегда != nil
            // и миграция со старого voiceHistoryDays в геттере НИКОГДА не сработает. Дефолт (60) и
            // миграцию (days→minutes, cap 480) полностью держит computed-геттер voiceHistoryMinutes.
            "escCancelsDictation": true,
            "voiceWarmSeconds": 30,
            // Обучение на отмене: если юзер сразу откатил авто-конверсию и точь-в-точь восстановил
            // оригинал N раз — слово переезжает в «выученные» и больше не трогается. Деф. ВКЛ —
            // безопасно из-за порога + отдельного списка + затухания (см. UndoLearner).
            "learnOnUndoEnabled": true,
            // Групповая конвертация (хоткеем чинит всю набранную фразу, не одно слово) — деф. ВКЛ.
            // В коде гейтится `&& !autoEnabled`: при авто (тоже деф. ВКЛ) неактивна и серая, а как
            // только юзер выключает авто — целая строка по хоткею работает из коробки (можно выключить).
            "groupConvert": true,
            // Подсказка-tooltip (полный текст усечённых подписей) появляется почти сразу, а не через
            // ~2с — ключ AppKit NSInitialToolTipDelay в миллисекундах.
            "NSInitialToolTipDelay": 120
        ])
    }

    var autoEnabled: Bool { get { d.bool(forKey: Key.auto) } set { d.set(newValue, forKey: Key.auto) } }
    /// Чинить раскладку НА ЛЕТУ (мид-слово), как только сочетание невозможно в текущем языке.
    /// История дефолта: ВЫКЛ → ВКЛ 21.07 («отстоялась») → снова ВЫКЛ 24.07 (стабилизация: усиливала
    /// стейл-рассинхроны буфера с экраном до слышимых фантомов; подробности в
    /// register(defaults:)). Тумблер жив; явный выбор пользователя register не трогает.
    var liveFixEnabled: Bool { get { d.bool(forKey: "liveFixEnabled") } set { d.set(newValue, forKey: "liveFixEnabled") } }

    /// INLINE-починка: замена слова ПРЯМО в колбэке тапа (гонка закрыта по построению, 25.07).
    /// Аварийный рубильник без UI — если у кого-то приложение плохо принимает быструю синтетику:
    /// defaults write ru.keyboop.app inlineLiveFix -bool NO  → вернётся прежний асинхронный путь.
    var inlineLiveFix: Bool {
        get { d.object(forKey: "inlineLiveFix") == nil ? true : d.bool(forKey: "inlineLiveFix") }
        set { d.set(newValue, forKey: "inlineLiveFix") }
    }
    /// Обучение на отмене (см. UndoLearner). Ключ читается и напрямую в UndoLearner.enabled.
    var learnOnUndoEnabled: Bool { get { d.bool(forKey: "learnOnUndoEnabled") } set { d.set(newValue, forKey: "learnOnUndoEnabled") } }
    var soundEnabled: Bool { get { d.bool(forKey: Key.sound) } set { d.set(newValue, forKey: Key.sound) } }
    /// «Вообще без звуков»: один выключатель поверх всех остальных (см. Sounds.allMuted).
    /// Нужен потому, что отдельные тумблеры не покрывали системный бип, и человек не мог
    /// заглушить приложение никакими средствами (репорт #29).
    var silentMode: Bool { get { d.bool(forKey: "silentMode") } set { d.set(newValue, forKey: "silentMode") } }

    /// Громкости, запомненные на время тишины. −1 = «не запоминали» (человек сам двигал ползунок,
    /// пока звук был выключён, — его выбор важнее нашего). См. SettingsWindow.toggleSoundsEnabled.
    func mutedBackup(_ key: String) -> Double {
        d.object(forKey: "mutedVol." + key) == nil ? -1 : d.double(forKey: "mutedVol." + key)
    }
    func setMutedBackup(_ key: String, _ v: Double?) {
        if let v { d.set(v, forKey: "mutedVol." + key) } else { d.removeObject(forKey: "mutedVol." + key) }
    }
    var soundName: String { get { d.string(forKey: Key.soundName) ?? "Pop" } set { d.set(newValue, forKey: Key.soundName) } }
    /// Громкость звука переключения (0…1). По умолчанию потише (0.6).
    var soundVolume: Double { get { d.double(forKey: "soundVolume") } set { d.set(newValue, forKey: "soundVolume") } }

    /// Хоткей переключения. keyCode = -1 → комбинация только из модификаторов (по умолч. ⌥⇧).
    var hotkeyKeyCode: Int { get { d.integer(forKey: Key.hotkeyKeyCode) } set { d.set(newValue, forKey: Key.hotkeyKeyCode) } }
    var hotkeyModifiers: UInt64 { get { UInt64(bitPattern: Int64(d.integer(forKey: Key.hotkeyMods))) } set { d.set(Int(bitPattern: UInt(newValue)), forKey: Key.hotkeyMods) } }

    /// По каким клавишам после ввода срабатывает авто-переключение.
    var triggerSpace: Bool { get { d.bool(forKey: Key.triggerSpace) } set { d.set(newValue, forKey: Key.triggerSpace) } }
    var triggerEnter: Bool { get { d.bool(forKey: Key.triggerEnter) } set { d.set(newValue, forKey: Key.triggerEnter) } }
    var triggerTab: Bool { get { d.bool(forKey: Key.triggerTab) } set { d.set(newValue, forKey: Key.triggerTab) } }
    /// Enter-pre конверсия (см. Engine.convertBeforeReturn): голый Enter глотается, слово чинится,
    /// затем Enter уходит синтетикой — чат отправляет уже починенный текст. Деф. ВКЛ; без UI.
    var enterPreConvert: Bool { get { d.bool(forKey: "enterPreConvert") } set { d.set(newValue, forKey: "enterPreConvert") } }

    /// По каким клавишам разворачивается АВТОЗАМЕНА сниппетов (отдельно от авто-переключения раскладки).
    /// Дефолт — все три ВКЛ. Все три ВЫКЛ → автозамена фактически выключена (подпись в настройках).
    var snippetExpandSpace: Bool { get { d.object(forKey: "snippetExpandSpace") == nil ? true : d.bool(forKey: "snippetExpandSpace") } set { d.set(newValue, forKey: "snippetExpandSpace") } }
    var snippetExpandEnter: Bool { get { d.object(forKey: "snippetExpandEnter") == nil ? true : d.bool(forKey: "snippetExpandEnter") } set { d.set(newValue, forKey: "snippetExpandEnter") } }
    var snippetExpandTab: Bool { get { d.object(forKey: "snippetExpandTab") == nil ? true : d.bool(forKey: "snippetExpandTab") } set { d.set(newValue, forKey: "snippetExpandTab") } }
    /// Ни одна клавиша разворота не выбрана → автозамена не срабатывает вовсе.
    var snippetsDisabled: Bool { !snippetExpandSpace && !snippetExpandEnter && !snippetExpandTab }

    /// Стрелки отменяют авто-переключение текущего слова (сбрасывают контекст).
    var arrowsCancel: Bool { get { d.bool(forKey: Key.arrowsCancel) } set { d.set(newValue, forKey: Key.arrowsCancel) } }

    /// Отображаемая метка клавиши хоткея (для keyCode-хоткея, напр. "L").
    var hotkeyKeyLabel: String { get { d.string(forKey: "hotkeyKeyLabel") ?? "" } set { d.set(newValue, forKey: "hotkeyKeyLabel") } }

    /// Язык интерфейса: "auto" (язык ОС) / "ru" / "en".
    var language: String { get { d.string(forKey: "language") ?? "auto" } set { d.set(newValue, forKey: "language") } }

    /// Режим разработчика: НЕ авто-переключать в IDE/терминалах (ручной хоткей работает).
    var developerMode: Bool { get { d.bool(forKey: "developerMode") } set { d.set(newValue, forKey: "developerMode") } }

    /// Режим хоткея: "combo" (модификаторы ⌥⇧), "modkey" (одна клавиша-модификатор — напр. правый ⌥),
    /// "key" (обычная клавиша + модификаторы), "doubletap" (2× модификатор).
    var hotkeyMode: String { get { d.string(forKey: "hotkeyMode") ?? "combo" } set { d.set(newValue, forKey: "hotkeyMode") } }

    // MARK: - Голосовой ввод (диктовка, локально, whisper.cpp)

    /// Голосовой ввод включён.
    var voiceEnabled: Bool { get { d.object(forKey: "voiceEnabled") == nil ? true : d.bool(forKey: "voiceEnabled") } set { d.set(newValue, forKey: "voiceEnabled") } }
    /// Хоткей диктовки. По умолчанию — ПРАВЫЙ ⌥ (modkey, keyCode 61): зажал правый Option
    /// и говоришь, отпустил — стоп. Выбран как дефолт 2026-06-14: новый тестер не нашёл
    /// клавишу «`» в ⌥` (на разных раскладках она «уезжает»), а правый Option есть всегда
    /// на одном месте и не конфликтует с печатью (левый ⌥ при этом свободен).
    /// Режим: "modkey" (зажать клавишу-модификатор, напр. правый ⌥) или "key" (клавиша+модификаторы).
    var voiceHotkeyMode: String { get { d.string(forKey: "voiceHotkeyMode") ?? "modkey" } set { d.set(newValue, forKey: "voiceHotkeyMode") } }
    var voiceHotkeyKeyCode: Int { get { d.object(forKey: "voiceHotkeyKeyCode") == nil ? 61 : d.integer(forKey: "voiceHotkeyKeyCode") } set { d.set(newValue, forKey: "voiceHotkeyKeyCode") } }
    var voiceHotkeyModifiers: UInt64 { get { let v = d.object(forKey: "voiceHotkeyMods") as? Int; return UInt64(bitPattern: Int64(v ?? Int(CGEventFlags.maskAlternate.rawValue))) } set { d.set(Int(bitPattern: UInt(newValue)), forKey: "voiceHotkeyMods") } }
    var voiceHotkeyKeyLabel: String { get { d.string(forKey: "voiceHotkeyKeyLabel") ?? "правый ⌥" } set { d.set(newValue, forKey: "voiceHotkeyKeyLabel") } }
    /// Движок распознавания: "parakeet" (ANE, точнее на RU — по умолчанию) или "whisper".
    #if arch(arm64) && !KEYBOOP_NO_PARAKEET
    private static let defaultVoiceEngine = "parakeet"
    #else
    private static let defaultVoiceEngine = "whisper"   // Intel: Parakeet отсутствует в сборке (нет ANE)
    #endif
    var voiceEngine: String { get { d.string(forKey: "voiceEngine") ?? Self.defaultVoiceEngine } set { d.set(newValue, forKey: "voiceEngine") } }
    /// Режим диктовки: "hold" (зажать и говорить) или "toggle" (нажал — старт, нажал ещё — стоп).
    /// НОВЫМ пользователям дефолт — "toggle" (выбор автора 2026-06-25): выставляется ЯВНО на первом
    /// запуске (AppDelegate didInitialSetup). Read-дефолт здесь оставлен "hold" НАМЕРЕННО — чтобы
    /// существующие юзеры, не менявшие настройку, не «перепрыгнули» на toggle при обновлении.
    var voiceHoldMode: String { get { d.string(forKey: "voiceHoldMode") ?? "hold" } set { d.set(newValue, forKey: "voiceHoldMode") } }
    /// Звук старта/стопа записи (отдельно от звука конвертации). По умолчанию включён.
    var voiceSoundEnabled: Bool { get { d.bool(forKey: "voiceSoundEnabled") } set { d.set(newValue, forKey: "voiceSoundEnabled") } }

    /// Опции ВЫВОДА диктовки (просили несколько человек, задача #41). Обе выключены по умолчанию:
    /// модель отдаёт нормально оформленный текст, и портить его без просьбы мы не должны.
    /// Заглавная первая буква мешает тем, кто диктует в середину предложения; точка в конце —
    /// тем, кто диктует по кусочкам в мессенджер или в поле поиска.
    var voiceNoCapital: Bool { get { d.bool(forKey: "voiceNoCapital") } set { d.set(newValue, forKey: "voiceNoCapital") } }
    var voiceNoFinalPeriod: Bool { get { d.bool(forKey: "voiceNoFinalPeriod") } set { d.set(newValue, forKey: "voiceNoFinalPeriod") } }

    /// НЕ СТАВИТЬ ДЛИННЫЕ ТИРЕ в надиктованном тексте (автор 13.08). По умолчанию ВЫКЛ: длинное тире
    /// это нормальный знак русской пунктуации, и молча переписывать его всем нельзя.
    ///
    /// Зачем вообще: Whisper щедро расставляет «—» там, где человек его сам бы не поставил, а на
    /// клавиатуре этого знака нет. Для тех, кто пишет в мессенджеры и в соцсети, длинное тире ещё и
    /// выдаёт машинный текст. Заменяем на обычный дефис, а не выбрасываем: знак несёт паузу, и без
    /// него фраза слипается.
    var voiceNoEmDash: Bool { get { d.bool(forKey: "voiceNoEmDash") } set { d.set(newValue, forKey: "voiceNoEmDash") } }
    /// Пробел после вставленного текста. Обычно нужен (следующая фраза не слипнется), но в поле
    /// поиска и в паре с авто-Enter он лишний.
    /// Отправлять надиктованное сразу: после вставки уходит Enter (задача #36, просили несколько раз).
    /// Выключено по умолчанию: в текстовом редакторе Enter это перенос строки, а не отправка, и
    /// включать такое всем по умолчанию нельзя.
    var voiceAutoEnter: Bool { get { d.bool(forKey: "voiceAutoEnter") } set { d.set(newValue, forKey: "voiceAutoEnter") } }
    /// Чем именно «отправлять»: разные приложения шлют по разным сочетаниям (Telegram и большинство
    /// чатов — Enter, Slack в режиме «Enter = перенос строки», Gmail, Linear и почти вся веб-почта —
    /// ⌘Enter). Просьба автора 29.07 по обратной связи от людей. Храним маску CGEventFlags.
    var voiceAutoEnterMods: UInt64 { get { UInt64(bitPattern: Int64(d.integer(forKey: "voiceAutoEnterMods"))) } set { d.set(Int(bitPattern: UInt(newValue)), forKey: "voiceAutoEnterMods") } }

    // MARK: - Выбор сниппета по хоткею (задача 17, автор 06.08.2026)

    /// Клавиша общего хоткея выбора сниппета. -1 = функция выключена (умолчание).
    /// Выключено по умолчанию осознанно: это новый перехват сочетания, и включать его всем без
    /// спроса значит отобрать у кого-то работающий хоткей чужой программы.
    var snippetPickKeyCode: Int {
        get { d.object(forKey: "snippetPickKeyCode") == nil ? -1 : d.integer(forKey: "snippetPickKeyCode") }
        set { d.set(newValue, forKey: "snippetPickKeyCode") }
    }
    var snippetPickModifiers: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: "snippetPickModifiers"))) }
        set { d.set(Int(bitPattern: UInt(newValue)), forKey: "snippetPickModifiers") }
    }
    var snippetPickEnabled: Bool { snippetPickKeyCode >= 0 }

    // MARK: - Быстрое действие и пауза (задача 21, автор 05.08.2026)

    /// Что делает ПРАВЫЙ клик по значку в строке меню. Левый по-прежнему открывает меню.
    /// Значения: `copyVoice` (умолчание) · `pause` · `dictate` · `history`.
    ///
    /// ⚠️ Почему среди действий нет «вставить» и «исправить последнее слово», хотя их просят первыми:
    /// клик по значку делает активными НАС, а не то приложение, где стоит курсор. Любое действие,
    /// печатающее в «текущее поле», напечатало бы в самого Keyboop. Копирование работает именно
    /// потому, что чужой фокус ему не нужен.
    var quickAction: String {
        get { d.string(forKey: "quickAction") ?? "copyVoice" }
        set { d.set(newValue, forKey: "quickAction") }
    }

    /// На сколько минут усыпляет действие «пауза». 15 · 60 · 180 · 300 (выбор автора 05.08).
    var pauseMinutes: Int {
        get { let v = d.integer(forKey: "pauseMinutes"); return v > 0 ? v : 15 }
        set { d.set(newValue, forKey: "pauseMinutes") }
    }

    /// До какого момента (unix-время) приложение молчит. 0 = не на паузе.
    ///
    /// ⚠️ ХРАНИМ НА ДИСКЕ, а не в памяти. Пауза на пять часов, пережившая перезапуск как «снова
    /// работаю», это ровно тот сорт сюрприза, ради которого паузу и включали (демонстрация экрана,
    /// игра, чужой ноутбук). Перезапуск не повод передумать за человека.
    var pausedUntil: Double {
        get { d.double(forKey: "pausedUntil") }
        set { d.set(newValue, forKey: "pausedUntil") }
    }

    /// Сейчас на паузе? Единственный источник правды для всех потребителей.
    var isPaused: Bool { pausedUntil > Date().timeIntervalSince1970 }

    var voiceTrailingSpace: Bool {
        get { d.object(forKey: "voiceTrailingSpace") == nil ? true : d.bool(forKey: "voiceTrailingSpace") }
        set { d.set(newValue, forKey: "voiceTrailingSpace") }
    }
    /// Escape отменяет текущую диктовку (запись отбрасывается). По умолчанию включено.
    var escCancelsDictation: Bool { get { d.bool(forKey: "escCancelsDictation") } set { d.set(newValue, forKey: "escCancelsDictation") } }
    /// Отменённую по Escape диктовку всё равно распознать и положить В ИСТОРИЮ (просьба R37).
    /// ВЫКЛЮЧЕНО по умолчанию: Escape означает «не надо», и молча сохранять сказанное вопреки этому
    /// жесту нельзя. Кто хочет подстраховку от случайной отмены — включает сам.
    /// ⚠️ ПО УМОЛЧАНИЮ ВКЛЮЧЕНО с 11.08.2026 (аудит умолчаний, решение автора). Escape означает
    /// «не вставляй сюда», а не «выброси то, что я сказал»: человек чаще ошибается полем, чем
    /// содержанием, и потерянная фраза злит сильнее, чем лишняя строка в истории. Сама история
    /// шифруется и живёт на этом Mac, так что цена сохранения ровно нулевая.
    /// Разово ли мы уже включали автозапуск тем, у кого он был выключен (аудит умолчаний 11.08.2026).
    /// Маркер нужен именно потому, что человек вправе выключить автозапуск сам: без маркера мы
    /// возвращали бы его при каждом запуске и спорили с хозяином машины.
    var didLoginSeed: Bool { get { d.bool(forKey: "didLoginSeed") } set { d.set(newValue, forKey: "didLoginSeed") } }

    var escSaveToHistory: Bool {
        get { d.object(forKey: "escSaveToHistory") == nil ? true : d.bool(forKey: "escSaveToHistory") }
        set { d.set(newValue, forKey: "escSaveToHistory") }
    }
    // Тёплое окно: держать микрофон активным ~30с после диктовки для мгновенного повтора.
    // По умолчанию ВЫКЛ (приватность: иначе оранжевый индикатор горит в простое). Реестр default не нужен — bool=false.
    var voiceWarmWindow: Bool { get { d.bool(forKey: "voiceWarmWindow") } set { d.set(newValue, forKey: "voiceWarmWindow") } }
    // Сколько секунд держать микрофон тёплым после диктовки (если voiceWarmWindow вкл).
    var voiceWarmSeconds: Int { get { let v = d.integer(forKey: "voiceWarmSeconds"); return v > 0 ? v : 30 } set { d.set(newValue, forKey: "voiceWarmSeconds") } }
    /// ЖИВОЙ ЧЕРНОВИК НА ПЛАШКЕ: показывать распознанное по мере речи.
    ///
    /// Только показ, в поле отсюда не идёт ничего. Работает ТОЛЬКО на Parakeet: у Whisper потокового
    /// режима нет, а держать вторую резидентную модель ради показа слишком дорого. По умолчанию ВЫКЛ:
    /// скользящее окно гоняет энкодер раз в секунду, и цену этого человек должен включить осознанно.
    /// ⚠️ ОТКАЗАЛИСЬ ОТ ФУНКЦИИ ПЕРЕД 0.4 (решение автора 17.08): «достаточно бесполезная штука, и
    /// для красоты работает не очень». Геттер жёстко `false` — тем же приёмом, что и `voiceStreaming`
    /// выше: интерфейса у черновика не было ни дня, но настройка в defaults достижима, а
    /// полусделанная функция, до которой можно случайно добраться, хуже отсутствующей.
    /// Код `LiveDraftEngine` НЕ удалён: живой показ вернётся с облачным плагином (задача 150),
    /// где у него будет и смысл, и модель, которая тянет поток.
    var voiceLiveDraft: Bool { get { false } set { d.set(newValue, forKey: "voiceLiveDraft") } }
    // ЭКСПЕРИМЕНТАЛЬНО: потоковая диктовка — текст печатается по мере речи (EOU-движок, отдельная модель).
    // По умолчанию ВЫКЛ — включается осознанно. Реестр default не нужен — bool=false.
    /// Потоковый набор — УБРАН ИЗ ИНТЕРФЕЙСА ДО 0.4 (решение автора, 01.08.2026).
    ///
    /// Тумблер обещал «показывает речь на плашке, пока вы говорите», и этого не происходило.
    /// Настройка провисела так долго именно потому, что была спрятана в бета-канал: её мало кто
    /// включал, а кто включал, тот видел обычную диктовку и решал, что не разобрался. Обещание в
    /// интерфейсе, которое не выполняется, хуже отсутствующей функции, поэтому строка убрана из
    /// настроек целиком, а геттер возвращает false независимо от сохранённого значения.
    ///
    /// Код потокового пути НЕ удалён: в 0.4 фича вернётся уже с продуманным показом (кандидаты —
    /// текущая всплывающая плашка и обыгрывание выреза у MacBook, чтобы текст полз там). Сохранённый
    /// выбор человека тоже не стираем: он пригодится, когда будет что включать.
    var voiceStreaming: Bool {
        get { false }
        set { d.set(newValue, forKey: "voiceStreaming") }
    }

    /// ГДЕ ПОКАЗЫВАТЬ ПЛАШКУ ДИКТОВКИ (задача 125, 0.4). `false` — у каретки, как было всегда;
    /// `true` — вверху по центру, под чёлкой MacBook.
    ///
    /// Умолчание НЕ меняем: плашка у каретки стоит там, куда человек смотрит, и переносить её вверх
    /// всем без спроса значит забрать это у тех, кому и так хорошо.
    ///
    /// ⚠️ Верх работает ТОЛЬКО на встроенном экране (`VoiceIndicator.isBuiltIn`). У внешнего монитора
    /// выреза нет, и плашка под несуществующей чёлкой выглядит чужеродно, поэтому там она молча
    /// падает к каретке. Решение автора 11.08.2026.
    var voiceHudTop: Bool { get { d.bool(forKey: "voiceHudTop") } set { d.set(newValue, forKey: "voiceHudTop") } }

    /// ОСТРОВ В ВЫРЕЗЕ (задача 144). Третий вариант места плашки: она вырастает из чёлки MacBook.
    ///
    /// Отдельным флагом, а не третьим значением у `voiceHudTop`: у выреза он есть не у всех, и когда
    /// вырез недоступен, поведение обязано откатиться к тому, что человек выбрал ДО острова, а не к
    /// умолчанию. Два независимых флага это и дают.
    var voiceHudIsland: Bool { get { d.bool(forKey: "voiceHudIsland") } set { d.set(newValue, forKey: "voiceHudIsland") } }

    /// Перевод выделенного текста по хоткею (Apple Translation, macOS 15+). По умолчанию вкл.
    var translateEnabled: Bool { get { d.object(forKey: "translateEnabled") == nil ? true : d.bool(forKey: "translateEnabled") } set { d.set(newValue, forKey: "translateEnabled") } }
    /// Хоткей перевода. По умолчанию ⌃⌥T (keyCode 17 + Control+Option).
    var translateHotkeyKeyCode: Int { get { d.object(forKey: "translateHotkeyKeyCode") == nil ? 17 : d.integer(forKey: "translateHotkeyKeyCode") } set { d.set(newValue, forKey: "translateHotkeyKeyCode") } }
    var translateHotkeyModifiers: UInt64 { get { let v = d.object(forKey: "translateHotkeyMods") as? Int; return UInt64(bitPattern: Int64(v ?? Int(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue))) } set { d.set(Int(bitPattern: UInt(newValue)), forKey: "translateHotkeyMods") } }
    /// Подпись клавиши хоткея перевода (для отображения «своего» назначения). По умолч. «T».
    var translateHotkeyKeyLabel: String { get { d.string(forKey: "translateHotkeyKeyLabel") ?? "T" } set { d.set(newValue, forKey: "translateHotkeyKeyLabel") } }
    /// Звук перевода (отдельный от звука конвертации раскладки). По умолчанию вкл, наш синтез-звук.
    var translateSoundEnabled: Bool { get { d.bool(forKey: "translateSoundEnabled") } set { d.set(newValue, forKey: "translateSoundEnabled") } }
    /// Имя звука перевода: "keyboop" = наш синтез-трезвучие, "" = без звука, иначе системный звук по имени.
    var translateSoundName: String { get { d.string(forKey: "translateSoundName") ?? "keyboop" } set { d.set(newValue, forKey: "translateSoundName") } }
    var translateSoundVolume: Double { get { d.double(forKey: "translateSoundVolume") } set { d.set(newValue, forKey: "translateSoundVolume") } }
    /// Громкость звука записи (0…1).
    var voiceSoundVolume: Double { get { d.double(forKey: "voiceSoundVolume") } set { d.set(newValue, forKey: "voiceSoundVolume") } }
    /// Уровень полупрозрачности окна истории при включённом режиме (0.15…1).
    var voiceWinOpacity: Double { get { d.double(forKey: "voiceWinOpacity") } set { d.set(newValue, forKey: "voiceWinOpacity") } }
    /// Сохранять небольшую историю диктовок (зашифровано). По умолчанию включено.
    var voiceHistoryEnabled: Bool { get { d.object(forKey: "voiceHistoryEnabled") == nil ? true : d.bool(forKey: "voiceHistoryEnabled") } set { d.set(newValue, forKey: "voiceHistoryEnabled") } }
    /// Сколько минут хранить историю диктовок (0 = без удаления). По умолчанию 60 мин (1 час).
    /// Миграция с voiceHistoryDays: конвертим дни → минуты, cap 480 (8ч).
    var voiceHistoryMinutes: Int {
        get {
            if d.object(forKey: "voiceHistoryMinutes") != nil {
                return d.integer(forKey: "voiceHistoryMinutes")
            }
            let days = d.integer(forKey: "voiceHistoryDays")
            let mins = days > 0 ? min(days * 24 * 60, 480) : 60
            d.set(mins, forKey: "voiceHistoryMinutes")
            return mins
        }
        set { d.set(newValue, forKey: "voiceHistoryMinutes") }
    }
    /// Имя модели whisper (файл ggml-<model>.bin в ~/Library/Application Support/Keyboop/models).
    /// small — баланс качества RU/пунктуации и скорости (research: ≥ small для стабильной пунктуации).
    var voiceModel: String { get { d.string(forKey: "voiceModel") ?? "small" } set { d.set(newValue, forKey: "voiceModel") } }
    /// UID выбранного микрофона ("" = системный по умолчанию).
    var voiceMicUID: String { get { d.string(forKey: "voiceMicUID") ?? "" } set { d.set(newValue, forKey: "voiceMicUID") } }

    /// Язык распознавания голоса: "auto" (определить по речи), "ru", "en", … По умолчанию —
    /// язык ОС. ВАЖНО: язык РЕЧИ, не раскладки (можно диктовать RU при английской раскладке).
    var voiceLanguage: String {
        get { d.string(forKey: "voiceLanguage") ?? "auto" }   // по умолчанию — авто-определение по речи
        set { d.set(newValue, forKey: "voiceLanguage") }
    }

    /// Экспериментально: конвертировать несколько слов группой по хоткею (выключено по умолчанию).
    var groupConvert: Bool { get { d.bool(forKey: "groupConvert") } set { d.set(newValue, forKey: "groupConvert") } }
    /// Глотать дребезг клавиши: повтор той же буквы быстрее 30 мс (T18, просьба #7). ВЫКЛЮЧЕНО по
    /// умолчанию — это перехват ввода, и включать его всем из-за изношенных клавиатур меньшинства
    /// нельзя.
    var dedupeChatter: Bool { get { d.bool(forKey: "dedupeChatter") } set { d.set(newValue, forKey: "dedupeChatter") } }
    /// Исправлять «КОгда» → «Когда» (T28). ВЫКЛЮЧЕНО по умолчанию: это правка текста, а не раскладки.
    var twoCapsFix: Bool { get { d.bool(forKey: "twoCapsFix") } set { d.set(newValue, forKey: "twoCapsFix") } }
    /// Исправление опечаток по словарю (задача 114). ⚠️ По умолчанию ВЫКЛЮЧЕНО и должно таким
    /// остаться: это правка ТЕКСТА, а не раскладки, и на незнакомом слове она может ошибиться.
    /// Подробности и замеры — в `TypoFix`.
    var typoFix: Bool { get { d.bool(forKey: "typoFix") } set { d.set(newValue, forKey: "typoFix") } }

    /// Вставка без форматирования (задача 102). Выключено по умолчанию: во многих программах
    /// ⇧⌘V уже означает «вставить и согласовать стиль», и перехватывать чужое работающее
    /// поведение без спроса нельзя. Подробности — в `PlainPaste`.
    var plainPaste: Bool { get { d.bool(forKey: "plainPaste") } set { d.set(newValue, forKey: "plainPaste") } }
    var plainPasteKeyCode: Int {
        get { d.object(forKey: "plainPasteKeyCode") == nil ? 9 : d.integer(forKey: "plainPasteKeyCode") }   // 9 = «v»
        set { d.set(newValue, forKey: "plainPasteKeyCode") }
    }
    var plainPasteModifiers: UInt64 {
        get {
            let v = d.object(forKey: "plainPasteMods") as? Int
            return UInt64(bitPattern: Int64(v ?? Int(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)))
        }
        set { d.set(Int(bitPattern: UInt(newValue)), forKey: "plainPasteMods") }
    }
    var plainPasteKeyLabel: String {
        get { d.string(forKey: "plainPasteKeyLabel") ?? "⇧⌘V" }
        set { d.set(newValue, forKey: "plainPasteKeyLabel") }
    }

    /// ПОСЛЕДНЯЯ РАСКЛАДКА С КАЖДОЙ СТОРОНЫ, ПЕРЕЖИВАЮЩАЯ ПЕРЕЗАПУСК (отзыв #143 от 17.08:
    /// «выбирает то русскую, то русскую ПК»). Сама память в `LayoutManager` была и раньше, но
    /// жила в процессе: после каждого перезапуска первое переключение уходило в ПЕРВУЮ попавшуюся
    /// раскладку своей письменности, то есть в «Русскую» у того, кто живёт на «Русской ПК».
    /// Человек видит это как случайный выбор, потому что перезапуски он не считает.
    var lastLayoutCyr: String { get { d.string(forKey: "lastLayoutCyr") ?? "" } set { d.set(newValue, forKey: "lastLayoutCyr") } }
    var lastLayoutLat: String { get { d.string(forKey: "lastLayoutLat") ?? "" } set { d.set(newValue, forKey: "lastLayoutLat") } }

    /// СМЕНА РЕГИСТРА ВЫДЕЛЕННОГО (задача 122, просьба пользователя 10.08 + решение автора).
    ///
    /// Комбинация НЕ фиксирована и по умолчанию НЕ назначена (`-1`): человек выбирает сам, а мы
    /// не отбираем ни одного сочетания у тех, кому функция не нужна. Включение ставит первое
    /// свободное из готовых, см. `HotkeyGuard` и настройки.
    var caseChangeKeyCode: Int {
        get { d.object(forKey: "caseChangeKeyCode") == nil ? -1 : d.integer(forKey: "caseChangeKeyCode") }
        set { d.set(newValue, forKey: "caseChangeKeyCode") }
    }
    var caseChangeModifiers: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: "caseChangeMods"))) }
        set { d.set(Int(bitPattern: UInt(newValue)), forKey: "caseChangeMods") }
    }
    var caseChangeKeyLabel: String {
        get { d.string(forKey: "caseChangeKeyLabel") ?? "" }
        set { d.set(newValue, forKey: "caseChangeKeyLabel") }
    }
    /// Функция живёт ровно тогда, когда назначено сочетание. Отдельного тумблера-состояния нет:
    /// два источника правды («включено» и «есть комбинация») разъезжаются, это уже проходили.
    var caseChangeEnabled: Bool { caseChangeKeyCode >= 0 }

    /// Скорость воспроизведения клипа диктовки. Запоминается между запусками: человек, слушающий
    /// свои заметки на 2×, не должен возвращать её каждый раз (просьба автора 10.08).
    /// 0 в хранилище означает «никогда не трогали» → отдаём обычную скорость.
    var voiceClipRate: Double {
        get { let v = d.double(forKey: "voiceClipRate"); return v > 0 ? v : 1.0 }
        set { d.set(newValue, forKey: "voiceClipRate") }
    }

    /// Приглушать системную громкость на время диктовки. Выключено по умолчанию: трогать громкость
    /// чужого Mac без спроса нельзя, человек должен включить это сам.
    var voiceDuck: Bool { get { d.bool(forKey: "voiceDuck") } set { d.set(newValue, forKey: "voiceDuck") } }

    /// Поднимать уровень ВХОДА микрофона перед диктовкой (задача 93). Выключено по умолчанию:
    /// функция меняет СИСТЕМНУЮ настройку, видимую всем программам, и включать такое молча нельзя.
    /// ⚠️ ПО УМОЛЧАНИЮ ВКЛЮЧЕНО с 11.08.2026 (аудит умолчаний, решение автора): тихая запись это
    /// главный источник плохого распознавания, а уровень входа на маке уползает вниз сам по себе,
    /// стоит какой-нибудь программе его убавить и не вернуть.
    ///
    /// Требование автора «главное, чтобы не понижал» выполнено в самой механике, а не только здесь:
    /// `MicVolume.raiseIfEnabled` трогает уровень ТОЛЬКО когда он ниже цели (`now < target - 0.03`),
    /// то есть громкий микрофон остаётся громким.
    var voiceMicGain: Bool {
        get { d.object(forKey: "voiceMicGain") == nil ? true : d.bool(forKey: "voiceMicGain") }
        set { d.set(newValue, forKey: "voiceMicGain") }
    }
    /// Сохранять исходную запись диктовки рядом с текстом (задача 101).
    /// ⚠️ ПО УМОЛЧАНИЮ ВЫКЛЮЧЕНО и таким должно остаться: это единственная наша функция, которая
    /// заводит на диске часы человеческого голоса. Подробности — в `VoiceClips`.
    var voiceSaveAudio: Bool { get { d.bool(forKey: "voiceSaveAudio") } set { d.set(newValue, forKey: "voiceSaveAudio") } }

    /// До какого уровня поднимать, в процентах. 90 по умолчанию, а не 100: у части устройств верх
    /// шкалы это уже перегруз, и «на максимум» из коробки было бы плохим советом.
    /// ⚠️ Проценты означают РАЗНОЕ усиление на разных микрофонах (у RØDE шкала 0…24 дБ, у
    /// встроенного −12…+12), поэтому число это не громкость в дБ, а положение системного ползунка.
    var voiceMicGainLevel: Int {
        get { d.object(forKey: "voiceMicGainLevel") == nil ? 90 : max(10, min(100, d.integer(forKey: "voiceMicGainLevel"))) }
        set { d.set(max(10, min(100, newValue)), forKey: "voiceMicGainLevel") }
    }
    /// Потолок приглушения. Выше него ползунок не ходит, и это осознанно: убавить со ста процентов
    /// до девяноста означает не убавить ничего. 77 выбрано автором 30.07 как самое большое число,
    /// которое ещё честно называется «тише», и потому что две семёрки приятно смотрятся.
    static let duckMaxPercent = 77
    /// До скольких процентов приглушать (0 = полная тишина). По умолчанию 20%: музыку слышно, но
    /// говорить она не мешает. Значение всегда осмысленное, даже если ключа ещё нет или он больше
    /// потолка (у ранних сборок ползунок доходил до 100).
    var voiceDuckLevel: Int {
        get { d.object(forKey: "voiceDuckLevel") == nil ? 20
                : max(0, min(Self.duckMaxPercent, d.integer(forKey: "voiceDuckLevel"))) }
        set { d.set(max(0, min(Self.duckMaxPercent, newValue)), forKey: "voiceDuckLevel") }
    }

    /// Сколько слов зверёк «расколдовал» за всё время (счётчик спасённых раскладок). Растёт на
    /// каждой удачной конверсии — авто, ручной, группа, выделение, мид-слово. Чисто локальный счётчик.
    var rescuedCount: Int { get { d.integer(forKey: "rescuedCount") } set { d.set(newValue, forKey: "rescuedCount") } }

    /// Сколько надиктовано голосом за всё время — символы и слова (счётчик «о программе», как rescuedCount).
    /// ТОЛЬКО числа: сам текст никуда не пишется (принцип №2 — наружу и в хранилище не уходит контент).
    var voiceChars: Int { get { d.integer(forKey: "voiceChars") } set { d.set(newValue, forKey: "voiceChars") } }
    var voiceWords: Int { get { d.integer(forKey: "voiceWords") } set { d.set(newValue, forKey: "voiceWords") } }

    /// Через сколько МИНУТ простоя выгружать модель Whisper из памяти (0 = держать всегда).
    /// Модель ~1.5 ГБ и раньше висела в памяти вечно — фоновая утилита занимала 1.8 ГБ (замер 20.07).
    ///
    /// Дефолт 60 (был 5 — РЕГРЕССИЯ 0.2.58, поймана в тестировании): при обычном ритме «диктовка каждые
    /// 20–40 мин» модель перегружалась почти на каждую сессию (750–1550мс + всплеск памяти + циклы
    /// init/free Metal-контекста ggml). Теперь таймер — страховка на долгий простой (обед/ночь),
    /// а ОСНОВНОЙ триггер выгрузки — memory pressure от системы (см. VoiceController: отдаём 1.5 ГБ
    /// ровно тогда, когда системе реально не хватает памяти, а не по будильнику).
    var voiceModelIdleMinutes: Int {
        get { d.object(forKey: "voiceModelIdleMinutes") == nil ? 60 : d.integer(forKey: "voiceModelIdleMinutes") }
        set { d.set(newValue, forKey: "voiceModelIdleMinutes") }
    }

    /// Один раз при самом первом запуске включаем автозапуск при входе (дефолт-вкл).
    /// Дальше пользователь волен выключить — мы больше не навязываем.
    var didInitialSetup: Bool { get { d.bool(forKey: "didInitialSetup") } set { d.set(newValue, forKey: "didInitialSetup") } }
    /// Простой режим окна настроек: показываем только то, что нужно обычному человеку (список —
    /// `SimpleMode.rows` в SettingsWindow). Режим ТОЛЬКО ПРЯЧЕТ строки: спрятанная настройка
    /// продолжает работать ровно так, как её оставили, ничего не сбрасывается и не выключается.
    ///
    /// Дефолт FALSE намеренно. ВКЛ ставим ЯВНО на первом запуске (AppDelegate, didInitialSetup) —
    /// то есть только новым. Тому, кто уже пользуется программой, режим включать нельзя: он
    /// откроет настройки и увидит, что половина его настроек исчезла.
    /// Высота окна подробных настроек, как её оставил человек. 0 — ещё не трогал, тогда высота
    /// считается по первому разделу. Ширина не хранится: она фиксирована.
    var proWindowHeight: Double { get { d.double(forKey: "proWindowHeight") } set { d.set(newValue, forKey: "proWindowHeight") } }
    var simpleMode: Bool { get { d.bool(forKey: "simpleMode") } set { d.set(newValue, forKey: "simpleMode") } }
    /// Показывали ли окно-приветствие (онбординг) — один раз при первом запуске.
    var didShowWelcome: Bool { get { d.bool(forKey: "didShowWelcome") } set { d.set(newValue, forKey: "didShowWelcome") } }
    /// Версия прошлого запуска — для подсказки про Accessibility после обновления (смена подписи →
    /// доступ протух). Пусто на первом запуске. Сравниваем с текущей в AppDelegate.
    var lastRunVersion: String { get { d.string(forKey: "lastRunVersion") ?? "" } set { d.set(newValue, forKey: "lastRunVersion") } }
    /// Ставить обновления тихо, без вопроса (opt-in). По умолчанию FALSE — спрашиваем уведомлением
    /// «Обновить сейчас / Обновлять автоматически». Пользователь жмёт «авто» → ставим тихо в простое.
    var silentAutoUpdate: Bool { get { d.bool(forKey: "silentAutoUpdate") } set { d.set(newValue, forKey: "silentAutoUpdate") } }
    /// Канал обновлений «бета»: человек ДОБРОВОЛЬНО получает сборки раньше всех, до обкатки.
    /// Выключено по умолчанию и включается только вручную — иначе это не обкатка, а раздача сырого
    /// всем сразу, то есть ровно то, от чего канал и защищает.
    var betaChannel: Bool { get { d.bool(forKey: "betaChannel") } set { d.set(newValue, forKey: "betaChannel") } }

    /// Вид ЗНАЧКА в строке меню (автор 23.07, ред. — значок и язык независимы): brand — фирменный
    /// знак Keyboop и с 11.08 дефолт; keyboard — глиф клавиатуры (был дефолтом); hidden — значка нет.
    /// Показывать язык (RU/EN) РЯДОМ — отдельная галка menuBarShowLanguage, работает со всеми тремя.
    /// «Только язык» = hidden + показывать язык. Если hidden И язык выключен — пункта в строке меню
    /// нет совсем (настройки открываются повторным запуском из «Программ»).
    /// Миграция старых значений: letter→brand, layout→hidden(+язык уже вкл по умолчанию).
    /// 🌐/Fn мгновенно меняет язык (просьба пользователей, 24.07). По умолчанию ВЫКЛ: фича требует,
    /// чтобы пользователь сам снял системное действие с клавиши (иначе сработают оба) — включать
    /// такое молча нельзя. Статус конфликта читаем из GlobeKey и показываем рядом с тумблером.
    // ── МГНОВЕННОЕ ПЕРЕКЛЮЧЕНИЕ ЯЗЫКА (обобщение фичи 🌐, автор 24.07) ───────────────────────────
    // Смена языка БЕЗ конвертации набранного — замена системному переключателю, но без его задержки.
    // 🌐 есть только на новых маках, поэтому комбинация настраивается: Globe / ⌘Space / ⌃Space /
    // Caps Lock / своя. Работает через ГЛОТАНИЕ события в нашем активном тапе (проверено 24.07:
    // глотание гасит системное действие) — системные настройки НЕ трогаем, всё обратимо.
    // По умолчанию ВЫКЛ: фича перехватывает клавиши, на которых у человека может висеть своё.
    var instantSwitchEnabled: Bool {
        get {
            if d.object(forKey: "instantSwitchEnabled") == nil { return d.bool(forKey: "globeSwitchesLayout") }  // миграция
            return d.bool(forKey: "instantSwitchEnabled")
        }
        set { d.set(newValue, forKey: "instantSwitchEnabled") }
    }
    /// "globe" — клавиша 🌐/Fn; "key" — клавиша+модификаторы (⌘Space); "modkey" — одиночный
    /// модификатор по чистому тапу (Caps Lock).
    var instantSwitchMode: String { get { d.string(forKey: "instantSwitchMode") ?? "globe" } set { d.set(newValue, forKey: "instantSwitchMode") } }
    var instantSwitchKeyCode: Int { get { d.object(forKey: "instantSwitchKeyCode") == nil ? 63 : d.integer(forKey: "instantSwitchKeyCode") } set { d.set(newValue, forKey: "instantSwitchKeyCode") } }
    var instantSwitchMods: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: "instantSwitchMods"))) }
        set { d.set(Int(bitPattern: UInt(newValue)), forKey: "instantSwitchMods") }
    }
    /// Что мы «затеняем» этой комбинацией — показываем предупреждение в настройках (Spotlight и т.п.).
    var instantSwitchKeyLabel: String { get { d.string(forKey: "instantSwitchKeyLabel") ?? "" } set { d.set(newValue, forKey: "instantSwitchKeyLabel") } }
    /// Лампочка Caps Lock показывает ЯЗЫК (горит = русский), а не состояние капса — см. CapsLED.
    /// По умолчанию ВЫКЛ: настройка меняет смысл железной лампочки, включать такое молча нельзя.
    var capsLEDIndicator: Bool {
        get { d.bool(forKey: "capsLEDIndicator") }
        set { d.set(newValue, forKey: "capsLEDIndicator") }
    }
    /// Наш hidutil-ремап Caps→LANG1 применён (см. CapsRemap: ставится только в пустой список).
    var capsRemapApplied: Bool {
        get { d.bool(forKey: "capsRemapApplied") }
        set { d.set(newValue, forKey: "capsRemapApplied") }
    }
    /// Что система назначала на 🌐 ДО того, как мы забрали клавишу (чтобы вернуть при выключении).
    /// -1 — не сохраняли.
    var globePrevFnUsage: Int {
        get { d.object(forKey: "globePrevFnUsage") == nil ? -1 : d.integer(forKey: "globePrevFnUsage") }
        set { d.set(newValue, forKey: "globePrevFnUsage") }
    }

    var menuBarStyle: String {
        get {
            switch d.string(forKey: "menuBarStyle") {
            // ⚠️ Новый стиль значка НУЖНО дописать сюда: иначе белый список молча вернёт "keyboard",
            // и в настройках сегмент выберется, а в строке меню ничего не изменится (25.07: так и было
            // с "flag" — искал ошибку в отрисовке флага, а дело было в этой строке).
            case "brand", "keyboard", "flag", "hidden": return d.string(forKey: "menuBarStyle")!
            case "letter": return "brand"
            case "layout": return "hidden"
            // ⚠️ Дефолт сменён на «Логотип» (аудит умолчаний, автор 11.08): в строке меню нас узнают
            // по своему знаку, а системный глиф клавиатуры там ничей. Тех, кто выбирал значок сам,
            // это не трогает — у них в defaults лежит своя строка и до сюда не доходит.
            default: return "brand"
            }
        }
        set { d.set(newValue, forKey: "menuBarStyle") }
    }
    /// Показывать индикатор языка (RU/EN) рядом со значком. По умолчанию да. Старым «layout» юзерам
    /// миграция даёт hidden+этот флаг (он уже true по дефолту) → тот же вид «только язык».
    var menuBarShowLanguage: Bool {
        get { d.object(forKey: "menuBarShowLanguage") == nil ? true : d.bool(forKey: "menuBarShowLanguage") }
        set { d.set(newValue, forKey: "menuBarShowLanguage") }
    }

    /// Оформление приложения: "system" (по умолчанию), "light", "dark".
    ///
    /// Появилось 02.08.2026. До этого дня приложение не заявляло тему вовсе, и в светлой системе
    /// окно настроек разъезжалось: боковое меню светлело, правая часть оставалась тёмной. Первым
    /// движением я жёстко прибил окно к тёмной теме, но это оказалось лечением симптома: светлый
    /// путь в коде БЫЛ (см. ThemedBackgroundView, 29.07), просто где-то не срабатывал, а затычка
    /// его окончательно выключила. Правильный ответ - не выбирать за человека, а дать выбрать,
    /// с системой по умолчанию.
    var appTheme: String {
        get { d.string(forKey: "appTheme") ?? "system" }
        set { d.set(newValue, forKey: "appTheme") }
    }

    /// Оформление, которое надо навесить на окно. `nil` = «как в системе» (не трогаем appearance,
    /// и окно живёт по системной теме, как любое обычное приложение).
    var appAppearance: NSAppearance? {
        switch appTheme {
        case "light": return NSAppearance(named: .aqua)
        case "dark":  return NSAppearance(named: .darkAqua)
        default:      return nil
        }
    }

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
            return false
        }
        set {
            guard #available(macOS 13.0, *) else { return }
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
            } catch { NSLog("Keyboop: launchAtLogin error: \(error)") }
        }
    }
}
