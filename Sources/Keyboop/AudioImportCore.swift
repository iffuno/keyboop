import Foundation

// ИМПОРТ АУДИОФАЙЛА В ИСТОРИЮ (задача 229, 04.09.2026).
//
// Здесь всё, что можно проверить без AVFoundation и без движка: как длинная запись режется на
// куски для распознавания, как куски склеиваются обратно в текст с абзацами, как считается
// огибающая волны без хранения всех сэмплов и как показывать прогресс. Файл компилируется стендом
// `stands/run-audioimport.sh`. Чтение файла, движок и окно живут в `AudioImporter.swift`.
//
// # Почему режем сами, а не отдаём файл движку целиком
//
// автор записывает рабочие звонки на час двадцать. Файл такой длины это 77 миллионов сэмплов,
// 300 МБ в памяти одним массивом, и ни whisper.cpp, ни FluidAudio не расскажут, где они сейчас,
// пока не закончат. Кусками по 20–45 секунд память остаётся маленькой, прогресс честный, отмена
// работает между кусками, а движок получает окна той же длины, что и обычная диктовка.
//
// Режем в тишине, а не по секундомеру: граница посреди слова стоила бы искажённого слова на каждом
// стыке. Тишина ищется по RMS 20-миллисекундных кадров; если её долго нет (человек говорит без
// пауз), режем в самом тихом кадре последних секунд. Паузы длиннее полутора секунд становятся
// абзацами: расшифровка часового разговора без абзацев нечитаема.

/// Пороги резки и сборки. Числа подобраны под речь и звонки, а не под музыку.
enum AudioImportPolicy {
    static let sampleRate = 16_000
    /// Окно RMS: 20 мс, как у самого whisper.
    static let frameSeconds = 0.02
    /// Раньше этого куска не режем даже в тишине: слишком короткие окна хуже распознаются.
    static let minChunkSeconds = 20.0
    /// Не позже этого режем принудительно, в самом тихом месте хвоста.
    static let maxChunkSeconds = 45.0
    /// При принудительном резе самое тихое место ищем в последних секундах куска.
    static let hardCutLookbackSeconds = 6.0
    /// Тише этого кадр считается тишиной (шкала сэмплов −1…1). Диктовка считает «нет сигнала»
    /// от 0.001; комнатный шум записи звонка обычно 0.002–0.005.
    static let silenceRMS: Float = 0.006
    /// Столько тишины подряд — граница фразы, в ней можно резать.
    static let silenceMinSeconds = 0.35
    /// Пауза длиннее — новый абзац в тексте.
    static let paragraphGapSeconds = 1.6
    /// Количество корзин огибающей: столько же, сколько у клипов диктовки.
    static let envelopeBuckets = 64

    static var frameSamples: Int { Int(Double(sampleRate) * frameSeconds) }
}

/// Кусок записи, готовый для движка.
struct AudioChunk: Equatable {
    let samples: [Float]
    /// Где кусок начинается в исходном файле (секунды), для прогресса и отладки.
    let startSeconds: Double
    /// Сколько тишины было ПЕРЕД куском: по ней сборщик решает, абзац это или та же фраза.
    let gapBefore: Double
    var seconds: Double { Double(samples.count) / Double(AudioImportPolicy.sampleRate) }
}

/// Резка потока сэмплов на куски. Кормить `feed`, в конце обязательно `flush`.
final class AudioChunker {
    private typealias P = AudioImportPolicy
    private let frame = P.frameSamples
    private var pending: [Float] = []          // неполный кадр между вызовами feed
    private var buffer: [Float] = []           // текущий кусок (только с момента первой речи)
    private var frameRMS: [Float] = []         // RMS кадров текущего куска, по одному на кадр
    private var speechSeen = false
    private var silenceRun = 0                 // подряд тихих кадров в конце буфера
    private var gapFrames = 0                  // тихих кадров, отрезанных перед текущим куском
    private var consumed = 0                   // сколько сэмплов принято всего
    private var chunkStart = 0                 // индекс сэмпла, с которого начался буфер

    func feed(_ samples: [Float]) -> [AudioChunk] {
        var out: [AudioChunk] = []
        var data = pending + samples
        pending.removeAll(keepingCapacity: true)
        var i = 0
        while i + frame <= data.count {
            let slice = Array(data[i..<(i + frame)])
            i += frame
            if let c = push(frame: slice) { out.append(c) }
        }
        if i < data.count { pending = Array(data[i...]) }
        data.removeAll()
        return out
    }

    /// Остаток после конца файла. nil, если в остатке не было речи.
    func flush() -> AudioChunk? {
        if !pending.isEmpty {
            let tail = pending; pending = []
            let padded = tail + [Float](repeating: 0, count: max(0, frame - tail.count))
            _ = push(frame: padded)
        }
        guard speechSeen, !buffer.isEmpty else { return nil }
        let chunk = emit(upTo: buffer.count - silenceRun * frame)
        buffer.removeAll(); frameRMS.removeAll(); speechSeen = false; silenceRun = 0
        return chunk
    }

    private func push(frame slice: [Float]) -> AudioChunk? {
        consumed += frame
        let rms = Self.rms(slice)
        let quiet = rms < P.silenceRMS
        if !speechSeen {
            if quiet { gapFrames += 1; return nil }   // ведущую тишину не копим, только считаем
            speechSeen = true
            chunkStart = consumed - frame
        }
        buffer.append(contentsOf: slice)
        frameRMS.append(rms)
        silenceRun = quiet ? silenceRun + 1 : 0

        let seconds = Double(buffer.count) / Double(P.sampleRate)
        if seconds >= P.minChunkSeconds, Double(silenceRun) * P.frameSeconds >= P.silenceMinSeconds {
            // Режем по началу тишины: кусок заканчивается сразу после речи, тишина уходит в gap.
            let chunk = emit(upTo: buffer.count - silenceRun * frame)
            gapFrames = silenceRun
            buffer.removeAll(keepingCapacity: true); frameRMS.removeAll(keepingCapacity: true)
            speechSeen = false; silenceRun = 0
            return chunk
        }
        if seconds >= P.maxChunkSeconds {
            // Тишины не дождались: режем в самом тихом кадре хвоста, остаток становится новым куском.
            let lookback = Int(P.hardCutLookbackSeconds / P.frameSeconds)
            let from = max(1, frameRMS.count - lookback)
            var best = frameRMS.count - 1
            for f in from..<frameRMS.count where frameRMS[f] < frameRMS[best] { best = f }
            let cut = best * frame
            let chunk = emit(upTo: cut)
            let tail = Array(buffer[cut...]); let tailRMS = Array(frameRMS[best...])
            buffer = tail; frameRMS = tailRMS
            chunkStart += cut
            gapFrames = 0
            silenceRun = tailRMS.reversed().prefix { $0 < P.silenceRMS }.count
            speechSeen = tailRMS.contains { $0 >= P.silenceRMS }
            if !speechSeen { buffer.removeAll(); frameRMS.removeAll(); gapFrames = tailRMS.count; silenceRun = 0 }
            return chunk
        }
        return nil
    }

    private func emit(upTo end: Int) -> AudioChunk {
        let n = max(0, min(end, buffer.count))
        let chunk = AudioChunk(samples: Array(buffer[0..<n]),
                               startSeconds: Double(chunkStart) / Double(P.sampleRate),
                               gapBefore: Double(gapFrames) * P.frameSeconds)
        return chunk
    }

    static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for v in s { acc += v * v }
        return (acc / Float(s.count)).squareRoot()
    }
}

/// Огибающая волны для карточки, считается по ходу чтения: держать все сэмплы часовой записи ради
/// 64 байт картинки нельзя. Те же 64 корзины и та же квантизация, что у клипов диктовки.
struct EnvelopeAccumulator {
    private let buckets: Int
    private let perBucket: Int
    private var peaks: [Float]
    private var index = 0

    init(totalSamples: Int, buckets: Int = AudioImportPolicy.envelopeBuckets) {
        self.buckets = buckets
        self.perBucket = max(1, totalSamples / buckets)
        self.peaks = Array(repeating: 0, count: buckets)
    }

    mutating func feed(_ samples: [Float]) {
        for v in samples {
            let b = min(buckets - 1, index / perBucket)
            let a = abs(v)
            if a > peaks[b] { peaks[b] = a }
            index += 1
        }
    }

    func finish() -> [UInt8] {
        let top = peaks.max() ?? 0
        guard top > 0.0001 else { return Array(repeating: 0, count: buckets) }
        return peaks.map { UInt8(max(0, min(15, Int((($0 / top).squareRoot() * 15).rounded())))) }
    }
}

/// Сборка кусков текста обратно в документ.
enum TranscriptAssembler {
    struct Piece: Equatable {
        let text: String
        let gapBefore: Double
    }

    /// Пустые куски пропускаются; пауза длиннее `paragraphGap` даёт пустую строку между абзацами,
    /// короче — обычный пробел.
    static func join(_ pieces: [Piece], paragraphGap: Double = AudioImportPolicy.paragraphGapSeconds) -> String {
        var out = ""
        for p in pieces {
            let t = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if out.isEmpty { out = t; continue }
            out += (p.gapBefore >= paragraphGap ? "\n\n" : " ") + t
        }
        return out
    }
}

/// Прогресс для строки под поиском: время как на часах и честная оценка остатка.
enum ImportProgressFormat {
    /// 83 → «1:23», 4523 → «1:15:23».
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Оценка остатка по уже пройденному. nil, пока пройдено меньше пяти секунд: делить не на что.
    static func remaining(processed: Double, total: Double, elapsed: Double) -> Double? {
        guard processed >= 5, total > processed, elapsed > 0 else { return nil }
        return (total - processed) * elapsed / processed
    }
}
