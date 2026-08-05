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
    private static var cachedPID: pid_t = 0

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
        if cachedPID == 0 || NSRunningApplication(processIdentifier: cachedPID) == nil {
            cachedPID = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.Spotlight")
                .first?.processIdentifier ?? 0
        }
        guard cachedPID != 0 else { return }
        var open = false
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == cachedPID {
                // Высота отсекает служебные окна нулевого размера, прозрачность — затухающее после
                // закрытия. Оба порога взяты из замеров, а не на глаз: живая панель это 640×56 при
                // alpha ровно 1.0, а через 106 мс после Escape прозрачность уже 0.28.
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      (b["Height"] ?? 0) > 40,
                      (w[kCGWindowAlpha as String] as? Double ?? 0) > 0.5 else { continue }
                open = true
                break
            }
        }
        guard open != isOpen else { return }
        isOpen = open
        DispatchQueue.main.async {
            kbLog("Spotlight \(open ? "открыт" : "закрыт") — правила программы пересчитаны")
            onChange?()
        }
    }
}
