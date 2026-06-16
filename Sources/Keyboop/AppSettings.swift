import Foundation
import ServiceManagement
import CoreGraphics

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
            Key.sound: true,
            Key.soundName: "Pop",
            "soundVolume": 0.6,
            Key.hotkeyKeyCode: -1,
            Key.hotkeyMods: defaultMods,
            Key.triggerSpace: true,
            // Enter — такая же граница слова, как пробел: «ghbdtn»+Enter (отправка в Telegram/Slack
            // без финального пробела) теперь чинится. dev-приложения/режимы off-soft уже защищены.
            Key.triggerEnter: true,
            Key.triggerTab: false,
            Key.arrowsCancel: true,
            "voiceSoundEnabled": true,
            "voiceSoundVolume": 0.6,
            "translateSoundEnabled": true,
            "translateSoundName": "keyboop",   // "keyboop" = наш синтез-звук, "" = без звука, иначе системный
            "translateSoundVolume": 0.6,
            "voiceWinOpacity": 0.3,
            // ВАЖНО: voiceHistoryMinutes НЕ регистрируем здесь — иначе object(forKey:) всегда != nil
            // и миграция со старого voiceHistoryDays в геттере НИКОГДА не сработает. Дефолт (60) и
            // миграцию (days→minutes, cap 480) полностью держит computed-геттер voiceHistoryMinutes.
            "escCancelsDictation": true,
            "voiceWarmSeconds": 30,
            // Обучение на отмене: если юзер сразу откатил авто-конверсию и точь-в-точь восстановил
            // оригинал N раз — слово переезжает в «выученные» и больше не трогается. Деф. ВКЛ —
            // безопасно из-за порога + отдельного списка + затухания (см. UndoLearner / docs/IDEAS.md L).
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
    /// По умолчанию ВЫКЛ — фича агрессивная (Punto-стиль), включается осознанно.
    var liveFixEnabled: Bool { get { d.bool(forKey: "liveFixEnabled") } set { d.set(newValue, forKey: "liveFixEnabled") } }
    /// Обучение на отмене (см. UndoLearner). Ключ читается и напрямую в UndoLearner.enabled.
    var learnOnUndoEnabled: Bool { get { d.bool(forKey: "learnOnUndoEnabled") } set { d.set(newValue, forKey: "learnOnUndoEnabled") } }
    var soundEnabled: Bool { get { d.bool(forKey: Key.sound) } set { d.set(newValue, forKey: Key.sound) } }
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
    var voiceEngine: String { get { d.string(forKey: "voiceEngine") ?? "parakeet" } set { d.set(newValue, forKey: "voiceEngine") } }
    /// Режим диктовки: "hold" (зажать и говорить) или "toggle" (нажал — старт, нажал ещё — стоп).
    /// По умолчанию — "hold": зажал правый ⌥, говоришь, отпустил — стоп (push-to-talk, совпадает
    /// с инструкцией в DMG «зажми правый ⌥ и говори»). Для modkey-дефолта это самый интуитивный режим.
    var voiceHoldMode: String { get { d.string(forKey: "voiceHoldMode") ?? "hold" } set { d.set(newValue, forKey: "voiceHoldMode") } }
    /// Звук старта/стопа записи (отдельно от звука конвертации). По умолчанию включён.
    var voiceSoundEnabled: Bool { get { d.bool(forKey: "voiceSoundEnabled") } set { d.set(newValue, forKey: "voiceSoundEnabled") } }
    /// Escape отменяет текущую диктовку (запись отбрасывается). По умолчанию включено.
    var escCancelsDictation: Bool { get { d.bool(forKey: "escCancelsDictation") } set { d.set(newValue, forKey: "escCancelsDictation") } }
    // Тёплое окно: держать микрофон активным ~30с после диктовки для мгновенного повтора.
    // По умолчанию ВЫКЛ (приватность: иначе оранжевый индикатор горит в простое). Реестр default не нужен — bool=false.
    var voiceWarmWindow: Bool { get { d.bool(forKey: "voiceWarmWindow") } set { d.set(newValue, forKey: "voiceWarmWindow") } }
    // Сколько секунд держать микрофон тёплым после диктовки (если voiceWarmWindow вкл).
    var voiceWarmSeconds: Int { get { let v = d.integer(forKey: "voiceWarmSeconds"); return v > 0 ? v : 30 } set { d.set(newValue, forKey: "voiceWarmSeconds") } }

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

    /// Сколько слов зверёк «расколдовал» за всё время (счётчик спасённых раскладок). Растёт на
    /// каждой удачной конверсии — авто, ручной, группа, выделение, мид-слово. Чисто локальный счётчик.
    var rescuedCount: Int { get { d.integer(forKey: "rescuedCount") } set { d.set(newValue, forKey: "rescuedCount") } }

    /// Один раз при самом первом запуске включаем автозапуск при входе (дефолт-вкл).
    /// Дальше пользователь волен выключить — мы больше не навязываем.
    var didInitialSetup: Bool { get { d.bool(forKey: "didInitialSetup") } set { d.set(newValue, forKey: "didInitialSetup") } }
    /// Показывали ли окно-приветствие (онбординг) — один раз при первом запуске.
    var didShowWelcome: Bool { get { d.bool(forKey: "didShowWelcome") } set { d.set(newValue, forKey: "didShowWelcome") } }
    /// Версия прошлого запуска — для подсказки про Accessibility после обновления (смена подписи →
    /// доступ протух). Пусто на первом запуске. Сравниваем с текущей в AppDelegate.
    var lastRunVersion: String { get { d.string(forKey: "lastRunVersion") ?? "" } set { d.set(newValue, forKey: "lastRunVersion") } }
    /// Ставить обновления тихо, без вопроса (opt-in). По умолчанию FALSE — спрашиваем уведомлением
    /// «Обновить сейчас / Обновлять автоматически». Пользователь жмёт «авто» → ставим тихо в простое.
    var silentAutoUpdate: Bool { get { d.bool(forKey: "silentAutoUpdate") } set { d.set(newValue, forKey: "silentAutoUpdate") } }

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
