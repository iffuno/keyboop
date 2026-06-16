import Foundation

/// Обёртка над whisper.cpp (локально, без сети — принцип №2).
/// Транскрибирует PCM 16 kHz mono Float32 → текст. Metal/ANE включены по умолчанию.
/// Reference: vendor/whisper.cpp/include/whisper.h
final class WhisperBridge {
    private var ctx: OpaquePointer?

    /// Загружает модель ggml-*.bin. Возвращает nil, если файла нет / не та архитектура.
    init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true   // Metal на Apple Silicon
        ctx = whisper_init_from_file_with_params(modelPath, cparams)
        if ctx == nil { return nil }
    }

    deinit { if let ctx { whisper_free(ctx) } }

    /// Транскрибировать аудио. language: "ru" / "en" / "auto".
    /// initialPrompt с примером пунктуации стабилизирует знаки (см. docs/VOICE.md §4).
    func transcribe(samples: [Float], language: String) -> String {
        guard let ctx, !samples.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.translate = false
        params.suppress_blank = true
        params.no_context = true         // не тащить контекст между диктовками (анти-залипание)
        // single_segment=false: длинная диктовка (>30с) должна обрабатываться ВСЕМИ окнами,
        // иначе хвост речи терялся (раньше стояло true → частичное распознавание длинных реплик).
        params.single_segment = false
        params.temperature = 0.0
        params.temperature_inc = 0.0     // выключить temperature-fallback — главный источник «фантазий»
        params.no_speech_thold = 0.6
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        // whisper.h: для авто-определения language = "auto" (НЕ detect_language + пустой language —
        // тогда оставался дефолтный "en" → на RU-речи выходило пусто). Всегда задаём language строкой.
        let lang = strdup(language)
        defer { free(lang) }
        params.language = UnsafePointer(lang)        // "auto" → авто-детект; "ru"/"en" → явный язык
        // initial_prompt НАМЕРЕННО не задаём: content-промпт («Привет! Вот пример текста…») смещал
        // whisper к «фантазиям» — на сложном/тихом сегменте он «продолжал» промпт обобщённой фразой
        // вместо речи (например 19.5с речи → «Я не знаю, как это сделать…»). Пунктуацию medium/large
        // ставит и без подсказки. Если пунктуация просядет — вернём короткий промпт ТОЛЬКО из знаков.

        var out = ""
        samples.withUnsafeBufferPointer { buf in
            let rc = whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            let n = rc == 0 ? whisper_full_n_segments(ctx) : -1
            kbLog("whisper: rc=\(rc) segments=\(n) lang=\(language) samples=\(buf.count)")
            guard rc == 0 else { return }
            for i in 0..<whisper_full_n_segments(ctx) {
                if let cstr = whisper_full_get_segment_text(ctx, i) {
                    out += String(cString: cstr)
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
