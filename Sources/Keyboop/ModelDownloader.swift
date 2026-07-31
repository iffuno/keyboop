import Foundation
import CryptoKit

/// Скачивание моделей whisper (ggml-*.bin). Сеть — ТОЛЬКО по явному действию пользователя
/// (кнопка «Скачать»), с честной подписью (принцип №2). Фоном ничего не качается.
///
/// ЦЕЛОСТНОСТЬ (security-аудит M3, 01.07): раньше качали с мутабельного `resolve/main/…` без проверки —
/// подменённая на HF (или через MITM с доверенным CA) модель попадала бы в парсер CoreML/whisper в
/// непесочном процессе. Теперь: (1) URL пиннится на НЕИЗМЕНЯЕМЫЙ commit-revision (контент HF адресуется
/// коммитом → байты фиксированы); (2) после скачивания СВЕРЯЕМ SHA-256 файла с зашитым ожидаемым —
/// несовпадение = отказ, файл не устанавливается.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    /// Неизменяемый commit репозитория ggerganov/whisper.cpp, на который пиннятся все модели (01.07.2026).
    private static let pinnedRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    // size — в EN-единицах (MB/GB); локализуется на показе через L10n.size(). note — КЛЮЧ L10n,
    // резолвится через L10n.t() в SettingsWindow.unifiedModels (каталог статичен, язык — на показе).
    // sha256 — ожидаемый хеш файла модели на pinnedRevision (сверяется после скачивания).
    struct Model { let name: String; let size: String; let note: String; let sha256: String }
    static let catalog: [Model] = [
        Model(name: "base",           size: "142 MB", note: "model.base.note",
              sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        Model(name: "small",          size: "466 MB", note: "model.small.note",
              sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        Model(name: "medium",         size: "1.5 GB", note: "model.medium.note",
              sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        Model(name: "large-v3-turbo", size: "1.6 GB", note: "model.large.note",
              sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    ]

    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Bool) -> Void)?
    private var targetName = ""
    private var usingMirror = false     // текущая попытка идёт с зеркала (иначе — HF-фолбэк)

    var downloadingName: String? { task != nil ? targetName : nil }

    /// Зеркало моделей на keyboop.com (сервер в Москве). Источник №1: HuggingFace из РФ капризен и
    /// «застревает на N%» (репорты пользователей + тест Nemotron, 23.07.2026). Файлы на зеркале —
    /// байт-в-байт с pinnedRevision, поэтому SHA-256 тот же и сверяется одинаково для обоих источников.
    private static func mirrorURL(_ name: String) -> URL? {
        URL(string: "https://keyboop.com/models/whisper/ggml-\(name).bin")
    }
    private static func hfURL(_ name: String) -> URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(pinnedRevision)/ggml-\(name).bin")
    }

    func isInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: VoiceController.modelPath(name))
    }

    func download(_ name: String, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard task == nil else { done(false); return }
        targetName = name
        onProgress = progress
        onDone = done
        start(name, mirror: true)   // сначала зеркало; при неудаче — HF (см. фолбэк в делегатах)
    }

    /// Запустить загрузку с зеркала (mirror=true) или с HuggingFace (mirror=false).
    private func start(_ name: String, mirror: Bool) {
        guard let url = mirror ? Self.mirrorURL(name) : Self.hfURL(name) else {
            DispatchQueue.main.async { self.onDone?(false) }; return
        }
        usingMirror = mirror
        kbLog("model \(name): загрузка с \(mirror ? "зеркала keyboop.com" : "HuggingFace")")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
    }

    /// Провалилась попытка (сеть/404/хеш). С зеркала → молча пробуем HF. С HF → отдаём неудачу.
    private func failOrFallback(_ reason: String) {
        task = nil
        if usingMirror {
            kbLog("model \(targetName): зеркало не отдало (\(reason)) — пробую HuggingFace")
            start(targetName, mirror: false)
        } else {
            kbLog("model \(targetName): не скачалось (\(reason))")
            DispatchQueue.main.async { self.onDone?(false) }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    /// Удалить скачанную whisper-модель (освободить место). Файл — `ggml-<name>.bin` в models-папке.
    /// removeItem уводим в ФОН (единообразно с Parakeet: файл крупный, main-поток не морозим —
    /// см. deleteModel в ParakeetEngine, репорт 03.07.2026). completion — обратно на main.
    func delete(_ name: String, completion: @escaping (Bool) -> Void) {
        let path = VoiceController.modelPath(name)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if FileManager.default.fileExists(atPath: path) {
                do { try FileManager.default.removeItem(atPath: path); kbLog("model deleted: \(name)") }
                catch { ok = false; kbLog("model delete error \(name): \(error)") }
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let name = targetName
        // ЦЕЛОСТНОСТЬ: сверяем SHA-256 скачанного с ожидаемым для этой модели. Несовпадение → НЕ ставим.
        if let expected = Self.catalog.first(where: { $0.name == name })?.sha256,
           let actual = Self.sha256(ofFileAt: location), actual != expected {
            kbLog("model integrity FAIL \(name): hash mismatch — файл отклонён")   // сами хеши не логируем
            try? FileManager.default.removeItem(at: location)
            failOrFallback("хеш не сошёлся")   // битый файл на зеркале → добираем с HF
            return
        }
        let dest = URL(fileURLWithPath: VoiceController.modelPath(name))
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        // Успех тоже логируем (раньше писались только ошибки) — чтобы в отчётах юзеров был полный
        // след «скачал→удалил» (диагностика репортов про модели, 16.07). Без контента — только имя.
        kbLog(ok ? "model downloaded+verified: \(name)" : "model install error \(name): move failed")
        task = nil
        DispatchQueue.main.async { self.onDone?(ok) }
    }

    /// Потоковый SHA-256 файла (по 1 МБ, не грузим гигабайтную модель в память целиком).
    /// Не private: этим же примитивом проверяет свой tar.gz зеркало Parakeet (ParakeetEngine).
    /// Один источник на оба потребителя — дублировать хеширование в проекте, где целостность
    /// загрузок это вопрос безопасности, нельзя.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fh.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            failOrFallback("\(error.localizedDescription)")   // сеть/таймаут/404 → зеркало? тогда HF
        }
    }
}
