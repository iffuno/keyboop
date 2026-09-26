import AVFoundation
import AppKit
import CoreAudio

// ЗАПИСЬ ЗВОНКА НА MAC (задача 230, 04.09.2026). Захват и конвейер.
//
// автор выбрал Core Audio process tap (macOS 14.2+), а не ScreenCaptureKit: тап отдаёт звук всех
// программ без «Записи экрана», а микрофон подключается к тому же агрегатному устройству, и оба
// потока идут по одним часам с компенсацией дрейфа. Дальше всё как у импорта файла: моно 16 кГц,
// `AudioChunker` режет по тишине, куски уходят в общий движок, текст собирается с абзацами.
//
// Функция скрытая: ⌥-клик по значку в строке меню начинает и останавливает запись, на значке
// красный кружок, ни настроек, ни пункта меню. Разрешение на запись системного звука macOS
// спрашивает сама при первом тапе (текст в `NSAudioCaptureUsageDescription`).
//
// Что делается ради «сказанное потом не восстановить»: сегменты по две минуты на диске, сторож
// потока с перезапуском захвата, добор незавершённой сессии при следующем старте, автостоп по
// тишине только после вопроса. В лог не идут ни имена файлов, ни текст: длительности и счётчики.

// MARK: - Захват: тап + микрофон одним агрегатным устройством

@available(macOS 14.2, *)
final class SystemAudioCapture {
    enum CaptureError: Error { case tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus) }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48_000
    private let queue: DispatchQueue
    private let onSamples: ([Float]) -> Void

    /// `queue` — очередь, на которой приходят буферы: CoreAudio сам диспатчит IO-блок на неё,
    /// поэтому внутри можно ресемплировать и писать файлы, не трогая realtime-поток.
    init(queue: DispatchQueue, onSamples: @escaping ([Float]) -> Void) {
        self.queue = queue
        self.onSamples = onSamples
    }

    func start(micUID: String?) throws { try prepare(micUID: micUID); try run() }

    /// Тап и агрегатное устройство: после этого известна частота, а звука ещё нет.
    func prepare(micUID: String?) throws {
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "Keyboop call tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw CaptureError.tap(st) }
        tapID = tap

        var subDevices: [[String: Any]] = []
        if let mic = micUID {
            subDevices.append([kAudioSubDeviceUIDKey: mic, kAudioSubDeviceDriftCompensationKey: true])
        }
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Keyboop Call",
            kAudioAggregateDeviceUIDKey: "ru.keyboop.call." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            // ⚠️ `kAudioAggregateDeviceTapAutoStartKey` УБРАН НАМЕРЕННО (13.09.2026, отзыв #269).
            // Заголовок Apple (AudioHardware.h): «calling AudioDeviceStart with the aggregate device
            // will wait until a tapped process begins receiving its first audio from any tapped
            // applications». То есть с этим ключом старт откладывается до первого звука В СИСТЕМЕ, и
            // до тех пор обработчик не зовётся ВООБЩЕ — молчит и микрофонный сабдевайс тоже.
            //
            // Что это стоило человеку: он включал запись в тишине, чтобы проверить функцию, и каждый
            // раз получал «в записи не нашлось речи». В логе это выглядело как «микрофон есть, 48000
            // Гц» и следом ноль кадров. Функция работала бы только если начать запись ПОСЛЕ того,
            // как собеседник заговорил, и об этом нигде не сказано.
            //
            // Второй, менее очевидный ущерб: macOS спрашивает разрешение на запись системного звука
            // при ПЕРВОМ РЕАЛЬНОМ СТАРТЕ агрегата с тапом. Отложенный старт означает, что диалога
            // человек может не увидеть никогда — он честно пишет «все разрешения выданы», потому что
            // то, которого не хватает, у него никто не спрашивал.
            //
            // Без ключа старт происходит сразу: микрофон пишется с первой секунды, системный звук
            // подмешивается, когда появится, а диалог разрешения всплывает тогда же, когда человек
            // нажал на запись.
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]],
        ]
        // Микрофон задаёт часы: у него настоящий аппаратный тактовый генератор, а тап подстраивается.
        if let mic = micUID { dict[kAudioAggregateDeviceMainSubDeviceKey] = mic }
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap); tapID = kAudioObjectUnknown
            throw CaptureError.aggregate(st)
        }
        aggregateID = agg
        sampleRate = AudioDevices.nominalSampleRate(agg) ?? 48_000
    }

    /// IO-блок и старт устройства: с этого момента идут буферы.
    func run() throws {
        let agg = aggregateID
        guard agg != kAudioObjectUnknown else { throw CaptureError.start(-1) }
        var proc: AudioDeviceIOProcID? = nil
        var st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard st == noErr, let p = proc else { teardown(); throw CaptureError.ioProc(st) }
        procID = p
        st = AudioDeviceStart(agg, p)
        guard st == noErr else { teardown(); throw CaptureError.start(st) }
    }

    func stop() { teardown() }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
                procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Каждый входной буфер это один поток (микрофон или тап) с чередующимися каналами;
    /// сводим все в моно и складываем.
    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var sources: [[Float]] = []
        for buf in list {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.assumingMemoryBound(to: Float.self)
            let arr = Array(UnsafeBufferPointer(start: ptr, count: count))
            sources.append(MonoMixer.monoFromInterleaved(arr, channels: max(1, Int(buf.mNumberChannels))))
        }
        notePerStreamLevels(sources)
        let mono = MonoMixer.mix(sources)
        if !mono.isEmpty { onSamples(mono) }
    }

    /// ГРОМКОСТЬ КАЖДОГО ПОТОКА ОТДЕЛЬНО — ЕДИНСТВЕННЫЙ СПОСОБ УЗНАТЬ ПРО РАЗРЕШЕНИЕ (13.09.2026).
    ///
    /// Спросить систему, разрешена ли нам запись системного звука, нельзя: API не существует, и это
    /// сказано инженером Apple прямым текстом (форум 756783, «There is no API to determine whether
    /// an app still has permission to capture system audio… In some situations, you might be able to
    /// detect if a tap is silent by measuring the loudness of the incoming buffers»). Без разрешения
    /// всё возвращает `noErr` и отдаёт тишину: так сделано нарочно, чтобы вредонос не мог отличить
    /// отказ от молчания.
    ///
    /// Поэтому меряем сами. Порядок потоков в агрегате повторяет состав: сначала сабдевайсы
    /// (микрофон), потом тапы. Когда микрофон есть, поток 0 это он, поток 1 это системный звук.
    /// Допущение записано здесь, а не подразумевается: если Apple когда-нибудь переставит порядок,
    /// сломается диагностика, а не запись.
    private func notePerStreamLevels(_ sources: [[Float]]) {
        for (i, s) in sources.enumerated() where !s.isEmpty {
            var peak: Float = 0
            for v in s { let a = abs(v); if a > peak { peak = a } }
            if peak > 0.002 { heardStreams.insert(i) }      // −54 dBFS: тише этого и человека не слышно
        }
        streamCount = max(streamCount, sources.count)
    }

    /// Какие потоки хоть раз дали звук за эту запись, и сколько их было. Читает `CallRecorder`,
    /// чтобы на финале сказать человеку правду, а не «речи не нашлось».
    private(set) var heardStreams = Set<Int>()
    private(set) var streamCount = 0
}

// MARK: - Ресемплер в 16 кГц

/// Моно Float32 с частоты устройства в 16 кГц движка. Состояние конвертера живёт между вызовами,
/// поэтому границы буферов стыкуются без щелчков.
final class MonoResampler {
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    let inputRate: Double

    init?(from rate: Double) {
        guard let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioImportPolicy.sampleRate),
                                    channels: 1, interleaved: false) else { return nil }
        inputRate = rate
        inFormat = i; outFormat = o
        converter = rate == o.sampleRate ? nil : AVAudioConverter(from: i, to: o)
        if rate != o.sampleRate && converter == nil { return nil }
    }

    func convert(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let src = inBuf.floatChannelData?[0] else { return [] }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.update(from: $0.baseAddress!, count: samples.count) }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var given = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true; outStatus.pointee = .haveData; return inBuf
        }
        guard status != .error, let out = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: out, count: Int(outBuf.frameLength)))
    }
}

// MARK: - Рекордер

final class CallRecorder {
    static let shared = CallRecorder()

    enum StopReason { case user, silence, stalled, termination }

    private let processing = DispatchQueue(label: "ru.keyboop.call.audio", qos: .userInitiated)
    private let transcribing = DispatchQueue(label: "ru.keyboop.call.transcribe", qos: .userInitiated)
    /// ⚠️ Захват поднимаем и гасим ЗДЕСЬ, а не на processing. IO-блоки CoreAudio диспатчатся на
    /// processing, и AudioDeviceStop / DestroyIOProcID, вызванные оттуда, ждут завершения цикла,
    /// который сами же и заняли. Первая тестовая запись 04.09 так и повисла на остановке: сегмент
    /// не закрылся, файл остался без заголовка, сессия осталась «recording».
    private let control = DispatchQueue(label: "ru.keyboop.call.control", qos: .userInitiated)
    private var capture: AnyObject?
    private var resampler: MonoResampler?
    private var chunker = AudioChunker()
    private var planner = SegmentPlanner()
    private var silence = SilenceWatch(startAt: 0)
    /// Сколько целых минут тишины уже отмечено в логе (чтобы писать раз в минуту, а не на каждый буфер).
    private var lastSilenceLogMinute = 0
    private var watchdog = StreamWatchdog(startAt: 0)
    private var envelope = LiveEnvelope()
    private var pieces: [TranscriptAssembler.Piece] = []     // только на очереди transcribing
    private var chunksDone = 0
    private var session: CallSession?
    private var sessionDir: URL?
    private var segmentFile: AVAudioFile?
    private var recordedFrames = 0
    private var watchTimer: Timer?
    private var stopping = false
    private var micUID: String?
    /// Читается с главного потока (меню, ⌥-клик).
    private(set) var isRecording = false
    /// Запись ИЛИ её хвост: после stop() последние куски ещё расшифровываются, и модель им нужна.
    /// Этим признаком выгрузка модели после диктовки понимает, что звонок её пока держит.
    var isBusy: Bool { isRecording || stopping }
    private let chunkTimeout: TimeInterval = 180

    private init() {}

    private static var callsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/calls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    // MARK: старт и стоп

    /// ⌥-клик по значку: начать или остановить.
    func toggle() {
        if isRecording { stop(.user) } else { start() }
    }

    func start() {
        // Каждый отказ пишем в лог (26.09.2026): раньше эти выходы молчали, и «запись не начинается»
        // нельзя было отличить от «клик до нас не дошёл».
        guard !isRecording, !stopping else {
            kbLog("звонок: не начинаю, уже \(isRecording ? "идёт запись" : "дописывается прошлая")"); return
        }
        guard #available(macOS 14.2, *) else {
            kbLog("звонок: не начинаю, нужна macOS 14.2")
            VoiceIndicator.shared.showToast(L10n.t("call.unavailable")); return
        }
        guard AppSettings.shared.voiceHistoryEnabled else {
            kbLog("звонок: не начинаю, история выключена")
            VoiceIndicator.shared.showToast(L10n.t("hist.importNoHistory")); return
        }
        guard VoiceController.shared.hasUsableModel else {
            kbLog("звонок: не начинаю, нет модели распознавания")
            VoiceController.shared.onNeedModel?(); return
        }
        if let free = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64,
           free < CallRecordingPolicy.minFreeBytes {
            VoiceIndicator.shared.showToast(L10n.t("call.noSpace")); return
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Mac"
        let s = CallSession.fresh(app: app)
        let dir = Self.callsDir.appendingPathComponent(s.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            kbLog("звонок: папка сессии не создалась (\(error))"); return
        }
        session = s; sessionDir = dir; save(s)
        let pinned = AppSettings.shared.voiceMicUID
        micUID = pinned.isEmpty ? AudioDevices.systemDefaultInputUID() : pinned
        isRecording = true; stopping = false
        MenuBarController.shared?.setCallRecording(true)
        let now = ProcessInfo.processInfo.systemUptime
        processing.sync { [self] in
            chunker = AudioChunker(); planner = SegmentPlanner(); envelope = LiveEnvelope()
            silence = SilenceWatch(startAt: now); watchdog = StreamWatchdog(startAt: now)
            recordedFrames = 0; chunksDone = 0
        }
        transcribing.async { [self] in pieces.removeAll() }
        control.async { [self] in
            if let err = openCapture() {
                DispatchQueue.main.async { self.captureFailed(err) }
                return
            }
            DispatchQueue.main.async {
                self.startWatchdog()
                VoiceIndicator.shared.showToast(L10n.t("call.started"))
                kbLog("звонок: запись началась, микрофон \(self.micUID == nil ? "нет" : "есть"), частота \(Int(self.resampler?.inputRate ?? 0)) Гц")
            }
        }
    }

    /// На очереди control. nil — захват поднят. Ресемплер выставляется ДО старта IO, чтобы первые
    /// буферы не попали в конвертер с чужой частотой.
    private func openCapture() -> Error? {
        guard #available(macOS 14.2, *) else {
            return NSError(domain: "ru.keyboop.call", code: -1, userInfo: [NSLocalizedDescriptionKey: "macOS < 14.2"])
        }
        let cap = SystemAudioCapture(queue: processing) { [weak self] mono in self?.ingest(mono) }
        do {
            try cap.prepare(micUID: micUID)
            let rate = cap.sampleRate
            processing.sync { [self] in
                if resampler == nil || resampler?.inputRate != rate { resampler = MonoResampler(from: rate) }
            }
            try cap.run()
        } catch { cap.stop(); return error }
        capture = cap
        return nil
    }

    /// РАЗДЕЛ НАСТРОЕК, КУДА ВЕСТИ ЧЕЛОВЕКА ЗА РАЗРЕШЕНИЕМ НА СИСТЕМНЫЙ ЗВУК.
    ///
    /// ⚠️ Адрес сменился, и старый ведёт не туда (проверено на macOS 26.3, 13.09.2026). Раздел
    /// теперь живёт внутри «Запись экрана и системного звука» отдельным списком «Только запись
    /// системного звука», а панель приватности переехала в расширение настроек. Старый якорь
    /// `com.apple.preference.security?Privacy_AudioCapture` открывал общие настройки, и человек
    /// включал не тот переключатель либо не находил ничего. Пробуем новый, при неудаче старый.
    static func openAudioCaptureSettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        for s in [modern, legacy] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    private func captureFailed(_ error: Error) {
        kbLog("звонок: захват не поднялся (\(error))")
        isRecording = false
        MenuBarController.shared?.setCallRecording(false)
        if let dir = sessionDir { try? FileManager.default.removeItem(at: dir) }
        session = nil; sessionDir = nil
        AppBanner.shared.show(title: L10n.t("call.noPermissionTitle"), body: L10n.t("call.noPermissionBody"),
                              actions: [AppBanner.Action(title: L10n.t("call.noPermissionOpen"), coral: true) {
                                  CallRecorder.openAudioCaptureSettings()
                              }], autoDismiss: 20)
    }

    func stop(_ reason: StopReason) {
        guard isRecording, !stopping else { return }
        stopping = true
        isRecording = false
        MenuBarController.shared?.setCallRecording(false)
        watchTimer?.invalidate(); watchTimer = nil
        if reason == .silence { AppBanner.shared.dismiss() }
        kbLog("звонок: остановка (\(reason)), записано \(ImportProgressFormat.clock(Double(recordedFrames) / Double(AudioImportPolicy.sampleRate)))")
        control.async { [self] in
            if #available(macOS 14.2, *) { (capture as? SystemAudioCapture)?.stop() }
            capture = nil
            processing.async { [self] in
                closeSegment()
                if let last = chunker.flush() { transcribing.async { self.transcribe(last) } }
                if var s = session { s.state = .stopped; s.recordedSeconds = Double(recordedFrames) / Double(AudioImportPolicy.sampleRate); session = s; save(s) }
                transcribing.async { self.finalize(reason) }
            }
        }
    }

    /// Выход из приложения: остановить захват и закрыть сегмент синхронно; расшифровку доберёт
    /// следующий запуск.
    func stopForTermination() {
        guard isRecording || session != nil else { return }
        isRecording = false; stopping = true
        watchTimer?.invalidate(); watchTimer = nil
        control.sync { [self] in
            if #available(macOS 14.2, *) { (capture as? SystemAudioCapture)?.stop() }
            capture = nil
        }
        // Сегмент закрывается там же, где пишется, но ждём ограниченно: выход приложения не должен
        // зависнуть из-за очереди.
        let done = DispatchGroup(); done.enter()
        processing.async { [self] in
            closeSegment()
            if var s = session { s.state = .stopped; s.recordedSeconds = Double(recordedFrames) / Double(AudioImportPolicy.sampleRate); save(s) }
            done.leave()
        }
        _ = done.wait(timeout: .now() + 2)
        kbLog("звонок: приложение закрывается посреди записи, сессия сохранена для восстановления")
    }

    // MARK: конвейер (очередь processing)

    private func ingest(_ mono: [Float]) {
        let now = ProcessInfo.processInfo.systemUptime
        watchdog.noteBuffer(at: now)
        guard let r = resampler else { return }
        let s16 = r.convert(mono)
        guard !s16.isEmpty else { return }
        envelope.feed(s16)
        writeSegment(s16)
        recordedFrames += s16.count
        let rms = AudioChunker.rms(s16)
        switch silence.feed(rms: rms, at: now) {
        case .none:
            // Раз в минуту тишины — строка в лог. Без неё разбор случая «почему не остановилось»
            // упирается в расшифровку сохранённого клипа: именно так пришлось разбирать 07.09.
            // Уровней и текста тут нет, только длительность (принцип №2).
            let silent = silence.silentSeconds(at: now)
            if silent >= 60, Int(silent) / 60 > lastSilenceLogMinute {
                lastSilenceLogMinute = Int(silent) / 60
                kbLog("запись: тихо уже \(lastSilenceLogMinute) мин (вопрос на 5, остановка на 7)")
            }
            if silent == 0 { lastSilenceLogMinute = 0 }
        case .prompt:
            kbLog("запись: 5 минут тишины — спрашиваю, продолжать ли")
            DispatchQueue.main.async { self.promptSilence() }
        case .stop:
            kbLog("запись: 7 минут тишины — останавливаю сам")
            DispatchQueue.main.async { self.stop(.silence) }
        }
        for chunk in chunker.feed(s16) {
            transcribing.async { [self] in transcribe(chunk) }
        }
    }

    private func writeSegment(_ s16: [Float]) {
        guard let dir = sessionDir else { return }
        if segmentFile == nil {
            let name = String(format: "seg-%04d.m4a", (session?.segments.count ?? 0) + 1)
            let url = dir.appendingPathComponent(name)
            segmentFile = try? AVAudioFile(forWriting: url, settings: VoiceClips.encoderSettings)
            if segmentFile == nil { kbLog("звонок: сегмент не открылся, звук этого куска не сохранится"); return }
            if var s = session { s.segments.append(name); session = s; save(s) }
        }
        if let file = segmentFile,
           let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioImportPolicy.sampleRate), channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s16.count)),
           let dst = buf.floatChannelData?[0] {
            buf.frameLength = AVAudioFrameCount(s16.count)
            s16.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: s16.count) }
            if (try? file.write(from: buf)) == nil { kbLog("звонок: запись сегмента оборвалась") ; segmentFile = nil }
        }
        if planner.add(frames: s16.count) { closeSegment() }
    }

    /// AVAudioFile дописывает заголовок в deinit: закрыть значит отпустить объект.
    private func closeSegment() { segmentFile = nil }

    // MARK: расшифровка (очередь transcribing)

    private func transcribe(_ chunk: AudioChunk) {
        guard let raw = Self.transcribeSync(chunk.samples, timeout: chunkTimeout) else {
            kbLog("звонок: кусок \(chunksDone + 1) не расшифрован (движок молчит)"); return
        }
        let text = VoiceDictionary.shared.apply(WhisperGhosts.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines))
        pieces.append(.init(text: text, gapBefore: chunk.gapBefore))
        chunksDone += 1
        if chunksDone % 10 == 0 { kbLog("звонок: расшифровано кусков \(chunksDone)") }
    }

    private static func transcribeSync(_ samples: [Float], timeout: TimeInterval) -> String? {
        let done = DispatchSemaphore(value: 0)
        var result: String? = nil
        Task { result = await VoiceController.shared.transcribeImported(samples); done.signal() }
        return done.wait(timeout: .now() + timeout) == .timedOut ? nil : result
    }

    private func finalize(_ reason: StopReason) {
        let text = TranscriptAssembler.join(pieces)
        let dir = sessionDir
        let s = session
        let segmentsCount = s?.segments.count ?? 0
        let seconds = Double(recordedFrames) / Double(AudioImportPolicy.sampleRate)
        let wave = envelope.finish()
        var clip: (id: String, wave: [UInt8])? = nil
        if !text.isEmpty, AppSettings.shared.voiceSaveAudio, let dir, let s {
            if let data = Self.mergeSegments(in: dir, names: s.segments) { clip = VoiceClips.saveEncoded(data, wave: wave) }
        }
        DispatchQueue.main.async { [self] in
            defer {
                if let dir { try? FileManager.default.removeItem(at: dir) }
                session = nil; sessionDir = nil; stopping = false
                // Модели звонок больше не нужен. Зовём ПОСЛЕ снятия `stopping`: выгрузка после
                // диктовки (настройка) смотрит на `isBusy` и иначе пропустила бы этот раз.
                VoiceController.shared.importFinished()
            }
            guard !text.isEmpty, let s else {
                // ⚠️ ПУСТАЯ ЗАПИСЬ БЫВАЕТ ДВУХ РОДОВ, И ЧЕЛОВЕКУ ВАЖНО ЗНАТЬ, КАКОГО (13.09.2026).
                // «Речи не нашлось» честно только если звук ШЁЛ, а речи в нём не было. Если же от
                // системного звука не пришло ни одного ненулевого кадра, а от микрофона пришли, то
                // почти наверняка не выдано отдельное разрешение на запись системного звука: без
                // него Core Audio возвращает успех и отдаёт тишину, и узнать это иначе как замером
                // громкости нельзя (инженер Apple, форум 756783). Отзыв #269: человек трижды получил
                // «в записи не нашлось речи» и написал «разрешения все выданы» — то, которого не
                // хватало, у него просто никто не спросил.
                var tapSilent = false, micHeard = false, streams = 0, heardList = "—"
                if #available(macOS 14.2, *), let cap = capture as? SystemAudioCapture {
                    streams = cap.streamCount
                    tapSilent = cap.streamCount > 1 && !cap.heardStreams.contains(1)
                    micHeard = cap.heardStreams.contains(0)
                    heardList = cap.heardStreams.sorted().map(String.init).joined(separator: ",")
                }
                kbLog("звонок: речи не нашлось (\(segmentsCount) сегментов, \(ImportProgressFormat.clock(seconds)), потоков \(streams), звучали \(heardList))")
                if tapSilent, micHeard {
                    AppBanner.shared.show(title: L10n.t("call.noSystemAudioTitle"),
                                          body: L10n.t("call.noSystemAudioBody"),
                                          actions: [AppBanner.Action(title: L10n.t("call.noPermissionOpen"), coral: true) {
                                              CallRecorder.openAudioCaptureSettings()
                                          }], autoDismiss: 30)
                } else {
                    VoiceIndicator.shared.showToast(L10n.t("call.empty"))
                }
                return
            }
            VoiceHistory.shared.addImported(text, fileName: CallSession.title(app: s.app, recovered: false),
                                            audio: clip?.id, wave: clip?.wave, kind: .call)
            kbLog("звонок: сохранён, \(text.count) симв., \(chunksDone) кусков, \(ImportProgressFormat.clock(seconds)), клип \(clip == nil ? "нет" : "есть")")
            VoiceIndicator.shared.showToast(L10n.t(reason == .stalled ? "call.savedAfterStall" : "call.saved"))
        }
    }

    /// Сегменты → один AAC того же формата для клипа карточки. Потоково, по 32k кадров.
    static func mergeSegments(in dir: URL, names: [String]) -> Data? {
        guard !names.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kb-call-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            do {
                let out = try AVAudioFile(forWriting: tmp, settings: VoiceClips.encoderSettings)
                for name in names {
                    guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(name)) else { continue }
                    let fmt = file.processingFormat
                    while file.framePosition < file.length {
                        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768) else { break }
                        try file.read(into: buf)
                        if buf.frameLength == 0 { break }
                        try out.write(from: buf)
                    }
                }
            }
        } catch {
            kbLog("звонок: склейка сегментов не удалась (\(error))"); return nil
        }
        return try? Data(contentsOf: tmp)
    }

    // MARK: тишина и сторож (главный поток)

    private func promptSilence() {
        guard isRecording else { return }
        AppBanner.shared.show(title: L10n.t("call.silenceTitle"), body: L10n.t("call.silenceBody"), actions: [
            AppBanner.Action(title: L10n.t("call.silenceStop"), coral: true) { [weak self] in self?.stop(.silence) },
            AppBanner.Action(title: L10n.t("call.silenceContinue"), coral: false) { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.processing.async { self.silence.snooze(at: now) }
            },
        ], autoDismiss: 0)
    }

    private func startWatchdog() {
        watchTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.watchTick() }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
        NotificationCenter.default.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func wokeUp() { watchTick() }

    private func watchTick() {
        guard isRecording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        processing.async { [self] in
            switch watchdog.check(now: now) {
            case .fine: return
            case .restart(let attempt):
                kbLog("звонок: звук не приходит, перезапуск захвата №\(attempt)")
                control.async { [self] in
                    if #available(macOS 14.2, *) { (capture as? SystemAudioCapture)?.stop() }
                    capture = nil
                    if let err = openCapture() { kbLog("звонок: перезапуск не удался (\(err))") }
                }
            case .giveUp:
                DispatchQueue.main.async { [self] in
                    AppBanner.shared.show(title: L10n.t("call.stalledTitle"), body: L10n.t("call.stalledBody"), autoDismiss: 30)
                    stop(.stalled)
                }
            }
        }
    }

    // MARK: сессия на диске

    private func save(_ s: CallSession) {
        guard let dir = sessionDir ?? Optional(Self.callsDir.appendingPathComponent(s.id, isDirectory: true)) else { return }
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: dir.appendingPathComponent("session.json"), options: [.atomic])
        }
    }

    // MARK: восстановление после крэша или выключения

    private static var recoveryQueue: [URL] = []
    private static var recoveryObserver: NSObjectProtocol?

    /// На старте приложения: незавершённые сессии добираются через импорт файла, по одной.
    static func recoverUnfinishedSessions() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: callsDir, includingPropertiesForKeys: nil) else { return }
        var pending: [URL] = []
        for dir in dirs {
            let json = dir.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: json), let s = try? JSONDecoder().decode(CallSession.self, from: data) else {
                try? fm.removeItem(at: dir); continue
            }
            if s.needsRecovery { pending.append(dir) } else { try? fm.removeItem(at: dir) }
        }
        guard !pending.isEmpty else { return }
        kbLog("звонок: незавершённых сессий \(pending.count), добираю")
        recoveryQueue = pending
        recoverNext()
    }

    private static func recoverNext() {
        guard !recoveryQueue.isEmpty else { return }
        let dir = recoveryQueue.removeFirst()
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
              let s = try? JSONDecoder().decode(CallSession.self, from: data) else { recoverNext(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let merged = mergeSegments(in: dir, names: s.segments) else {
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async { recoverNext() }
                return
            }
            let name = CallSession.title(app: s.app, recovered: true).replacingOccurrences(of: "/", with: "-") + ".m4a"
            let url = dir.appendingPathComponent(name)
            do { try merged.write(to: url, options: [.atomic]) } catch {
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async { recoverNext() }
                return
            }
            // Склейка из незакрытых сегментов даёт пустой контейнер: такую сессию не крутим при
            // каждом запуске с тостом, а честно удаляем (первая тестовая запись 04.09).
            guard let probe = try? AVAudioFile(forReading: url), probe.fileFormat.sampleRate > 0,
                  Double(probe.length) / probe.fileFormat.sampleRate >= 1.0 else {
                kbLog("звонок: сегменты сессии не читаются (файлы без заголовка), сессия удалена")
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async { recoverNext() }
                return
            }
            DispatchQueue.main.async {
                recoveryObserver.map { NotificationCenter.default.removeObserver($0) }
                recoveryObserver = NotificationCenter.default.addObserver(forName: .keyboopAudioImportFinished, object: nil, queue: .main) { n in
                    recoveryObserver.map { NotificationCenter.default.removeObserver($0) }
                    recoveryObserver = nil
                    // Папку сессии убираем только когда текст реально лёг в историю: без модели или
                    // при отказе движка сегменты остаются до следующего запуска.
                    switch n.object as? AudioImporter.Outcome {
                    case .done, .partial, .empty: try? FileManager.default.removeItem(at: dir)
                    default: kbLog("звонок: восстановление не удалось, сегменты оставлены до следующего запуска")
                    }
                    recoverNext()
                }
                VoiceIndicator.shared.showToast(L10n.t("call.recovering"))
                if !AudioImporter.shared.start(url: url) {
                    recoveryObserver.map { NotificationCenter.default.removeObserver($0) }
                    recoveryObserver = nil
                    recoveryQueue.removeAll()   // импорт занят: доберём в следующий запуск
                    kbLog("звонок: импорт занят, восстановление отложено")
                }
            }
        }
    }
}
