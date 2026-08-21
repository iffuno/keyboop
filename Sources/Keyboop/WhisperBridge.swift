import Foundation

/// Обёртка над whisper.cpp (локально, без сети — принцип №2).
/// Транскрибирует PCM 16 kHz mono Float32 → текст. Metal/ANE включены по умолчанию.
/// Reference: vendor/whisper.cpp/include/whisper.h
final class WhisperBridge {
    private var ctx: OpaquePointer?

    /// Сколько потоков отдавать whisper. Считается ОДИН раз: значение не меняется в течение сессии,
    /// а sysctl в горячем пути нам ни к чему.
    ///
    /// Правило: на Apple Silicon берём производительные ядра МИНУС ОДНО, чтобы звуку и интерфейсу
    /// осталось где выполняться. На Intel (где деления на P/E нет) сохраняем прежнее поведение.
    /// Потолок 8 оставлен как был: выше whisper.cpp почти не ускоряется, а тепла добавляет.
    static let transcribeThreads: Int = {
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // hw.perflevel0 — производительные ядра; на Intel такого ключа нет, sysctlbyname вернёт != 0.
        if sysctlbyname("hw.perflevel0.logicalcpu", &perf, &size, nil, 0) == 0, perf > 1 {
            let n = max(1, min(8, Int(perf) - 1))
            kbLog("whisper: потоков \(n) (производительных ядер \(perf), одно оставлено системе)")
            return n
        }
        let n = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        kbLog("whisper: потоков \(n) (ядер \(ProcessInfo.processInfo.activeProcessorCount), деления на P/E нет)")
        return n
    }()

    /// Загружает модель ggml-*.bin. Возвращает nil, если файла нет / не та архитектура.
    init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true   // Metal на Apple Silicon
        ctx = whisper_init_from_file_with_params(modelPath, cparams)
        if ctx == nil { return nil }
    }

    deinit { if let ctx { whisper_free(ctx) } }

    /// Сколько кадров энкодера (по 20 мс) выделить под запись. Сейчас всегда 0 = полные 30 секунд.
    ///
    /// ⛔️ ЭТО ВЫКЛЮЧЕНО НАМЕРЕННО, И ВКЛЮЧАТЬ ОБРАТНО «ПРОСТО ПОДНЯВ ПОРОГ» НЕЛЬЗЯ.
    ///
    /// Задумка была честная. Whisper дополняет любую запись тишиной до 30 секунд и всегда гоняет
    /// через энкодер все 1500 кадров, поэтому по логам у нас ровный пол в 0.9 с на всём, что короче
    /// пяти секунд: диктовка из двух слов обходится почти как из двадцати. `params.audio_ctx`
    /// (в whisper.cpp помечен экспериментальным) укорачивает это окно, и энкодер честно ускоряется
    /// в разы: 384 → 253 мс при 900 кадрах, 384 → 76 мс при 200.
    ///
    /// Чего это стоит. Когда окна не хватает, декодер срывается в повтор, а автоопределение языка
    /// уезжает в чужой язык. 21.08.2026 сборка с этой обрезкой сутки не прожила: автор диктовал
    /// короткие фразы, в логе стояло ac=368…444, и вместо «относительно» приходил английский мусор.
    ///
    /// Почему безопасного порога не вышло подобрать. Он НЕ является функцией длины записи, а это
    /// единственное, что мы знаем в момент вызова. Замеры на large-v3-turbo с нашим промптом:
    /// 0.55 с ломается уже на 900, 2.2 с живёт на 300, 7.5 с ломается на 300, 2.47 с ломается на
    /// 700, но целая на 500. Зависимость немонотонная, то есть порог не вывести из длины никак.
    ///
    /// И главное, ради чего это затевалось, всё равно не окупается. Энкодер это лишь треть работы:
    /// на диктовку в пару секунд полное время расшифровки (без разовой загрузки модели) падает
    /// 491 → 340 мс. Полторы десятых секунды в обмен на риск получить вместо фразы бессмыслицу.
    /// По нашему же правилу про автозамену опечаток: лучше не ускорить, чем испортить.
    ///
    /// Если возвращаться, то не сюда, а к причине: тишину в хвосте окна надо не обрезать, а не
    /// создавать (VAD-обрезка записи до реальной речи) — тогда меняется вход, а не внутренности
    /// модели. Формула ниже сохранена как след замера, ею ничего не управляется.
    static func audioContext(forSamples n: Int) -> Int32 {
        let seconds = Double(n) / 16_000.0
        let frames = Int((seconds * 1.4 + 3.0) / 0.02) + 1
        _ = frames
        return 0
    }

    /// Транскрибировать аудио. language: "ru" / "en" / "auto".
    /// initialPrompt с примером пунктуации стабилизирует знаки.
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
        // temperature-fallback ВКЛЮЧЁН (temp_inc>0): при детекте ВЫРОЖДЕННОГО сегмента (entropy_thold —
        // повтор/гиббериш; logprob_thold — низкая уверенность) whisper.cpp ПЕРЕдекодирует его на чуть
        // большей температуре. Это ШТАТНЫЙ механизм РАЗРЫВА repetition-loop — Whisper на длинной диктовке
        // повторял одно слово/фразу много раз (баг-репорт, подтверждён исследованием моделей).
        // Раньше стоял 0.0 (fallback ВЫКЛ ради «без фантазий») — но это и ОСТАВЛЯЛО петли. Срабатывает
        // ТОЛЬКО на вырожденных сегментах; чистую речь греедичный проход (temp 0) проходит как раньше.
        // Системно петли решает Parakeet v3 (transducer, без авторегрессии) — для RU/EU он и дефолт.
        //
        // ⚠️ ПОТОКИ СЧИТАЕМ ПО ПРОИЗВОДИТЕЛЬНЫМ ЯДРАМ, А НЕ ПО ВСЕМ (01.08.2026, жалоба пользователя).
        // Раньше стояло `activeProcessorCount - 2`, и двойка задумывалась как «оставим запас».
        // На Apple Silicon это оказалось ловушкой: у M1 Max 8 P-ядер и 2 E-ядра, всего 10, и формула
        // давала ровно 8 — то есть мы забирали ВСЕ производительные ядра, а звуковому потоку
        // оставались только экономичные. Симптом: во время диктовки заикается музыка, и человек
        // думает, что приложение вешает компьютер.
        // Модель и качество при этом ни при чём: тяжёлую large-v3-turbo автор выбирает сознательно,
        // она лучше расставляет знаки препинания. Наша задача не отговаривать его, а не мешать
        // остальной системе. Оставляем одно P-ядро свободным.
        params.temperature_inc = 0.2
        params.entropy_thold = 2.4       // повтор/гиббериш в сегменте → перезапуск (порог whisper.cpp по умолч.)
        params.no_speech_thold = 0.6
        params.n_threads = Int32(Self.transcribeThreads)

        // ⚠️ ЭНКОДЕР ВСЕГДА МОЛОЛ ПОЛНЫЕ 30 СЕКУНД, ДАЖЕ ЕСЛИ ЧЕЛОВЕК СКАЗАЛ ОДНО СЛОВО (20.08.2026).
        // Whisper дополняет любую запись тишиной до окна в 30 с и прогоняет через энкодер все 1500
        // кадров. По логам это давало ровный пол в 0.9 с на всём, что короче пяти секунд: диктовка из
        // двух слов обходилась почти так же дорого, как из двадцати. Больно это в первую очередь не
        // на M1 Max, а на обычных M1/M2, где тот же энкодер идёт заметно дольше.
        //
        // params.audio_ctx (в whisper.cpp помечен экспериментальным) укорачивает окно энкодера.
        // Один кадр энкодера = 20 мс звука (hop 160 при 16 кГц даёт мел-кадр 10 мс, энкодер их делит
        // пополам), максимум 1500 кадров = те самые 30 с, больше нельзя — whisper_full вернёт -5.
        params.audio_ctx = Self.audioContext(forSamples: samples.count)

        // whisper.h: для авто-определения language = "auto" (НЕ detect_language + пустой language —
        // тогда оставался дефолтный "en" → на RU-речи выходило пусто). Всегда задаём language строкой.
        let lang = strdup(language)
        defer { free(lang) }
        params.language = UnsafePointer(lang)        // "auto" → авто-детект; "ru"/"en" → явный язык

        // initial_prompt: НАТУРАЛЬНАЯ фраза со знаками препинания смещает авторегрессионный whisper
        // к «режиму С пунктуацией». Без неё на ХОЛОДНОМ декоде (no_context=true) whisper ~в трети
        // случаев залипал в «no-punctuation mode» — реальная телеметрия: 3/9 диктовок сплошняком,
        // аудио ЧИСТОЕ (noSpeechMax=0.00), длина ни при чём (сплошняк и на 526 симв.). Корень —
        // openai/whisper#194 (jongwook: «nudge к with-punctuation mode»); фикс подтверждён adversarial-
        // ресёрчем по форумам/исходникам whisper.cpp (Habr Соколов: ~1/3 → 99%+ на RU large-v3/turbo).
        // ВАЖНО (всё проверено ресёрчем 11.07):
        //  — промпт = НАТУРАЛЬНАЯ фраза, НЕ «мешок знаков» ., ? ! (короткие/атипичные промпты — самый
        //    ненадёжный случай, могут искажать слова; OpenAI cookbook whisper_prompting_guide);
        //  — промпт ПОД ЯЗЫК: RU-промпт на EN-речи смещает вывод к русскому на пограничном аудио;
        //  — БЕЗ ёлочек « » и без : ; — модель принимает « » за маркер прямой речи и заворачивает в неё
        //    не-речь (Соколов), а turbo эти знаки всё равно теряет;
        //  — no_context=true СОВМЕСТИМ с initial_prompt (no_context чистит ПРОШЛУЮ расшифровку, а промпт
        //    присваивается ПОСЛЕ этой чистки, src/whisper.cpp) — анти-залипание сохраняем;
        //  — carry_initial_prompt=true: на длинной диктовке (>30с = несколько окон) знаки не теряются на
        //    2-м+ окне; для коротких реплик это no-op, downside нет.
        let prompt = Self.punctuationPrompt(for: language)
        let promptC = strdup(prompt)
        defer { free(promptC) }
        params.initial_prompt = UnsafePointer(promptC)
        params.carry_initial_prompt = true

        var out = ""
        // Время самого распознавания в лог: без него «медленно» и «быстро» остаются ощущениями.
        // Секундной точности системного времени в строке лога не хватает — вся расшифровка короткой
        // фразы укладывается примерно в полсекунды (замер 21.08.2026).
        let t0 = CFAbsoluteTimeGetCurrent()
        samples.withUnsafeBufferPointer { buf in
            let rc = whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            let n = rc == 0 ? whisper_full_n_segments(ctx) : -1
            guard rc == 0 else {
                kbLog("whisper: rc=\(rc) segments=\(n) lang=\(language) samples=\(buf.count) за=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))мс")
                return
            }
            // noSpeechMax — макс. вероятность «тишины» по сегментам (диагностика). Реальная телеметрия
            // 10–11.07 ОПРОВЕРГЛА гипотезу «тихий хвост → пропажа знаков»: у ВСЕХ сплошняков noSpeechMax=0.00
            // (аудио чистое). Корень пунктуации — не тишина, а холодный no-punctuation-mode, лечится
            // initial_prompt выше. Метрику оставляем: полезна для repetition-loop / тихого аудио.
            var noSpeechMax: Float = 0
            for i in 0..<n {
                noSpeechMax = max(noSpeechMax, whisper_full_get_segment_no_speech_prob(ctx, i))
                if let cstr = whisper_full_get_segment_text(ctx, i) {
                    out += String(cString: cstr)
                }
            }
            kbLog("whisper: rc=\(rc) segments=\(n) lang=\(language) samples=\(buf.count) ac=\(params.audio_ctx) за=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))мс noSpeechMax=\(String(format: "%.2f", noSpeechMax))")
        }
        // Защита от эха промпта: whisper изредка (на почти-тишине) «продолжает» затравку и выдаёт её
        // началом расшифровки. Наши провалы — чистое аудио (риск низкий), но срезаем ТОЧНОЕ ведущее
        // совпадение с промптом — дёшево и безопасно (реальная речь так дословно не начинается).
        var result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, result.hasPrefix(prompt) {
            result = String(result.dropFirst(prompt.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            kbLog("whisper: срезано эхо initial_prompt")
        }
        return result
    }

    /// Короткая натуральная фраза-«затравка» со всеми ключевыми знаками ( , . ! ? — ) под язык речи.
    /// Демонстрирует whisper «стиль с пунктуацией», не неся смысла (→ ~0 риск утечки/галлюцинаций).
    /// Намеренно БЕЗ « » : ; (см. коммент в transcribe). Для "auto" — русская: аудитория Keyboop
    /// RU-first, дефект пунктуации проявлялся на RU, а на чистом аудио языковой сдвиг от промпта
    /// минимален. Reference: openai/whisper#194 · cookbook whisper_prompting_guide · Habr Соколов 1024634.
    /// Сколько слов было в прошлой подсказке — чтобы не писать одну строку на каждую диктовку.
    private static var lastHintCount = -1

    private static func punctuationPrompt(for language: String) -> String {
        let base: String
        if language == "en" {
            base = "Hi! How are you? The weather is nice today, but it looks like it might rain. Well, let's wait — there's still time."
        } else {
            base = "Привет! Как дела? Сегодня хорошая погода, но, кажется, скоро пойдёт дождь. Ну что ж, подождём — время ещё есть."
        }
        // СЛОВАРЬ ДИКТОВКИ ДОБИРАЕТ ОСТАТОК ОКНА (задача 143). Смысл: не только править вывод, но и
        // заранее сказать модели, какие слова тут вообще бывают, — тогда часть имён она расслышит
        // сама, и правка на выходе останется страховкой, а не единственным механизмом.
        //
        // ⚠️ ДОПИСЫВАЕМ ЦЕЛОЙ ФРАЗОЙ, А НЕ СПИСКОМ ЧЕРЕЗ ЗАПЯТУЮ В ПУСТОТЕ. Прямо выше записано
        // исследование 11.07: промпт должен оставаться НАТУРАЛЬНЫМ текстом, «мешок» коротких токенов
        // — самый ненадёжный случай и умеет искажать соседние слова. Поэтому слова вставляются в
        // обычное предложение на языке промпта, а фраза про пунктуацию остаётся первой: она нам
        // дороже, без неё треть диктовок уходит в режим без знаков препинания.
        guard let words = VoiceDictionary.shared.recognitionHint() else { return base }
        // В лог — только СКОЛЬКО слов подмешали, и один раз на смену состава. Сами слова это
        // содержимое, которое человек завёл сам, а лог уезжает к нам с отзывом (принцип №2).
        // Одного раза достаточно: строка нужна, чтобы ответить «подсказка вообще применилась?»,
        // а не чтобы сопровождать каждую диктовку.
        let count = words.split(separator: ",").count
        if lastHintCount != count {
            lastHintCount = count
            kbLog("voice: в подсказку распознавания подмешано \(count) слов из словаря диктовки")
        }
        return language == "en"
            ? base + " Words that often come up: \(words)."
            : base + " Часто встречаются слова: \(words)."
    }
}
