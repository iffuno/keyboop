import Foundation

/// ПАУЗА «НЕ МЕШАЙ СЕЙЧАС» (задача 21, автор 05.08.2026).
///
/// Зачем отдельное понятие, если есть тумблер «авто». Выключенный тумблер человек забывает вернуть,
/// и приложение молчит неделю, а потом приходит отзыв «перестало работать». Пауза сама кончается, и
/// именно этим отличается от выключения: она для игры, демонстрации экрана и чужого ноутбука, то
/// есть для случаев, которые заведомо конечны.
///
/// ⚠️ СОСТОЯНИЕ ЖИВЁТ В ПОЛЕ, А НЕ В UserDefaults. Проверка стоит на самом горячем пути проекта, в
/// колбэке перехвата, а чтение настроек оттуда у нас в списке архитектурного долга отдельной
/// строкой. На диск пишем при смене, читаем один раз при первом обращении.
enum Pause {

    /// Момент окончания в unix-времени. 0 = паузы нет.
    private static var untilCache: Double = AppSettings.shared.pausedUntil

    /// Дёргается при каждой смене состояния — меню перерисовывает себя.
    static var onChange: (() -> Void)?

    /// На паузе прямо сейчас? Читается на горячем пути: одно сравнение и чтение часов.
    static var active: Bool { untilCache > Date().timeIntervalSince1970 }

    /// Сколько осталось. nil, если паузы нет.
    static var remaining: TimeInterval? {
        let left = untilCache - Date().timeIntervalSince1970
        return left > 0 ? left : nil
    }

    /// Когда закончится — для строки в меню.
    static var until: Date? { untilCache > 0 ? Date(timeIntervalSince1970: untilCache) : nil }

    static func start(minutes: Int) {
        untilCache = Date().timeIntervalSince1970 + Double(minutes) * 60
        AppSettings.shared.pausedUntil = untilCache
        kbLog("пауза: молчу \(minutes) мин, до \(shortTime(untilCache))")
        notify()
        // Разбудить меню в момент истечения. Таймер — только для картинки: сама проверка `active`
        // всегда считает по часам, поэтому пропущенное срабатывание (сон машины) ничего не ломает.
        let left = untilCache - Date().timeIntervalSince1970
        DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.5) {
            guard !active else { return }
            notify()
        }
    }

    static func stop() {
        guard untilCache != 0 else { return }
        untilCache = 0
        AppSettings.shared.pausedUntil = 0
        kbLog("пауза: снята вручную")
        notify()
    }

    private static func notify() { DispatchQueue.main.async { onChange?() } }

    private static func shortTime(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
