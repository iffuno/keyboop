import Foundation

/// Caps Lock как мгновенный переключатель языка — БЕЗ включения самого капса.
///
/// Почему не event tap: замок Caps (LED + верхний регистр) включается в HID-драйвере, НИЖЕ
/// session-тапа — проглатывание flagsChanged событие прячет, но замок уже включён (проверено
/// 24.07 на живой машине: капс загорался, язык не переключался). Ровно поэтому референсный
/// опенсорс (CapsLockSwitcher) идёт другим путём, и мы за ним:
///
/// РЕМАП НА УРОВНЕ HID: usage 0x700000039 (Caps) → 0x700000090 (LANG1, «корейская» клавиша,
/// у которой в macOS НЕТ никакого системного действия — ни замка, ни LED). Применяется через
/// `hidutil property --set UserKeyMapping` (официальный механизм Apple, TN2450: root не нужен,
/// действует на все клавиатуры). Физический Caps приходит к нам обычным keyDown с keyCode 104
/// (LANG1) — EventTap его глотает и переключает язык.
///
/// Свойства механизма:
/// - НЕ переживает перезагрузку (TN2450) → повторно применяем при каждом старте (reconcile).
/// - Глобальный список ремапов. Мы применяем СВОЙ ремап только если список ПУСТ, поэтому
///   `remove` честно ставит пустой список — чужого там быть не может (инвариант apply).
///   Если у пользователя уже есть свои ремапы (Karabiner-style) — НЕ вмешиваемся и пишем в лог.
/// - Снимаем: при выключении тумблера/смене комбинации, при выходе приложения. После падения
///   без restore ремап снимет reconcile() следующего запуска (настройка выключена → remove).
enum CapsRemap {
    /// Виртуальный keyCode, которым LANG1 приходит в CGEventTap.
    static let lang1KeyCode: Int64 = 104

    private static let mappingJSON =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000090}]}"#

    /// Нужен ли ремап при текущих настройках?
    static var wanted: Bool {
        let s = AppSettings.shared
        return s.instantSwitchEnabled && s.instantSwitchMode == "modkey" && s.instantSwitchKeyCode == 57
    }

    /// Привести состояние системы к настройкам. Звать: на старте, после изменения настроек
    /// мгновенного переключения, при выходе (через removeIfOurs). Работает асинхронно (subprocess).
    static func reconcile() {
        let want = wanted
        DispatchQueue.global(qos: .userInitiated).async {
            want ? apply() : removeIfOurs()
        }
    }

    /// Почему Caps-режим не включился. `nil` — всё в порядке.
    ///
    /// ⚠️ ЗАВЕДЕНО, ПОТОМУ ЧТО ОТКАЗ БЫЛ МОЛЧАЛИВЫМ (01.08.2026). Оба провала ниже писались только
    /// в лог, а человек видел ровно одно: тумблер включён, Caps Lock язык не меняет. Дальше он
    /// решает, что сломано приложение, и уходит. Отказ, о котором знает только лог, для человека
    /// неотличим от бага — а причина у нас на руках и объясняется одной строкой.
    enum Failure { case foreignMapping, hidutilFailed }
    private(set) static var failure: Failure? {
        didSet {
            guard failure != oldValue else { return }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .capsRemapStatusChanged, object: nil) }
        }
    }

    private static func apply() {
        guard !AppSettings.shared.capsRemapApplied else {
            // Наш флаг стоит, но после перезагрузки системный список мог обнулиться — переприменяем.
            _ = run(["property", "--set", mappingJSON])
            return
        }
        let cur = run(["property", "--get", "UserKeyMapping"]) ?? ""
        let empty = cur.contains("(null)") || !cur.contains("HIDKeyboardModifierMappingSrc")
        guard empty else {
            // Чужие ремапы клавиш (hidutil/Karabiner-скрипты). Молча перезаписать = сломать чужое.
            kbLog("caps: у системы уже есть свои ремапы клавиш — Caps-режим их не трогает и НЕ активирован; сообщите нам через «Сообщить о проблеме…»")
            failure = .foreignMapping
            return
        }
        if run(["property", "--set", mappingJSON]) != nil {
            AppSettings.shared.capsRemapApplied = true
            failure = nil
            kbLog("caps: ремап Caps→LANG1 применён (hidutil), капс-замок отключён на время режима")
        } else {
            failure = .hidutilFailed
            kbLog("caps: hidutil не отработал — Caps-режим не активирован")
        }
    }

    static func removeIfOurs() {
        failure = nil   // режим выключают — жаловаться больше не на что
        guard AppSettings.shared.capsRemapApplied else { return }
        // Инвариант apply: наш ремап ставился только в ПУСТОЙ список → пустой список = «как было».
        _ = run(["property", "--set", #"{"UserKeyMapping":[]}"#])
        AppSettings.shared.capsRemapApplied = false
        kbLog("caps: ремап Caps→LANG1 снят, капс снова обычный")
    }

    /// Синхронный вызов hidutil; nil = не запустился/ненулевой код выхода.
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
