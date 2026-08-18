import Foundation

/// СТОРОЖ КЛАВИШИ 🌐 — процесс, который переживает нас и возвращает системе то, что мы забрали
/// (задача 96, решение автора 12.08.2026).
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
/// Сторож запускается как `Keyboop --globe-guard <pid>`. Отдельный файл в бандле означал бы свою
/// сборку, свою подпись, свою универсальную (arm64+x86_64) сборку и свой шаг нотаризации — четыре
/// новых места, где что-то может разойтись. Тот же бинарник подписан и нотаризован ровно один раз,
/// вместе с приложением.
///
/// В режиме сторожа программа НЕ поднимает ни перехватчик, ни строку меню, ни одного разрешения:
/// флаг проверяется до всего остального (`main.swift`). Она умеет ровно одно — ждать и вернуть.
///
/// # Что он стоит человеку
///
/// Второй процесс с именем Keyboop в Мониторинге системы, пока включён захват 🌐. Он спит на
/// `kqueue` (ни опроса, ни таймера, 0% процессора) и уходит сам, как только сделает работу.
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

    private static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

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
    static func ensure() {
        if let pid = readPid(), alive(pid) { return }
        spawn()
    }

    private static func spawn() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [flag, String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            kbLog("globe-сторож: не запустился (\(error.localizedDescription))")
            return
        }
        try? String(p.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        kbLog("globe-сторож: запущен (pid \(p.processIdentifier))")
    }

    /// Погасить сторожа: клавиша возвращена нами самими, стеречь больше нечего.
    static func stop() {
        guard let pid = readPid() else { return }
        // ⚠️ НЕ УБИТЬ САМОГО СЕБЯ. Возврат клавиши у сторожа и у приложения общий (`GlobeKey.release`),
        // а он первым делом гасит сторожа — то есть проснувшийся сторож, дойдя сюда, нашёл бы в
        // файле СВОЙ pid и застрелился бы ровно перед тем, как сделать работу.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            try? FileManager.default.removeItem(at: pidURL)
            return
        }
        if alive(pid) { kill(pid, SIGTERM); kbLog("globe-сторож: остановлен (pid \(pid))") }
        try? FileManager.default.removeItem(at: pidURL)
    }

    // MARK: - Сторона сторожа

    /// Мы запущены сторожем? Тогда эта функция НЕ ВОЗВРАЩАЕТСЯ: подождёт родителя и выйдет.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let parent = pid_t(args[i + 1]) else { return }
        let startedAt = Date()
        waitForParent(parent)
        // ⚠️ ЕСЛИ МЫ ПРОСНУЛИСЬ, ВЫХОД БЫЛ АВАРИЙНЫМ, и это не догадка. При нормальном выходе
        // приложение гасит сторожа САМО (`GlobeKey.release` → `GlobeGuard.stop`), причём SIGTERM
        // убивает нас прямо в `kevent`, до единой строчки нашего кода. Значит сюда мы попадаем
        // только после падения, `kill -9` или исчезновения приложения вместе с бандлом.
        kbLog("globe-сторож: Keyboop (pid \(parent)) больше нет, выход был аварийным — возвращаю клавишу")
        // Клавишу возвращаем ПЕРВЫМ делом и ВСЕГДА, даже если следом собираемся поднимать
        // приложение: перезапуск умеет не удаться, а обещание про клавишу не должно от него зависеть.
        GlobeKey.release()
        handleCrash(livedSince: startedAt)
        // ⚠️ ПАУЗА ПЕРЕД ВЫХОДОМ, И ОНА НЕ ЛИШНЯЯ. `kbLog` пишет на своей очереди асинхронно, а
        // `exit(0)` следом убивает процесс раньше, чем очередь дойдёт до диска: первая живая
        // проверка сторожа отработала верно, но в логе не осталось ни строчки. Сторож просыпается
        // раз в жизни и ровно в тот момент, который потом придётся расследовать по логу.
        Thread.sleep(forTimeInterval: 0.3)
        exit(0)
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
    private static func handleCrash(livedSince: Date) {
        // Отчёт macOS пишет с задержкой в пару секунд, поэтому ждём его, а не спрашиваем однажды.
        // Восемь секунд это верхняя граница по наблюдениям; дальше считаем, что отчёта не будет.
        let deadline = Date().addingTimeInterval(8)
        var found: (url: URL, when: Date)?
        while Date() < deadline, found == nil {
            found = reports(freshFor: 120).first
            if found == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        guard let report = found else {
            kbLog("globe-сторож: отчёта о падении нет — значит приложение закрыли принудительно, не поднимаю")
            return
        }
        if let s = CrashNote.summarize(report.url) { kbLog("globe-сторож: \(s)") }
        else { kbLog("globe-сторож: отчёт о падении есть, но разобрать не удалось") }
        // Отчёт разобран нами — приложению, которое мы сейчас поднимем, писать о нём второй раз
        // незачем: в логе получались две одинаковые записи подряд.
        CrashNote.markScanned()

        let lived = Date().timeIntervalSince(livedSince)
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

    /// Спим до смерти родителя. `kqueue` вместо опроса: ни таймера, ни просыпаний, ни процессора.
    ///
    /// ⚠️ Если родитель успел умереть ДО того, как мы подписались, `kevent` отвечает ошибкой ESRCH.
    /// Это не сбой, а «уже всё»: выходим из ожидания и идём возвращать клавишу. Без этой ветки
    /// сторож завис бы навсегда ровно в самом быстром сценарии аварии.
    private static func waitForParent(_ parent: pid_t) {
        let kq = kqueue()
        guard kq >= 0 else { return }
        var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        guard kevent(kq, &ev, 1, nil, 0, nil) == 0 else { close(kq); return }
        var out = kevent()
        _ = kevent(kq, nil, 0, &out, 1, nil)
        close(kq)
    }
}
