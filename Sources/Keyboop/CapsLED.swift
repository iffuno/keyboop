import Foundation
import AppKit
import Carbon   // kTISNotifySelectedKeyboardInputSourceChanged
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Лампочка Caps Lock как ИНДИКАТОР ЯЗЫКА: горит — русский, погасла — английский.
/// Перенос проверенной наработки из USRU (наш же переключатель, 2026-07-15…24) — там этот механизм
/// отработал месяц на живом железе, включая внешнюю Bluetooth-клавиатуру и встроенную MacBook.
///
/// КАК: пишем HID-элемент Caps-LED (usage page 0x08, usage 0x02) на КАЖДОЙ клавиатуре, у которой он
/// есть. Это независимый от замка Caps канал: лампочка загорается, а сам капс не включается.
/// Открываем HID НЕ эксклюзивно (в отличие от Karabiner) — никому не мешаем, и нам никто не мешает.
///
/// ЧТО НУЖНО: разрешение «Мониторинг ввода» (IOHIDManagerOpen без него вернёт 0x...02e2). Accessibility
/// НЕ нужен — индикатор работает, даже когда движок Keyboop ещё не стартовал.
///
/// ЦЕНА: лампочка перестаёт означать «включён капс» — она означает «включён русский» (так же, как
/// `grp_led:caps` в Linux XKB, откуда фича и родом). Поэтому настройка ВЫКЛЮЧЕНА по умолчанию и
/// честно описана в UI: заглавные включаются по Shift+Caps Lock, когда Caps занят сменой языка.
///
/// ЖИВУЧЕСТЬ (уроки USRU): систему нужно догонять, а не однократно писать —
///  • клавиатура (пере)подключилась → приходит с погашенной лампочкой (device-matching колбэк);
///  • пробуждение из сна → HID-сервисы пересоздаются, лампочка гаснет (NSWorkspace.didWake);
///  • реальный капс сменился → ОС сама дёргает лампочку под своё состояние (перезаписываем).
enum CapsLED {

    // MARK: - Состояние (всё — с главного потока; запись в железо уходит на writeQ)

    /// HID-элемент лампочки Caps Lock.
    private static let ledPage = 0x08
    private static let ledCapsLock = 0x02

    private static var manager: IOHIDManager?
    /// Клавиатуры, у которых РЕАЛЬНО есть caps-LED (остальные не держим вовсе).
    private static var devices: [IOHIDDevice] = []
    /// Что лампочка должна показывать (true = русский).
    private static var desiredOn = false
    /// Логируем только ПЕРЕХОДЫ «пишется ↔ не пишется», а не каждую запись: отключённая
    /// (или уснувшая) клавиатура иначе спамит лог на каждом переключении языка.
    private static var lastWriteOK = true
    /// Была ли хоть одна запись с момента включения (иначе первый set того же значения — не «повтор»).
    private static var wroteOnce = false
    private static var wakeObserver: NSObjectProtocol?
    private static var tisObserver: NSObjectProtocol?
    private static var refreshWork: DispatchWorkItem?
    /// Когда язык последний раз сообщили ДОСТОВЕРНО (наш select / сверка с реальностью). Чтение TIS
    /// в этом окне возвращает старое значение (баг стейл-чтения, см. LayoutManager.opinionCyr) —
    /// и перечитывание перебило бы лампочку неправдой сразу после честного переключения.
    private static var lastAuthoritativeAt: TimeInterval = 0
    /// Secure Input (парольное поле, sudo, диалог авторизации) ЗАПРЕЩАЕТ запись в лампочку:
    /// IOHIDDeviceSetValue отвечает kIOReturnNotPermitted (0x...02e2) на КАЖДОЙ клавиатуре — и
    /// через свежий менеджер, и через элементы, взятые до появления поля (замер USRU 28.07).
    /// Уведомления об этом состоянии в системе НЕТ, только опрос. Смена языка при этом проходит
    /// (её делает не HID), и TIS-уведомление к нам доезжает — то есть про язык мы знаем, а
    /// написать не можем; без догоняющей записи лампочка врала бы до следующего переключения.
    private static var secureTimer: Timer?
    private static var secureOn = false
    /// Одна строка в лог на эпизод, а не на каждую заблокированную запись.
    private static var secureLogged = false
    /// Запись в железо — не на главном потоке: IOHIDDeviceSetValue по Bluetooth может задуматься,
    /// а на main живёт ранлуп CGEventTap (затык main = система глушит тап, инцидент 21.07).
    private static let writeQ = DispatchQueue(label: "ru.keyboop.caps-led", qos: .userInitiated)

    // MARK: - Публичное

    /// Настройка включена?
    static var wanted: Bool { AppSettings.shared.capsLEDIndicator }

    /// Сколько подключённых клавиатур умеют зажигать Caps-LED (для честного статуса в настройках;
    /// достоверно только когда индикатор запущен).
    static var ledKeyboardCount: Int { devices.count }
    static var running: Bool { manager != nil }

    /// Привести лампочку к настройке. Звать: на старте приложения и при переключении тумблера.
    static func reconcile() {
        onMain {
            if wanted {
                start()
                refreshFromSystem(force: true)
            } else {
                shutdown()
            }
        }
    }

    /// Язык переключили МЫ (LayoutManager.selectLayout) или сверка установила правду —
    /// это достоверное значение, кладём его на лампочку. Повтор того же значения НЕ пишем:
    /// фоновая сверка раскладки зовёт нас каждые 2.5с, а лишний output-репорт по Bluetooth
    /// — это лишний трафик и разряд клавиатуры на ровном месте (переписываем только по reassert).
    /// `authoritative` — «значение назвали, а не прочитали». Взводит окно, внутри которого
    /// перечитывание системы откладывается: сразу после нашего `TISSelectInputSource` чтение
    /// возвращает СТАРЫЙ источник (стейл-баг, см. LayoutManager.opinionCyr), и перечитывание
    /// перебило бы лампочку неправдой.
    /// Периодическая сверка (`reconcileWithReality`) зовёт нас с `false`: её значение тоже верное,
    /// но окно взводить нельзя. Она срабатывает на каждой границе слова, то есть при печати
    /// практически непрерывно, — и окно оказывалось взведено всегда, из-за чего ВНЕШНЕЕ
    /// переключение (🌐 или ⌃Space) выбрасывалось и лампочка замирала. Ровно этот баг и был.
    /// `KEYBOOP_LEDDEBUG=1` пишет в лог каждый вызов set: без этого лампочка отлаживается вслепую —
    /// сами записи в железо намеренно не логируются (переходы «пишется/не пишется» только).
    private static let debugLog = ProcessInfo.processInfo.environment["KEYBOOP_LEDDEBUG"] == "1"

    static func set(cyrillic: Bool, authoritative: Bool = true) {
        onMain {
            if debugLog {
                kbLog("caps-LED[debug]: set(cyr=\(cyrillic), authoritative=\(authoritative)) "
                    + "было desiredOn=\(desiredOn) manager=\(manager != nil)")
            }
            if authoritative { lastAuthoritativeAt = ProcessInfo.processInfo.systemUptime }
            let changed = (cyrillic != desiredOn) || !wroteOnce
            desiredOn = cyrillic
            guard manager != nil, changed else { return }
            write(cyrillic)
        }
    }

    /// Язык сменили ИЗВНЕ (системный переключатель). Чтение TIS прямо в момент уведомления бывает
    /// стейлым (см. LayoutManager.opinionCyr) — перечитываем чуть позже, когда оно устоялось.
    static func refreshSoon(after: TimeInterval = 0.25) {
        guard wanted else { return }
        onMain {
            refreshWork?.cancel()
            let w = DispatchWorkItem { refreshFromSystem() }
            refreshWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
        }
    }

    /// Перечитать язык из системы и переписать лампочку. `force` — для момента включения индикатора:
    /// там читать надо в любом случае, иначе лампочка останется погашенной до следующего переключения.
    static func refreshFromSystem(force: Bool = false) {
        guard wanted else { return }
        onMain {
            let since = ProcessInfo.processInfo.systemUptime - lastAuthoritativeAt
            if !force, since <= 1.0 {
                // Внутри окна читать нельзя (стейл), но и ВЫБРАСЫВАТЬ перечитывание нельзя: если
                // язык за это время увела система, лампочка так и останется врать до следующего
                // события. Поэтому откладываем до конца окна, а не отменяем.
                refreshSoon(after: 1.0 - since + 0.05)
                return
            }
            // Прочитанное — не «названное»: окно не взводим, иначе следующая внешняя смена
            // подавила бы сама себя.
            let cyr = LayoutManager.systemIsCyrillic()
            if debugLog { kbLog("caps-LED[debug]: refreshFromSystem → cyr=\(cyr)") }
            set(cyrillic: cyr, authoritative: false)
        }
    }

    /// Лампочку мог перебить кто-то ещё (реальный капс, пробуждение, переподключение клавиатуры) —
    /// переписываем своё состояние сейчас и ещё раз следом, чтобы выиграть гонку с системой.
    static func reassert(ladder: [TimeInterval] = [0.15, 0.6]) {
        guard wanted else { return }
        onMain {
            guard manager != nil else { return }
            write(desiredOn)
            for d in ladder {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    guard wanted, manager != nil else { return }
                    write(desiredOn)
                }
            }
        }
    }

    /// Выключить индикатор: вернуть лампочке её системный смысл (состояние реального капса) и
    /// отпустить HID.
    ///
    /// `atExit` — ТОЛЬКО для applicationWillTerminate: там нельзя уйти в async (терминацию GCD не
    /// ждёт), поэтому пишем через `writeQ.sync` — блокируемся, зато очередь сначала доигрывает
    /// незавершённые записи, и наша «восстановительная» ложится ПОСЛЕДНЕЙ (иначе поздняя запись
    /// перебила бы её и лампочка осталась бы горящей).
    ///
    /// Обычный путь (тумблер в настройках выключили) — АСИНХРОННО: `IOHIDDeviceSetValue` по
    /// Bluetooth и `IOServiceOpen` могут задуматься, а на main живёт ранлуп CGEventTap — затык main
    /// система лечит отключением тапа с потерей нажатий (инцидент 21.07). Ровно то, от чего
    /// writeQ и придуман; на этом пути обходить его нельзя.
    static func shutdown(atExit: Bool = false) {
        guard let mgr = manager else { return }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        if let o = tisObserver { DistributedNotificationCenter.default().removeObserver(o); tisObserver = nil }
        refreshWork?.cancel(); refreshWork = nil
        secureTimer?.invalidate(); secureTimer = nil; secureLogged = false
        // Состояние гасим СРАЗУ: пока идёт восстановительная запись, отложенные reassert-замыкания
        // видят manager == nil и молчат — перебить нас уже некому.
        let snapshot = devices
        manager = nil
        devices = []
        wroteOnce = false
        let release = {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            kbLog("caps-LED: индикатор языка выключен, лампочка возвращена системе")
        }
        if atExit {
            writeQ.sync { _ = writeAll(snapshot, RealCapsLock.isOn) }
            release()
        } else {
            writeQ.async {
                _ = writeAll(snapshot, RealCapsLock.isOn)
                DispatchQueue.main.async(execute: release)
            }
        }
    }

    // MARK: - HID

    private static func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Матчим ТОЛЬКО клавиатуры (Generic Desktop / Keyboard). С nil-матчингом в набор попадают
        // неоткрываемые SMC/PMU-эндпойнты, и IOHIDManagerOpen возвращает kIOReturnUnsupported,
        // хотя настоящие клавиатуры открылись бы (замер USRU 24.07).
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDDeviceUsagePageKey as String: Int(1),
            kIOHIDDeviceUsageKey as String: Int(6),
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, deviceArrived, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, deviceRemoved, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        // Не выходим по ошибке открытия: USRU видел kIOReturnUnsupported при исправно работающих
        // записях в лампочку. Реальную неудачу поймает первая запись (лог перехода ниже).
        if r != kIOReturnSuccess {
            kbLog("caps-LED: IOHIDManagerOpen вернул 0x\(String(format: "%08x", r)) " +
                  "(0x...02e2 = нет доступа «Мониторинг ввода»; 0x...02c5 = клавиатуру захватила другая программа)")
        }
        // Список наполняем СИНХРОННО: колбэк матчинга приедет только следующим витком ранлупа, а
        // настройкам статус («лампочек не нашлось») нужен сразу после включения тумблера.
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            devices = set.filter { !capsLEDElements($0).isEmpty }
        }
        // Смена языка ЛЮБЫМ способом — своя подписка, а не через движок: индикатору не нужен
        // Accessibility, и он обязан работать, даже когда движок ещё не стартовал (доступ не выдан).
        // Наши собственные переключения приходят сюда же, но их правду уже установил set() —
        // от стейл-чтения в этот момент защищает окно lastAuthoritativeAt (см. refreshFromSystem).
        tisObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in refreshSoon() }
        // Пробуждение: HID-сервисы пересоздаются, лампочка гаснет (в USRU это ловилось
        // IORegisterForSystemPower; здесь хватает NSWorkspace — подтверждать sleep не нужно).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            kbLog("caps-LED: пробуждение — переписываю лампочку")
            reassert(ladder: [1, 3, 8])
        }
        // Secure Input: ловим фронт «включено → выключено» и переписываем лампочку БЕЗУСЛОВНО, а
        // не только когда видели отказ, — про смену языка внутри поля мы могли и не узнать.
        // Лесенка нужна потому, что запрет живёт ещё мгновение после закрытия поля (USRU 28.07).
        secureOn = IsSecureEventInputEnabled()
        secureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let now = IsSecureEventInputEnabled()
            defer { secureOn = now }
            guard secureOn, !now else { return }
            secureLogged = false
            reassert(ladder: [0.3, 1.0])
        }
        kbLog("caps-LED: индикатор языка включён (клавиатур с лампочкой: \(devices.count))")
    }

    /// Клавиатура появилась (включая уже подключённые при старте): свежая приходит с погашенной
    /// лампочкой — дожимаем не только сейчас, но и чуть позже (BT-устройство «доезжает»).
    private static let deviceArrived: IOHIDDeviceCallback = { _, _, _, device in
        guard !capsLEDElements(device).isEmpty else { return }
        if !devices.contains(where: { $0 === device }) { devices.append(device) }
        reassert(ladder: [0.5, 2.0])
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { _, _, _, device in
        devices.removeAll { $0 === device }
    }

    private static func capsLEDElements(_ d: IOHIDDevice) -> [IOHIDElement] {
        let match: [String: Any] = [
            kIOHIDElementUsagePageKey as String: ledPage,
            kIOHIDElementUsageKey as String: ledCapsLock,
        ]
        guard let arr = IOHIDDeviceCopyMatchingElements(d, match as CFDictionary,
                                                        IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return [] }
        return arr
    }

    /// Записать лампочку на всех клавиатурах фоном (см. writeQ — main держит ранлуп тапа).
    /// Последнее желаемое значение и флаг «задача уже в очереди». Оба трогаются ТОЛЬКО с main.
    ///
    /// ⚠️ ОЧЕРЕДЬ БЕЗ ЭТОГО ПРИМЕНЯЛА ИСТОРИЮ, А НЕ ПОСЛЕДНЕЕ ЗНАЧЕНИЕ (найдено обратным чтением
    /// 17.08). Запись в спящую Bluetooth-клавиатуру блокирует writeQ на ~5 с, задачи копились
    /// FIFO, и на ЖИВУЮ клавиатуру приезжали устаревшие значения с опозданием в десятки секунд:
    /// лог поймал запись «1» через 15 с после того, как язык стал английским. Со стороны это
    /// выглядит как «лампочка постоянно горит» — ровно жалоба пользователя. Теперь задача одна и читает
    /// последнее значение в момент исполнения.
    /// ⚠️ НЕ main.sync: на выходе `shutdown(atExit:)` держит main в `writeQ.sync`, и задача,
    /// которая полезла бы с writeQ обратно на main, повесила бы завершение намертво. Поэтому
    /// последнее значение и снимок устройств передаются через собственный замок.
    private static let pendingLock = NSLock()
    private static var pendingOn = false
    private static var writeScheduled = false
    private static var pendingDevices: [IOHIDDevice] = []

    private static func write(_ on: Bool) {
        wroteOnce = true
        pendingLock.lock()
        pendingOn = on
        pendingDevices = devices
        let already = writeScheduled
        writeScheduled = true
        pendingLock.unlock()
        guard !already else { return }          // задача в очереди подхватит последнее значение сама
        writeQ.async {
            pendingLock.lock()
            let value = pendingOn
            let snapshot = pendingDevices
            writeScheduled = false
            pendingLock.unlock()
            let r = writeAll(snapshot, value)
            DispatchQueue.main.async {
                noteWrite(r, devicesEmpty: snapshot.isEmpty)
                evict(r.dead)
            }
        }
    }

    /// Убрать из списка устройства, в которые не пишется (`kIOReturnNotOpen`/`kIOReturnTimeout`):
    /// каждая запись в такое блокирует очередь на секунды, а толку ноль. Вернётся — придёт заново
    /// через device-matching.
    private static func evict(_ dead: [IOHIDDevice]) {
        guard !dead.isEmpty else { return }
        let before = devices.count
        devices.removeAll { d in dead.contains(where: { $0 === d }) }
        if devices.count != before {
            kbLog("caps-LED: убрал \(before - devices.count) клавиатуру(ы) без связи из списка — "
                + "вернутся сами при переподключении")
        }
    }

    private static func writeAll(_ list: [IOHIDDevice], _ on: Bool)
        -> (ok: Bool, blocked: Bool, dead: [IOHIDDevice]) {
        var any = false, blocked = false
        var dead: [IOHIDDevice] = []
        for d in list {
            let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "?"
            for el in capsLEDElements(d) {
                let v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, el, 0, on ? 1 : 0)
                let r = IOHIDDeviceSetValue(d, el, v)
                switch r {
                case kIOReturnSuccess:      any = true
                case kIOReturnNotPermitted: blocked = true   // Secure Input, см. secureTimer
                // ⚠️ И ТАЙМАУТ ТОЖЕ (замер 17.08: у встроенной клавиатуры ВТОРОЙ HID-интерфейс с
                // пустым именем, он не принимает выходные отчёты и держит запись 5 секунд до
                // kIOReturnTimeout — 0x2d6). Настоящая клавиатура, уснувшая по Bluetooth, при
                // пробуждении переподключается и придёт заново через device-matching.
                case kIOReturnNotOpen, kIOReturnTimeout:
                    if !dead.contains(where: { $0 === d }) { dead.append(d) }
                default:                    break
                }
                if debugLog {
                    // Обратное чтение: что железо ДУМАЕТ о лампочке после нашей записи.
                    let ph = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, el, 0, 0)
                    var back = Unmanaged.passUnretained(ph)
                    let rr = IOHIDDeviceGetValue(d, el, &back)
                    let got = rr == kIOReturnSuccess
                        ? String(IOHIDValueGetIntegerValue(back.takeUnretainedValue())) : "?"
                    kbLog("caps-LED[debug]: запись \(on ? 1 : 0) → \(name) "
                        + "usage=\(IOHIDElementGetUsage(el)) ret=0x\(String(format: "%04x", r & 0xffff)) "
                        + "читается=\(got)")
                }
            }
        }
        return (any, blocked, dead)
    }

    private static func noteWrite(_ r: (ok: Bool, blocked: Bool, dead: [IOHIDDevice]), devicesEmpty: Bool) {
        // Запрет по Secure Input — не поломка: писать нельзя, пока открыто парольное поле, и
        // лампочку допишет фронт «поле закрылось». Состояние lastWriteOK при этом НЕ трогаем,
        // иначе лог скажет «ни одна клавиатура не приняла запись» — правдоподобная неправда,
        // которая уводит диагностику к правам и отвалившейся клавиатуре (урок USRU 28.07).
        if r.blocked && !r.ok {
            // ⚠️ ТОТ ЖЕ КОД ОШИБКИ ДАЁТ И ОТСУТСТВИЕ «МОНИТОРИНГА ВВОДА» (ревью 17.08). Пока это не
            // различалось, включённый без доступа тумблер писал в лог про парольное поле, которое
            // «закроется» никогда, и уводил разбор багрепорта в ложную ветку. Права проверяются
            // дёшево, поэтому спрашиваем их прежде, чем валить на Secure Input.
            if !Permissions.inputMonitoringGranted() {
                guard lastWriteOK else { return }
                lastWriteOK = false
                kbLog("caps-LED: нет доступа «Мониторинг ввода» — лампочка ждёт разрешения")
                return
            }
            guard !secureLogged else { return }
            secureLogged = true
            kbLog("caps-LED: Secure Input запрещает запись — перепишу лампочку, когда поле закроется")
            return
        }
        guard r.ok != lastWriteOK else { return }
        lastWriteOK = r.ok
        kbLog(r.ok ? "caps-LED: запись в лампочку снова работает"
                   : "caps-LED: ни одна клавиатура не приняла запись" +
                     (devicesEmpty ? " (клавиатур с лампочкой нет)" : " (нет доступа «Мониторинг ввода»?)"))
    }

    private static func onMain(_ b: @escaping () -> Void) {
        if Thread.isMainThread { b() } else { DispatchQueue.main.async(execute: b) }
    }
}

/// НАСТОЯЩИЙ замок Caps Lock (заглавные) — отдельно от лампочки.
///
/// Нужен, потому что в режиме «Caps Lock переключает язык» физический Caps ремапнут в LANG1
/// (см. CapsRemap) и обычным способом капс не включить вовсе. Как в USRU: Shift+Caps Lock.
/// Механизм — IOHIDSystem (kIOHIDParamConnectType): тот же канал, которым капс щёлкает сама ОС,
/// поэтому заглавные, индикатор в меню и всё прочее ведут себя как при обычном нажатии.
enum RealCapsLock {

    static var isOn: Bool {
        var state = false
        _ = withConnect { IOHIDGetModifierLockState($0, Int32(kIOHIDCapsLockState), &state) }
        return state
    }

    /// Переключить настоящий капс. Лампочку после этого перезаписываем: ОС дёргает её под
    /// состояние капса, а у нас она — индикатор языка (USRU: гонку выигрывает повтор через 0.15с).
    static func toggle() {
        var state = false
        // Логируем только то, что РЕАЛЬНО произошло: если IOHIDSystem не открылся, замок не
        // переключился — врать в лог нельзя, по нему потом разбирают баг-репорты.
        let ok = withConnect {
            IOHIDGetModifierLockState($0, Int32(kIOHIDCapsLockState), &state)
            IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), !state)
        }
        kbLog(ok ? "caps: Shift+Caps → настоящий Caps Lock \(!state ? "ВКЛ" : "выкл")"
                 : "caps: Shift+Caps → IOHIDSystem не открылся, замок НЕ переключён")
        if ok { CapsLED.reassert() }
    }

    /// false = не удалось открыть IOHIDSystem (тело не выполнялось).
    @discardableResult
    private static func withConnect(_ body: (io_connect_t) -> Void) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS
        else { return false }
        defer { IOServiceClose(connect) }
        body(connect)
        return true
    }
}
