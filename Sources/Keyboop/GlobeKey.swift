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

    // MARK: - Аварийная расписка (28.07)
    //
    // ⚠️ ПОЧЕМУ ФАЙЛ, А НЕ ТОЛЬКО UserDefaults. `release()` возвращает клавишу, только если у него
    // есть запись «мы её забирали». Запись жила в defaults БАНДЛА, и терялась сразу в трёх случаях:
    //   1. дев-сборка (ru.keyboop.app.dev) забрала, прод (ru.keyboop.app) отпускает — домены разные;
    //   2. процесс убит SIGTERM/Activity Monitor/падением — applicationWillTerminate не выполняется;
    //   3. настройки сброшены или приложение переустановлено.
    // Во всех трёх клавиша 🌐 остаётся с системным действием «Ничего не делать» — то есть МЁРТВОЙ,
    // причём НАВСЕГДА и даже после удаления Keyboop. Человек видит сломанную клавишу и никак не
    // связывает это с нами. Мы ломаем систему за пределами своего приложения и не оставляем следа.
    //
    // Расписка лежит в общем для всех сборок месте и переживает и падение, и снос настроек.
    // Пишется ДО того, как забрали, удаляется ПОСЛЕ того, как вернули.
    private static var receiptURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("globe-fn-receipt")
    }

    private static func writeReceipt(_ prev: Int) {
        try? String(prev).write(to: receiptURL, atomically: true, encoding: .utf8)
    }
    private static func readReceipt() -> Int? {
        guard let s = try? String(contentsOf: receiptURL, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func clearReceipt() { try? FileManager.default.removeItem(at: receiptURL) }

    /// Привести систему к нашим настройкам. Звать: на старте, при смене тумблера/комбинации.
    /// При выключении фичи (или смене комбинации с 🌐 на другую) честно возвращаем «как было».
    static func reconcile() {
        let s = AppSettings.shared
        if s.instantSwitchEnabled && s.instantSwitchMode == "globe" {
            guard current != .nothing else { return }   // уже свободна — забирать нечего
            let prev = s.globePrevFnUsage == -1 ? (rawValue() ?? -2) : s.globePrevFnUsage
            s.globePrevFnUsage = prev
            writeReceipt(prev)          // расписка ДО захвата: падение между строками не осиротит клавишу
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

    /// Вернуть системе прежнее действие (выключение тумблера / смена комбинации / выход / старт).
    ///
    /// ⚠️ Расписка на диске — ВТОРОЙ источник (28.07). Раньше здесь стоял только `guard != -1` по
    /// defaults бандла, и осиротевшая клавиша не возвращалась НИКОГДА: у прод-сборки нет записи
    /// дев-сборки, у переустановленной — записи прошлой, у убитой SIGTERM — вообще никакой.
    /// Симптом: 🌐 не делает ничего, ни системного действия, ни нашего, и лечится только включением
    /// нашей же фичи обратно. Именно так это поймал автор 28.07.
    static func release() {
        let s = AppSettings.shared
        let prev = s.globePrevFnUsage != -1 ? s.globePrevFnUsage : (readReceipt() ?? -1)
        guard prev != -1 else { return }   // ни записи, ни расписки — мы действительно не забирали
        // Не отбираем чужой выбор: если человек САМ поставил на 🌐 что-то другое после нас, наше
        // «как было» уже неактуально. Возвращаем только то, что оставили мы («Ничего не делать»).
        guard current == .nothing else {
            s.globePrevFnUsage = -1
            clearReceipt()
            kbLog("globe: возвращать нечего — на клавише уже чужая настройка, расписку снял")
            return
        }
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
        clearReceipt()
        kbLog("globe: клавиша возвращена системе (было \(prev == -2 ? "умолчание" : String(prev)))")
    }
}
