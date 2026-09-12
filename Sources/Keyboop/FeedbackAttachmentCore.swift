import Foundation

/// Вложение к отзыву (задача 191, 05.09.2026): что принимаем и как везём. Чистая часть без AppKit,
/// проверяется стендом `stands/run-feedbackattach.sh`.
///
/// Протокол в два шага, зеркало серверного (`site-admin/server.py` + `feedback_attachment.py`):
///   1. обычный JSON в /api/feedback получает поле `attachment: {type, size}`; сервер кладёт текст
///      в базу и отвечает `upload.token`;
///   2. сырой файл уходит в /api/feedback/attachment с токеном в заголовке `X-Keyboop-Upload`.
/// Разделено намеренно: если файл не дойдёт, текст уже у автора, и человек не переписывает отзыв.
/// На сервере файл живёт секунды: временный файл → Telegram владельца → удаление. Хранилища нет,
/// и подпись под кнопкой говорит это прямо (принцип №2: человек видит, что и куда уходит).
enum FeedbackAttachmentPolicy {
    static let imageMaxBytes = 10 * 1024 * 1024
    static let videoMaxBytes = 25 * 1024 * 1024
    static let endpoint = URL(string: "https://keyboop.com/api/feedback")!
    static let uploadEndpoint = URL(string: "https://keyboop.com/api/feedback/attachment")!

    /// Тип по расширению. Сигнатуру файла сверяет сервер; здесь отсеиваем заранее, чтобы не гонять
    /// мегабайты, которые всё равно отклонят.
    static func contentType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return nil
        }
    }

    static func isImage(_ type: String) -> Bool { type.hasPrefix("image/") }
    static func limit(for type: String) -> Int { isImage(type) ? imageMaxBytes : videoMaxBytes }

    enum Verdict: Equatable { case ok(type: String), unsupported, empty, tooLarge(limit: Int) }

    static func verdict(fileExtension: String, size: Int) -> Verdict {
        guard let type = contentType(forExtension: fileExtension) else { return .unsupported }
        guard size > 0 else { return .empty }
        let cap = limit(for: type)
        return size > cap ? .tooLarge(limit: cap) : .ok(type: type)
    }

    /// «1.2 МБ» / «340 КБ». Единицы подставляет вызывающий: локализация живёт в L10n, а не здесь.
    static func humanSize(_ bytes: Int, mb: String = "МБ", kb: String = "КБ") -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f %@", Double(bytes) / 1_048_576, mb) }
        return "\(max(1, bytes / 1024)) \(kb)"
    }

    /// Поле `attachment` для JSON первого шага.
    static func declaration(type: String, size: Int) -> [String: Any] { ["type": type, "size": size] }

    /// Токен второго шага из ответа сервера; nil — сервер файла не ждёт (старый сервер или отказ).
    static func uploadToken(fromResponse data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let up = obj["upload"] as? [String: Any],
              let token = up["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// Запрос второго шага: тело — сам файл, тип и токен в заголовках. Content-Length URLSession
    /// ставит по файлу сам, а сервер сверяет его с заявленным размером байт в байт.
    static func uploadRequest(token: String, type: String, url: URL = uploadEndpoint) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Keyboop-Upload")
        req.timeoutInterval = 120
        return req
    }
}
