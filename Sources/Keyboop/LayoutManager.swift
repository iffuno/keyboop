import Foundation
import Carbon

/// Чтение и переключение системной раскладки через Text Input Source (TIS).
final class LayoutManager {

    /// НАШЕ МНЕНИЕ о текущей раскладке. Известный баг macOS (kawa PR #21, подтверждён нашим логом
    /// 24.07: «→ EN» ×6 подряд): при быстрых переключениях БЕЗ нажатий клавиш между ними
    /// TISCopyCurrentKeyboardInputSource возвращает УСТАРЕВШЕЕ значение — процесс читает свой
    /// замороженный кэш, пока его не синхронизирует нажатие/смена окна. Из-за этого мгновенный
    /// переключатель считал «всё ещё RU» и шесть раз подряд «переключал» в EN.
    /// Лекарство то же, что у kawa: ПОМНИТЬ последний выбранный источник самим и верить памяти,
    /// а не чтению. Память обновляется нашими select'ами и TIS-уведомлениями (внешняя смена).
    private var opinionCyr: Bool?

    /// Текущая раскладка — кириллическая? (сырое чтение TIS; может отставать, см. opinionCyr)
    func currentIsCyrillic() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return Self.languages(of: src).first?.hasPrefix("ru") ?? false
    }

    /// Текущая раскладка с поправкой на баг стейл-чтения: если мы недавно переключали сами —
    /// отвечает память, иначе честное чтение TIS.
    func currentIsCyrillicOpinion() -> Bool { opinionCyr ?? currentIsCyrillic() }

    /// Внешняя смена раскладки (TIS-уведомление): обновляем мнение свежим чтением.
    /// ⚠️ Чтение прямо в момент уведомления МОЖЕТ быть стейлым (24.07: ручная смена раскладки →
    /// уведомление → чтение вернуло старую → мнение и кэш дружно зарядились неправдой, и целая
    /// строка «cyjdf drk.xbk…» осталась латиницей при идеально-русском буфере). Поэтому мнение
    /// здесь только помечается сомнительным, а правду устанавливает reconcileWithReality() на
    /// ближайшей границе слова — в момент, когда чтение достоверно (kawa: «после нажатия»).
    /// (Финал аудита 24.07, R2): чтению в момент уведомления НЕ доверяем вовсе — мнение честно
    /// сбрасывается в «не знаю», правду установят boundary-сверка (следующее слово) или фоновая
    /// (2.5с простоя). Пока мнения нет, currentIsCyrillicOpinion() отвечает сырым чтением — хуже
    /// самосогласованной лжи оно не бывает.
    func noteExternalLayoutChange() { opinionCyr = nil }

    /// Когда мы сами переключали в последний раз (для сверки: свежий свой select не проверяем —
    /// чтение в этот момент само стейлится и дало бы ложное «не применилось»).
    private var lastSelectAt: TimeInterval = 0

    /// Мы в grace-окне собственного переключения: любые чтения «текущего» из TIS недостоверны,
    /// а правда уже установлена детерминированно (кэш из выбранного объекта + мнение).
    var withinOwnSelectGrace: Bool { ProcessInfo.processInfo.systemUptime - lastSelectAt < 1.0 }

    /// Сверить мнение с реальностью. Звать ТОЛЬКО в моменты, когда чтение TIS достоверно:
    /// на границе слова (только что было реальное нажатие) или в глубоком простое.
    /// true = расходились, мнение и кэш приведены к реальности.
    @discardableResult
    func reconcileWithReality() -> Bool {
        guard ProcessInfo.processInfo.systemUptime - lastSelectAt > 0.8 else { return false }
        let real = currentIsCyrillic()
        guard let op = opinionCyr else {
            // Мнение сброшено (внешняя смена раскладки, R2): принимаем реальность. Слово подозрительно
            // ТОЛЬКО если блоб декодера при этом реально сменился — иначе декод шёл верной раскладкой
            // и пропускать конверсию незачем.
            opinionCyr = real
            return KeyboardLayoutCache.refreshOnMain()
        }
        guard real != op else { return false }
        opinionCyr = real
        KeyboardLayoutCache.refreshOnMain()   // чтение здесь достоверно — момент выбран вызывающим
        return true
    }

    /// Короткий код текущей раскладки для индикатора ("RU"/"EN"/…).
    /// Язык АКТИВНОЙ раскладки для индикатора — с поправкой на фоновую природу приложения.
    ///
    /// ⚠️ Почему не просто `currentCode()`: `TISCopyCurrentKeyboardInputSource` в агенте без окон
    /// отдаёт раскладку СВОЕГО процесса и не следует за внешними переключениями. Замер 25.07.2026:
    /// система щёлкала RU→EN→RU→EN, чтение всё это время возвращало «RU», а системное уведомление
    /// `kTISNotifySelectedKeyboardInputSourceChanged` в наш процесс не пришло ни разу (0 из 4).
    /// Настройки HIToolbox при этом менялись мгновенно и без ошибок — их и спрашиваем.
    /// Из-за этого индикатор RU/EN давно показывал устаревший язык, если раскладку меняли не через
    /// Keyboop; со флагом это стало заметно сразу.
    func currentCodeLive() -> String {
        Self.languageFromSystemPrefs() ?? currentCode()
    }

    /// Нормализованное имя раскладки → код языка. Строим один раз по списку установленных раскладок:
    /// в настройках лежит имя («U.S.», «Russian — PC»), а язык знает только TIS-объект.
    private static var nameToLang: [String: String] = [:]

    /// Имена в настройках и в TIS пишутся по-разному («U.S.» против «US» в идентификаторе), поэтому
    /// сравниваем по «скелету»: только буквы и цифры в нижнем регистре.
    private static func nameKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func buildNameMap() {
        guard nameToLang.isEmpty else { return }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        for src in list {
            guard let lang = languages(of: src).first else { continue }
            let code = String(lang.prefix(2)).uppercased()
            var names: [String] = []
            if let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
                names.append(Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
            }
            if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
                names.append(String(id.split(separator: ".").last ?? ""))   // «com.apple.keylayout.Russian-PC» → «Russian-PC»
            }
            for n in names where !n.isEmpty { nameToLang[nameKey(n)] = code }
        }
    }

    /// Что система САМА считает выбранной раскладкой. `Synchronize` обязателен: без него значение
    /// в нашем процессе кэшируется (тот же урок, что с AppleFnUsageType в GlobeKey).
    private static func languageFromSystemPrefs() -> String? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        guard let raw = CFPreferencesCopyAppValue("AppleSelectedInputSources" as CFString,
                                                 "com.apple.HIToolbox" as CFString) as? [[String: Any]]
        else { return nil }
        buildNameMap()
        for entry in raw {
            let name = (entry["KeyboardLayout Name"] as? String) ?? (entry["Input Mode"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            // Для метода ввода (китайский/японский) в имени лежит идентификатор — берём хвост.
            let key = nameKey(String(name.split(separator: ".").last ?? Substring(name)))
            if let code = nameToLang[key] { return code }
        }
        return nil
    }

    func currentCode() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "??" }
        let lang = Self.languages(of: src).first ?? "en"
        return String(lang.prefix(2)).uppercased()
    }

    /// Переключить системную раскладку на кириллицу/латиницу (если такая включена).
    @discardableResult
    func selectLayout(cyrillic: Bool) -> Bool {
        let wanted = cyrillic ? "ru" : "en"
        guard let src = enabledKeyboardSources().first(where: {
            (Self.languages(of: $0).first ?? "").hasPrefix(wanted)
        }) else { return false }
        let ok = TISSelectInputSource(src) == noErr
        if ok {
            opinionCyr = cyrillic   // память против стейл-чтения (см. opinionCyr)
            lastSelectAt = ProcessInfo.processInfo.systemUptime
            // Кэш — из ТОГО источника, который мы только что выбрали (объект в руках). НЕ через
            // чтение «текущего»: сразу после TISSelect оно возвращает СТАРЫЙ источник (стейл-баг
            // kawa PR#21) — 24.07 кэш заряжался старьём, сверка алфавитов портила правильные буквы
            // (50 ложных подмен за 9с), а отложенный перечит мог заражать кэш повторно. TIS — main-only.
            if Thread.isMainThread { KeyboardLayoutCache.refresh(fromSelected: src) }
            else { DispatchQueue.main.async { KeyboardLayoutCache.refresh(fromSelected: src) } }
        }
        return ok
    }

    // MARK: - Внутреннее

    private func enabledKeyboardSources() -> [TISInputSource] {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(cf)
        var result: [TISInputSource] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard Self.stringProp(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsEnabled) else { continue }
            result.append(src)
        }
        return result
    }

    private static func languages(of src: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray
        return arr.compactMap { $0 as? String }
    }

    private static func stringProp(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(src, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }
}
