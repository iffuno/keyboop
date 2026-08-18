import Foundation
import AVFoundation
#if arch(arm64) && !KEYBOOP_NO_PARAKEET
import FluidAudio

/// ЭКСПЕРИМЕНТАЛЬНО: потоковая диктовка (Parakeet EOU streaming · FluidAudio · CoreML · ANE).
/// Текст печатается ПО МЕРЕ речи, не дожидаясь конца фразы. Это ОТДЕЛЬНАЯ модель (~120 МБ),
/// качается ЯВНО при включении тумблера (принцип №2: в рантайме сеть запрещена `enforceOffline`).
/// API сверен по исходникам FluidAudio: StreamingEouAsrManager.swift (loadModels/appendAudio/
/// processBufferedAudio/finish/reset, partial-callback = ПОЛНЫЙ текущий транскрипт), ModelNames.swift.
final class StreamingEouEngine {
    static let shared = StreamingEouEngine()
    private var manager: StreamingEouAsrManager?
    private(set) var ready = false

    /// Свой корень кэша под Keyboop (чтобы не мешать batch-parakeet v3).
    static var modelRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/eou-streaming", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    /// Каталог конкретной модели (160 мс — минимальная задержка).
    ///
    /// ⚠️ ПУТЬ БЕРЁМ У БИБЛИОТЕКИ, А НЕ ПИШЕМ РУКАМИ (13.08.2026). Здесь был литерал
    /// «parakeet-realtime-eou-120m-coreml/160ms», и это ИМЯ РЕПОЗИТОРИЯ на HuggingFace
    /// (`ModelNames.swift:22`), а кладёт файлы `loadModels(to:)` в `repo.folderName`, то есть в
    /// «parakeet-eou-streaming/160ms» (`ModelNames.swift:223`). Два разных имени у одной модели.
    /// Из-за этого `modelInstalled` смотрел в несуществующий каталог и всегда возвращал false:
    /// модель была скачана 29.07, лежала на диске, а потоковый путь молча откатывался на батч.
    /// Ни одна проверка этого не поймала, потому что откат тихий и выглядит как обычная диктовка.
    /// `Repo` публичный, так что спрашиваем имя у того, кто его и назначает.
    static var modelDir: URL {
        modelRoot.appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
    }

    /// Установлена ли модель: все файлы, которые читает loadModels(from:) (StreamingEouAsrManager.swift:288-299).
    static var modelInstalled: Bool {
        let d = modelDir
        let files = [ModelNames.ParakeetEOU.encoderFile, ModelNames.ParakeetEOU.decoderFile,
                     ModelNames.ParakeetEOU.jointFile, ModelNames.ParakeetEOU.vocab]
        return files.allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) }
    }

    /// Жёстко включить рантайм-офлайн (принцип №2). Зовём на старте: по умолчанию флаг false, и без
    /// этого фоновая загрузка модели теоретически могла бы пойти в сеть. Сеть разрешаем ТОЛЬКО внутри download().
    static func enforceRuntimeOffline() { DownloadUtils.enforceOffline = true }

    // MARK: - Загрузка / скачивание

    /// Офлайн-загрузка из кэша. Идемпотентно. false — если модели нет / не загрузилась.
    func loadIfNeeded() async -> Bool {
        if ready { return true }
        guard Self.modelInstalled else { kbLog("eou: модель не установлена"); return false }
        do {
            DownloadUtils.enforceOffline = true                 // рантайм — ноль сети (принцип №2)
            // Конфигурацию берём библиотечную: она ставит cpuAndNeuralEngine и подсказки резидентности
            // ANE. Голый MLModelConfiguration() означает computeUnits = .all, то есть единственную
            // нашу модель, которой разрешено уехать на GPU и подраться там с чужой отрисовкой.
            let mgr = manager ?? StreamingEouAsrManager(configuration: MLModelConfigurationUtils.defaultConfiguration(),
                                                       chunkSize: .ms160)
            try await mgr.loadModels(from: Self.modelDir)
            manager = mgr; ready = true
            kbLog("eou: модель загружена (офлайн)")
            return true
        } catch { kbLog("eou: загрузка не удалась: \(error)"); return false }
    }

    /// Скачать модель — ЯВНОЕ действие пользователя (тумблер). progress 0…1.
    ///
    /// Размер: 216 МБ нужных файлов, 429 МБ в каталоге после загрузки (качается и .mlpackage рядом
    /// с .mlmodelc). Замерено 13.08.2026 на скачанной копии; прежние «~120 МБ» в комментарии и в
    /// диалоге были втрое меньше правды.
    func download(progress: @escaping (Double) -> Void) async -> Bool {
        do {
            DownloadUtils.enforceOffline = false                // на время скачивания сеть нужна
            let mgr = StreamingEouAsrManager(configuration: MLModelConfigurationUtils.defaultConfiguration(),
                                             chunkSize: .ms160)
            try await mgr.loadModels(to: Self.modelRoot,
                                     configuration: MLModelConfigurationUtils.defaultConfiguration(),
                                     progressHandler: { p in progress(p.fractionCompleted) })
            DownloadUtils.enforceOffline = true
            // ⚠️ СВЕРЯЕМ С ДИСКОМ, А НЕ ВЕРИМ СЕБЕ. Раньше здесь просто ставили ready = true, и
            // расхождение путей (см. modelDir) прошло мимо всех проверок: скачивание отчитывалось
            // об успехе, а следующий запуск не находил файлов и тихо откатывался на батч.
            guard Self.modelInstalled else {
                kbLog("eou: скачивание отчиталось об успехе, но файлов по \(Self.modelDir.path) нет")
                return false
            }
            manager = mgr; ready = true
            kbLog("eou: модель скачана и загружена")
            return true
        } catch {
            DownloadUtils.enforceOffline = true
            kbLog("eou: скачивание не удалось: \(error)")
            return false
        }
    }

    // MARK: - Потоковая сессия

    /// Начать новую сессию диктовки. reset() чистит токены/состояние, модель остаётся загруженной.
    /// onPartial получает ПОЛНЫЙ текущий транскрипт (не дельту) — вызывающий сам диффит.
    func startSession(onPartial: @escaping @Sendable (String) -> Void) async {
        guard let mgr = manager else { return }
        await mgr.reset()
        await mgr.setPartialTranscriptCallback(onPartial)
    }

    /// Скормить очередной 16кГц-mono-чанк. Внутри буферизуется и обрабатывается полными окнами.
    func feed(_ samples: [Float]) async {
        guard let mgr = manager, let buf = Self.buffer16k(samples) else { return }
        _ = try? await mgr.process(audioBuffer: buf)
    }

    /// Завершить речь: дослать остаток, вернуть ФИНАЛЬНЫЙ полный транскрипт.
    func finishSession() async -> String {
        guard let mgr = manager else { return "" }
        return (try? await mgr.finish()) ?? ""
    }

    /// Отмена сессии — просто сбрасываем состояние (ничего не коммитим).
    func cancelSession() async {
        await manager?.reset()
    }

    // MARK: - Утилиты

    private static let fmt16k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 16_000, channels: 1, interleaved: false)!
    /// [Float] 16кГц mono → AVAudioPCMBuffer (формат, который ждёт streamAudio/appendAudio).
    private static func buffer16k(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt16k, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }
}

#else
/// Intel-заглушка (см. комментарий в ParakeetEngine): стриминговая диктовка — это Parakeet-EOU
/// на Neural Engine, в x86-срезе недоступна. modelInstalled=false гасит useStreaming, и диктовка
/// идёт обычным батч-путём через whisper.
final class StreamingEouEngine {
    static let shared = StreamingEouEngine()
    private(set) var ready = false
    static var modelInstalled: Bool { false }
    static func enforceRuntimeOffline() {}
    func loadIfNeeded() async -> Bool { false }
    func download(progress: @escaping (Double) -> Void) async -> Bool {
        kbLog("eou: недоступен на Intel (нет Neural Engine)"); return false
    }
    func startSession(onPartial: @escaping @Sendable (String) -> Void) async {}
    func feed(_ samples: [Float]) async {}
    func finishSession() async -> String { "" }
    func cancelSession() async {}
}
#endif
