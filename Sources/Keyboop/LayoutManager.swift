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
