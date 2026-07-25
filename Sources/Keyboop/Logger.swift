import Foundation
import AppKit   // NSRunningApplication — детект второй параллельной сборки (см. kbLogPathOnce)

/// Простой файловый лог в ~/Library/Logs/Keyboop.log (права 0600). NSLog НЕ зовём в release: он
/// дублирует строку в системный unified log / sysdiagnose в обход прав на файл, и пользователь невольно
/// слил бы фрагменты лога в поддержку/Apple (security review 15.06). В dev (-DDEBUG) — оставляем для
/// Console. Сам контент (набранные слова, перевод) в лог НЕ пишем нигде — только длины/направления/счётчики.
///
/// РОТАЦИЯ (05.07.2026, просьба автора — лог не должен раздувать диск за месяцы использования): держим
/// файл в пределах ~1 МБ. При превышении оставляем ПОСЛЕДНИЕ ~512 КБ (свежие строки — они и нужны для
/// диагностики), старые удаляем. Хвост читаем через seek, поэтому даже уже раздувшийся до сотен МБ лог
/// НЕ грузится в память целиком. Запись — в serial-очереди: (1) чинит гонку (kbLog зовут и main, и фоновые
/// очереди — whisper/parakeet/удаление модели), (2) убирает синхронный диск-I/O с горячего пути обработки
/// событий (детектор логировал прямо в CGEventTap-колбэке). Таймстамп берём в момент вызова (до dispatch),
/// поэтому порядок и время строк точны.
private let kbLogQueue = DispatchQueue(label: "ru.keyboop.log")
private let kbLogMaxBytes = 1_048_576          // 1 МБ — потолок; ~10–16 тыс. строк
private let kbLogKeepBytes = 524_288           // при обрезке оставляем последние 512 КБ
private let kbLogCheckEvery = 128              // размер проверяем раз в N записей (не stat на каждый вызов)
// Стартуем с порога, чтобы ПЕРВАЯ запись сразу проверила размер (подчистит уже раздутый лог). НЕ Int.max:
// `+= 1` на Int.max → переполнение и краш (SIGTRAP).
private var kbLogWritesSinceCheck = kbLogCheckEvery

/// Путь лога. DEV-сборка (`ru.keyboop.app.dev`) пишет в ОТДЕЛЬНЫЙ файл `Keyboop-dev.log`.
///
/// Зачем (инцидент 21.07): dev и боевая сборки имеют РАЗНЫЕ bundle id (это сделано намеренно, чтобы
/// dev не отбирал TCC у боевой) — значит single-instance их не считает одним приложением, и они
/// спокойно работают ОДНОВРЕМЕННО. Обе писали в один `Keyboop.log`, и диагностика шла по СМЕСИ двух
/// процессов: чужие тайминги, дублирующиеся события, «launched» от одной сборки посреди работы другой.
/// Хуже того, параллельная работа сама порождает баги (обе слышат хоткей → обе открывают микрофон →
/// одна получает звук, вторая побитовые нули). Разделяем файлы, чтобы лог всегда описывал ОДИН процесс.
let kbLogPath: String = {
    let dev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    let name = dev ? "Keyboop-dev.log" : "Keyboop.log"
    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/\(name)")
}()
/// Одноразовое предупреждение в лог, если рядом крутится вторая сборка Keyboop (см. kbLogPath).
private let kbLogPathOnce: Void = {
    let me = Bundle.main.bundleIdentifier ?? ""
    let other = me.hasSuffix(".dev") ? "ru.keyboop.app" : "ru.keyboop.app.dev"
    if !NSRunningApplication.runningApplications(withBundleIdentifier: other).isEmpty {
        let warn = "[\(Date())] ⚠️ ПАРАЛЛЕЛЬНО РАБОТАЕТ ВТОРАЯ СБОРКА (\(other)) — обе слушают хоткеи и микрофон; диагностика будет врать. Оставь одну.\n"
        if let d = warn.data(using: .utf8) {
            let u = URL(fileURLWithPath: kbLogPath)
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: u, options: .atomic) }
        }
    }
}()

func kbLog(_ message: String) {
    #if DEBUG
    NSLog("Keyboop: \(message)")
    #endif
    _ = kbLogPathOnce
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = kbLogPath
    let url = URL(fileURLWithPath: path)
    kbLogQueue.async {
        // Размер проверяем не на каждый вызов (это stat) — раз в kbLogCheckEvery записей; при превышении режем.
        kbLogWritesSinceCheck += 1
        if kbLogWritesSinceCheck >= kbLogCheckEvery {
            kbLogWritesSinceCheck = 0
            kbLogTrimIfNeeded(path: path, url: url)
        }
        if FileManager.default.fileExists(atPath: path), let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
            // Лог не должен быть world-readable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

/// Если лог перерос потолок — оставить последние ~512 КБ (по границе строки), старое удалить.
/// Читаем ТОЛЬКО хвост через seek(toOffset:), не загружая весь файл (он мог раздуться до сотен МБ).
private func kbLogTrimIfNeeded(path: String, url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.intValue, size > kbLogMaxBytes else { return }
    guard let rh = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? rh.close() }
    let start = UInt64(max(0, size - kbLogKeepBytes))
    do { try rh.seek(toOffset: start) } catch { return }
    guard var tail = try? rh.readToEnd() else { return }   // читаем только последние ~512 КБ
    // Выровнять по НАЧАЛУ строки: отрезать возможный обрезок первой строки (до первого '\n').
    if start > 0, let nl = tail.firstIndex(of: 0x0A) {
        tail = tail.subdata(in: tail.index(after: nl)..<tail.endIndex)
    }
    var out = Data("[\(Date())] — лог обрезан: оставлены последние ~\(kbLogKeepBytes / 1024) КБ, старые строки удалены —\n".utf8)
    out.append(tail)
    // Атомарная замена + возвращаем права 0600 (atomic-запись может создать файл с дефолтными правами).
    guard (try? out.write(to: url, options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
