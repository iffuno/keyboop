import AppKit

/// ОПОЗНАНИЕ SPOTLIGHT, КОТОРОГО НЕ ВИДНО ОБЫЧНЫМ СПОСОБОМ (05.08.2026).
///
/// Зачем это вообще понадобилось. 31.07 мы внесли `com.apple.Spotlight` в `defaultOffApps`: его
/// инлайн-автодополнение вставляет хвост ВЫДЕЛЕННЫМ текстом, наш первый Backspace гасит выделение
/// вместо символа, и «ghjdthrf» превращается в «gпров». Правило записали, посчитали закрытым, а оно
/// **ни разу не сработало**: режим программы ищется по `NSWorkspace.frontmostApplication`, а
/// Spotlight фронтальную программу НЕ меняет. Замерено дважды: пока панель открыта и человек в неё
/// печатает, `frontmostApplication` продолжает показывать Telegram. То есть исключение было
/// недостижимо по построению, и отзыв #90 («doube» → «вdouble») это ровно та порча, от которой мы
/// уже защитились на бумаге.
///
/// Почему именно список окон. Проверены три способа, два отпали:
/// - `NSWorkspace.didActivateApplicationNotification` — на Spotlight не приходит вовсе;
/// - `NSRunningApplication.isActive` у процесса Spotlight — остаётся `false`, даже когда панель
///   открыта и принимает ввод;
/// - распределённые и darwin-уведомления — система об открытии не сообщает ничего (слушали оба
///   центра со всеми именами, за открытие и закрытие не пришло ни одного события).
///
/// Остаётся `CGWindowListCopyWindowInfo`. Он стоит **1.3 мс** на вызов, поэтому на горячем пути его
/// быть не может: наружу торчит только поле `isOpen`, а сам опрос идёт в фоне.
///
/// Опознаём по PID процесса, а НЕ по `kCGWindowOwnerName`. Имя владельца локализуется (в том же
/// списке окон рядом лежат «Календарь» и «Reminders»), и опора на строку «Spotlight» сломалась бы
/// на языке, который мы не проверяли. Bundle id не переводится.
///
/// Замеры задержек, из которых выбраны пороги:
/// - окно появляется через **69–213 мс** после ⌘Space (первый заход дольше, процесс прогревается);
/// - при закрытии окно висит в списке ещё **800 мс**, но прозрачность падает до нуля за **170 мс**.
///   Поэтому закрытие определяем по `alpha`, а не по исчезновению окна: иначе после каждого захода в
///   Spotlight мы почти секунду не конвертировали бы в обычной программе.
enum SpotlightWatch {

    /// Открыта ли панель. Читается на ГОРЯЧЕМ пути, поэтому обязано оставаться чтением поля.
    /// Пишется из фоновой очереди, читается из потока тапа: гонка тут безобидна, худшее следствие
    /// это решение по значению возрастом в одну пробу.
    private(set) static var isOpen = false

    /// Дёргается, когда состояние ИЗМЕНИЛОСЬ. Зовётся на главном потоке.
    static var onChange: (() -> Void)?

    private static let queue = DispatchQueue(label: "ru.keyboop.spotlight", qos: .utility)
    private static var lastPoke: CFTimeInterval = 0
    /// PID каждого хоста панели; 0, пока процесс не найден. Проверяются ОБА на каждой пробе:
    /// на 26 Spotlight поднимается по требованию, и запомнить навсегда первый найденный хост нельзя.
    private static var pids: [String: pid_t] = [:]
    private static var loggedHosts = Set<String>()

    /// ⚠️ НА macOS 27 ПАНЕЛЬ SPOTLIGHT ЖИВЁТ В ДРУГОМ ПРОЦЕССЕ (задача 261, отзывы #309, #311, #289,
    /// #282; проверено на Маке автора 26.09.2026). Процесса `com.apple.Spotlight` там нет вовсе
    /// (`launchctl print gui/501/com.apple.Spotlight` отвечает «Could not find service», LaunchAgent
    /// выключен под флагом `IntelligenceFlow/Campo`), а поиск рисует `/System/Applications/Siri AI.app`
    /// с bundle id `com.apple.campo`. Раньше мы искали только старый id, `isOpen` на 27 был навсегда
    /// false, и молча: в лог пишется только смена состояния. Отсюда оба симптома 0.4.9 на 27:
    /// первая буква остаётся (не включался Delete-вперёд), а при соседнем перехватчике замена
    /// уходила в окно под Spotlight (synthPostTap выбирал annotated).
    ///
    /// Старый id стоит первым и проверяется как раньше, путь macOS 26 не меняется. Для нового хоста
    /// добавлен фильтр ширины: у Siri AI бывает маленькое окно (84×77), которое на экране само по
    /// себе и поиском не является; ложное «открыт» включило бы Delete-вперёд в обычных программах.
    ///
    /// И слой: на Маке автора 26.09.2026 панель поиска на 27 это 640×57 на слое 23, то есть плавает
    /// над обычными окнами, как и старая панель 640×56. Обычное окно самого Siri AI (чат) лежит на
    /// слое 0, и поиском оно не является. Для старого хоста слой не проверяем: путь 26 не трогаем.
    private static let hosts: [(id: String, minWidth: CGFloat, floatingOnly: Bool)] = [
        ("com.apple.Spotlight", 0, false),
        ("com.apple.campo", 400, true),
    ]

    /// Интервал опроса. 250 мс подобраны так: первая буква в Spotlight конверсию не вызывает (для
    /// неё нужно слово), значит к моменту, когда мы впервые захотим тронуть текст, проба уже прошла.
    private static let interval: CFTimeInterval = 0.25

    /// Зовётся из тапа на каждое нажатие. Синхронно здесь происходит ровно одно чтение часов и
    /// сравнение — всё остальное уезжает в фон.
    ///
    /// Почему опрос привязан к НАЖАТИЯМ, а не к таймеру: Spotlight интересен только тогда, когда в
    /// него печатают. Таймер жёг бы батарею круглосуточно ради события, которое случается несколько
    /// раз в день; так же в простое мы не делаем ничего вообще.
    static func poke() {
        let now = CACurrentMediaTime()
        guard now - lastPoke > interval else { return }
        lastPoke = now
        queue.async { probe() }
    }

    private static func probe() {
        for host in hosts {
            if let p = pids[host.id], p != 0, NSRunningApplication(processIdentifier: p) != nil { continue }
            let p = NSRunningApplication.runningApplications(withBundleIdentifier: host.id).first?.processIdentifier ?? 0
            pids[host.id] = p
            // Одна строка на хост за запуск: по ней в отзыве видно, нашли ли мы панель вообще. На 26
            // Spotlight поднимается по требованию, поэтому «не найден» до первого ⌘Space это норма,
            // и её мы не пишем.
            if p != 0, loggedHosts.insert(host.id).inserted {
                let id = host.id
                DispatchQueue.main.async { kbLog("Spotlight: панель живёт в \(id) (pid \(p))") }
            }
        }
        var minWidth: [pid_t: CGFloat] = [:]
        var floatingOnly: [pid_t: Bool] = [:]
        for host in hosts {
            if let p = pids[host.id], p != 0 { minWidth[p] = host.minWidth; floatingOnly[p] = host.floatingOnly }
        }
        var open = false
        var why = ""
        if !minWidth.isEmpty,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let need = minWidth[pid] else { continue }
                // Высота отсекает служебные окна нулевого размера, прозрачность — затухающее после
                // закрытия. Оба порога взяты из замеров, а не на глаз: живая панель это 640×56 при
                // alpha ровно 1.0, а через 106 мс после Escape прозрачность уже 0.28. Ширина нужна
                // только хосту macOS 27 (см. `hosts`).
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      (b["Height"] ?? 0) > 40,
                      (b["Width"] ?? 0) >= need,
                      !(floatingOnly[pid] ?? false) || ((w[kCGWindowLayer as String] as? Int) ?? 0) > 0,
                      (w[kCGWindowAlpha as String] as? Double ?? 0) > 0.5 else { continue }
                open = true
                // По какому окну решили: хост, размер, слой. Только геометрия, без содержимого. На 27
                // у Siri AI могут быть и другие крупные окна, и по этой строке видно, не принято ли
                // за поиск чужое окно (задача 261).
                let host = hosts.first { pids[$0.id] == pid }?.id ?? "?"
                why = " (\(host), \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0)), слой \(w[kCGWindowLayer as String] ?? "?"))"
                break
            }
        }
        guard open != isOpen else { return }
        isOpen = open
        DispatchQueue.main.async {
            kbLog("Spotlight \(open ? "открыт" + why : "закрыт") — правила программы пересчитаны")
            onChange?()
        }
    }
}
