import Foundation

/// Совместимый фасад объединённого resource-сторожа (задачи 96 + 35).
///
/// # Зачем он вообще нужен
///
/// Когда «мгновенное переключение» висит на 🌐, мы забираем клавишу у системы: `AppleFnUsageType`
/// становится «ничего не делать». Вернуть её обязаны мы сами, и делаем это на выходе. Но выход
/// бывает не только нормальным: `kill -9` перехватить нельзя, падение мы не ловим, а удаление
/// приложения не шлёт вообще ничего. Во всех этих случаях клавиша оставалась мёртвой — в худшем
/// варианте НАВСЕГДА, потому что чинить её было уже некому и человек никак не связывал сломанную
/// клавишу с давно удалённой программой.
///
/// ⚠️ Опыт 12.08 (`Tools/GlobeProbe.swift`) закрыл красивую альтернативу: применить настройку
/// «только живьём», не трогая диск, невозможно — `TISUpdateFnUsageType` САМ пишет значение в
/// настройки. То есть след на диске неизбежен, и единственный способ его убрать после аварии это
/// кто-то, кто нас переживёт.
///
/// # Почему это тот же бинарник, а не отдельный
///
/// v3 по-прежнему запускается как `Keyboop --globe-guard <pid>`, но получает дополнительный
/// маркер и приватные pipe-дескрипторы. Старый двухаргументный режим оставлен для совместимости с
/// уже запущенными v1-сторожами. Отдельный файл в бандле означал бы свою
/// сборку, свою подпись, свою универсальную (arm64+x86_64) сборку и свой шаг нотаризации — четыре
/// новых места, где что-то может разойтись. Тот же бинарник подписан и нотаризован ровно один раз,
/// вместе с приложением.
///
/// В режиме сторожа программа НЕ поднимает ни перехватчик, ни строку меню, ни одного разрешения:
/// флаг проверяется до всего остального (`main.swift`). v3 держит независимые аренды 🌐 и SPU;
/// state machine живёт в `PersistentResourceGuard.swift`, а это имя сохраняет старые API.
///
/// # Что он стоит человеку
///
/// Второй процесс с именем Keyboop в Мониторинге системы живёт всю сессию приложения, даже когда
/// обе аренды пусты. Он спит на pipe+kqueue без опроса; выходит после normalExit или NOTE_EXIT
/// родителя и только когда доказан cleanup. Legacy v1 по-прежнему спит на kqueue.
/// Прятать его мы не будем: он назван в разделе «Приватность» и под кнопкой «i» самой функции.
enum GlobeGuard {
    static let flag = "--globe-guard"

    /// Файл с pid текущего сторожа. Свой на каждую сборку: dev и прод не должны гасить сторожей
    /// друг друга, хотя расписку о клавише делят намеренно.
    private static var pidURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bid = Bundle.main.bundleIdentifier ?? "ru.keyboop.app"
        return dir.appendingPathComponent("globe-guard-\(bid).pid")
    }

    private static func readPid() -> pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let v = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return v
    }

    // MARK: - Сторона приложения

    /// Убедиться, что сторож есть. Зовётся из `GlobeKey.reconcile()` каждый раз, когда клавиша наша.
    ///
    /// ⚠️ Именно «убедиться», а не «запустить». На перезапуске после аварии клавиша УЖЕ забрана
    /// (её никто не вернул), поэтому `take()` не зовётся, и привязать запуск сторожа к захвату
    /// значило бы остаться без него ровно в том случае, ради которого он существует.
    @discardableResult
    static func ensure() -> Bool {
        PersistentResourceGuard.ensureGlobe(legacyPID: readPid())
    }

    /// Попросить helper выполнить restore→verify→durable clear и только потом снять аренду/flock.
    @discardableResult
    static func stop() -> Bool {
        PersistentResourceGuard.dropGlobe()
    }

    // MARK: - Сторона сторожа

    /// Мы запущены сторожем? Тогда эта функция НЕ ВОЗВРАЩАЕТСЯ: подождёт родителя и выйдет.
    static func runIfRequested() {
        switch ResourceGuardLaunchPolicy.parse(CommandLine.arguments) {
        case .application:
            return
        case .invalid:
            kbLog("resource-сторож: malformed/unsupported helper argv — AppKit не запускаю")
            exit(EX_USAGE)
        case let .persistent(parent):
            exit(PersistentResourceGuard.runIfRequested(parentPID: parent) ? 0 : EX_SOFTWARE)
        case let .legacy(parent):
            exit(PersistentResourceGuard.runLegacyGlobeIfRequested(parentPID: parent) ? 0 : EX_SOFTWARE)
        }
    }

    // MARK: - Падение: запись в лог и перезапуск

    /// Отметки о перезапусках — предохранитель от петли. Простой текстовый список отметок времени.
    private static var restartsURL: URL {
        pidURL.deletingLastPathComponent().appendingPathComponent("globe-guard-restarts")
    }
    /// Больше трёх подъёмов за десять минут значит, что приложение падает не случайно, а на старте.
    private static let restartLimit = 3
    private static let restartWindow: TimeInterval = 600
    /// Приложение, прожившее меньше этого, поднимать бессмысленно: оно упало на разгоне.
    private static let minLifetime: TimeInterval = 30

    /// Разобраться, было ли это падением, записать причину и решить, поднимать ли приложение.
    ///
    /// ⚠️ ПОДНИМАЕМ ТОЛЬКО ПРИ НАЙДЕННОМ ОТЧЁТЕ О ПАДЕНИИ. «Завершить принудительно» и `kill -9`
    /// отчёта не пишут, а перезапуск после них означал бы драку с человеком, который только что
    /// сознательно закрыл программу. Это единственный признак, отличающий «упало» от «закрыли», и
    /// поэтому он же и условие.
    static func handleCrash(parentPID: pid_t, livedSince: Date, diedAt: Date) {
        // Отчёт macOS пишет с задержкой в пару секунд, поэтому ждём его, а не спрашиваем однажды.
        // Восемь секунд это верхняя граница по наблюдениям; дальше считаем, что отчёта не будет.
        let deadline = diedAt.addingTimeInterval(ResourceGuardCrashReportPolicy.secondsAfterDeath)
        var found: (url: URL, when: Date)?
        repeat {
            let lower = Date(timeIntervalSince1970: max(
                livedSince.timeIntervalSince1970 - 1,
                diedAt.timeIntervalSince1970 - ResourceGuardCrashReportPolicy.secondsBeforeDeath
            ))
            found = CrashNote.reports(after: lower).compactMap { report in
                guard let eventDate = CrashNote.processDate(report.url),
                      ResourceGuardCrashReportPolicy.matches(
                    reportPID: CrashNote.processID(report.url),
                    reportDate: eventDate,
                    parentPID: parentPID,
                    parentStartedAt: livedSince,
                    parentDiedAt: diedAt
                ) else { return nil }
                return (url: report.url, when: eventDate)
            }.first
            if found == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        } while found == nil && Date() < deadline
        guard let report = found else {
            kbLog("resource-сторож: точного crash-report для pid \(parentPID) нет — не поднимаю")
            return
        }
        if let s = CrashNote.summarize(report.url) { kbLog("globe-сторож: \(s)") }
        else { kbLog("globe-сторож: отчёт о падении есть, но разобрать не удалось") }
        // Отчёт разобран нами — приложению, которое мы сейчас поднимем, писать о нём второй раз
        // незачем: в логе получались две одинаковые записи подряд.
        CrashNote.markScanned()

        let lived = diedAt.timeIntervalSince(livedSince)
        guard lived >= minLifetime else {
            kbLog("globe-сторож: приложение прожило \(Int(lived))с — падает на старте, не поднимаю")
            return
        }
        var stamps = recentRestarts()
        guard stamps.count < restartLimit else {
            kbLog("globe-сторож: \(stamps.count) подъёма за \(Int(restartWindow / 60)) мин — дальше не поднимаю, иначе это петля")
            return
        }
        stamps.append(Date().timeIntervalSince1970)
        let text = stamps.map { "\($0)" }.joined(separator: "\n")
        try? text.write(to: restartsURL, atomically: true, encoding: .utf8)
        relaunch()
    }

    /// Отчёты о нашем падении не старше `sec` секунд.
    private static func reports(freshFor sec: TimeInterval) -> [(url: URL, when: Date)] {
        CrashNote.reports(after: Date().addingTimeInterval(-sec))
    }

    private static func recentRestarts() -> [TimeInterval] {
        guard let s = try? String(contentsOf: restartsURL, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        return s.split(separator: "\n").compactMap(Double.init).filter { now - $0 < restartWindow }
    }

    /// Поднять приложение обратно. Через `open` по бандлу, а не запуском бинарника: так это
    /// нормальный запуск программы со всеми правами и своим окружением, а не наш дочерний процесс.
    /// Если бандла больше нет (приложение удалили), `open` честно не сработает, и это правильно.
    private static func relaunch() {
        guard let bundle = Bundle.main.bundleURL as URL? else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [bundle.path]
        do { try p.run(); kbLog("globe-сторож: поднимаю Keyboop обратно") }
        catch { kbLog("globe-сторож: поднять не удалось (\(error.localizedDescription))") }
    }

}
