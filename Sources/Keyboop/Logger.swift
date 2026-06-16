import Foundation

/// Простой файловый лог в ~/Library/Logs/Keyboop.log (права 0600). NSLog НЕ зовём в release: он
/// дублирует строку в системный unified log / sysdiagnose в обход прав на файл, и пользователь невольно
/// слил бы фрагменты лога в поддержку/Apple (security review 15.06). В dev (-DDEBUG) — оставляем для
/// Console. Сам контент (набранные слова, перевод) в лог НЕ пишем нигде — только длины/направления/счётчики.
func kbLog(_ message: String) {
    #if DEBUG
    NSLog("Keyboop: \(message)")
    #endif
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Keyboop.log")
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: path), let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: url)
        // Лог не должен быть world-readable (см. docs/SECURITY.md).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
