import AppKit

/// ЗАНЯТО ЛИ СОЧЕТАНИЕ САМОЙ macOS (задача автора 06.08.2026).
///
/// Повод конкретный: в готовые варианты вставки сниппета я предложил ⌃⌥Space, а это системное
/// «предыдущий источник ввода», и на живой машине оно включено. То есть мы раздавали настройку,
/// которая заведомо не сработает. Подбирать сочетания по памяти нельзя, надо спрашивать систему.
///
/// Где живут системные сочетания: `com.apple.symbolichotkeys`, ключ `AppleSymbolicHotKeys`. Каждая
/// запись это `{ enabled: Bool, value: { parameters: [ascii, keyCode, modifiers] } }`.
///
/// ⚠️ Маска модификаторов там СОВПАДАЕТ с `CGEventFlags` бит в бит (⇧ 0x20000, ⌃ 0x40000,
/// ⌥ 0x80000, ⌘ 0x100000), поэтому никакого перевода не нужно. Проверено сверкой на живых данных;
/// если однажды перестанет сходиться, ломаться будет тихо, поэтому строка про это здесь и стоит.
///
/// ⚠️ `CFPreferencesAppSynchronize` обязателен: без него значение кэшируется в нашем процессе, и
/// человек, только что освободивший сочетание в системных настройках, продолжал бы видеть «занято».
/// Тот же урок, что с `AppleSelectedInputSources` и с `AppleFnUsageType`.
enum SystemHotkeys {

    /// Имена тех функций, в которых мы уверены. Остальные называем обобщённо: выдумывать имя
    /// системной функции по номеру хуже, чем честно сказать «занято macOS».
    private static let known: [Int: String] = [
        32:  "Mission Control",
        33:  "окна программы",
        60:  "переключение раскладки",
        61:  "переключение раскладки",
        64:  "Spotlight",
        65:  "поиск в Finder",
        160: "Launchpad",
        163: "Центр уведомлений",
        179: "панель эмодзи",
    ]

    /// Чем занято сочетание, или nil, если свободно.
    /// Учитываются ТОЛЬКО включённые сочетания: выключенное в системных настройках не мешает.
    static func takenBy(keyCode: Int, mods: CGEventFlags) -> String? {
        let want = mods.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        guard want != 0 else { return nil }
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        else { return nil }
        for (id, entry) in raw {
            guard let e = entry as? [String: Any], (e["enabled"] as? Bool) == true,
                  let value = e["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let code = (params[1] as? NSNumber)?.intValue,
                  let mask = (params[2] as? NSNumber)?.uint64Value
            else { continue }
            guard code == keyCode else { continue }
            // Сравниваем ровно четыре модификатора: в маске системы встречаются и служебные биты.
            let theirs = CGEventFlags(rawValue: mask)
                .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
            guard theirs == want else { continue }
            return known[Int(id) ?? -1] ?? L10n.t("hk.sysGeneric")
        }
        return nil
    }
}
