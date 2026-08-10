import AVFoundation
import CryptoKit
import Foundation

/// АУДИО ДИКТОВОК: сохранение исходной записи рядом с распознанным текстом (задача 101, просьба
/// @alexey_vakhrushev в отзыве #110 от 08.08.2026).
///
/// Повод дословно: «распознавание это хорошо, но иногда хочется достать и переслушать оригинальный
/// файл». Человек прямо назвал это единственной причиной, по которой он до сих пор пользуется чужим
/// приложением вместо нашей диктовки.
///
/// ⚠️ ТРИ РЕШЕНИЯ, КОТОРЫЕ ЗДЕСЬ НЕЛЬЗЯ ОСЛАБЛЯТЬ.
///
/// **1. Выключено по умолчанию.** Принципу №2 («ничего не покидает устройство») сохранение не
/// противоречит: файл лежит на маке и никуда не уходит. Противоречит оно другому нашему обещанию —
/// у нас в лог не пишется ни текст, ни речь, а тут на диске заводятся часы чужого голоса. Поэтому
/// только по явному включению, и в интерфейсе рядом сказано честно, что это такое.
///
/// **2. Шифруем тем же ключом, что и текст истории.** Класть открытый m4a рядом с зашифрованным
/// `history.enc` было бы бессмысленно: голос восстанавливает содержание диктовки не хуже текста, и
/// незашифрованный клип стал бы самым слабым звеном. Ключ живёт в Keychain, см. `VoiceHistory`.
/// Проигрываем из памяти (`AVAudioPlayer(data:)`), расшифрованный файл на диск не кладём НИКОГДА.
///
/// **3. Клип живёт ровно столько, сколько его запись.** Отдельного срока хранения нет намеренно:
/// два разных срока на одну и ту же диктовку это два разных обещания, и человек неизбежно решит,
/// что сработает то, которое он помнит. Удаление записи, истечение срока хранения истории, «очистить
/// всё» и выключение самой опции — каждый из этих путей обязан унести и файл (см. `VoiceHistory`).
///
/// ФОРМАТ И БИТРЕЙТ, ЗАМЕРЕНО, А НЕ ВЗЯТО ИЗ ДОКУМЕНТАЦИИ (08.08.2026). Пишем AAC в .m4a, 16 кГц
/// моно. Частота ровно та, на которой мы и записываем для распознавания (`AudioRecorder`: 16000 Hz
/// 1ch Float32), пересчёта нет.
///
/// ⚠️ `AVEncoderBitRateKey` НЕ означает «столько и будет». Замер на десятисекундном речеподобном
/// сигнале, все значения реальные:
///
/// | просим | получаем | размер |
/// |---|---|---|
/// | не указывать | 43 кбит/с | 316 КБ/мин |
/// | 16000 | 34 кбит/с | 252 КБ/мин |
/// | 24000 | 43 кбит/с | 316 КБ/мин |
/// | 32000 | 51 кбит/с | 376 КБ/мин |
/// | PCM 16 бит | 259 кбит/с | 1899 КБ/мин |
///
/// То есть кодировщик округляет запрос к своей сетке и выдаёт примерно вдвое больше запрошенного, а
/// `AVEncoderBitRatePerChannelKey` и `AVEncoderAudioQualityKey` на моно 16 кГц не делают ВООБЩЕ
/// НИЧЕГО (все три дали ровно те же 53984 байта, что и настройки по умолчанию). Поэтому просим
/// 16000: это нижняя доступная ступень, на выходе 34 кбит/с, чего речи с ноутбучного микрофона
/// хватает с запасом. Практический потолок: 50 записей по полминуты ≈ 6 МБ.
enum VoiceClips {

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ id: String) -> URL { dir.appendingPathComponent(id + ".enc") }

    // MARK: - Запись

    /// Сохранить запись и вернуть идентификатор клипа. nil — не сохраняли (выключено, пусто, ошибка).
    ///
    /// ⚠️ Зовётся из фонового потока транскрипции и НИКОГДА не должно ронять диктовку: любая
    /// неудача это просто отсутствие клипа, текст при этом сохраняется как раньше.
    /// ОГИБАЮЩАЯ ДЛЯ ВОЛНЫ. Считаем ЗДЕСЬ, при сохранении, а не при воспроизведении: сэмплы уже на
    /// руках, а декодировать клип ради картинки означало бы платить за неё каждым открытием окна.
    ///
    /// 64 корзины по пиковому значению, квантованные в 0…15. Это 64 байта на запись, то есть на всю
    /// историю в 50 записей около трёх килобайт. Пик, а не среднее: среднее по корзине сглаживает
    /// речь в ровную колбасу, и волна перестаёт показывать то единственное, ради чего нужна, — где
    /// говорили, а где пауза.
    static func envelope(samples: [Float], buckets: Int = 64) -> [UInt8] {
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / buckets)
        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)
        var i = 0
        while i < samples.count && peaks.count < buckets {
            var m: Float = 0
            for j in i..<min(i + per, samples.count) { m = max(m, abs(samples[j])) }
            peaks.append(m)
            i += per
        }
        // Нормируем по САМОМУ ГРОМКОМУ месту записи, а не по абсолютной шкале: тихая диктовка
        // иначе нарисовалась бы плоской ниткой, хотя внутри неё есть и речь, и паузы.
        let top = peaks.max() ?? 0
        guard top > 0.0001 else { return Array(repeating: 0, count: peaks.count) }
        return peaks.map { UInt8(max(0, min(15, Int((($0 / top).squareRoot() * 15).rounded())))) }
    }

    /// Сохранить запись. Возвращает идентификатор клипа и огибающую для волны.
    static func save(samples: [Float]) -> (id: String, wave: [UInt8])? {
        guard AppSettings.shared.voiceSaveAudio, !samples.isEmpty else { return nil }
        guard let key = VoiceHistory.storageKey else { return nil }

        // Кодируем через временный файл: AVAudioFile умеет писать AAC только в файл, а нам нужны
        // байты контейнера, чтобы их зашифровать. Временный файл живёт миллисекунды и удаляется
        // в defer — незашифрованного аудио в Application Support не появляется ни на мгновение.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let raw = encodeAAC(samples: samples, to: tmp) else { return nil }
        do {
            let sealed = try AES.GCM.seal(raw, using: key)
            guard let combined = sealed.combined else { return nil }
            let id = UUID().uuidString
            try combined.write(to: url(id), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(id).path)
            kbLog("аудио диктовки: сохранено \(combined.count / 1024) КБ за \(String(format: "%.1f", Double(samples.count) / 16_000))с")
            return (id, envelope(samples: samples))
        } catch {
            kbLog("аудио диктовки: не зашифровать (\(error))")
            return nil
        }
    }

    /// [Float] 16 кГц моно → AAC .m4a. Возвращает байты файла.
    private static func encodeAAC(samples: [Float], to tmp: URL) -> Data? {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                           channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   16_000,   // на выходе ~34 кбит/с, см. таблицу замеров выше
        ]
        // ⚠️ ФАЙЛ ОБЯЗАН БЫТЬ ЗАКРЫТ ДО ЧТЕНИЯ БАЙТОВ, и ровно это делает вложенный do: `AVAudioFile`
        // дописывает заголовок контейнера в deinit. Прочитанный при живом объекте .m4a получается
        // битым, и `AVAudioPlayer(data:)` возвращает nil — поймано на стенде, где сразу все
        // двенадцать вариантов кодирования показали «плеер=НЕТ», включая несжатый PCM, что и выдало
        // общую причину.
        do {
            do {
                let file = try AVAudioFile(forWriting: tmp, settings: settings)
                try file.write(from: buffer)
            }
        } catch {
            // Не находим кодек / система отказала — молча остаёмся без клипа. Ронять из-за этого
            // диктовку нельзя: текст человеку нужнее записи.
            kbLog("аудио диктовки: кодирование не удалось (\(error))")
            return nil
        }
        return try? Data(contentsOf: tmp)
    }

    // MARK: - Чтение и удаление

    /// Расшифрованные байты .m4a для `AVAudioPlayer(data:)`. На диск ничего не кладём.
    static func data(for id: String) -> Data? {
        guard let key = VoiceHistory.storageKey,
              let blob = try? Data(contentsOf: url(id)),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let raw = try? AES.GCM.open(box, using: key)
        else { return nil }
        return raw
    }

    static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    /// Снести все клипы разом (выключение опции, «очистить историю», кнопка в настройках).
    static func deleteAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "enc" { try? FileManager.default.removeItem(at: f) }
    }

    /// Оставить на диске только те клипы, которые кто-то ещё держит за руку.
    ///
    /// ⚠️ Нужен именно СБОРЩИК СИРОТ, а не только точечное удаление. Запись истории может исчезнуть
    /// путём, который про файл ничего не знает: перевыпуск ключа шифрования (`resolveKey` делает это
    /// молча, когда связка перестала узнавать подпись) обнуляет историю целиком, и без уборки клипы
    /// остались бы лежать навсегда, да ещё и нечитаемыми, потому что старым ключом их уже не открыть.
    static func keepOnly(_ ids: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var killed = 0
        for f in files where f.pathExtension == "enc" {
            if !ids.contains(f.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: f); killed += 1
            }
        }
        if killed > 0 { kbLog("аудио диктовки: убрано \(killed) осиротевших клипов") }
    }

    /// Сколько всего занято на диске, байт. Для честной строки в настройках.
    static func totalBytes() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// «12,4 МБ» / «812 КБ» — человеческий размер для настроек.
    static func humanSize(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
