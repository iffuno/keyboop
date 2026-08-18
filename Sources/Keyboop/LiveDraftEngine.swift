import Foundation
import AVFoundation
#if arch(arm64) && !KEYBOOP_NO_PARAKEET
import FluidAudio

/// ЖИВОЙ ЧЕРНОВИК ДИКТОВКИ: что мы слышим прямо сейчас, показанное на плашке.
///
/// ⚠️ ЭТО ТОЛЬКО ПОКАЗ. В поле ввода отсюда не попадает ни один символ: чистовик по-прежнему
/// делает батчевый путь через `deliver()`, со словарём, опциями вставки и авто-Enter. Решение
/// автора 30.07.2026 в силе: гипотеза постоянно переписывается, пока модель уточняет, и писать-стирать
/// в чужом документе нельзя. Отсюда же приятное следствие: у нас НЕТ второго конвейера вывода,
/// который пришлось бы держать в согласии с первым.
///
/// ⚠️ РАБОТАЕТ НА УЖЕ СКАЧАННОЙ МОДЕЛИ. `SlidingWindowAsrManager` принимает готовые `AsrModels`,
/// то есть ровно ту Parakeet v3, которую грузит `ParakeetEngine`. Ни одного лишнего мегабайта:
/// потоковая EOU-модель (216 МБ) не нужна, а главное — она ТОЛЬКО АНГЛИЙСКАЯ (в её словаре 1023
/// латинских токена и ноль кириллических, замерено 13.08.2026), то есть на русской речи показывала
/// бы правдоподобную кашу. v3 многоязычна, поэтому черновик честен на обоих языках.
///
/// Механика у библиотеки такая: офлайновый энкодер гоняется по перекрывающимся окнам, гипотеза
/// раз в секунду, устойчивый текст по окну в 11 секунд. Своими словами авторов, «similar to Apple's
/// SpeechAnalyzer». Отсюда два уровня текста, подтверждённый и волатильный, которые мы и склеиваем.
@available(macOS 14.0, *)
final class LiveDraftEngine {
    static let shared = LiveDraftEngine()

    private var manager: SlidingWindowAsrManager?
    private var pump: Task<Void, Never>?
    private var format: AVAudioFormat?
    private(set) var running = false

    /// Доступен ли черновик прямо сейчас: только Parakeet и только с установленной моделью.
    /// У Whisper потокового режима нет, а держать вторую резидентную модель ради показа это ровно
    /// та дороговизна, ради ухода от которой всё и затевалось.
    static var available: Bool {
        AppSettings.shared.voiceEngine == "parakeet" && ParakeetEngine.modelInstalled
    }

    /// Запустить черновик. `onText` зовётся на главном потоке с ПОЛНЫМ текущим текстом.
    /// Молча ничего не делает, если черновик недоступен: вызывающему не нужно об этом думать.
    func start(onText: @escaping (String) -> Void) async {
        guard Self.available, !running else { return }
        do {
            let mgr = manager ?? SlidingWindowAsrManager(config: .streaming)
            if manager == nil {
                // ⚠️ БЕРЁМ УЖЕ ЗАГРУЖЕННОЕ, А НЕ ГРУЗИМ СВОЁ. Модель у черновика та же самая, что у
                // обычной диктовки. Своя загрузка стоила бы второй копии в памяти и, на чистой
                // машине, первой компиляции CoreML под ANE: стенд намерил 49,7 секунды против 0,26
                // на прогретой. Если батчевый движок ещё не поднят, поднимаем его, а не дублируем.
                if ParakeetEngine.shared.loadedModels == nil { _ = await ParakeetEngine.shared.loadIfNeeded() }
                guard let models = ParakeetEngine.shared.loadedModels else {
                    kbLog("черновик: модели v3 не загружены, показывать нечего"); return
                }
                try await mgr.loadModels(models)
                manager = mgr
            } else {
                try await mgr.reset()
            }
            try await mgr.startStreaming(source: .microphone)
            running = true
            // Подтверждённое плюс волатильное: человеку нужна вся фраза, а не только её устоявшаяся
            // часть. Разделять их визуально не пытаемся (см. PLAN_VOICE_HUD): в строке шириной в
            // три слова второй цвет читается как дефект отрисовки, а не как «мы ещё думаем».
            pump = Task { [weak self] in
                guard let mgr = self?.manager else { return }
                var confirmed = ""
                for await u in await mgr.transcriptionUpdates {
                    if u.isConfirmed { confirmed = u.text }
                    let full = u.isConfirmed ? confirmed
                                             : (confirmed.isEmpty ? u.text : confirmed + " " + u.text)
                    await MainActor.run { onText(full) }
                }
            }
            kbLog("черновик: запущен на Parakeet v3 (скользящее окно)")
        } catch {
            running = false
            kbLog("черновик: не завёлся: \(error)")
        }
    }

    /// Скормить кусок записи. Формат наш, 16 кГц моно; библиотека при необходимости пересчитает.
    func feed(_ samples: [Float]) {
        guard running, let mgr = manager, !samples.isEmpty else { return }
        let fmt = format ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                          channels: 1, interleaved: false)
        guard let fmt else { return }
        format = fmt
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        Task { await mgr.streamAudio(buf) }
    }

    /// Остановить черновик. Результат НЕ используем: чистовик придёт батчевым путём.
    /// Модель в памяти оставляем, следующая диктовка начнётся без паузы на загрузку.
    func stop() {
        guard running else { return }
        running = false
        pump?.cancel(); pump = nil
        Task { [weak self] in _ = try? await self?.manager?.finish() }
    }

    /// Выгрузить модель под давлением памяти. Не на главном потоке (урок 0.2.47).
    func unload() async {
        stop()
        await manager?.cleanup()
        manager = nil
    }
}
#else
// ⚠️ INTEL-СРЕЗ. FluidAudio это arm64-статика с CoreML на Neural Engine, на x86 её нет. Заглушка
// нужна не для красоты: универсальную сборку делает release.sh, и без неё второй проход не
// скомпилируется вовсе. `available = false` гасит черновик молча, диктовка работает как обычно.
@available(macOS 14.0, *)
final class LiveDraftEngine {
    static let shared = LiveDraftEngine()
    static var available: Bool { false }
    private(set) var running = false
    func start(onText: @escaping (String) -> Void) async {}
    func feed(_ samples: [Float]) {}
    func stop() {}
    func unload() async {}
}
#endif
