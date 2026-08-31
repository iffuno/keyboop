import Foundation

/// ПОЧЕМУ ПРИЛОЖЕНИЯ НЕ СТАЛО — безопасная выжимка из системного отчёта о падении (задача 135).
///
/// # Зачем
///
/// Самый частый непонятный класс отзывов звучит как «оно просто не запущено». Разбирать его сегодня
/// приходится по ТИШИНЕ в логе: в отзыве #131 причину пришлось выводить из того, что между двумя
/// строчками восемьдесят минут пустоты. Своей записи «меня не стало вот почему» у нас нет вовсе.
///
/// macOS такую запись делает сама и кладёт в `~/Library/Logs/DiagnosticReports/Keyboop-*.ips`. Мы
/// её читаем и переписываем к себе в лог — коротко и без единой личной подробности, потому что наш
/// лог человек отправляет нам вместе с отзывом.
///
/// # Что берём и, главное, чего НЕ берём (принцип №2)
///
/// Берём: тип исключения, сигнал, причину завершения, версию и верхушку стека упавшего потока в
/// виде «модуль · символ · смещение».
///
/// ⚠️ НЕ берём НИ ОДНОГО ПУТИ. В `usedImages[].path` лежит `/Users/<имя>/…`, то есть имя человека,
/// а иногда и название его организации. Поэтому пути не фильтруются «по возможности», а не читаются
/// в принципе: используется только `name`. Сверх этого готовая строка ещё раз прочёсывается на
/// случай, если путь просочился внутрь символа или причины завершения: домашний каталог заменяется
/// на `~`, а всё, что похоже на `/Users/кто-то`, обрезается.
///
/// Не берём тем более: ничего про набранный текст, речь, буфер обмена и открытые программы. В
/// отчёте этого и нет, но правило записано, чтобы следующий соблазн «а давайте ещё вот это поле»
/// упирался в него.
enum CrashNote {
    struct Note {
        let when: Date
        let summary: String
    }

    private static var reportsDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    /// Отчёты о нашем падении, изменённые позже `after`, самый свежий первым.
    static func reports(after: Date) -> [(url: URL, when: Date)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: reportsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> (URL, Date)? in
            let n = url.lastPathComponent
            // Имя процесса у нас одно и то же в обеих сборках — «Keyboop».
            guard n.hasPrefix("Keyboop"), n.hasSuffix(".ips") else { return nil }
            guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  d > after else { return nil }
            return (url, d)
        }
        .sorted { $0.1 > $1.1 }
        .map { (url: $0.0, when: $0.1) }
    }

    /// Exact process identity for the crash-surviving guard. macOS has used both the JSON header
    /// and body for `pid` across .ips revisions, so accept either but never infer it from a filename.
    static func processID(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let newline = text.firstIndex(of: "\n") else { return nil }
        let header = parse(String(text[..<newline]))
        let body = parse(String(text[text.index(after: newline)...]))
        for object in [header, body] {
            if let number = object?["pid"] as? NSNumber { return pid_t(number.int32Value) }
            if let value = object?["pid"] as? Int { return pid_t(value) }
        }
        return nil
    }

    /// Embedded crash timestamp, not the file modification time. DiagnosticReports may be copied,
    /// rescanned or written a few seconds late; only the event's own timestamp can be compared to
    /// the exact watched parent's NOTE_EXIT window.
    static func processDate(_ url: URL) -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let newline = text.firstIndex(of: "\n") else { return nil }
        let objects = [
            parse(String(text[..<newline])),
            parse(String(text[text.index(after: newline)...])),
        ]
        for object in objects {
            for key in ["timestamp", "captureTime"] {
                guard let value = object?[key] as? String else { continue }
                if let date = ISO8601DateFormatter().date(from: value) { return date }
                for format in [
                    "yyyy-MM-dd HH:mm:ss.SSSSSS Z",
                    "yyyy-MM-dd HH:mm:ss.SSS Z",
                    "yyyy-MM-dd HH:mm:ss.SS Z",
                    "yyyy-MM-dd HH:mm:ss.S Z",
                    "yyyy-MM-dd HH:mm:ss Z",
                ] {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = format
                    if let date = formatter.date(from: value) { return date }
                }
            }
        }
        return nil
    }

    /// Разобрать один отчёт в короткую безопасную строку. nil, если это не разбираемый отчёт.
    ///
    /// Формат `.ips`: первая строка это JSON-заголовок, дальше отдельным JSON тело. Разбираем оба и
    /// берём ровно шесть полей.
    static func summarize(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let nl = text.firstIndex(of: "\n") else { return nil }
        let head = parse(String(text[..<nl]))
        let body = parse(String(text[text.index(after: nl)...]))
        guard head != nil || body != nil else { return nil }

        var parts: [String] = []
        if let v = head?["app_version"] as? String { parts.append("версия \(v)") }
        if let kind = head?["bug_type"] as? String { parts.append("тип \(kind)") }
        if let exc = body?["exception"] as? [String: Any] {
            var e = (exc["type"] as? String) ?? "?"
            if let sig = exc["signal"] as? String { e += " (\(sig))" }
            if let sub = exc["subtype"] as? String { e += " · \(sub)" }
            parts.append(e)
        }
        if let term = body?["termination"] as? [String: Any] {
            let ns = (term["namespace"] as? String) ?? "?"
            let code = (term["code"] as? NSNumber).map { " код \($0)" } ?? ""
            parts.append("завершение \(ns)\(code)")
        }
        var out = "падение: " + (parts.isEmpty ? "подробностей нет" : parts.joined(separator: " · "))

        // Верхушка стека упавшего потока: где именно нас застало.
        if let frames = faultingFrames(body), !frames.isEmpty {
            out += "\n" + frames.map { "    " + $0 }.joined(separator: "\n")
        }
        return scrub(out)
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// До двенадцати верхних кадров упавшего потока, «модуль · символ + смещение».
    ///
    /// ⚠️ Модуль берём из `usedImages[].name`, и это единственное поле оттуда, к которому мы
    /// прикасаемся: соседнее `path` содержит домашний каталог человека.
    private static func faultingFrames(_ body: [String: Any]?) -> [String]? {
        guard let body,
              let threads = body["threads"] as? [[String: Any]] else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let idx = (body["faultingThread"] as? Int) ?? 0
        guard idx >= 0, idx < threads.count,
              let frames = threads[idx]["frames"] as? [[String: Any]] else { return nil }
        return frames.prefix(12).map { f in
            let imgIdx = (f["imageIndex"] as? Int) ?? -1
            let module = (imgIdx >= 0 && imgIdx < images.count ? images[imgIdx]["name"] as? String : nil) ?? "?"
            if let sym = f["symbol"] as? String {
                let off = (f["symbolLocation"] as? NSNumber).map { " + \($0)" } ?? ""
                return "\(module) · \(sym)\(off)"
            }
            let off = (f["imageOffset"] as? NSNumber).map { "\($0)" } ?? "?"
            return "\(module) + \(off)"
        }
    }

    /// Последний рубеж против личного в строке. Работает даже если поле, которое мы считали
    /// безопасным, однажды окажется не таким: домашний каталог схлопывается в `~`, а любой другой
    /// `/Users/кто-то/…` обрезается до `/Users/…`.
    static func scrub(_ s: String) -> String {
        var out = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        while let r = out.range(of: "/Users/[^/ ]+", options: .regularExpression) {
            out.replaceSubrange(r, with: "/Users/…")
        }
        return out
    }

    // MARK: - Сторона приложения

    /// Ключ-отметка «до какого момента отчёты уже прочитаны». Живёт не в `AppSettings`, потому что
    /// это не выбор человека, а служебная закладка, и в окне настроек ей делать нечего.
    private static let markKey = "lastCrashScanAt"

    /// Отметить, что отчёты по этот момент уже разобраны.
    ///
    /// Нужно сторожу: он читает отчёт первым и пишет о нём подробнее («выход был аварийным»), а
    /// поднятое им приложение через секунду прочитало бы тот же отчёт и написало о нём второй раз.
    /// Домен настроек у сторожа и у приложения общий, поэтому отметка одна на двоих.
    static func markScanned() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: markKey)
    }

    /// Посмотреть на старте, не падали ли мы, и записать это в свой лог.
    ///
    /// Достаётся ВСЕМ и не требует второго процесса — в отличие от перезапуска, который умеет только
    /// сторож. Поэтому это первая половина задачи 135 и делается независимо от того, включён ли
    /// захват 🌐.
    static func scanAtLaunch() {
        let d = UserDefaults.standard
        let markRaw = d.double(forKey: markKey)
        // Первый запуск после установки: не вываливаем в лог всю историю падений за год, а просто
        // ставим отметку. Иначе первое же обращение в поддержку приедет с чужой археологией.
        guard markRaw > 0 else { d.set(Date().timeIntervalSince1970, forKey: markKey); return }
        let mark = Date(timeIntervalSince1970: markRaw)
        let fresh = reports(after: mark)
        guard !fresh.isEmpty else { return }
        d.set(Date().timeIntervalSince1970, forKey: markKey)
        // Три штуки хватит: если падений больше, важна не полнота списка, а сам факт и последний.
        for r in fresh.prefix(3) {
            guard let s = summarize(r.url) else { continue }
            kbLog("с прошлого запуска macOS записала отчёт о падении — \(s)")
        }
        if fresh.count > 3 { kbLog("…и ещё \(fresh.count - 3) отчёт(ов) о падении, в лог не пишу") }
    }
}
