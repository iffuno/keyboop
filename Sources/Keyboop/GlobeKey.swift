import Foundation

/// Системная настройка клавиши 🌐/Fn («При нажатии 🌐» в Настройках → Клавиатура).
///
/// Зачем (просьба пользователей + требование автора 24.07): мы хотим повесить на 🌐 МГНОВЕННУЮ
/// смену языка. Системное действие той же клавиши работает с задержкой (macOS ждёт, не окажется
/// ли это началом комбинации Fn+F1 / Fn+стрелки). Но если системное действие оставить включённым,
/// сработают ОБА — получится каша. Поэтому перед включением нашей фичи мы обязаны ЗНАТЬ, что на
/// клавише сейчас, и честно об этом сказать.
///
/// Замерено на macOS 26 (24.07.2026): ключ `AppleFnUsageType` в домене `com.apple.HIToolbox`,
/// значения 0/1/2/3 (см. `Action`). Пока настройку не меняли, ключ ОТСУТСТВУЕТ — это умолчание,
/// и на маках с 🌐 оно означает «сменить источник ввода» (то самое, что конфликтует). Домен
/// пользовательский: читается и пишется без прав администратора (проверено 0→2→0).
enum GlobeKey {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key    = "AppleFnUsageType" as CFString

    enum Action: Int {
        case nothing = 0        // «Ничего не делать» — клавиша свободна, конфликта нет
        case inputSource = 1    // «Сменить источник ввода» — ПРЯМОЙ конфликт с нашей фичей
        case emoji = 2          // «Показать эмодзи и символы»
        case dictation = 3      // «Начать диктовку»

        /// Мешает ли нашей фиче: свободна только `nothing`.
        var conflicts: Bool { self != .nothing }
    }

    // ЧТЕНИЕ/ЗАПИСЬ — строго через варианты с ЯВНЫМИ user/host. CopyAppValue отдаёт кэш нашего
    // процесса и НЕ видит правку, сделанную в Настройках системы (поймано 24.07: автор вернул
    // «сменить язык», а мы продолжали показывать «свободна»). CopyValue + Synchronize с
    // kCFPreferencesCurrentUser/kCFPreferencesAnyHost читает актуальное значение из cfprefsd.
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost

    private static func rawValue() -> Int? {
        CFPreferencesSynchronize(domain, user, host)
        return CFPreferencesCopyValue(key, domain, user, host) as? Int
    }

    /// Что назначено на 🌐 сейчас. Ключа нет (настройку не трогали) → системное УМОЛЧАНИЕ.
    /// Отсутствие трактуем как `.inputSource`: именно так ведут себя маки с 🌐 из коробки
    /// (замерено на реальной машине: клавиша переключала язык, ключа при этом не было).
    static var current: Action {
        guard let v = rawValue() else { return .inputSource }
        return Action(rawValue: v) ?? .inputSource
    }

    /// Записан ли ключ явно (иначе мы лишь ПРЕДПОЛАГАЕМ умолчание) — для честности формулировок в UI.
    static var isExplicitlySet: Bool { rawValue() != nil }

    /// ЖИВОЕ применение записанной настройки. Ровно так делает сам System Settings
    /// (KeyboardSettings.appex, найдено по его bind-таблице 24.07): записать plist →
    /// синхронизировать → вызвать `TISUpdateFnUsageType()` из Carbon. Вызов рассылает
    /// broadcast (kToolboxMessageFnKeySettingChanged), по которому ВСЕ процессы сбрасывают
    /// кэш роли Fn (sFnUsageType). Без него запись «не применяется до перелогина» — наш
    /// вчерашний тупик: мы просто не знали про этот вызов. Символа нет в заголовках → dlsym.
    /// Значение передаём аргументом: реальная арность не документирована — если функция void,
    /// лишний аргумент в регистре безвреден; если принимает значение — передано верное.
    private static func applyLive(_ value: Int) {
        typealias Fn = @convention(c) (Int32) -> Void
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW),
              let sym = dlsym(carbon, "TISUpdateFnUsageType") else {
            kbLog("globe: TISUpdateFnUsageType недоступен — настройка применится после перелогина")
            return
        }
        unsafeBitCast(sym, to: Fn.self)(Int32(value))
    }

    /// Привести систему к нашим настройкам. Звать: на старте, при смене тумблера/комбинации.
    /// При выключении фичи (или смене комбинации с 🌐 на другую) честно возвращаем «как было».
    static func reconcile() {
        let s = AppSettings.shared
        if s.instantSwitchEnabled && s.instantSwitchMode == "globe" {
            guard current != .nothing else { return }   // уже свободна — забирать нечего
            if s.globePrevFnUsage == -1 { s.globePrevFnUsage = rawValue() ?? -2 }   // −2 = ключа не было
            take()
        } else {
            release()
        }
    }

    /// Забрать клавишу себе: выставить «Ничего не делать» и применить живьём. Зовётся при включении
    /// тумблера — ПОСЛЕ явного предупреждения пользователю, что прежнее действие клавиши отключится
    /// (решение автора 24.07: не гонять человека по системным настройкам). true = запись перечиталась.
    @discardableResult
    static func take() -> Bool {
        CFPreferencesSetValue(key, Action.nothing.rawValue as CFNumber, domain, user, host)
        CFPreferencesSynchronize(domain, user, host)
        applyLive(Action.nothing.rawValue)
        let ok = current == .nothing
        kbLog("globe: клавиша забрана Keyboop (системное действие отключено живьём) — \(ok ? "ок" : "система не приняла")")
        return ok
    }

    /// Вернуть системе прежнее действие (выключение тумблера / смена комбинации / выход).
    static func release() {
        let s = AppSettings.shared
        guard s.globePrevFnUsage != -1 else { return }   // мы ничего не забирали
        let prev = s.globePrevFnUsage
        if prev == -2 {
            // Ключа до нас не было — честно УДАЛЯЕМ, а не пишем «умолчание» (оно может отличаться
            // по типу мака). Кэшам рассылаем фактическое умолчание глобус-маков: inputSource.
            CFPreferencesSetValue(key, nil, domain, user, host)
            CFPreferencesSynchronize(domain, user, host)
            applyLive(Action.inputSource.rawValue)
        } else {
            CFPreferencesSetValue(key, prev as CFNumber, domain, user, host)
            CFPreferencesSynchronize(domain, user, host)
            applyLive(prev)
        }
        s.globePrevFnUsage = -1
        kbLog("globe: клавиша возвращена системе (было \(prev == -2 ? "умолчание" : String(prev)))")
    }
}
