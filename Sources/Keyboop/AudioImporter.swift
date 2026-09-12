import AVFoundation
import AppKit

extension Notification.Name {
    /// Импорт аудиофайла (задача 229): прогресс, object = `AudioImporter.Progress`.
    static let keyboopAudioImportProgress = Notification.Name("keyboopAudioImportProgress")
    /// Импорт закончился, object = `AudioImporter.Outcome`. Окно истории показывает тост и перечитывает ленту.
    static let keyboopAudioImportFinished = Notification.Name("keyboopAudioImportFinished")
}

/// Импорт аудиофайла в историю (задача 229, 04.09.2026).
///
/// Файл читается `AVAssetReader` уже в формате движка (16 кГц, моно, Float32) небольшими буферами,
/// `AudioChunker` режет поток на куски по тишине, каждый кусок уходит в тот же движок, что и
/// диктовка (`VoiceController.transcribeImported`), текст собирается с абзацами по паузам. Памяти
/// нужно на один кусок, а не на весь файл; прогресс и отмена живут между кусками.
///
/// Клип для карточки кодируется по ходу чтения в тот же AAC 16 кбит/с, что у диктовок: часовая
/// запись это около 7 МБ на диске, и плеер карточки загружает её без заметной паузы. Перекодировать
/// исходник системным пресетом было бы в разы тяжелее и по размеру, и для окна истории.
///
/// ⚠️ Пока идёт импорт, незашифрованный `.m4a` живёт во временной папке системы: AVAudioFile умеет
/// писать AAC только в файл. Он удаляется при любом исходе, включая отмену и ошибку; исходный файл
/// человека и так лежит на его диске открытым. В лог не пишется ни имя файла, ни текст: только
/// длительности и счётчики (принцип №2).
final class AudioImporter {
    static let shared = AudioImporter()

    struct Progress {
        let fileName: String
        let processed: Double   // секунд разобрано
        let total: Double       // секунд в файле
        let remaining: Double?  // оценка остатка, nil в самом начале
    }

    enum Outcome {
        case done(chars: Int)
        case partial(chars: Int)   // отменили, но расшифрованная часть сохранена
        case cancelled             // отменили до первого куска
        case empty                 // речи не нашлось
        case unreadable            // файл не открылся или в нём нет звуковой дорожки
        case engineFailed          // движок отказал или завис
    }

    private let queue = DispatchQueue(label: "ru.keyboop.import", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var cancelRequested = false
    private(set) var lastProgress: Progress?
    /// Сколько ждём один кусок, прежде чем считать движок зависшим. Кусок ≤ 45 с, whisper на CPU
    /// думает над ним секунды; три минуты это уже не «медленно», а «застрял».
    private let chunkTimeout: TimeInterval = 180

    private init() {}

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    /// Запустить импорт. false — импорт уже идёт (один за раз: движок и так общий).
    @discardableResult
    func start(url: URL) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true; cancelRequested = false
        lock.unlock()
        let name = url.lastPathComponent
        lastProgress = Progress(fileName: name, processed: 0, total: 0, remaining: nil)
        queue.async { [weak self] in self?.run(url: url, name: name) }
        return true
    }

    func cancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
        kbLog("импорт: отмена запрошена")
    }

    // MARK: - Конвейер

    private func run(url: URL, name: String) {
        let t0 = Date()
        let asset = AVURLAsset(url: url)
        // Свойства грузим современным async API, а ждём синхронно: конвейер намеренно
        // последовательный, и своя очередь у него именно для этого.
        var tracks: [AVAssetTrack] = []
        var duration = CMTime.zero
        let loaded = DispatchSemaphore(value: 0)
        Task {
            tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            duration = (try? await asset.load(.duration)) ?? .zero
            loaded.signal()
        }
        loaded.wait()
        let totalSeconds = CMTimeGetSeconds(duration)
        guard let track = tracks.first, totalSeconds.isFinite, totalSeconds > 0.5,
              let reader = try? AVAssetReader(asset: asset) else {
            kbLog("импорт: файл не читается (дорожек: \(tracks.count))")
            finish(.unreadable, tmp: nil); return
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(AudioImportPolicy.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // AudioMixOutput, а не TrackOutput: он честно сводит стерео в моно и пересчитывает частоту.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { finish(.unreadable, tmp: nil); return }
        reader.add(output)
        guard reader.startReading() else {
            kbLog("импорт: reader не стартовал (\(reader.error.map { "\($0)" } ?? "?"))")
            finish(.unreadable, tmp: nil); return
        }
        kbLog("импорт: старт, \(ImportProgressFormat.clock(totalSeconds)) аудио, .\(url.pathExtension.lowercased())")

        // Клип пишем по ходу, если человек хранит записи голоса. Иначе файла нет вовсе.
        var tmp: URL? = nil
        var aac: AVAudioFile? = nil
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(AudioImportPolicy.sampleRate), channels: 1, interleaved: false)
        if AppSettings.shared.voiceSaveAudio, let fmt = pcmFormat {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("kb-import-\(UUID().uuidString).m4a")
            if let f = try? AVAudioFile(forWriting: u, settings: VoiceClips.encoderSettings) { aac = f; tmp = u }
            else { kbLog("импорт: клип писать не удалось, продолжаю без него") }
            _ = fmt
        }

        let chunker = AudioChunker()
        var envelope = EnvelopeAccumulator(totalSamples: Int(totalSeconds * Double(AudioImportPolicy.sampleRate)))
        var pieces: [TranscriptAssembler.Piece] = []
        var processed = 0.0
        var engineFailed = false

        func handle(_ chunk: AudioChunk) -> Bool {   // false = остановиться
            if isCancelled { return false }
            guard let raw = transcribe(chunk.samples) else { engineFailed = true; return false }
            let text = VoiceDictionary.shared.apply(WhisperGhosts.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines))
            pieces.append(.init(text: text, gapBefore: chunk.gapBefore))
            processed = chunk.startSeconds + chunk.seconds
            report(name: name, processed: processed, total: totalSeconds, elapsed: Date().timeIntervalSince(t0))
            return true
        }

        var stopped = false
        readLoop: while let sb = output.copyNextSampleBuffer() {
            if isCancelled { stopped = true; break }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var floats = [Float](repeating: 0, count: length / 4)
            let copied = floats.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard copied == noErr else { continue }
            envelope.feed(floats)
            if let file = aac, let fmt = pcmFormat,
               let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(floats.count)),
               let dst = buf.floatChannelData?[0] {
                buf.frameLength = AVAudioFrameCount(floats.count)
                floats.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: floats.count) }
                if (try? file.write(from: buf)) == nil { aac = nil; kbLog("импорт: запись клипа оборвалась, продолжаю без него") }
            }
            for chunk in chunker.feed(floats) {
                if !handle(chunk) { stopped = true; break readLoop }
            }
        }
        if !stopped, reader.status == .failed {
            kbLog("импорт: чтение оборвалось (\(reader.error.map { "\($0)" } ?? "?"))")
        }
        if !stopped, let last = chunker.flush() { _ = handle(last) }
        if stopped { reader.cancelReading() }

        // AVAudioFile дописывает заголовок в deinit: отпускаем объект ДО чтения байтов (тот же
        // урок, что и в VoiceClips.encodeAAC).
        aac = nil

        let text = TranscriptAssembler.join(pieces)
        let cancelled = isCancelled
        if engineFailed && text.isEmpty { finish(.engineFailed, tmp: tmp); return }
        if cancelled && text.isEmpty { finish(.cancelled, tmp: tmp); return }
        if text.isEmpty {
            kbLog("импорт: речи не нашлось (\(pieces.count) кусков)")
            finish(.empty, tmp: tmp); return
        }

        var clip: (id: String, wave: [UInt8])? = nil
        if let u = tmp, let raw = try? Data(contentsOf: u) {
            clip = VoiceClips.saveEncoded(raw, wave: envelope.finish())
        }
        DispatchQueue.main.sync {
            VoiceHistory.shared.addImported(text, fileName: name, audio: clip?.id, wave: clip?.wave)
        }
        let elapsed = Int(Date().timeIntervalSince(t0))
        kbLog("импорт: \(cancelled ? "отменён, сохранена часть" : "готово"), \(text.count) симв., \(pieces.count) кусков, \(ImportProgressFormat.clock(processed)) из \(ImportProgressFormat.clock(totalSeconds)) за \(elapsed)с\(engineFailed ? ", движок отказал на последнем куске" : "")")
        finish(cancelled || engineFailed ? .partial(chars: text.count) : .done(chars: text.count), tmp: tmp)
    }

    /// Расшифровка куска через общий движок, синхронно для конвейера. nil — отказ или таймаут.
    private func transcribe(_ samples: [Float]) -> String? {
        let done = DispatchSemaphore(value: 0)
        var result: String? = nil
        Task {
            result = await VoiceController.shared.transcribeImported(samples)
            done.signal()
        }
        if done.wait(timeout: .now() + chunkTimeout) == .timedOut {
            kbLog("импорт: кусок не расшифрован за \(Int(chunkTimeout))с — останавливаю импорт")
            return nil
        }
        return result
    }

    private func report(name: String, processed: Double, total: Double, elapsed: TimeInterval) {
        let p = Progress(fileName: name, processed: processed, total: total,
                         remaining: ImportProgressFormat.remaining(processed: processed, total: total, elapsed: elapsed))
        lastProgress = p
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .keyboopAudioImportProgress, object: p)
        }
    }

    private func finish(_ outcome: Outcome, tmp: URL?) {
        if let u = tmp { try? FileManager.default.removeItem(at: u) }
        lock.lock(); running = false; lock.unlock()
        lastProgress = nil
        VoiceController.shared.importFinished()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .keyboopAudioImportFinished, object: outcome)
        }
    }
}
