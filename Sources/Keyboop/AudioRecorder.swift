import AVFoundation
import Accelerate
import CoreMedia

/// Запись микрофона на macOS → 16 kHz mono Float32 для whisper.cpp / Parakeet.
///
/// АРХИТЕКТУРА (переезд AVAudioEngine → AVCaptureSession, 21.07.2026):
/// AVAudioEngine на macOS НИКОГДА не открывает выбранное устройство — его inputNode живёт на
/// приватном агрегате CADefaultDeviceAggregate из СИСТЕМНЫХ умолчаний. Смена
/// kAudioOutputUnitProperty_CurrentDevice возвращала noErr, но формат шины не перепроговаривался
/// никогда → tap вставал на протухшую частоту (24кГц от AirPods) поверх железа на 48кГц и не
/// вызывался НИ РАЗУ: «выбран RODE + подключены AirPods = тишина» (баг-репорт, воспроизведено
/// и замерено). Плюс сборка движка на main при HAL-чехарде зависала до 2.6с → macOS глушила event-tap.
///
/// AVCaptureSession прибивается к конкретному AVCaptureDevice(uniqueID:) ДО старта, а формат мы
/// ОБЪЯВЛЯЕМ (audioSettings → сразу 16кГц mono Float32), а не выторговываем у железа. Замер в точной
/// аварийной конфигурации (RODE выбран, AirPods — системный вход): 281 колбэк за 3с на верных 48кГц.
/// Вместе с движком уходят: AVAudioConverter, guard 0ch/0Hz, дилемма outputFormat-vs-inputFormat,
/// наблюдатель AVAudioEngineConfigurationChange и анти-каскадный дебаунс 0.7с (пересборка сессии
/// не порождает событие, которое её же вызвало, — самозацикливание невозможно по построению).
///
/// КРИТИЧНО: требует entitlement `com.apple.security.device.audio-input` (иначе нули).
/// voiceMicUID мигрирует без конвертации: CoreAudio kAudioDevicePropertyDeviceUID и
/// AVCaptureDevice.uniqueID — побайтово одна строка (проверено: built-in / USB / Continuity / BT).
final class AudioRecorder: NSObject {
    private var session: AVCaptureSession?
    private var pinnedUID = ""                 // voiceMicUID, на котором собрана текущая сессия
    private var activeDeviceUID = ""           // uniqueID устройства, реально открытого сессией
    private var disconnectObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var rebuilding = false             // ре-энтранси-гард пересборки (main-only)
    /// Последний увиденный UID системного входа. Нужен, чтобы отличить РЕАЛЬНУЮ смену устройства
    /// от пачки нотификаций об одной и той же (main-only, как и rebuilding).
    private var lastDefaultInputUID: String?
    private var watchdog: DispatchWorkItem?
    private var deadSignalWatchdog: DispatchWorkItem?   // «буферы идут, но в них ноль» (см. armWatchdog)
    private var rebuildStrikes = 0             // подряд «немых» пересборок (main-only); сброс в start()/при буфере
    private var deadStrikes = 0                // подряд «нулевых» эскалаций (main-only); сброс в start()/при живом сигнале
    /// Сериализация startRunning/stopRunning при быстрых циклах диктовка/стоп.
    private let sessionQueue = DispatchQueue(label: "ru.keyboop.capture.session")
    /// Очередь доставки сэмпл-буферов делегату (НЕ realtime-поток — можно lock и аллокации).
    private let sampleQueue  = DispatchQueue(label: "ru.keyboop.capture.samples")

    private let lock = NSLock()
    private var samples: [Float] = []
    private var loggedInput = false
    private var firstBufferSeen = false        // сторож «буферы реально идут» — читать/писать под lock
    /// Был ли хоть один НЕнулевой сэмпл. Живой микрофон всегда даёт шум ≠ 0; РОВНЫЙ цифровой ноль
    /// на протяжении секунд = вход мёртв (устройство спит / замьючено / отдаёт пустой поток).
    /// Отличать это от «человек молчит» важно: молчание даёт малый RMS, но не побитовый ноль.
    private var nonZeroSeen = false            // под lock
    private var levelFrameAcc = 0              // троттлинг уровня по кадрам (только sampleQueue)
    private var capturing = false              // реально ли пишем в samples (vs тёплый холостой ход)
    private var warmRelease: DispatchWorkItem?
    private var warmSeconds: Double { Double(AppSettings.shared.voiceWarmSeconds) }  // длина «тёплого окна»

    /// Запись умерла и восстановить не удалось (вход пропал, пересборка провалилась) — VoiceController
    /// обязан штатно свернуть диктовку (индикатор, streaming-сессия). Зовётся на main.
    var onDied: (() -> Void)?

    /// Однострочное человеческое объяснение проблемы со звуком (HUD-тост у VoiceController) —
    /// вместо молчаливого «тишина — пропуск», из-за которого «программа меня не слышит» выглядит
    /// как мистика или вирус. Зовётся на main.
    var onNotice: ((String) -> Void)?

    /// Опциональный хук «живого» аудио для потоковой диктовки: вызывается с каждым 16кГц-mono-чанком
    /// ([Float]) ПОКА идёт запись. nil — обычный батч-путь не меняется ни на байт.
    /// Доступ под `lock`: ставится из main, читается с sampleQueue.
    private var _onChunk: (([Float]) -> Void)?
    func setChunkHook(_ cb: (([Float]) -> Void)?) { lock.lock(); _onChunk = cb; lock.unlock() }

    /// Хук «живого уровня» (RMS) для waveform-индикатора, ~12 обновлений/сек.
    private var _onLevel: ((Float) -> Void)?
    func setLevelHook(_ cb: ((Float) -> Void)?) { lock.lock(); _onLevel = cb; lock.unlock() }

    // isRecording = именно АКТИВНАЯ диктовка (а не «сессия ещё тёплая и крутится вхолостую»).
    // ОБА геттера — под lock (ревью 21.07, №1): samples пишется делегатом на sampleQueue под lock,
    // несинхронизированный count на main = гонка на Swift Array (COW-реаллокация) → UB/краш; а запись
    // capturing без lock не давала happens-before с чтением в делегате → протухший true мог дописать
    // хвост ПОСЛЕ снапшота stop(). Пишем capturing только через setCapturing().
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return capturing }
    var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / 16_000.0 }
    private func setCapturing(_ v: Bool) { lock.lock(); capturing = v; lock.unlock() }

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
        lock.lock(); samples.removeAll(keepingCapacity: true); loggedInput = false; firstBufferSeen = false; nonZeroSeen = false; lock.unlock()
        // Тёплое окно — но с ПРОВЕРКОЙ АКТУАЛЬНОСТИ: смена микрофона в меню/настройках ничего не
        // постит, поэтому тёплая сессия могла быть собрана на другом устройстве. Сравнение двух
        // строк — ноль обращений к CoreAudio на горячем пути (регресс 0.2.53 не повторяем).
        rebuildStrikes = 0
        // ⚠️ deadStrikes НЕ сбрасываем (репорт #32, 27.07: «не работает голосовой набор»). Лестница
        // объяснений про мёртвый вход шагает раз в 3 секунды, а человек жмёт диктовку короткими
        // попытками по 2-5с — и обнуление на каждом старте не давало ему дойти ни до одного
        // сообщения. Пять попыток подряд с RMS=0.0000 и полная тишина в ответ. Счётчик обнуляется
        // там, где ему и место: при живом сигнале (см. ниже, alive → deadStrikes = 0).
        if let s = session, s.isRunning, pinnedUID == AppSettings.shared.voiceMicUID {
            setCapturing(true)
            armWatchdog()   // сторож и на тёплом пути: ловит «сессия жива, но буферы умерли»
            kbLog("voice rec: мгновенный старт (тёплая сессия)")
            return
        }
        if session != nil { releaseEngine() }   // тёплая, но устаревшая (сменили микрофон) — сносим
        try buildEngine()
        setCapturing(true)
    }

    /// Собрать СВЕЖУЮ capture-сессию на выбранном устройстве.
    /// `ignorePin` — аварийная пересборка на системном входе (сторож: выбранный микрофон молчит).
    /// `forceUID` — эскалация сторожа тишины: системный вход может оказаться ТЕМ ЖЕ мёртвым
    /// устройством (внешний микрофон = дефолт), тогда пробуем ДРУГОЕ железо явно.
    private func buildEngine(ignorePin: Bool = false, forceUID: String? = nil) throws {
        let t0 = ProcessInfo.processInfo.systemUptime

        // 1. Устройство. НИКАКОГО AudioDevices.inputs() на пути старта (перечисление CoreAudio с
        //    Bluetooth занимает сотни мс — регресс 0.2.53); AVCaptureDevice(uniqueID:) — прямой lookup.
        let uid = forceUID ?? (ignorePin ? "" : AppSettings.shared.voiceMicUID)
        // Пусто = «системный по умолчанию». Спрашиваем СИСТЕМУ (CoreAudio), а не AVFoundation:
        // её `default(for: .audio)` не следует за выбором в Настройках → Звук → Вход, из-за чего
        // AirPods и Continuity не подхватывались (репорт #23). Один быстрый запрос свойства, без
        // перечисления устройств — то самое, что в 0.2.53 стоило сотни мс на Bluetooth.
        var picked: AVCaptureDevice? = uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid)
        if uid.isEmpty, let sysUID = AudioDevices.systemDefaultInputUID() {
            picked = AVCaptureDevice(uniqueID: sysUID)
            // Доказательство вместо веры: если два источника расходятся, это ровно тот случай, ради
            // которого правка и делалась, и в багрепорте он будет виден. Пишем только при
            // расхождении — на совпадении строка была бы шумом.
            if let avDefault = AVCaptureDevice.default(for: .audio), avDefault.uniqueID != sysUID {
                kbLog("voice rec: система выбрала «\(picked?.localizedName ?? "?")», AVFoundation предлагала «\(avDefault.localizedName)» — берём системный")
            }
        }
        guard let device = picked ?? AVCaptureDevice.default(for: .audio) else {
            self.session = nil
            kbLog("voice rec: нет ни одного входного устройства")
            throw NSError(domain: "keyboop.voice", code: 1)
        }
        if !uid.isEmpty, picked == nil {
            kbLog("voice rec: выбранный микрофон недоступен → системный по умолчанию")
        }

        // 2. Сессия. Любой выход по ошибке ОБЯЗАН оставить self.session == nil — иначе следующий
        //    start() уйдёт в тёплую ветку на мёртвом объекте (та же сигнатура «0 сэмплов»; в старом
        //    коде self.engine выставлялся ДО try engine.start() — это была живая дыра).
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch {
            self.session = nil
            kbLog("voice rec: не открыть вход \(device.localizedName): \(error)")
            throw error
        }

        // 3. ФОРМАТ ОБЪЯВЛЯЕМ, А НЕ ВЫЧИТЫВАЕМ — здесь умирает весь класс stale-format багов.
        //    CoreMedia отдаёт ровно 16кГц mono Float32 non-interleaved — вход whisper.cpp/Parakeet
        //    без AVAudioConverter (замер: flags=9 float|packed).
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             16_000.0,
            AVNumberOfChannelsKey:       1,
            AVLinearPCMBitDepthKey:      32,
            AVLinearPCMIsFloatKey:       true,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        out.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(out) else {
            session.commitConfiguration()
            self.session = nil
            kbLog("voice rec: сессия не принимает вход/выход (\(device.localizedName))")
            throw NSError(domain: "keyboop.voice", code: 2)
        }
        session.addInput(input)
        session.addOutput(out)
        session.commitConfiguration()

        levelFrameAcc = 0

        // 4. Старт. startRunning() блокирует ~110–160мс — МЕНЬШЕ прежней сборки движка (211–463мс,
        //    в плохих случаях 2613мс → зависание main и убитый системой event-tap, репорт 21.07).
        //    Синхронно намеренно: VoiceController.begin() играет стартовый cue ПОСЛЕ возврата
        //    start() — «пикнуло» должно означать «микрофон реально живой».
        // 🚨 startRunning() — СТРОГО АСИНХРОННО. Он блокирует вызывающий поток (в норме 90–160мс, при
        // проблемах с устройством — секунды), а зовут нас с ГЛАВНОГО потока, на котором живёт runloop
        // нашего CGEventTap. Подмороженный main = macOS перестаёт доставлять события ВСЕЙ СИСТЕМЕ:
        // мышь ездит, клики и клавиши не проходят (инцидент — пришлось выходить из
        // приложения через меню, чтобы вернуть себе Mac). Никакая точность стартового «пик» не стоит
        // фриза чужого ввода. Что сессия реально поднялась, проверяем в самом задании и, отдельно,
        // сторожем первого буфера (2с) — он уже умеет пересобирать и сдаваться.
        self.session = session
        sessionQueue.async { [weak self] in
            session.startRunning()
            guard !session.isRunning else { return }
            kbLog("voice rec: сессия не запустилась (\(device.localizedName))")
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }   // уже сменили — не мешаем
                self.handleDeviceChange(reason: "сессия не запустилась", ignorePin: true)
            }
        }
        self.pinnedUID = uid
        self.activeDeviceUID = device.uniqueID
        let dt = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        let auth = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        kbLog("voice rec: 16000.0Hz 1ch auth=\(auth) (3=authorized), сессия поднята за \(dt)мс")

        // 5. Диагностика СТРОГО в фоне: в лог идёт РЕАЛЬНО открытое устройство и его аппаратная
        //    частота — старый лог печатал ВЫБРАННОЕ имя рядом с частотой чужого агрегата и потому
        //    не мог показать баг. Пара «вход=RODE (железо 48000Hz)» при подключённых AirPods —
        //    решающее доказательство, что открыт настоящий RODE.
        let nameForLog = device.localizedName
        let uidForLog  = device.uniqueID
        DispatchQueue.global(qos: .utility).async {
            let hw = AudioDevices.deviceID(forUID: uidForLog).flatMap { AudioDevices.nominalSampleRate($0) }
            kbLog("voice rec: вход=\(nameForLog) (железо \(hw.map { String(Int($0)) } ?? "?")Hz)")
        }

        // 6. Смена устройства — два точечных источника вместо ConfigurationChange:
        //    выдернули АКТИВНОЕ устройство → пересборка (сэмплы сохраняются);
        //    микрофон не закреплён → следим за сменой СИСТЕМНОГО входа сами (AVCaptureSession
        //    прибита к конкретному устройству и за дефолтом не следует).
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice,
                  d.uniqueID == self.activeDeviceUID else { return }
            self.handleDeviceChange(reason: "устройство отключено")
        }
        // Смерть сессии БЕЗ отключения устройства (рестарт coreaudiod / mediaServicesWereReset):
        // wasDisconnected не приходит, одноразовый сторож уже отработал → без этого наблюдателя
        // буферы тихо кончались бы при живом «Слушаю» навсегда (ревью 21.07, №2 — паритет со
        // старым AVAudioEngineConfigurationChange). Маршрут через handleDeviceChange бесплатно
        // даёт rebuilding-гард и exactly-once для onDied.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
            kbLog("voice rec: сессия упала (runtime error \(code)) — пересборка")
            self.handleDeviceChange(reason: "сессия упала")
        }
        if pinnedUID.isEmpty {
            lastDefaultInputUID = AudioDevices.systemDefaultInputUID()
            defaultInputListener = AudioDevices.addDefaultInputListener { [weak self] in
                guard let self else { return }
                // CoreAudio шлёт нотификацию на КАЖДЫЙ изменившийся адрес свойства, поэтому на одну
                // реальную смену устройства прилетает пачка вызовов. Гард `rebuilding` их не ловит:
                // он ставится и снимается внутри одного синхронного вызова, а блоки приходят
                // отдельными тиками main. В отчётах @phelicks (#44/#45) это дало ДВАДЦАТЬ одинаковых
                // строк с одной секундой — двадцать из двадцати четырёх строк лога, то есть человек
                // прислал диагностику, в которой почти не осталось диагностики.
                // Сравниваем фактический UID: если вход не менялся, это дубль, и делать нечего.
                let now = AudioDevices.systemDefaultInputUID()
                guard now != self.lastDefaultInputUID else { return }
                self.lastDefaultInputUID = now
                self.handleDeviceChange(reason: "сменился системный вход")
            }
        }

        // 7. Сторож первого буфера: формат-рассинхрон и «пин не взлетел» не бросают исключение —
        //    единственный надёжный признак поломки — тишина в колбэке.
        armWatchdog()
    }

    /// Сторож: 2с без единого буфера при активной записи → аварийная пересборка на системном входе.
    /// Порог 2.0с, не меньше: пробуждение уснувшего аудио-HAL занимает 1–3с (замерено на v0.1.41),
    /// короткий сторож убивал бы здоровые холодные старты по Bluetooth.
    private func armWatchdog() {
        watchdog?.cancel()
        deadSignalWatchdog?.cancel()
        // Сторож МЁРТВОГО СИГНАЛА: буферы идут, но в них побитовый ноль. Живой микрофон всегда даёт
        // шум ≠ 0, поэтому ровный ноль секундами = вход не отдаёт звук (устройство спит/замьючено/
        // отдаёт пустой поток). Раньше это молча превращалось в «тишина — пропуск»: пользователь
        // говорил 9 секунд и не получал НИЧЕГО без объяснения (баг-репорт). Порог 3.0с, а не
        // 2.0с как у сторожа буферов: нулевой ПЕРВЫЙ буфер — норма, устройство просыпается (видно в
        // логах и до переезда). Пересборка сохраняет уже накопленные сэмплы.
        let dead = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.lock.lock()
            let seen = self.firstBufferSeen, alive = self.nonZeroSeen
            self.lock.unlock()
            if alive { self.deadStrikes = 0 }
            guard seen, !alive else { return }   // буферов нет — это дело сторожа ниже; сигнал есть — всё хорошо
            // ЭСКАЛАЦИЯ (инцидент 23.07.2026): «системный вход» может оказаться
            // ТЕМ ЖЕ мёртвым устройством (внешний микрофон и есть дефолт) — тогда пересборка ходит
            // по кругу. А нули бывают и ПЕР-КЛИЕНТСКИМИ: coreaudiod молча глушит процесс, чей бандл
            // изменили на диске (TCC при этом отвечает authorized, система микрофон «видит»).
            // Лестница: 1) системный вход → 2) встроенный микрофон (другое железо) → 3) честно
            // сдаться и ОБЪЯСНИТЬ пользователю, что происходит.
            self.deadStrikes += 1
            switch self.deadStrikes {
            case 1:
                kbLog("voice rec: 3с цифрового нуля — вход не отдаёт звук, пересборка на системном входе")
                self.handleDeviceChange(reason: "вход отдаёт тишину", ignorePin: true)
            case 2:
                kbLog("voice rec: и системный вход отдаёт нули — пробую встроенный микрофон")
                self.handleDeviceChange(reason: "нули и на системном входе", ignorePin: true,
                                        forceUID: "BuiltInMicrophoneDevice")
            default:
                let exe = Bundle.main.executablePath ?? ""
                let gutted = exe.isEmpty || !FileManager.default.fileExists(atPath: exe)
                kbLog("voice rec: нули на всех входах — сдаюсь; бинарь на диске \(gutted ? "ОТСУТСТВУЕТ (бандл изменён под работающим процессом → системный mic-мьют)" : "на месте (микрофон/система)")")
                self.onNotice?(L10n.t(gutted ? "voice.deadBundle" : "voice.deadMic"))
                self.setCapturing(false)
                self.teardownSession()
                self.onDied?()
            }
        }
        deadSignalWatchdog = dead
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: dead)

        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.lock.lock(); let seen = self.firstBufferSeen; self.lock.unlock()
            guard !seen else { self.rebuildStrikes = 0; return }
            // ЭСКАЛАЦИЯ (ревью 21.07, №5): если и системный вход «немой» (открываемое, но молчащее
            // виртуальное устройство), без счётчика цикл «пересборка каждые 2с» молотил бы main
            // бесконечно (~200мс sync-стопов) и onDied не наступал никогда. Три страйка → сдаёмся.
            self.rebuildStrikes += 1
            if self.rebuildStrikes >= 3 {
                kbLog("voice rec: \(self.rebuildStrikes) пересборки без звука — сдаёмся")
                self.setCapturing(false)
                self.teardownSession()
                self.onDied?()
                return
            }
            kbLog("voice rec: 2с без единого буфера (попытка \(self.rebuildStrikes)) — пересборка на системном входе")
            self.handleDeviceChange(reason: "нет звука с выбранного микрофона", ignorePin: true)
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    /// Вход сменился/умер. Тёплый простой → отпускаем сессию (следующий старт возьмёт актуальное
    /// устройство). Активная запись → пересборка; собранные сэмплы и capturing СОХРАНЯЮТСЯ —
    /// VoiceController не должен заметить пересборку. Дебаунса нет: пересборка AVCaptureSession
    /// не порождает событий, которые её же вызвали (в отличие от AVAudioEngine, регресс 0.2.53).
    private func handleDeviceChange(reason: String, ignorePin: Bool = false, forceUID: String? = nil) {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        let wasCapturing = capturing
        teardownSession()
        guard wasCapturing else {
            kbLog("voice rec: \(reason) в тёплом простое — сессия отпущена")
            return
        }
        do {
            lock.lock(); loggedInput = false; firstBufferSeen = false; nonZeroSeen = false; lock.unlock()
            try buildEngine(ignorePin: ignorePin, forceUID: forceUID)
            kbLog("voice rec: \(reason) — переключился, запись продолжается")
        } catch {
            setCapturing(false)
            kbLog("voice rec: \(reason), рестарт не удался: \(error)")
            onDied?()   // VoiceController штатно сворачивает диктовку (индикатор/стриминг)
        }
    }

    @discardableResult
    func stop() -> [Float] {
        setCapturing(false)   // под lock: happens-before с чтением в делегате — хвост не допишется после снапшота
        watchdog?.cancel(); watchdog = nil
        deadSignalWatchdog?.cancel(); deadSignalWatchdog = nil
        lock.lock(); let out = samples; lock.unlock()
        // Тёплое окно (opt-in): держим сессию живой ещё warmSeconds — повторная диктовка стартует
        // мгновенно. Оранжевый индикатор горит это время (честно: микрофон формально открыт,
        // буферы молча отбрасываются). Иначе — сразу отпускаем.
        if AppSettings.shared.voiceWarmWindow, session != nil {
            scheduleWarmRelease()
        } else {
            releaseEngine()
        }
        return out
    }

    /// Полностью отпустить сессию и устройство (гасит оранжевый индикатор).
    private func releaseEngine() {
        warmRelease?.cancel(); warmRelease = nil
        teardownSession()
        setCapturing(false)
    }

    private func teardownSession() {
        watchdog?.cancel(); watchdog = nil
        deadSignalWatchdog?.cancel(); deadSignalWatchdog = nil
        if let o = disconnectObserver { NotificationCenter.default.removeObserver(o); disconnectObserver = nil }
        if let o = runtimeErrorObserver { NotificationCenter.default.removeObserver(o); runtimeErrorObserver = nil }
        if let b = defaultInputListener { AudioDevices.removeDefaultInputListener(b); defaultInputListener = nil }
        guard let s = session else { return }
        // Отвязываемся СРАЗУ, а тяжёлый разбор сессии — в фон (см. коммент про main в buildEngine):
        // stopRunning() блокирует, а мы на главном потоке, где живёт runloop CGEventTap.
        // Буферы, что успеют прийти до снятия делегата, отбрасываются по capturing == false.
        session = nil
        activeDeviceUID = ""; pinnedUID = ""
        sessionQueue.async {
            s.stopRunning()
            s.beginConfiguration()
            for i in s.inputs { s.removeInput(i) }
            for o in s.outputs { (o as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil); s.removeOutput(o) }
            s.commitConfiguration()
        }
    }

    /// Отложенное отпускание сессии после тёплого окна (если новой диктовки не случилось).
    private func scheduleWarmRelease() {
        warmRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.releaseEngine()
            kbLog("voice rec: тёплое окно истекло — микрофон отпущен")
        }
        warmRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
    }
}

// MARK: - Доставка аудио (sampleQueue; НЕ realtime — lock и аллокации допустимы)

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard st == noErr, let blockBuffer = block, let raw = abl.mBuffers.mData else { return }
        // blockBuffer владеет памятью raw — держим его живым на всё чтение.
        withExtendedLifetime(blockBuffer) {
            let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return }
            let ch = raw.assumingMemoryBound(to: Float.self)

            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))

            lock.lock()
            firstBufferSeen = true                      // сторож: буферы идут (и в тёплом простое тоже)
            if rms > 0 {
                nonZeroSeen = true
                // Живой сигнал — счётчик мёртвых попыток обнуляем ЗДЕСЬ. В стороже (3с) этого мало:
                // у диктовок короче трёх секунд он не выполняется вовсе, и страйки от давно
                // закрытого Zoom копились до ветки «сдаюсь» (ревью 28.07).
                if deadStrikes != 0 { deadStrikes = 0 }
            }           // вход реально живой (а не пустой поток)
            guard capturing else { lock.unlock(); return }   // тёплый холостой ход: отбрасываем молча
            let chunk = Array(UnsafeBufferPointer(start: ch, count: n))
            samples.append(contentsOf: chunk)
            let cb = _onChunk, lv = _onLevel
            let logNow = !loggedInput
            if logNow { loggedInput = true }
            lock.unlock()

            if logNow {
                // mNumberBuffers — чтобы исключить «читаем не тот канал»: при моно non-interleaved
                // должен быть ровно 1 буфер; если система вдруг отдаст стерео, мы бы читали только
                // левый канал и на микрофоне-в-правом-канале получали бы ровные нули.
                kbLog("voice rec: первый буфер RMS=\(String(format: "%.4f", rms)) frames=\(n) buffers=\(abl.mNumberBuffers)")
            }
            cb?(chunk)   // стриминг: отдать чанк живьём (nil в батч-режиме)
            // Троттлинг уровня ПО КАДРАМ (~12/сек при 16кГц), независимо от размера буферов CoreMedia.
            levelFrameAcc += n
            if levelFrameAcc >= 1300 {
                levelFrameAcc = 0
                lv?(rms)
            }
        }
    }
}
