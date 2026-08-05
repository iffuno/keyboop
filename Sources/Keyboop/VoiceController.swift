import AppKit
import AVFoundation

/// Оркестратор голосового ввода (диктовка): hold-хоткей → запись → whisper.cpp →
/// вставка БЕЗ буфера (принцип №1). Всё локально, без сети (принцип №2).
final class VoiceController {
    static let shared = VoiceController()
    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private let layout = LayoutManager()
    private var whisper: WhisperBridge?
    private var starting = false   // begin() уже запустил async-старт — не запускать второй (гонка)
    private var abortStart = false // end()/cancel() пришёл во время async-старта → прервать его
    /// СИНХРОННЫЙ флаг намерения: true с момента begin() и до остановки записи. Источник истины
    /// для toggle (EventTap), т.к. begin() асинхронный и recorder.isRecording в момент toggle ещё false.
    /// Прокси к атомарному VoiceGate: колбэк CGEventTap читает это СИНХРОННО, а сам begin/end
    /// уезжает на main (см. VoiceGate — там причина). Семантика прежняя: «намерение записывать».
    var isActive: Bool { VoiceGate.isActive }
    /// Сериализация транскрипции: новая ЗАПИСЬ может начаться, пока прошлая транскрибируется
    /// (запись и whisper независимы), но сами whisper-вызовы — строго по одному (не реентерабельно).
    /// ⚠️ QoS ЗАДАН ЯВНО (01.08.2026). Без него очередь получала неопределённый приоритет и для
    /// планировщика была равна интерактивной работе — а распознавание занимает все выделенные ядра
    /// на секунды. Отсюда заикание звука в других программах во время диктовки.
    /// Берём `.userInitiated`, а НЕ `.utility`: человек нажал хоткей и ждёт результат, поэтому нам
    /// нужны производительные ядра. `.utility` на Apple Silicon уводит поток на экономичные, и
    /// распознавание стало бы втрое дольше — это ухудшение, а не улучшение.
    private let transcribeQueue = DispatchQueue(label: "ru.keyboop.voice.transcribe", qos: .userInitiated)
    private var transcribing = 0   // сколько клипов сейчас в транскрипции (для индикатора)
    private var transcribeGen = 0              // генерации задач транскрипции (main-only)
    private var liveTranscriptions = Set<Int>()  // ещё не завершившиеся генерации (main-only)
    /// Поколения, которые надо положить ТОЛЬКО в историю, без вставки в поле (отмена по Escape, R37).
    private var historyOnlyGens = Set<Int>()

    /// Снять невостребованную пометку «только в историю».
    ///
    /// Ставится она при отмене на СЛЕДУЮЩЕЕ поколение (`transcribeGen + 1`) в расчёте, что его
    /// заведёт текущая запись. Если запись до расшифровки не дошла, поколение не создаётся и метка
    /// остаётся ждать чужую диктовку. Зовётся из каждой ветки раннего выхода `end()`.
    private func dropPendingHistoryOnly() {
        if historyOnlyGens.remove(transcribeGen + 1) != nil {
            kbLog("voice: снял невостребованную пометку «только в историю» (запись не дошла до расшифровки)")
        }
    }

    // ── ЭКСПЕРИМЕНТАЛЬНО: потоковая диктовка (EOU) ──
    private var streamingActive = false
    private var typedTail = ""                          // что мы УЖЕ напечатали в поле (для диффа)
    private var eouChunks: AsyncStream<[Float]>.Continuation?   // очередь чанков (сохраняет порядок аудио)
    private var eouTask: Task<Void, Never>?            // единый потребитель: кормит движок по порядку
    private var streamFinalize: Task<Void, Never>?     // финализация прошлой сессии (finish/reset) — новая ждёт её
    /// Использовать потоковый путь: фича ВКЛ + движок parakeet + EOU-модель скачана.
    private var useStreaming: Bool {
        guard settings.voiceStreaming else { return false }
        // ⚠️ Молчаливый отказ здесь читался как «фича не работает» (автор 30.07: включил, продиктовал,
        // ничего не увидел). Условий два, и оба невидимы из интерфейса, поэтому называем их в логе.
        guard settings.voiceEngine == "parakeet" else {
            kbLog("потоковый набор пропущен: он только для Parakeet, а выбран \(settings.voiceEngine)")
            return false
        }
        guard StreamingEouEngine.modelInstalled else {
            kbLog("потоковый набор пропущен: модель потокового распознавания не скачана")
            return false
        }
        return true
    }

    enum State { case idle, recording, processing }
    var onStateChange: ((State) -> Void)?

    private init() {
        // Живой уровень микрофона → waveform индикатора «Слушаю». pushLevel сам игнорирует всё,
        // что приходит не в состоянии записи, поэтому хук безопасно держать постоянно.
        recorder.setLevelHook { rms in
            VoiceIndicator.shared.pushLevel(rms)      // плашка «Слушаю»
            MenuBarController.shared?.pushLevel(rms)  // живой waveform в строке меню
        }
        // Запись умерла безвозвратно (вход пропал, аварийная пересборка не удалась) — сворачиваем
        // диктовку ШТАТНО, а не оставляем вечное «Слушаю». Уже напечатанные стрим-партиалы НЕ стираем
        // (текст на экране ценнее); finish() очереди чанков даёт стриму финализироваться как обычно.
        recorder.onNotice = { msg in VoiceIndicator.shared.showToast(msg) }
        recorder.onDied = { [weak self] in
            guard let self else { return }
            kbLog("voice: запись оборвалась (вход недоступен) — диктовка завершена")
            VoiceGate.set(false)
            self.recorder.setChunkHook(nil)
            self.eouChunks?.finish(); self.eouChunks = nil
            // Стрим-конвейер гасим ЦЕЛИКОМ (ревью 21.07, №3): иначе streamingActive оставался true →
            // (а) дренируемые чанки продолжали ПЕЧАТАТЬ в поле после fail-cue (streamStep жив),
            // (б) следующий батч-end() мис-роутился в streamEnd(), (в) осиротевший eouTask
            // интерливился с новой сессией на общем singleton-акторе. Уже напечатанный текст
            // НЕ стираем (ценнее конвейера); финализацию сериализуем через streamFinalize,
            // чтобы следующий streamBegin дождался чистого reset движка.
            if self.streamingActive {
                self.streamingActive = false
                self.typedTail = ""
                let task = self.eouTask; self.eouTask = nil
                self.streamFinalize = Task { await task?.value; await StreamingEouEngine.shared.cancelSession() }
            }
            self.playCue(self.failSound)
            self.setState(.idle)
        }
        setupMemoryPressureUnload()
    }

    /// ОСНОВНОЙ триггер выгрузки модели (~1.5 ГБ): системный memory pressure, а не таймер.
    /// Урок регрессии 0.2.58 (баг-репорт): выгрузка по 5-минутному будильнику заставляла
    /// перегружать модель почти на каждую диктовку (750–1550мс + всплеск аллокации 1.5 ГБ + циклы
    /// init/free Metal-контекста ggml) — «стало дольше и подтормаживает». Правильная семантика:
    /// пока памяти хватает — модель живёт (мгновенная диктовка); система прижала память (.warning/
    /// .critical) и мы простаиваем — отдаём немедленно. Таймер остаётся страховкой на долгий простой.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastVoiceUseAt = Date.distantPast   // последняя диктовка (main-only) — для анти-карусели
    private func setupMemoryPressureUnload() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.whisper != nil, self.transcribing == 0, !self.isActive, !self.recorder.isRecording
            else { return }   // заняты диктовкой — не дёргаем; таймер/следующее событие доберёт
            // КАРУСЕЛЬ ПЕРЕЗАГРУЗОК (баг-репорт): крупная модель (turbo, 1.6 ГБ) сама создаёт
            // warning-давление → мы выгружаем → следующая диктовка платит ~1.2с за перезагрузку →
            // снова давление, по кругу каждые полчаса. Warning в течение 10 минут после последней
            // диктовки игнорируем — пользователь РАБОТАЕТ; по warning выгружаем только в простое.
            // Critical уважаем всегда: системе реально плохо — отдаём немедленно.
            let ev = DispatchSource.MemoryPressureEvent(rawValue: self.memoryPressureSource?.data ?? 0)
            if !ev.contains(.critical), Date().timeIntervalSince(self.lastVoiceUseAt) < 600 {
                kbLog("voice: memory warning в активной сессии диктовок — модель НЕ выгружаю")
                return
            }
            self.modelIdleRelease?.cancel(); self.modelIdleRelease = nil
            self.transcribeQueue.async { [weak self] in
                self?.whisper = nil
                kbLog("voice: системе не хватает памяти (pressure) — модель Whisper выгружена")
            }
        }
        src.resume()
        memoryPressureSource = src
    }

    /// Предзагрузка модели в фоне (на старте приложения, если голос включён и модель есть) — чтобы
    /// ПЕРВОЕ нажатие диктовки не платило за загрузку (частая причина «не сработало с первого раза»).
    func preload() {
        StreamingEouEngine.enforceRuntimeOffline()   // рантайм-офлайн со старта (принцип №2): сеть только при явной докачке
        guard settings.voiceEnabled, hasUsableModel else { return }
        // Прогрев device-discovery AVFoundation в фоне (ревью 21.07, №6): первый AVCaptureDevice-lookup
        // в процессе лениво поднимает инфраструктуру захвата (с BT — заметно), и без прогрева это
        // платил бы ПЕРВЫЙ buildEngine на main. Только lookup — capture-объектов не создаёт, TCC-промпт
        // не триггерит (инвариант «ничего до requestAccess» цел).
        DispatchQueue.global(qos: .utility).async { _ = AVCaptureDevice.default(for: .audio) }
        // Греем ТОТ движок, которым реально пойдёт диктовка.
        // Parakeet раньше не грелся вообще, хотя он движок ПО УМОЛЧАНИЮ: его CoreML-модель грузится
        // и компилируется под ANE лениво, при первой транскрипции — замер 21.07 на чистом контейнере:
        // запись кончилась в 15:16:14, текст пришёл в 15:16:57 (+43с!). Пользователь видит «первая
        // диктовка думает полминуты», дальше всё быстро. Теперь греем в фоне со старта.
        if willUseParakeet {
            Task { _ = await ParakeetEngine.shared.loadIfNeeded() }
        } else {
            transcribeQueue.async { [weak self] in
                self?.loadModelIfNeeded()
                // ⚠️ ЗАВОДИМ ТАЙМЕР ВЫГРУЗКИ СРАЗУ ПОСЛЕ ПРОГРЕВА (05.08.2026, жалоба на память).
                //
                // Раньше `scheduleModelRelease()` звался ровно в одном месте: после расшифровки. То
                // есть человек, который запустил Keyboop и НИ РАЗУ не диктовал, держал модель в
                // памяти бессрочно, потому что таймеру было неоткуда взяться: прогрев её загружает,
                // а завести срок жизни забывает. Замер на этой машине: 1883 МБ с large-v3-turbo
                // против ~380 МБ без модели, и они висели, пока системе не станет плохо.
                //
                // Страховка по нехватке памяти (setupMemoryPressureUnload) это не отменяет: она
                // срабатывает только когда системе УЖЕ плохо, а до тех пор полтора гигабайта видно в
                // мониторе, и человек справедливо считает это багом.
                DispatchQueue.main.async { self?.scheduleModelRelease() }
            }
        }
        // Потоковая модель (если фича вкл и скачана) — прогреть, чтобы первая диктовка не лагала.
        if settings.voiceStreaming && StreamingEouEngine.modelInstalled {
            Task { _ = await StreamingEouEngine.shared.loadIfNeeded() }
        }
    }

    /// Каким движком пойдёт СЛЕДУЮЩАЯ диктовка — та же формула, что в transcribe().
    /// Нужна, чтобы не грузить впустую чужую модель (whisper — это 1.5 ГБ и секунды).
    private var willUseParakeet: Bool {
        settings.voiceEngine == "parakeet" && ParakeetEngine.modelInstalled
    }

    // MARK: - Модель

    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func modelPath(_ name: String) -> String {
        modelsDir.appendingPathComponent("ggml-\(name).bin").path
    }
    var modelInstalled: Bool { FileManager.default.fileExists(atPath: Self.modelPath(settings.voiceModel)) }
    /// Есть ли пригодная модель: Parakeet (если выбран и скачан) ИЛИ whisper-файл (fallback).
    var hasUsableModel: Bool {
        if settings.voiceEngine == "parakeet" && ParakeetEngine.modelInstalled { return true }
        return modelInstalled
    }
    /// Зовётся, когда диктовку нажали, а модели нет — UI предложит скачать.
    var onNeedModel: (() -> Void)?

    // MARK: - Hold-to-talk

    /// Зажали хоткей диктовки. ВАЖНО: НЕ блокируем по «идёт транскрипция прошлого клипа» — запись и
    /// whisper независимы (баг «не сработало с первого раза»: новую запись глушил busy предыдущей).
    func begin() {
        guard settings.voiceEnabled else { return }
        if starting { kbLog("voice: begin пропущен — старт уже идёт"); return }
        if recorder.isRecording { kbLog("voice: begin пропущен — запись уже идёт"); return }
        VoiceGate.set(true)            // СИНХРОННО: намерение записывать — toggle сразу видит активность
        starting = true
        abortStart = false
        lastVoiceUseAt = Date()        // маркер «пользователь диктует» для анти-карусели pressure-выгрузки
        Task { @MainActor in
            defer { starting = false }
            // Доступ к микрофону — ПЕРВЫМ (даже без модели), чтобы новый юзер увидел системный промпт.
            guard await AudioRecorder.requestAccess() else {
                kbLog("voice: нет доступа к микрофону"); Sounds.beep(); VoiceGate.set(false); return
            }
            if abortStart { kbLog("voice: старт прерван (отпустили до начала записи)"); VoiceGate.set(false); setState(.idle); return }
            guard hasUsableModel else {
                kbLog("voice: нет модели распознавания — предлагаем скачать")
                VoiceGate.set(false); onNeedModel?(); return
            }
            // Загрузка модели — строго на transcribeQueue, НЕ на @MainActor.
            // whisper_init_from_file_with_params() читает модель с диска (75–1500+ МБ) несколько секунд.
            // Вызов на main thread замораживал RunLoop: CGEventTap переставал отвечать → весь ввод
            // (мышь, клавиатура) зависал до конца загрузки. Serializes с preload() — оба на одной очереди.
            // ТОЛЬКО если диктовать будет whisper. Раньше грузили безусловно — при движке Parakeet
            // (дефолт!) это впустую тянуло с диска 1.5 ГБ и задерживало старт записи на секунды,
            // а в dev-домене (модель `small` не скачана) давало «модель не загрузилась» на каждой
            // диктовке. Parakeet свою модель грузит сам в transcribe() и греется в preload().
            //
            // БЕЗ ОЖИДАНИЯ (баг-репорт: «старт диктовки стал дольше»): раньше begin() ждал
            // загрузку ЦЕЛИКОМ (large-v3-turbo ~1.2с) и только потом включал микрофон. Записи модель
            // не нужна, а транскрипция встаёт на transcribeQueue ПОЗАДИ загрузки — порядок гарантирует
            // сама очередь. Параллельно: старт мгновенный, загрузка прячется под время речи.
            if !willUseParakeet {
                transcribeQueue.async { [weak self] in self?.loadModelIfNeeded() }
            }
            if abortStart { VoiceGate.set(false); setState(.idle); return }
            do {
                try recorder.start()
                if abortStart {        // отпустили ровно в момент старта — стоп немедленно
                    _ = recorder.stop(); VoiceGate.set(false); setState(.idle); return
                }
                if useStreaming {
                    await streamBegin()   // потоковый путь: текст пойдёт по мере речи
                    // РЕ-ЧЕК после await (ревью 21.07, №4): за время streamBegin (loadIfNeeded /
                    // streamFinalize / actor-hop) юзер мог отпустить хоткей (end() уже отработал
                    // батч-путём) или запись могла умереть (onDied уже поставил .idle). Безусловные
                    // .recording+cue тут воскрешали индикатор на мёртвой записи — «Слушаю» навсегда.
                    // В else СОСТОЯНИЕ НЕ трогаем: его уже корректно выставили end()/cancel()/onDied
                    // (например .processing от батч-финала — .idle затёр бы его).
                    guard recorder.isRecording, !abortStart else { return }
                }
                setState(.recording)
                playCue(startSound)    // восходящее «тук-тук» — пошла запись
            } catch {
                kbLog("voice: старт записи не удался: \(error)")
                VoiceGate.set(false); setState(.idle)
            }
        }
    }

    /// Отпустили хоткей — стоп, транскрипция, вставка.
    func end() {
        // Отпустили/нажали стоп ДО того как async-begin реально завёл запись — прерываем старт.
        if starting && !recorder.isRecording {
            abortStart = true; VoiceGate.set(false); dropPendingHistoryOnly()
            kbLog("voice: end во время старта — прерываю запуск (запись ещё не пошла)")
            return
        }
        guard recorder.isRecording else { VoiceGate.set(false); dropPendingHistoryOnly(); return }
        if streamingActive { streamEnd(); return }   // потоковый путь: финализируем стрим
        let samples = recorder.stop()
        VoiceGate.set(false)      // ЗАПИСЬ окончена → можно сразу начинать НОВУЮ (транскрипция идёт в фоне)
        playCue(stopSound)    // нисходящее «тук-тук» — запись остановлена (до транскрипции)
        let rms = samples.isEmpty ? 0 : (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        kbLog("voice: \(samples.count) сэмплов, \(String(format: "%.1f", recorder.duration))с, RMS=\(String(format: "%.4f", rms))")
        // ⚠️ ПОМЕТКА «ТОЛЬКО В ИСТОРИЮ» ОБЯЗАНА СНИМАТЬСЯ НА КАЖДОМ ВЫХОДЕ ОТСЮДА (баг-репорт,
        // 03.08.2026, подтверждён логом трижды).
        //
        // Симптом: диктовка распознана, лежит в истории, копируется, но в поле не вставилась.
        // Причина: отмена по Escape метит СЛЕДУЮЩЕЕ поколение (`transcribeGen + 1`) в расчёте, что
        // его заберёт текущая запись. Но если запись до расшифровки не доходит — а после случайного
        // Escape она как раз почти всегда тихая, потому что человек уже молчит — поколение никто не
        // забирает, и метка висит. Её подбирает следующая, ни в чём не повинная диктовка, и молча
        // уезжает в историю вместо поля. В логе это выглядело так:
        //   16:51:40  отмена (Escape)
        //   16:51:40  тишина — пропуск            ← поколение не создано, метка осталась
        //   16:52:00  отменённая диктовка сохранена, 45 симв.   ← съело ЧУЖУЮ диктовку
        // Разрыв доходил до двух минут, поэтому связь никак не читалась.
        //
        // Escape тут не виноват: у автора хоткей диктовки ⌥`, а тильда прямо под Escape, задеть её
        // проще простого. Цена случайного нажатия должна быть нулевой, а не «съем следующую».
        //
        // ⚠️ Снимаем метку ТОЛЬКО в ветках раннего выхода, а НЕ здесь, до проверок. Отмена по
        // Escape зовёт `end()` сразу после того, как поставила метку, и снятие в начале функции
        // убило бы саму функцию «Отменённую всё равно сохранять»: текст поехал бы в поле, чего
        // человек как раз и не просил.

        // Слишком короткое нажатие (< 0.3 c) — просто отмена, без шума.
        guard recorder.duration >= 0.3 else { dropPendingHistoryOnly(); kbLog("voice: слишком коротко (\(String(format: "%.2f", recorder.duration))с) — отмена"); refreshIndicator(); return }
        // Тишина (нет сигнала) — не зовём whisper (иначе галлюцинации «Продолжение следует»).
        guard rms > 0.001 else {
            dropPendingHistoryOnly()
            kbLog("voice: тишина (RMS \(String(format: "%.4f", rms))) — пропуск (микрофон молчал — мог быть занят другим приложением)")
            refreshIndicator(); playCue(failSound)
            return
        }
        let lang = languageForWhisper()
        let useParakeet = settings.voiceEngine == "parakeet" && ParakeetEngine.modelInstalled
        // Холодный whisper (модели нет в памяти): загрузка крупной модели с незакэшированного
        // диска — секунды-десятки секунд, и она не должна съедать бюджет сторожа транскрипции.
        // ⚠️ ХОЛОДНАЯ ЗАГРУЗКА СЧИТАЕТСЯ ДЛЯ ОБОИХ ДВИЖКОВ (фикс 30.07). Раньше здесь стояло
        // `!useParakeet && whisper == nil`, то есть бюджет на загрузку получал ТОЛЬКО whisper, а у
        // паракита флаг не поднимался никогда. Между тем именно его первая загрузка самая долгая:
        // CoreML компилирует модель под ANE, замеры 37.5с (30.07) и 43с (21.07). Сторож при этом
        // давал 15 секунд, и первая диктовка после холодного паракита была не «медленной», а
        // ГАРАНТИРОВАННО потерянной: текст распознавался и приходил, но его отбрасывали как поздний.
        // Воспроизводится не на старте (там греет preload), а при смене движка в настройках на ходу.
        let cold = useParakeet ? !ParakeetEngine.shared.ready : (whisper == nil)
        let gen = beginTranscription(duration: recorder.duration, coldLoad: cold)
        refreshIndicator()   // НЕ setState(.processing) напрямую: отменённую диктовку считаем молча

        // Диагностика «почему медленно»: сразу видно, на каком движке распознаём и почему НЕ Parakeet
        // (whisper на CPU/Metal растёт с длиной аудио; Parakeet на ANE — почти мгновенный). Если тут
        // whisper при voiceEngine=parakeet — значит модель Parakeet не скачана (parakeetInstalled=false).
        kbLog("voice: движок=\(useParakeet ? "parakeet/ANE" : "whisper/CPU") · выбран=\(settings.voiceEngine) parakeetInstalled=\(ParakeetEngine.modelInstalled) whisperModel=\(settings.voiceModel)")
        if useParakeet {
            Task { [weak self] in
                guard let self else { return }
                let ok = await ParakeetEngine.shared.loadIfNeeded()
                // Язык передаём и в parakeet (03.08.2026). Раньше не передавали вовсе, и выбор
                // языка в настройках для этого движка не делал НИЧЕГО. Он и сейчас не выбирает
                // язык (модель этого не умеет), но включает фильтр по письменности — см. подробный
                // комментарий в ParakeetEngine.transcribe.
                let text = ok ? await ParakeetEngine.shared.transcribe(samples: samples, language: lang) : ""
                kbLog("voice: parakeet(готов=\(ok), язык=\(lang)) → \(text.count) симв.")
                await MainActor.run {
                    guard self.endTranscription(gen) else { return }   // сторож уже бросил — поздний результат в топку
                    self.deliver(text, historyOnly: self.historyOnlyGens.remove(gen) != nil)
                    self.refreshIndicator()
                }
            }
            return
        }
        // whisper — строго по одному (serial queue): новая ЗАПИСЬ при этом не блокируется.
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let modelReady = self.whisper != nil
            let text = self.whisper?.transcribe(samples: samples, language: lang) ?? ""
            kbLog("voice: whisper(модель=\(modelReady ? "ок" : "НЕТ"), \(lang)) → \(text.count) симв.")
            DispatchQueue.main.async {
                guard self.endTranscription(gen) else { return }   // сторож уже бросил — поздний результат в топку
                self.deliver(text, historyOnly: self.historyOnlyGens.remove(gen) != nil)
                self.refreshIndicator()
                self.scheduleModelRelease()   // простаиваем → вернём ~1.5 ГБ системе
            }
        }
    }

    /// СТОРОЖ ТРАНСКРИПЦИИ (репорт пользователя 23.07.2026: «Распознаю» зависла навечно, Keyboop
    /// не закрывался — пришлось перезагружать Мак). Инференс без таймаута = вечная плашка. По
    /// таймауту задачу БРОСАЕМ: счётчик/индикатор чинятся, поздний результат отбрасывается по
    /// генерации (гвард в completion), пользователю — честный тост вместо вечного «Распознаю».
    private func beginTranscription(duration: Double, streaming: Bool = false, coldLoad: Bool = false) -> Int {
        transcribing += 1
        transcribeGen += 1
        let gen = transcribeGen
        liveTranscriptions.insert(gen)
        var timeout = min(90, max(15, duration * 1.5))   // Parakeet/ANE — секунды; whisper растёт с длиной клипа
        if coldLoad { timeout += 60 }                    // +бюджет на холодную загрузку модели с диска
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.liveTranscriptions.remove(gen) != nil else { return }
            self.transcribing -= 1
            self.historyOnlyGens.remove(gen)   // иначе пометка «молча» пережила бы саму расшифровку
            kbLog("voice: транскрипция №\(gen) висит >\(Int(timeout))с — бросаю (поздний результат отброшу)")
            if streaming { self.streamingActive = false; self.typedTail = "" }   // застрявший финал не должен блокировать новые стримы
            VoiceIndicator.shared.showToast(L10n.t("voice.stuck"))
            self.refreshIndicator()
            // Попытка освободить возможно-отравленный движок. Если очередь реально висит —
            // задание просто не выполнится; выходу это не мешает (bounded unloadForTermination).
            self.transcribeQueue.async { [weak self] in self?.whisper = nil }
        }
        return gen
    }

    /// true = задача ещё живая (сторож не срабатывал) — результат можно доставлять.
    private func endTranscription(_ gen: Int) -> Bool {
        guard liveTranscriptions.remove(gen) != nil else { return false }
        transcribing -= 1
        return true
    }

    /// Индикатор после события: если сейчас пишем — recording; если ещё идёт транскрипция — processing;
    /// иначе — idle. Чтобы back-to-back диктовки не схлопывали индикатор раньше времени.
    ///
    /// ⚠️ ОТМЕНЁННАЯ ДИКТОВКА РАСПОЗНАЁТСЯ МОЛЧА (автор 31.07). Человек нажал Escape — для него
    /// диктовка закончилась, и всплывающая следом плашка «Распознаю» выглядит так, будто отмена не
    /// сработала. Текст всё равно посчитается и ляжет в историю, просто без показа процесса.
    /// Считаем по МНОЖЕСТВАМ, а не по счётчику: пока молчаливая расшифровка считается, человек уже
    /// мог начать обычную диктовку, и её плашку прятать нельзя. Плашка нужна, только если есть хотя
    /// бы одна живая расшифровка, которую ждут в поле.
    private func refreshIndicator() {
        if recorder.isRecording { setState(.recording) }
        else if liveTranscriptions.contains(where: { !historyOnlyGens.contains($0) }) { setState(.processing) }
        else { setState(.idle) }
    }

    // Свои звуковые метки записи (CueSynth): восходящее «тук-тук» на старте,
    // нисходящее — на стопе. Отличаются от звука конвертации. Инстансы держим
    // в свойствах (локальный NSSound освободился бы и оборвал звук). Подчиняются
    // общему переключателю звука и громкости (settings.soundEnabled / soundVolume).
    private let startSound = NSSound(data: CueSynth.startData)
    private let stopSound  = NSSound(data: CueSynth.stopData)
    private let failSound  = NSSound(data: CueSynth.failData)
    private func playCue(_ sound: NSSound?) {
        guard settings.voiceSoundEnabled, !Sounds.allMuted, let sound else { return }
        // Ноль на ползунке = не играть вовсе (задача #60): иначе ползунок врёт, а звук «есть,
        // но не слышно» ещё и будит аудиоустройство.
        let vol = max(0, min(1, settings.voiceSoundVolume))
        guard vol > 0 else { return }
        sound.stop()   // на случай быстрого повторного вызова — переиграть с начала
        sound.volume = Float(vol)
        sound.play()
    }

    /// Отмена текущей диктовки (Escape) — запись отбрасываем, ничего не вставляем.
    func cancel() {
        if starting && !recorder.isRecording {   // отмена во время async-старта — прерываем запуск
            abortStart = true; VoiceGate.set(false)
            kbLog("voice: отмена во время старта — прерываю запуск")
            return
        }
        guard recorder.isRecording else { VoiceGate.set(false); return }
        if streamingActive { streamCancel(); return }   // потоковый путь: стереть напечатанное
        // ОТМЕНА С СОХРАНЕНИЕМ В ИСТОРИЮ (R37, выключено по умолчанию). Человек просил: «нажал
        // Escape — пусть всё равно распознает и положит куда-нибудь». Идём ТЕМ ЖЕ путём, что и
        // обычное завершение, чтобы не заводить второй конвейер транскрипции со своими проверками
        // длительности, тишины и сторожем; отличие ровно одно и оно в самом конце — в поле ничего не
        // вставляем. Поколение помечаем в множестве, а не флагом: пока эта расшифровка считается,
        // человек уже может начать следующую диктовку, и перепутать их нельзя.
        if settings.escSaveToHistory {
            kbLog("voice: отмена (Escape) — распознаю и положу в историю, вставлять не буду")
            historyOnlyGens.insert(transcribeGen + 1)   // следующее поколение заведёт end()
            end()
            return
        }
        _ = recorder.stop()
        VoiceGate.set(false)
        refreshIndicator()
        playCue(failSound)   // мягкий нисходящий «отменено»
        kbLog("voice: диктовка отменена (Escape)")
    }

    // MARK: - Потоковая диктовка (EOU, экспериментально)

    /// Старт потоковой сессии: грузим/прогреваем EOU, заводим очередь чанков и единый потребитель.
    /// ВАЖНО (анти-гонки, ревью 2026-06-19): streamingActive выставляем ПОСЛЕДНИМ (после wiring), и
    /// после КАЖДОГО await пере-проверяем, что запись ещё идёт — иначе быстрый отпуск/тоггл оставит
    /// orphan-eouTask на мёртвом рекордере. Новая сессия ЖДЁТ финализацию прошлой (анти reset-во-время-finish).
    @MainActor private func streamBegin() async {
        guard await StreamingEouEngine.shared.loadIfNeeded() else {
            kbLog("voice: EOU не загрузилась → откат на батч"); return   // streamingActive=false → end() пойдёт батчем
        }
        guard recorder.isRecording, !abortStart else { await StreamingEouEngine.shared.cancelSession(); return }
        await streamFinalize?.value          // дождаться finish/reset прошлой сессии (общий singleton-актор)
        guard recorder.isRecording, !abortStart else { await StreamingEouEngine.shared.cancelSession(); return }
        await StreamingEouEngine.shared.startSession(onPartial: { [weak self] full in
            Task { @MainActor in self?.streamStep(full) }     // partial = ПОЛНЫЙ транскрипт → диффим
        })
        guard recorder.isRecording, !abortStart else { await StreamingEouEngine.shared.cancelSession(); return }
        typedTail = ""
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        eouChunks = cont
        recorder.setChunkHook { chunk in cont.yield(chunk) } // tap-поток → очередь (порядок сохраняется)
        eouTask = Task { for await chunk in stream { await StreamingEouEngine.shared.feed(chunk) } }
        streamingActive = true               // ПОСЛЕДНИМ: теперь end()/cancel() корректно увидят активный стрим
    }

    /// Применить новый полный транскрипт: стираем разошедшийся хвост, допечатываем новый.
    /// Печать — нашей синтетикой (маркер kbSyntheticMarker) → live-fix её не трогает.
    /// deleteCount ≤ typedTail.count (только наш текст) — дотекстовый ввод пользователя НЕ стираем.
    /// `commit: false` (по ходу речи) — только показываем текст на плашке, в поле НЕ пишем.
    /// `commit: true` (финал) — печатаем разницу, то есть весь текст сразу, раз до этого не печатали.
    ///
    /// ⚠️ ПОЧЕМУ БОЛЬШЕ НЕ ПЕЧАТАЕМ НА ЛЕТУ (решение автора 30.07). Потоковая расшифровка постоянно
    /// переписывается, пока модель уточняет гипотезу, и печать «в реальном времени» означала писать
    /// и тут же стирать текст в чужом документе. К тому же в Electron-приложениях наша синтетика
    /// игнорируется, поэтому там фича не работала вовсе: автор включил её, продиктовал и не увидел
    /// ничего. Диффу это ничего не ломает — `typedTail` остаётся пустым до финала, и финальный вызов
    /// печатает всю фразу одним куском, ровно как обычная батч-диктовка.
    @MainActor private func streamStep(_ full: String, commit: Bool = false) {
        guard streamingActive else { return }
        VoiceIndicator.shared.showLive(full)
        guard commit else { return }
        let common = typedTail.commonPrefix(with: full).count
        let deleteCount = typedTail.count - common
        let toType = String(Array(full).suffix(full.count - common))
        guard deleteCount > 0 || !toType.isEmpty else { return }
        TextReplacer.replace(deleteCount: deleteCount, with: toType)
        typedTail = full
    }

    /// Финал: дослать остаток, сверить с финальным текстом, закоммитить (пробел+история+уведомление ОДИН раз).
    /// recorder.stop() делает end()/cancel() no-op'ами (не recording) → нет реентерабельного финала.
    /// streamingActive держим true ДО конца финала (чтобы финальный streamStep напечатал), сбрасываем в самом конце.
    private func streamEnd() {
        recorder.setChunkHook(nil)
        eouChunks?.finish(); eouChunks = nil
        _ = recorder.stop()
        VoiceGate.set(false)
        playCue(stopSound)
        let gen = beginTranscription(duration: recorder.duration, streaming: true)
        setState(.processing)
        let task = eouTask; eouTask = nil
        streamFinalize = Task { [weak self] in
            guard let self else { return }
            await task?.value                                 // дождаться, пока скормятся все чанки
            let final = await StreamingEouEngine.shared.finishSession()
            await MainActor.run {
                self.streamStep(final, commit: true)           // ЕДИНСТВЕННОЕ место, где стрим печатает
                let clean = self.typedTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    if TextReplacer.secureInputActive {
                        // Финал пришёлся на поле пароля: хвост не досылаем (streamStep выше уже
                        // пропущен гвардом в TextReplacer), текст сохраняем и честно говорим.
                        kbLog("voice: secure input на финале стриминга — текст в истории")
                        VoiceIndicator.shared.showToast(L10n.t("voice.securePwd"))
                    } else {
                        TextReplacer.insert(" ") {                  // пробел в конце, как в батч-deliver()
                            NotificationCenter.default.post(name: .keyboopVoiceInserted, object: nil)
                        }
                    }
                    VoiceHistory.shared.add(clean)             // в историю — ОДИН раз, на финале
                    kbLog("voice: стриминг завершён, \(clean.count) симв.")
                    self.noteVoiceStats(clean)                 // статистика — тоже один раз, на финале
                } else {
                    playCue(failSound)
                }
                self.streamingActive = false; self.typedTail = ""
                if self.endTranscription(gen) { self.refreshIndicator() }
            }
        }
    }

    /// Отмена потоковой диктовки (Escape): стереть уже напечатанное, ничего не коммитить.
    private func streamCancel() {
        recorder.setChunkHook(nil)
        eouChunks?.finish(); eouChunks = nil
        _ = recorder.stop()
        VoiceGate.set(false)
        streamingActive = false   // отмена: партиалы больше не принимаем (streamStep сразу выйдет)
        if !typedTail.isEmpty { TextReplacer.replace(deleteCount: typedTail.count, with: "") }
        let n = typedTail.count; typedTail = ""
        let task = eouTask; eouTask = nil
        streamFinalize = Task { await task?.value; await StreamingEouEngine.shared.cancelSession() }
        refreshIndicator()
        playCue(failSound)
        kbLog("voice: стриминг отменён, стёрто \(n) симв.")
    }

    /// Текущее состояние записи (для кнопки в окне истории).
    var isRecording: Bool { recorder.isRecording }
    /// Запись по кнопке (toggle): не активна → старт; активна → стоп. Опирается на isActive
    /// (синхронный), а не isRecording — иначе быстрый второй тап во время async-старта рассинхронит.
    func toggleRecording() {
        if isActive { kbLog("voice: toggle → СТОП"); end() }
        else { kbLog("voice: toggle → СТАРТ"); begin() }
    }

    /// Единая точка смены состояния: статус-бар (onStateChange) + плашка у курсора.
    private func setState(_ s: State) {
        onStateChange?(s)
        // ГРОМКОСТЬ ПРИГЛУШАЕМ ЗДЕСЬ, а не рядом с recorder.start()/stop() (30.07). Выходов из
        // записи много: обычный конец, Escape, слишком короткое нажатие, тишина, смерть устройства,
        // прерванный старт. Развесить restore() по каждому — гарантированно забыть один и оставить
        // человеку тихий Mac. Смена состояния же одна на всех: ушли из .recording — вернули громкость.
        switch s {
        case .recording:
            if settings.voiceDuck { SystemVolume.duck(to: Float(settings.voiceDuckLevel) / 100) }
            VoiceIndicator.shared.showRecording()
        case .processing:
            SystemVolume.restore()          // распознавание идёт в фоне, слушать музыку уже можно
            VoiceIndicator.shared.showProcessing()
        case .idle:
            SystemVolume.restore()
            VoiceIndicator.shared.hide()
        }
    }

    /// Опции вывода (#41). Порядок важен: сначала убираем точку, потом регистр — иначе строка из
    /// одной буквы с точкой («А.») после снятия точки осталась бы заглавной.
    ///
    /// Точку снимаем ТОЛЬКО одиночную в самом конце и только её: «...» и «?»/«!» не трогаем, они
    /// несут смысл, а многоточие вдобавок часто ставит сама модель на оборванной фразе.
    /// Регистр опускаем ТОЛЬКО у первой буквы и только если вторая — строчная: иначе аббревиатуры
    /// («МФЦ», «ГОСТ») превратились бы в «мФЦ». Это тот случай, где «умное» правило без оговорки
    /// портит редкий, но заметный ввод.
    static func applyOutputOptions(_ text: String) -> String {
        let s = AppSettings.shared
        var out = text
        if s.voiceNoFinalPeriod, out.hasSuffix("."), !out.hasSuffix("..") {
            out.removeLast()
            out = String(out.reversed().drop { $0 == " " }.reversed())
        }
        if s.voiceNoCapital, let first = out.first, first.isUppercase {
            let second = out.dropFirst().first
            if second == nil || !(second!.isUppercase) {
                out = first.lowercased() + out.dropFirst()
            }
        }
        return out
    }

    private func deliver(_ text: String, historyOnly: Bool = false) {
        // Фразы-призраки Whisper («Субтитры создавал…», «Продолжение следует») — отсекаем ДО всего
        // остального, чтобы они не попали ни в поле, ни в историю, ни в статистику. См. WhisperGhosts.
        let clean = WhisperGhosts.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Диктовку отменили по Escape, но человек попросил её всё-таки сохранять (R37). В поле не
        // пишем ничего: Escape означает «не вставляй». Кладём в историю и говорим об этом тостом,
        // иначе сохранение выглядело бы как то, что программа проигнорировала отмену.
        if historyOnly {
            guard !clean.isEmpty else { kbLog("voice: отменённая диктовка пустая — в историю нечего класть"); return }
            VoiceHistory.shared.add(clean)
            noteVoiceStats(clean)
            kbLog("voice: отменённая диктовка сохранена в историю, \(clean.count) симв.")
            VoiceIndicator.shared.showToast(L10n.t("voice.escSaved"))
            return
        }
        guard !clean.isEmpty else {
            kbLog("voice: пустой результат — ничего не вставляю")
            playCue(failSound)   // мягкий нисходящий сигнал «не вышло», чтобы не было тихо
            return
        }
        // Поле пароля/системный диалог украли фокус (инцидент 23.07.2026): печатать нельзя,
        // но распознанное НЕ теряем — история + честный тост вместо молчаливой пропажи.
        if TextReplacer.secureInputActive {
            kbLog("voice: активен secure input — не печатаю \(clean.count) симв., текст в истории")
            VoiceHistory.shared.add(clean)
            noteVoiceStats(clean)
            VoiceIndicator.shared.showToast(L10n.t("voice.securePwd"))
            return
        }
        // Диагностика «пропадает пунктуация» (10.07): считаем ЗНАКИ ПРЕПИНАНИЯ в выводе (только счётчик,
        // не контент). По логу видно, когда распознавание пришло «сплошняком» (пунктуация=0) — на любом
        // движке. Корень исследован (whisper «no-punctuation mode» / Parakeet не эмитит знак-токены на
        // тихих хвостах). Коррелировать с длительностью/noSpeechMax из строк выше.
        let punct = clean.reduce(0) { $0 + (".,!?;:…—–".contains($1) ? 1 : 0) }
        kbLog("voice: распознано \(clean.count) симв., пунктуация=\(punct)")
        noteVoiceStats(clean)
        // Пробел в конце — чтобы следующая фраза не слиплась с этой (предложил пользователь).
        // insert — async на serial-очереди; notification шлём в completion (после постинга), чтобы Engine
        // очистил буфер не раньше времени: надиктованный текст не должен попасть в групповую конвертацию (G3).
        // Авто-Enter гасит хвостовой пробел: « текст » + Enter отправляет сообщение с пробелом на
        // конце, и это видно получателю. Настройку пробела при этом НЕ трогаем — человек включит
        // авто-Enter, потом выключит, и его выбор про пробел должен вернуться (тот же принцип, что
        // с громкостями при «Звуки выкл»).
        let autoEnter = settings.voiceAutoEnter
        let out = Self.applyOutputOptions(clean) + ((settings.voiceTrailingSpace && !autoEnter) ? " " : "")
        TextReplacer.insert(out, thenReturn: autoEnter,
                            returnMods: CGEventFlags(rawValue: settings.voiceAutoEnterMods)) {
            NotificationCenter.default.post(name: .keyboopVoiceInserted, object: nil)
        }
        VoiceHistory.shared.add(clean)
    }

    /// Копим статистику «надиктовано» для счётчика в «О программе». Считаем ТОЛЬКО длину и число слов —
    /// сам текст не сохраняем (принцип №2). Зовётся один раз на удачную вставку: из deliver() (батч)
    /// и с финала стриминга (партиалы не считаем, иначе одна фраза учлась бы многократно).
    private func noteVoiceStats(_ clean: String) {
        settings.voiceChars += clean.count
        settings.voiceWords += clean.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Отложенная выгрузка модели Whisper из памяти (см. scheduleModelRelease).
    private var modelIdleRelease: DispatchWorkItem?

    private func loadModelIfNeeded() {
        DispatchQueue.main.async { self.modelIdleRelease?.cancel(); self.modelIdleRelease = nil }
        if whisper == nil {
            let t0 = ProcessInfo.processInfo.systemUptime
            whisper = WhisperBridge(modelPath: Self.modelPath(settings.voiceModel))
            if whisper == nil { kbLog("voice: модель не загрузилась") }
            else { kbLog("voice: модель Whisper загружена за \(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))мс") }
        }
    }

    /// СТРАХОВОЧНАЯ выгрузка модели после ДОЛГОГО простоя (осн. триггер — memory pressure, см. выше).
    /// Модель large-v3-turbo — ~1.5 ГБ физической памяти, и до 0.2.58 она висела там ВЕЧНО (замер:
    /// phys_footprint 1833 МБ у фоновой утилиты). Дефолт интервала — 60 мин (5 мин в 0.2.58 было
    /// регрессией: перегрузка почти на каждую диктовку). 0 = держать всегда.
    /// Выгружаем ТОЛЬКО когда реально простаиваем: идёт запись/транскрипция → откладываем.
    private func scheduleModelRelease() {
        modelIdleRelease?.cancel(); modelIdleRelease = nil
        let minutes = settings.voiceModelIdleMinutes
        guard minutes > 0, whisper != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transcribing == 0, !self.isActive, !self.recorder.isRecording else {
                self.scheduleModelRelease(); return   // занят — отложим ещё на интервал
            }
            self.transcribeQueue.async { [weak self] in
                self?.whisper = nil                   // deinit → whisper_free → ~1.5 ГБ обратно системе
                kbLog("voice: модель Whisper выгружена после \(minutes) мин простоя — память освобождена")
            }
        }
        modelIdleRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60, execute: work)
    }

    /// Язык для whisper — из настроек (по умолчанию язык ОС, НЕ раскладки). "auto" → whisper определит.
    private func languageForWhisper() -> String { settings.voiceLanguage }

    /// Синхронно освободить модель ПЕРЕД выходом из процесса (applicationWillTerminate).
    /// Swift не запускает deinit при exit(), поэтому без этого whisper_free не случался и Metal-буферы
    /// «утекали» за exit — статический деструктор ggml бил ассерт → SIGABRT при квите (краш 20.07).
    /// GGML_METAL_NO_RESIDENCY=1 (main.swift) уже делает ассерт невозможным; это — второй слой,
    /// санкционированный апстримом путь (llama.cpp #19137: «free your context before exit»).
    /// sync на transcribeQueue: дожидается in-flight транскрипции (редкий случай — квит прямо во
    /// время распознавания добавит к выходу её хвост, приемлемо).
    func unloadForTermination() {
        modelIdleRelease?.cancel(); modelIdleRelease = nil
        // ОГРАНИЧЕННОЕ ожидание: безусловный sync при зависшем инференсе вешал ВЫХОД навечно —
        // плашка «Распознаю» оставалась, Док-квит молчал, пользователь перезагружал Мак (репорт
        // 23.07.2026). Ждём выгрузку максимум 2с: GGML_METAL_NO_RESIDENCY уже прикрывает ggml-ассерт
        // на выходе, а невозможность выйти строго хуже теоретического abort при exit.
        let sem = DispatchSemaphore(value: 0)
        transcribeQueue.async { [weak self] in self?.whisper = nil; sem.signal() }
        if sem.wait(timeout: .now() + 2.0) == .timedOut {
            kbLog("voice: транскрипция висит — выходим, не дожидаясь выгрузки модели")
        }
    }
}
