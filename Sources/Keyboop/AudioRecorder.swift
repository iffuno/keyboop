import AVFoundation
import Accelerate
import AudioToolbox

/// Запись микрофона на macOS → 16 kHz mono Float32 для whisper.cpp.
/// Ключевые решения (research 3 production-приложений: vocamac / openwhisper / speak2):
/// — СВЕЖИЙ AVAudioEngine на каждую запись (отпускает прежний HAL-claim, лечит TCC-кэш «deny»);
/// — tap по `outputFormat(forBus:0)` (на macOS inputFormat часто 0ch → NSException);
/// — НЕ подключаем inputNode к mixer (для tap-only записи не нужно);
/// — проверка немого/битого устройства (0 каналов / 0 Гц).
/// КРИТИЧНО: требует entitlement `com.apple.security.device.audio-input` (иначе нули, RMS=0).
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var loggedInput = false
    private var capturing = false            // реально ли пишем в samples (vs тёплый холостой ход)
    private var warmRelease: DispatchWorkItem?
    private var warmSeconds: Double { Double(AppSettings.shared.voiceWarmSeconds) }  // длина «тёплого окна», из настроек
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1, interleaved: false)!

    // isRecording = именно АКТИВНАЯ диктовка (а не «движок ещё тёплый и крутится вхолостую»).
    var isRecording: Bool { capturing }
    var duration: Double { Double(samples.count) / 16_000.0 }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() throws {
        warmRelease?.cancel(); warmRelease = nil
        lock.lock(); samples.removeAll(keepingCapacity: true); loggedInput = false; lock.unlock()
        // Тёплое окно: движок ещё крутится с прошлой диктовки (HAL разбужен) → мгновенный старт,
        // просто снова включаем сбор сэмплов. Ноль задержки на пробуждение устройства.
        if engine != nil {
            capturing = true
            kbLog("voice rec: мгновенный старт (тёплый движок)")
            return
        }
        let engine = AVAudioEngine()   // свежий движок на каждую запись (холодный путь)
        self.engine = engine

        let input = engine.inputNode
        // Выбранный пользователем микрофон (если задан и доступен) — иначе системный по умолчанию.
        let uid = AppSettings.shared.voiceMicUID
        if !uid.isEmpty, let devID = AudioDevices.deviceID(forUID: uid), let au = input.audioUnit {
            var dev = devID
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)   // outputFormat, НЕ inputFormat (0ch на macOS)
        let auth = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        kbLog("voice rec: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch auth=\(auth) (3=authorized)")
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            self.engine = nil
            kbLog("voice rec: немой/битый input device (0ch/0Hz)")
            throw NSError(domain: "keyboop.voice", code: 1)
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            self.engine = nil
            throw NSError(domain: "keyboop.voice", code: 2)
        }
        converter.primeMethod = .none

        // НЕ подключаем к mainMixerNode — для tap-only записи это не нужно.
        // В тёплом холостом ходе (capturing=false) буферы молча отбрасываем.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, self.capturing else { return }
            self.append(buf, converter: converter)
        }
        engine.prepare()
        try engine.start()
        capturing = true
    }

    @discardableResult
    func stop() -> [Float] {
        capturing = false
        lock.lock(); let out = samples; lock.unlock()
        // Тёплое окно (opt-in): НЕ глушим движок — держим HAL разбуждённым ещё warmSeconds,
        // чтобы повторная диктовка стартовала мгновенно. Оранжевый индикатор горит это время
        // (честно: микрофон формально открыт, но звук отбрасывается). Иначе — сразу отпускаем.
        if AppSettings.shared.voiceWarmWindow, engine != nil {
            scheduleWarmRelease()
        } else {
            releaseEngine()
        }
        return out
    }

    /// Полностью отпустить движок и HAL/устройство (гасит оранжевый индикатор).
    private func releaseEngine() {
        warmRelease?.cancel(); warmRelease = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        engine = nil
        capturing = false
    }

    /// Отложенное отпускание движка после тёплого окна (если новой диктовки не случилось).
    private func scheduleWarmRelease() {
        warmRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.releaseEngine()
            kbLog("voice rec: тёплое окно истекло — микрофон отпущен")
        }
        warmRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        if !loggedInput {
            loggedInput = true
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(out.frameLength))
            kbLog("voice rec: первый буфер RMS=\(String(format: "%.4f", rms)) frames=\(out.frameLength)")
        }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}
