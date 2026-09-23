import Cocoa

/// ЕСТЬ ЛИ РЯДОМ ЧУЖОЙ АКТИВНЫЙ ПЕРЕХВАТЧИК КЛАВИАТУРЫ (12.09.2026).
///
/// Зачем это вообще понадобилось. 11.09 на реальной машине параллельно работал второй переключатель
/// раскладки, и его АКТИВНЫЙ тап на ступени session съедал куски нашей вставки: из 34 диктовок три
/// приехали порванными. Лечится это отправкой нашей синтетики НИЖЕ его тапа, на ступень annotated.
///
/// ⚠️ НО ОТПРАВЛЯТЬ ТУДА ВСЕГДА НЕЛЬЗЯ, И ЭТО ВЫЯСНИЛОСЬ ЦЕНОЙ СЛОМАННОГО ВЫПУСКА. События,
/// положенные на annotated, идут тому приложению, которое система считает передним, а Spotlight
/// передним приложением не становится (та же причина, по которой у нас висит задача 60). В
/// результате 0.4.8 уехала в бету с неработающей конверсией в Spotlight: слово распознавалось,
/// замена отправлялась, и текст не доезжал. Проверено опытом 12.09: одна и та же строка,
/// отправленная на hid, в Spotlight появляется, отправленная на annotated — нет.
///
/// Отсюда правило: **ниже чужого тапа уходим только тогда, когда чужой тап действительно есть**.
/// Без соседа отправляем как раньше, с самой ранней ступени, и Spotlight с прочими накладными
/// панелями работают как работали.
enum RivalTapWatch {

    /// Ответ живёт несколько секунд: перечисление тапов это системный вызов, а спрашивать его на
    /// каждую вставку незачем — соседи не появляются и не исчезают по десять раз в секунду.
    private static var cached = false
    private static var checkedAt: TimeInterval = -1
    private static let ttl: TimeInterval = 5

    /// Рядом работает ЧУЖОЙ активный перехватчик клавиатуры, способный съесть наше событие.
    ///
    /// Считаем чужим тап, который: не наш по pid, включён, слушает всю систему (а не один процесс),
    /// стоит на ступени HID или session (то есть ВЫШЕ нашей синтетики), имеет право её удалить
    /// (активный фильтр, а не слушатель) и интересуется нажатиями клавиш.
    static var present: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt < ttl { return cached }
        checkedAt = now
        cached = scan()
        return cached
    }

    private static func scan() -> Bool {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return report(nil) }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var got: UInt32 = 0
        guard CGGetEventTapList(count, &taps, &got) == .success else { return report(nil) }
        let mine = pid_t(ProcessInfo.processInfo.processIdentifier)
        for t in taps.prefix(Int(got)) where isRival(t, mine: mine, pathOf: executablePath) {
            return report(executablePath(t.tappingProcess) ?? "pid \(t.tappingProcess)")
        }
        return report(nil)
    }

    /// ЧИСТОЕ ПРАВИЛО «ЭТОТ ТАП — СОСЕД» (вынесено 23.09.2026 под стенд `stands/run-rivaltap.sh`).
    ///
    /// ⚠️ СИСТЕМНЫЕ ПРОЦЕССЫ APPLE СОСЕДЯМИ НЕ СЧИТАЕМ (23.09.2026). Живой замер 22.09 на машине
    /// автора: под прежний фильтр попадали Siri (`/System/Library/CoreServices/Siri.app`) и
    /// SiriNCService. То есть «сосед есть» было правдой почти у каждого, у кого включена Siri, и
    /// синтетика уезжала на annotated. Spotlight спасало второе условие в `TextReplacer.synthPostTap`,
    /// а Launchpad и прочие накладные панели — нет: у них та же беда, «переднее приложение» не они.
    /// Отсюда отзывы #292 (Launchpad) и #296 («в каких-то системных меню») даже после починки
    /// Spotlight. До 0.4.8 мы годами отправляли всё на hid при живой Siri, и её тап наших событий не
    /// ел — значит исключение возвращает проверенное поведение, а не придумывает новое.
    ///
    /// Системным считаем только то, что лежит под SIP: `/System/`, `/usr/libexec/`, `/usr/sbin/`,
    /// `/usr/bin/`, `/sbin/`, `/bin/`. Сторонний код туда положить нельзя. `/usr/local/` намеренно
    /// НЕ входит: он не защищён. Путь не определился (процесс ушёл, нет прав) — считаем соседом:
    /// лишний уход ниже чужого тапа дешевле порванной диктовки.
    static func isRival(_ t: CGEventTapInformation, mine: pid_t,
                        pathOf: (pid_t) -> String?) -> Bool {
        let keyMask: UInt64 = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard t.enabled, t.options == .defaultTap,
              t.tappingProcess != mine, t.processBeingTapped == 0,
              t.tapPoint == .cghidEventTap || t.tapPoint == .cgSessionEventTap,
              (t.eventsOfInterest & keyMask) != 0 else { return false }
        if let path = pathOf(t.tappingProcess), isSystemPath(path) { return false }
        return true
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]
            .contains { path.hasPrefix($0) }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// В лог только СМЕНУ вердикта: без неё по отзыву не понять, на какую ступень шла синтетика,
    /// а писать на каждый опрос незачем. Имя соседа это путь к программе, не текст ввода.
    private static var lastReported: String?? = .none
    private static func report(_ rival: String?) -> Bool {
        if lastReported != .some(rival) {
            lastReported = .some(rival)
            if let rival {
                kbLog("соседний перехватчик клавиатуры: \((rival as NSString).lastPathComponent) — синтетика идёт ниже него")
            } else {
                kbLog("соседних перехватчиков клавиатуры нет — синтетика идёт с ранней ступени")
            }
        }
        return rival != nil
    }
}
