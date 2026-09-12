import Foundation

// ЗАПИСЬ ЗВОНКА НА MAC (задача 230, 04.09.2026). Чистая часть.
//
// автор созванивается в Zoom и записывал звонки диктофоном на iPhone, потом пересылал файл и
// расшифровывал. Теперь Keyboop пишет системный звук вместе с микрофоном прямо на Mac и кладёт
// расшифровку в историю. Функция скрытая (⌥-клик по значку), без настроек и без строки в «Что
// нового»: она пересекается с рабочим проектом автора в компании.
//
// Здесь всё, что можно проверить без CoreAudio: автостоп по тишине, сторож потока, ролловер
// сегментов, микшер в моно, огибающая без хранения сэмплов, описание сессии на диске. Захват через
// Core Audio tap, микрофон, кодирование и движок живут в `CallRecorder.swift`.
//
// # Подстраховка от потери записи (автор: «то, что сказано, потом никак не восстановишь»)
//
//   • звук пишется сегментами по две минуты, каждый закрывается сразу: AAC-файл без закрытого
//     заголовка нечитаем, поэтому один файл на час нельзя;
//   • если буферы не приходят дольше пяти секунд, а человек запись не останавливал, захват
//     пересоздаётся; три неудачи подряд → уведомление, чтобы успеть включить диктофон на телефоне;
//   • незавершённая сессия (крэш, выключение) добирается при следующем старте из сегментов;
//   • автостоп по тишине сначала спрашивает и только потом останавливает.

enum CallRecordingPolicy {
    /// Длина сегмента на диске. Две минуты: при крэше теряется не больше двух минут звука.
    static let segmentSeconds = 120.0
    /// Тишина, после которой спрашиваем «остановить?».
    static let silencePromptSeconds = 300.0
    /// Тишина, после которой останавливаем сами (считая от её начала).
    static let silenceStopSeconds = 420.0
    /// Порог тишины тот же, что у резки импорта: один и тот же микрофон и тот же звонок.
    static let silenceRMS: Float = AudioImportPolicy.silenceRMS
    /// Окно, по которому решаем «звучит или нет». См. `SilenceWatch`.
    static let silenceWindowSeconds = 30.0
    /// Доля громкого времени в окне, выше которой считаем, что кто-то говорит.
    ///
    /// ⚠️ ЧИСЛО ИЗМЕРЕНО, А НЕ ВЫБРАНО НА ГЛАЗ (07.09.2026, разбор записи автора 1:33:31). В живом
    /// разговоре речь занимает десятки процентов времени; в пустой комнате с открытым микрофоном
    /// остаются одиночные щелчки — на последних двадцати минутах той записи громкими оказались 9%
    /// кадров, но 217 отдельными вспышками медианой 80 мс. Порог 10% разделяет эти два мира.
    static let silenceLoudShare = 0.10
    /// Без буферов дольше этого захват считается умершим.
    static let stallSeconds = 5.0
    /// Сколько раз пересоздаём захват, прежде чем сдаться и сказать человеку.
    static let maxRestarts = 3
    /// Меньше этого свободного места запись не начинаем: час звонка это ~7 МБ, но система с
    /// полным диском ведёт себя непредсказуемо.
    static let minFreeBytes: Int64 = 500 * 1024 * 1024
}

/// Автостоп по тишине: сначала предложить, потом остановить.
///
/// ⚠️ РЕШАЕТ НЕ ОТДЕЛЬНЫЙ БУФЕР, А ОКНО (переписано 07.09.2026, разбор живого случая).
///
/// Было так: любой буфер громче порога сбрасывал отсчёт. На бумаге это «любой звук сбрасывает
/// тишину», на деле — «любой щелчок». автор оставил запись включённой после созвона; она шла
/// 1 час 33 минуты и не предложила остановиться ни разу. Расшифровка сохранённого клипа показала
/// почему: в последние двадцать минут комната была тихой (медиана RMS 0.0019 при пороге 0.006),
/// но 9% кадров по 20 мс всё же превышали порог — 217 отдельных вспышек, медиана 80 мс. Клавиатура,
/// стул, шум с улицы. Самая длинная непрерывная тишина по старому правилу вышла 139 секунд при
/// нужных 300, поэтому вопрос был недостижим в принципе, а не «не успел».
///
/// Стало: держим окно последних `silenceWindowSeconds` и считаем ДОЛЮ громкого времени в нём.
/// Речь занимает десятки процентов, случайные щелчки — единицы. Прогон по той же записи: вопрос
/// на 79-й минуте, остановка на 81-й, то есть человек узнал бы о забытой записи за четверть часа
/// до того, как заметил сам.
///
/// Цена решения, названная числом: тишина считается не от последнего звука, а от момента, когда
/// громкое вытечет из окна. После обычного разговора (речь занимает около половины времени) это
/// примерно 23 секунды, то есть вопрос приходит на 5:23 вместо 5:00. Проверено стендом. И наоборот, редкие
/// короткие «ага» в разговоре в долю не наберут — на этот случай вопрос и существует: он спрашивает,
/// а не останавливает.
struct SilenceWatch: Equatable {
    enum Event: Equatable { case none, prompt, stop }
    private var silentSince: Double?
    private var prompted = false
    private var stopped = false
    private(set) var lastSoundAt: Double
    /// Посекундные корзины окна: сколько времени в секунде было громким и сколько всего.
    private var buckets: [(second: Int, loud: Double, total: Double)] = []
    /// Предыдущий кадр — из него берём длительность буфера (она бывает разной).
    private var lastFeedAt: Double?

    init(startAt: Double) { lastSoundAt = startAt; lastFeedAt = startAt }

    /// Доля громкого времени в окне. Пустое окно считаем тишиной.
    private var loudShare: Double {
        let total = buckets.reduce(0.0) { $0 + $1.total }
        guard total > 0 else { return 0 }
        return buckets.reduce(0.0) { $0 + $1.loud } / total
    }

    mutating func feed(rms: Float, at t: Double) -> Event {
        // Длительность кадра: разница с прошлым вызовом, зажатая в разумное (первый кадр, скачок
        // времени после сна, подвисший поток не должны весить как час).
        let dt = min(max((lastFeedAt.map { t - $0 }) ?? 0.02, 0.001), 1.0)
        lastFeedAt = t
        let loud = rms >= CallRecordingPolicy.silenceRMS
        if loud { lastSoundAt = t }
        let sec = Int(t.rounded(.down))
        if buckets.last?.second == sec {
            buckets[buckets.count - 1].loud += loud ? dt : 0
            buckets[buckets.count - 1].total += dt
        } else {
            buckets.append((second: sec, loud: loud ? dt : 0, total: dt))
        }
        let cutoff = sec - Int(CallRecordingPolicy.silenceWindowSeconds)
        buckets.removeAll { $0.second <= cutoff }

        // Звучит ли ЧТО-ТО осмысленное прямо сейчас — решает доля, а не последний буфер.
        guard loudShare < CallRecordingPolicy.silenceLoudShare else {
            silentSince = nil; prompted = false; stopped = false
            return .none
        }
        guard let since = silentSince else { silentSince = t; return .none }
        let silent = t - since
        if silent >= CallRecordingPolicy.silenceStopSeconds {
            if stopped { return .none }
            stopped = true; return .stop
        }
        if silent >= CallRecordingPolicy.silencePromptSeconds, !prompted {
            prompted = true; return .prompt
        }
        return .none
    }

    /// «Продолжить» из уведомления: тишина начинает считаться заново с этого момента.
    mutating func snooze(at t: Double) { silentSince = t; prompted = false; stopped = false }

    func silentSeconds(at t: Double) -> Double { silentSince.map { t - $0 } ?? 0 }

    static func == (a: SilenceWatch, b: SilenceWatch) -> Bool {
        a.silentSince == b.silentSince && a.prompted == b.prompted
            && a.stopped == b.stopped && a.lastSoundAt == b.lastSoundAt
    }
}

/// Сторож потока: буферы обязаны приходить постоянно, иначе захват пересоздаётся.
struct StreamWatchdog: Equatable {
    enum Verdict: Equatable { case fine, restart(attempt: Int), giveUp }
    private(set) var attempts = 0
    private(set) var lastBufferAt: Double

    init(startAt: Double) { lastBufferAt = startAt }

    mutating func noteBuffer(at t: Double) { lastBufferAt = t; attempts = 0 }

    mutating func check(now: Double) -> Verdict {
        guard now - lastBufferAt > CallRecordingPolicy.stallSeconds else { return .fine }
        attempts += 1
        if attempts > CallRecordingPolicy.maxRestarts { return .giveUp }
        lastBufferAt = now   // новому захвату даём свои пять секунд
        return .restart(attempt: attempts)
    }
}

/// Когда закрывать текущий сегмент и открывать следующий.
struct SegmentPlanner: Equatable {
    private let framesPerSegment: Int
    private(set) var framesInCurrent = 0
    private(set) var segmentsRolled = 0

    init(sampleRate: Int = AudioImportPolicy.sampleRate, seconds: Double = CallRecordingPolicy.segmentSeconds) {
        framesPerSegment = Int(Double(sampleRate) * seconds)
    }

    /// true — после этого буфера сегмент пора закрыть.
    mutating func add(frames: Int) -> Bool {
        framesInCurrent += frames
        guard framesInCurrent >= framesPerSegment else { return false }
        framesInCurrent = 0; segmentsRolled += 1
        return true
    }
}

/// Сведение нескольких источников (микрофон, системный звук) в один моно-поток.
enum MonoMixer {
    /// Источники одинаковой длины складываются; разной — по короткому, лишнее отбрасывается
    /// (в одном IO-цикле длины равны, а расхождение это сбой, который не должен ронять запись).
    /// Сумма ограничивается ±1: два громких голоса не должны давать треск.
    static func mix(_ sources: [[Float]]) -> [Float] {
        let live = sources.filter { !$0.isEmpty }
        guard let n = live.map({ $0.count }).min(), n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for s in live { for i in 0..<n { out[i] += s[i] } }
        for i in 0..<n { out[i] = max(-1, min(1, out[i])) }
        return out
    }

    /// Чередующиеся каналы одного потока → моно (среднее по каналам).
    static func monoFromInterleaved(_ data: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return data }
        let frames = data.count / channels
        var out = [Float](repeating: 0, count: frames)
        let k = 1 / Float(channels)
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<channels { acc += data[f * channels + c] }
            out[f] = acc * k
        }
        return out
    }
}

/// Огибающая для карточки, когда длина заранее неизвестна: пики по секундам, в конце 64 корзины.
struct LiveEnvelope {
    private var perSecond: [Float] = []
    private var current: Float = 0
    private var framesInSecond = 0
    private let rate: Int

    init(sampleRate: Int = AudioImportPolicy.sampleRate) { rate = sampleRate }

    mutating func feed(_ samples: [Float]) {
        for v in samples {
            let a = abs(v)
            if a > current { current = a }
            framesInSecond += 1
            if framesInSecond >= rate { perSecond.append(current); current = 0; framesInSecond = 0 }
        }
    }

    func finish(buckets: Int = AudioImportPolicy.envelopeBuckets) -> [UInt8] {
        var peaks = perSecond
        if framesInSecond > 0 { peaks.append(current) }
        guard !peaks.isEmpty else { return Array(repeating: 0, count: buckets) }
        var out = [Float](repeating: 0, count: buckets)
        for (i, p) in peaks.enumerated() {
            let b = min(buckets - 1, i * buckets / peaks.count)
            if p > out[b] { out[b] = p }
        }
        let top = out.max() ?? 0
        guard top > 0.0001 else { return Array(repeating: 0, count: buckets) }
        return out.map { UInt8(max(0, min(15, Int((($0 / top).squareRoot() * 15).rounded())))) }
    }
}

/// Описание сессии на диске: по нему незавершённая запись добирается при следующем старте.
struct CallSession: Codable, Equatable {
    enum State: String, Codable { case recording, stopped, finalizing, done }
    let id: String
    let startedAt: Date
    /// Имя переднего приложения в момент старта («zoom.us»): для подписи записи.
    let app: String
    var state: State
    /// Имена файлов сегментов в папке сессии, по порядку.
    var segments: [String]
    /// Сколько секунд звука записано (для лога и подписи восстановления).
    var recordedSeconds: Double

    static func fresh(app: String, now: Date = Date()) -> CallSession {
        CallSession(id: UUID().uuidString, startedAt: now, app: app, state: .recording, segments: [], recordedSeconds: 0)
    }

    /// Незавершённую сессию имеет смысл добирать, только если от неё остались сегменты.
    var needsRecovery: Bool { state != .done && !segments.isEmpty }

    /// Подпись записи в истории.
    static func title(app: String, recovered: Bool) -> String {
        recovered ? "\(app) (восстановлено)" : app
    }
}
