import Foundation

/// Скачивание моделей whisper (ggml-*.bin). Сеть — ТОЛЬКО по явному действию пользователя
/// (кнопка «Скачать»), с честной подписью (принцип №2). Фоном ничего не качается.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    struct Model { let name: String; let size: String; let note: String }
    static let catalog: [Model] = [
        Model(name: "base",            size: "142 МБ", note: "быстрая, базовая точность"),
        Model(name: "small",           size: "466 МБ", note: "баланс качества и скорости"),
        Model(name: "medium",          size: "1.5 ГБ", note: "выше точность, медленнее"),
        Model(name: "large-v3-turbo",  size: "1.6 ГБ", note: "максимум качества RU")
    ]

    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Bool) -> Void)?
    private var targetName = ""

    var downloadingName: String? { task != nil ? targetName : nil }

    func isInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: VoiceController.modelPath(name))
    }

    func download(_ name: String, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard task == nil,
              let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")
        else { done(false); return }
        targetName = name
        onProgress = progress
        onDone = done
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil }

    /// Удалить скачанную whisper-модель (освободить место). Файл — `ggml-<name>.bin` в models-папке.
    @discardableResult
    func delete(_ name: String) -> Bool {
        let path = VoiceController.modelPath(name)
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            kbLog("model deleted: \(name)")
            return true
        } catch {
            kbLog("model delete error \(name): \(error)")
            return false
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = URL(fileURLWithPath: VoiceController.modelPath(targetName))
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        task = nil
        DispatchQueue.main.async { self.onDone?(ok) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            kbLog("model download error: \(error)")
            self.task = nil
            DispatchQueue.main.async { self.onDone?(false) }
        }
    }
}
