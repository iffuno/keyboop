import AppKit

/// Свои звуковые метки записи: два коротких перкуссивных тона «тук-тук».
/// Восходящие (старт записи) и нисходящие (стоп). Генерим WAV в памяти —
/// без файлов в бандле и без сети (принцип №2). Тон — синус с быстрым attack
/// и экспоненциальным decay, чтобы звучало как мягкий «тук», а не гудок.
enum CueSynth {
    private static let sampleRate = 44_100.0
    private static let baseHz = 330.0           // нижняя нота (низко — не режет ухо)
    private static let ratio  = 440.0 / 330.0   // шаг ≈ кварта (×4/3) — одинаковый для обоих звуков
    private static let toneDur = 0.050  // 50 мс на «пык» (короче)
    private static let gapDur  = 0.030  // 30 мс пауза между ними
    private static let amp     = 0.38   // тише — метка незаметная, не назойливая

    /// Оба звука ВОСХОДЯЩИЕ, одинаковым шагом. Конец продолжает старт: его первая нота =
    /// последняя нота старта, и поднимается ровно на тот же интервал. Получается лесенка
    /// 330→440 (старт) · 440→587 (конец) — конец выше, но «в ту же сторону».
    static let startData: Data = makeTwoTone(baseHz, baseHz * ratio)                 // 330 → 440 ↗
    static let stopData:  Data = makeTwoTone(baseHz * ratio, baseHz * ratio * ratio) // 440 → 587 ↗
    static let failData:  Data = makeTwoTone(300, 225)                               // 300 → 225 ↘ «не вышло»
    /// СВОЙ звук переключения раскладки (опция в настройках; по умолчанию остаётся системный Pop —
    /// решение автора 25.07). Выбран им из десяти вариантов на слух — №9: «короткий и сухой».
    ///
    /// Параметры и почему такие: 440 Гц — выше нашей базовой 330 (на 330 с падением тона звук
    /// получался «грустным»: падение = минорный ход). Тон РОВНЫЙ, без съезда. Удар короче обычного
    /// (34 мс вместо 45) и спад быстрее (taufrac 0.38) — отсюда «сухость», без звона и хвоста.
    /// Мягкая атака 7 мс, как у остальных наших звуков (не щелчок). Повтор через 22 мс — двойной,
    /// но слитный. Итого ~90 мс.
    static let switchData: Data = makeSwitchCue()

    private static func makeSwitchCue() -> Data {
        var s: [Int16] = []
        appendDry(&s)
        appendSilence(&s, 0.022)
        appendDry(&s)
        return wav(s)
    }

    /// Один короткий сухой удар 440 Гц (без падения тона и обертонов).
    private static func appendDry(_ out: inout [Int16]) {
        let dur = 0.034, freq = 440.0
        let n = Int(sampleRate * dur)
        out.reserveCapacity(out.count + n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let attack = min(1.0, t / 0.007)
            let decay  = exp(-t / (dur * 0.38))
            let v = sin(2.0 * .pi * freq * t) * attack * decay * amp
            out.append(Int16(max(-1.0, min(1.0, v)) * 32_767))
        }
    }

    /// Звук перевода: тёплое восходящее трезвучие (три ноты) — «преобразование / перетекание
    /// смысла из языка в язык». Отличается от двухтонового «тук-тук» конвертации и записи.
    static let translateData: Data = makeTriTone(330, 415, 523)                      // до-ми-соль ↗ мажор

    // ── Пасхалка: «мяу» по ПЯТИкратному клику на версию (одиночный — ничего) ──
    private static var eggCount = 0
    private static var eggLast = Date.distantPast
    /// Засчитать клик по версии. Серия из 5 (без пауз >1.5с) → «мяу».
    static func versionTap() {
        let now = Date()
        if now.timeIntervalSince(eggLast) > 1.5 { eggCount = 0 }
        eggLast = now
        eggCount += 1
        if eggCount >= 5 { eggCount = 0; playMeow() }
    }

    static let meowData: Data = makeMeow()
    private static var meowSound: NSSound?   // удерживаем, иначе оборвётся
    static func playMeow() {
        meowSound?.stop()
        meowSound = Sounds.play(NSSound(data: meowData), volume: 0.7)
    }

    /// Синтез «мяу»: фундамент скользит вверх-вниз (ме-оу), 4 гармоники + вибрато,
    /// огибающая attack/release. Не настоящий кот, но узнаваемо-милый писк.
    private static func makeMeow() -> Data {
        let sr = sampleRate, dur = 0.42
        let n = Int(sr * dur)
        var s: [Int16] = []; s.reserveCapacity(n)
        let harm: [Double] = [1.0, 0.5, 0.28, 0.12]
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr, x = t / dur
            let f0base = x < 0.45 ? 480 + (760 - 480) * (x / 0.45)
                                  : 760 + (500 - 760) * ((x - 0.45) / 0.55)
            let vib = 1.0 + 0.03 * sin(2.0 * .pi * 6.0 * t)
            phase += 2.0 * .pi * f0base * vib / sr
            var v = 0.0
            for (k, a) in harm.enumerated() { v += a * sin(phase * Double(k + 1)) }
            v /= 1.9
            let env = min(1.0, t / 0.02) * max(0.0, min(1.0, (dur - t) / 0.09))
            v *= env * 0.5
            s.append(Int16(max(-1.0, min(1.0, v)) * 32_767))
        }
        return wav(s)
    }

    private static func makeTwoTone(_ f1: Double, _ f2: Double) -> Data {
        var s: [Int16] = []
        appendTone(&s, f1, toneDur)
        appendSilence(&s, gapDur)
        appendTone(&s, f2, toneDur)
        return wav(s)
    }

    private static func makeTriTone(_ f1: Double, _ f2: Double, _ f3: Double) -> Data {
        var s: [Int16] = []
        appendTone(&s, f1, toneDur)
        appendSilence(&s, gapDur * 0.6)   // ноты ближе друг к другу — слитное арпеджио, не «тук-тук-тук»
        appendTone(&s, f2, toneDur)
        appendSilence(&s, gapDur * 0.6)
        appendTone(&s, f3, toneDur)
        return wav(s)
    }

    private static func appendTone(_ out: inout [Int16], _ freq: Double, _ dur: Double) {
        let n = Int(sampleRate * dur)
        out.reserveCapacity(out.count + n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let attack = min(1.0, t / 0.007)            // 7 мс мягкий вход — без щелчка
            let decay  = exp(-t / (dur * 0.5))          // мягкое затухание → «пык»
            let v = sin(2.0 * .pi * freq * t) * attack * decay * amp
            out.append(Int16(max(-1.0, min(1.0, v)) * 32_767))
        }
    }

    private static func appendSilence(_ out: inout [Int16], _ dur: Double) {
        out.append(contentsOf: repeatElement(0, count: Int(sampleRate * dur)))
    }

    /// Минимальный 16-бит mono PCM WAV (RIFF).
    private static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        let sr = Int(sampleRate)
        let dataSize = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)             // PCM, mono
        u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)                          // byteRate, block, bits
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        for v in samples { u16(UInt16(bitPattern: v)) }
        return d
    }
}
