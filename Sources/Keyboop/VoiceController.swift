import AppKit

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
    private(set) var isActive = false
    /// Сериализация транскрипции: новая ЗАПИСЬ может начаться, пока прошлая транскрибируется
    /// (запись и whisper независимы), но сами whisper-вызовы — строго по одному (не реентерабельно).
    private let transcribeQueue = DispatchQueue(label: "ru.keyboop.voice.transcribe")
    private var transcribing = 0   // сколько клипов сейчас в транскрипции (для индикатора)

    enum State { case idle, recording, processing }
    var onStateChange: ((State) -> Void)?

    /// Предзагрузка модели в фоне (на старте приложения, если голос включён и модель есть) — чтобы
    /// ПЕРВОЕ нажатие диктовки не платило за загрузку (частая причина «не сработало с первого раза»).
    func preload() {
        guard settings.voiceEnabled, hasUsableModel else { return }
        transcribeQueue.async { [weak self] in self?.loadModelIfNeeded() }
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
        isActive = true            // СИНХРОННО: намерение записывать — toggle сразу видит активность
        starting = true
        abortStart = false
        Task { @MainActor in
            defer { starting = false }
            // Доступ к микрофону — ПЕРВЫМ (даже без модели), чтобы новый юзер увидел системный промпт.
            guard await AudioRecorder.requestAccess() else {
                kbLog("voice: нет доступа к микрофону"); NSSound.beep(); isActive = false; return
            }
            if abortStart { kbLog("voice: старт прерван (отпустили до начала записи)"); isActive = false; setState(.idle); return }
            guard hasUsableModel else {
                kbLog("voice: нет модели распознавания — предлагаем скачать")
                isActive = false; onNeedModel?(); return
            }
            loadModelIfNeeded()
            if abortStart { isActive = false; setState(.idle); return }
            do {
                try recorder.start()
                if abortStart {        // отпустили ровно в момент старта — стоп немедленно
                    _ = recorder.stop(); isActive = false; setState(.idle); return
                }
                setState(.recording)
                playCue(startSound)    // восходящее «тук-тук» — пошла запись
            } catch {
                kbLog("voice: старт записи не удался: \(error)")
                isActive = false; setState(.idle)
            }
        }
    }

    /// Отпустили хоткей — стоп, транскрипция, вставка.
    func end() {
        // Отпустили/нажали стоп ДО того как async-begin реально завёл запись — прерываем старт.
        if starting && !recorder.isRecording {
            abortStart = true; isActive = false
            kbLog("voice: end во время старта — прерываю запуск (запись ещё не пошла)")
            return
        }
        guard recorder.isRecording else { isActive = false; return }
        let samples = recorder.stop()
        isActive = false      // ЗАПИСЬ окончена → можно сразу начинать НОВУЮ (транскрипция идёт в фоне)
        playCue(stopSound)    // нисходящее «тук-тук» — запись остановлена (до транскрипции)
        let rms = samples.isEmpty ? 0 : (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        kbLog("voice: \(samples.count) сэмплов, \(String(format: "%.1f", recorder.duration))с, RMS=\(String(format: "%.4f", rms))")
        // Слишком короткое нажатие (< 0.3 c) — просто отмена, без шума.
        guard recorder.duration >= 0.3 else { kbLog("voice: слишком коротко (\(String(format: "%.2f", recorder.duration))с) — отмена"); refreshIndicator(); return }
        // Тишина (нет сигнала) — не зовём whisper (иначе галлюцинации «Продолжение следует»).
        guard rms > 0.001 else {
            kbLog("voice: тишина (RMS \(String(format: "%.4f", rms))) — пропуск (микрофон молчал — мог быть занят другим приложением)")
            refreshIndicator(); playCue(failSound)
            return
        }
        transcribing += 1
        setState(.processing)
        let lang = languageForWhisper()
        let useParakeet = settings.voiceEngine == "parakeet" && ParakeetEngine.modelInstalled
        if useParakeet {
            Task { [weak self] in
                guard let self else { return }
                let ok = await ParakeetEngine.shared.loadIfNeeded()
                let text = ok ? await ParakeetEngine.shared.transcribe(samples: samples) : ""
                kbLog("voice: parakeet(готов=\(ok)) → \(text.count) симв.")
                await MainActor.run { self.transcribing -= 1; self.deliver(text); self.refreshIndicator() }
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
                self.transcribing -= 1
                self.deliver(text)
                self.refreshIndicator()
            }
        }
    }

    /// Индикатор после события: если сейчас пишем — recording; если ещё идёт транскрипция — processing;
    /// иначе — idle. Чтобы back-to-back диктовки не схлопывали индикатор раньше времени.
    private func refreshIndicator() {
        if recorder.isRecording { setState(.recording) }
        else if transcribing > 0 { setState(.processing) }
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
        guard settings.voiceSoundEnabled, let sound else { return }
        sound.stop()   // на случай быстрого повторного вызова — переиграть с начала
        sound.volume = Float(max(0, min(1, settings.voiceSoundVolume)))
        sound.play()
    }

    /// Отмена текущей диктовки (Escape) — запись отбрасываем, ничего не вставляем.
    func cancel() {
        if starting && !recorder.isRecording {   // отмена во время async-старта — прерываем запуск
            abortStart = true; isActive = false
            kbLog("voice: отмена во время старта — прерываю запуск")
            return
        }
        guard recorder.isRecording else { isActive = false; return }
        _ = recorder.stop()
        isActive = false
        refreshIndicator()
        playCue(failSound)   // мягкий нисходящий «отменено»
        kbLog("voice: диктовка отменена (Escape)")
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
        switch s {
        case .recording:  VoiceIndicator.shared.showRecording()
        case .processing: VoiceIndicator.shared.showProcessing()
        case .idle:       VoiceIndicator.shared.hide()
        }
    }

    private func deliver(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            kbLog("voice: пустой результат — ничего не вставляю")
            playCue(failSound)   // мягкий нисходящий сигнал «не вышло», чтобы не было тихо
            return
        }
        kbLog("voice: распознано \(clean.count) симв.")
        // Пробел в конце — чтобы следующая фраза не слиплась с этой (предложил пользователь).
        // insert — async на serial-очереди; notification шлём в completion (после постинга), чтобы Engine
        // очистил буфер не раньше времени: надиктованный текст не должен попасть в групповую конвертацию (G3).
        TextReplacer.insert(clean + " ") {
            NotificationCenter.default.post(name: .keyboopVoiceInserted, object: nil)
        }
        VoiceHistory.shared.add(clean)
    }

    private func loadModelIfNeeded() {
        if whisper == nil {
            whisper = WhisperBridge(modelPath: Self.modelPath(settings.voiceModel))
            if whisper == nil { kbLog("voice: модель не загрузилась") }
        }
    }

    /// Язык для whisper — из настроек (по умолчанию язык ОС, НЕ раскладки). "auto" → whisper определит.
    private func languageForWhisper() -> String { settings.voiceLanguage }
}
