import Foundation

/// Разовая загрузка файла по URL в заданное место с колбэком прогресса, обёрнутая в async.
/// Нужна для зеркала Parakeet (tar.gz с keyboop.com): URLSession.download(for:) прогресса не даёт,
/// а гонять 445 МБ через async-bytes по байту — не вариант. Делегат отдаёт прогресс, continuation —
/// результат. Ничего не кэширует, сеть только по этому вызову (принцип №2: явное действие юзера).
final class TarballDownloader: NSObject, URLSessionDownloadDelegate {
    private var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<Bool, Never>?
    private let dest: URL
    private var session: URLSession?

    private init(dest: URL) { self.dest = dest }

    /// true — файл скачан и лежит в `to`. false — любая сетевая ошибка (вызывающий уйдёт на фолбэк).
    static func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async -> Bool {
        let dl = TarballDownloader(dest: dest)
        dl.onProgress = progress
        return await withCheckedContinuation { cont in
            dl.continuation = cont
            let s = URLSession(configuration: .default, delegate: dl, delegateQueue: nil)
            dl.session = s
            s.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        finish(ok)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            kbLog("tarball download error: \(error.localizedDescription)")
            finish(false)
        }
    }

    private func finish(_ ok: Bool) {
        session?.invalidateAndCancel(); session = nil
        continuation?.resume(returning: ok)
        continuation = nil
    }
}
