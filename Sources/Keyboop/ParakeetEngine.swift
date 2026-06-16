import Foundation
import FluidAudio

/// Распознавание речи через Parakeet (FluidAudio · CoreML · Apple Neural Engine).
/// Офлайн по принципу №2: модель грузится из локальной папки, сеть в рантайме запрещена
/// (`DownloadUtils.enforceOffline`). Скачивание модели — только по явной кнопке пользователя.
/// Требует macOS 14+. API сверен по исходникам FluidAudio (docs/PARAKEET_BUILD.md).
final class ParakeetEngine {
    static let shared = ParakeetEngine()
    private var manager: AsrManager?
    private var decoderLayers = 0
    private(set) var ready = false

    /// Папка с моделью v3 (кэш FluidAudio: .mlmodelc-бандлы + parakeet_vocab.json).
    static var modelDir: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    /// Модель уже скачана?
    static var modelInstalled: Bool { AsrModels.modelsExist(at: modelDir) }

    /// Загрузить модель из локальной папки (офлайн). Идемпотентно.
    func loadIfNeeded() async -> Bool {
        if ready { return true }
        guard Self.modelInstalled else { kbLog("parakeet: модель не установлена"); return false }
        do {
            DownloadUtils.enforceOffline = true               // в рантайме — ноль сети (принцип №2)
            let models = try await AsrModels.load(from: Self.modelDir, version: .v3)
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            decoderLayers = await mgr.decoderLayerCount
            manager = mgr
            ready = true
            kbLog("parakeet: модель загружена (layers=\(decoderLayers))")
            return true
        } catch {
            kbLog("parakeet: загрузка не удалась: \(error)")
            return false
        }
    }

    /// Транскрибировать 16кГц mono Float32 (наш буфер от AVAudioEngine — как у whisper).
    func transcribe(samples: [Float]) async -> String {
        guard let mgr = manager else { return "" }
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await mgr.transcribe(samples, decoderState: &state)
            return result.text
        } catch {
            kbLog("parakeet: ошибка транскрипции: \(error)")
            return ""
        }
    }

    /// Скачать модель v3 (~465 МБ) — ЯВНОЕ действие пользователя (кнопка в настройках).
    /// На время скачивания временно снимаем офлайн-флаг, потом возвращаем. `progress` — доля 0…1.
    func download(progress: @escaping (Double) -> Void) async -> Bool {
        do {
            DownloadUtils.enforceOffline = false
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { p in
                progress(p.fractionCompleted)
            })
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            decoderLayers = await mgr.decoderLayerCount
            manager = mgr
            ready = true
            DownloadUtils.enforceOffline = true
            kbLog("parakeet: модель скачана и загружена (layers=\(decoderLayers))")
            return true
        } catch {
            DownloadUtils.enforceOffline = true
            kbLog("parakeet: скачивание не удалось: \(error)")
            return false
        }
    }

    /// Удалить скачанную модель (освободить место). Сбрасывает и состояние в памяти, чтобы при
    /// следующей диктовке честно сработал onNeedModel (а не отдавал пустой результат с мёртвым manager).
    @discardableResult
    func deleteModel() -> Bool {
        manager = nil
        ready = false
        decoderLayers = 0
        let dir = Self.modelDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do {
            try FileManager.default.removeItem(at: dir)
            kbLog("parakeet: модель удалена (\(dir.path))")
            return true
        } catch {
            kbLog("parakeet: удаление не удалось: \(error)")
            return false
        }
    }
}
