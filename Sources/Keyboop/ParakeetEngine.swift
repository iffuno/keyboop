import Foundation
#if arch(arm64) && !KEYBOOP_NO_PARAKEET
import FluidAudio

/// Распознавание речи через Parakeet (FluidAudio · CoreML · Apple Neural Engine).
/// Офлайн по принципу №2: модель грузится из локальной папки, сеть в рантайме запрещена
/// (`DownloadUtils.enforceOffline`). Скачивание модели — только по явной кнопке пользователя.
/// Требует macOS 14+. API сверен по исходникам FluidAudio.
final class ParakeetEngine {
    static let shared = ParakeetEngine()
    private var manager: AsrManager?
    private var decoderLayers = 0
    private(set) var ready = false

    /// Папка с моделью v3 (кэш FluidAudio: .mlmodelc-бандлы + parakeet_vocab.json).
    static var modelDir: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    /// Модель уже скачана?
    static var modelInstalled: Bool { AsrModels.modelsExist(at: modelDir) }

    /// Загрузить модель из локальной папки (офлайн). Идемпотентно.
    func loadIfNeeded() async -> Bool {
        if ready { return true }
        guard Self.modelInstalled else { kbLog("parakeet: модель не установлена"); return false }
        do {
            let t0 = ProcessInfo.processInfo.systemUptime
            DownloadUtils.enforceOffline = true               // в рантайме — ноль сети (принцип №2)
            let models = try await AsrModels.load(from: Self.modelDir, version: .v3)
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            decoderLayers = await mgr.decoderLayerCount
            manager = mgr
            ready = true
            // Время в лог: на чистом контейнере CoreML компилирует модель под ANE десятками секунд
            // (замер 21.07: 43с), потом кэширует. Видно, окупается ли прогрев из preload().
            kbLog("parakeet: модель загружена за \(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000))мс (layers=\(decoderLayers))")
            return true
        } catch {
            kbLog("parakeet: загрузка не удалась: \(error)")
            return false
        }
    }

    /// Транскрибировать 16кГц mono Float32 (наш буфер от AVAudioEngine — как у whisper).
    /// `language` — НЕ выбор языка модели, а ФИЛЬТР ПО ПИСЬМЕННОСТИ (исследование 03.08.2026,
    /// подробности ниже).
    ///
    /// Задать язык самой модели нельзя в принципе: сотрудник NVIDIA прямо ответил, что
    /// parakeet-tdt-0.6b-v3 не принимает язык на вход и не отдаёт определённый на выход, а тикет с
    /// такой просьбой закрыт как «не будет». Тот же запрос уже подавали и в FluidAudio, закрыт как
    /// невыполнимый. Поэтому ждать здесь настоящего выбора языка бессмысленно.
    ///
    /// Что параметр делает на самом деле (doc в AsrManager.swift:475): при заданном языке кандидаты
    /// top-K, не совпадающие по ПИСЬМЕННОСТИ, отбрасываются в пользу подходящих. Это лечит ровно
    /// нашу жалобу #67: у модели один словарь на 25 языков, и, решив что речь русская, она пишет
    /// кириллицей даже английские слова («Дидю коммит энд пуш» вместо «Did you commit and push»).
    /// С фильтром английская речь кириллицей уже не запишется.
    ///
    /// ⚠️ `nil` здесь означает НЕ автоопределение, а ВЫКЛЮЧЕННЫЙ фильтр (TdtDecoderV3: needsTopK =
    /// language != nil). Поэтому для «Авто» мы честно передаём nil: сказать модели «определи сам»
    /// нечем, а фильтровать письменность, не зная языка, не по чему.
    func transcribe(samples: [Float], language: String) async -> String {
        guard let mgr = manager else { return "" }
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            // Коды у нас те же ISO, что у движка («ru», «en»), поэтому маппинг прямой.
            // «auto» и всё незнакомое → nil, то есть фильтр не включаем.
            let lang = Language(rawValue: language)
            let result = try await mgr.transcribe(samples, decoderState: &state, language: lang)
            return result.text
        } catch {
            kbLog("parakeet: ошибка транскрипции: \(error)")
            return ""
        }
    }

    /// Скачать модель v3 (~465 МБ) — ЯВНОЕ действие пользователя (кнопка в настройках).
    /// СНАЧАЛА пробуем зеркало keyboop.com (сервер в Москве — HuggingFace из РФ «застревает на N%»,
    /// репорты + тест Nemotron 23.07). Не вышло — фолбэк на штатный загрузчик FluidAudio (HF).
    /// `progress` — доля 0…1.
    func download(progress: @escaping (Double) -> Void) async -> Bool {
        if await downloadFromMirror(progress: progress) { return true }
        do {
            DownloadUtils.enforceOffline = false
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { p in
                progress(p.fractionCompleted)
            })
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            decoderLayers = await mgr.decoderLayerCount
            manager = mgr
            ready = true
            DownloadUtils.enforceOffline = true
            kbLog("parakeet: модель скачана и загружена (HF-фолбэк, layers=\(decoderLayers))")
            return true
        } catch {
            DownloadUtils.enforceOffline = true
            kbLog("parakeet: скачивание не удалось: \(error)")
            return false
        }
    }

    /// Зеркало: качаем tar.gz-бандл с keyboop.com → распаковываем в кэш FluidAudio → грузим офлайн.
    /// Бандл — байт-в-байт та же папка, что создаёт штатный загрузчик (parakeet-tdt-0.6b-v3 с
    /// .mlmodelc + vocab). Любой сбой (сеть/распаковка/структура) → false, вызывающий уйдёт на HF.
    private func downloadFromMirror(progress: @escaping (Double) -> Void) async -> Bool {
        guard let url = URL(string: "https://keyboop.com/models/parakeet/parakeet-v3.tar.gz") else { return false }
        let dir = Self.modelDir
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-v3-\(UUID().uuidString).tar.gz")
        guard await TarballDownloader.download(url, to: tmp, progress: progress) else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // ⚠️ ЦЕЛОСТНОСТЬ АРХИВА (31.07). До этого дня 466-мегабайтный tar.gz распаковывался
        // системным tar'ом в кэш модели БЕЗ ЕДИНОЙ ПРОВЕРКИ — в непесочном процессе, который читает
        // клавиатуру. Соседний ModelDownloader при этом честно сверяет потоковый SHA-256 и
        // отказывается ставить файл при несовпадении; здесь этого просто забыли. Битое зеркало,
        // оборванная докачка или подменённый файл на сервере проходили насквозь.
        //
        // ⚠️ ОБЯЗАТЕЛЬСТВО РЕЛИЗА: при ЛЮБОЙ перезаливке parakeet-v3.tar.gz этот хеш надо обновить,
        // иначе зеркало начнёт отвергаться и все уйдут на медленный HF-фолбэк. Считать `sha256sum`
        // по файлу на раздающем хосте, а не по локальной копии: сверять надо ровно то, что получит
        // пользователь. Размер держим рядом как дешёвую отсечку — он ловит обрыв докачки до того,
        // как мы потратим время на хеширование полугигабайта.
        let expectedSHA = "05ba35d6c7a4c486bab4c729175f09f73db81bd7dbf6f99e9187fa5dbaed98fe"
        let expectedSize: Int64 = 466_626_231
        let gotSize = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? nil
        guard gotSize == expectedSize else {
            kbLog("parakeet mirror: размер не сошёлся (\(gotSize.map(String.init) ?? "?") ≠ \(expectedSize)) — уходим на HF")
            return false
        }
        guard ModelDownloader.sha256(ofFileAt: tmp) == expectedSHA else {
            kbLog("parakeet mirror: SHA-256 не сошёлся — архив отклонён, уходим на HF")   // сам хеш не логируем
            return false
        }
        kbLog("parakeet mirror: архив проверен (размер + SHA-256) — распаковываю")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Распаковка через системный tar (приложение не в песочнице). -C — прямо в кэш модели.
            // --no-same-owner: не пытаться восстанавливать владельца из архива. Содержимое уже
            // прибито хешем выше, так что это страховка второго рубежа, а не основная защита.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["--no-same-owner", "-xzf", tmp.path, "-C", dir.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0, Self.modelInstalled else {
                kbLog("parakeet mirror: распаковка/структура не сошлись (tar=\(p.terminationStatus)) — уходим на HF")
                return false
            }
            DownloadUtils.enforceOffline = true
            let models = try await AsrModels.load(from: dir, version: .v3)
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            decoderLayers = await mgr.decoderLayerCount
            manager = mgr
            ready = true
            kbLog("parakeet: модель c зеркала keyboop.com (layers=\(decoderLayers))")
            return true
        } catch {
            kbLog("parakeet mirror: \(error) — уходим на HF")
            return false
        }
    }

    /// Удалить скачанную модель (освободить место). Сбрасывает и состояние в памяти, чтобы при
    /// следующей диктовке честно сработал onNeedModel (а не отдавал пустой результат с мёртвым manager).
    ///
    /// ⚠️ Тяжёлую работу — освобождение CoreML-менеджера (AsrManager/ANE) и `removeItem` (~465 МБ) —
    /// делаем В ФОНЕ, НЕ на main-потоке. Причина (репорт 03.07.2026: окно настроек намертво зависало
    /// на удалении, пользователь закрывал через Force Quit): релиз AsrManager на main мог упереться в
    /// его собственный cleanup (или долгий teardown ANE/Metal) и заморозить main-runloop → окно не
    /// закрыть. Состояние (manager/ready) обнуляем сразу на вызывающем потоке (дёшево), сам релиз и
    /// удаление файлов уводим в фон; `completion` зовём обратно на main.
    func deleteModel(completion: @escaping (Bool) -> Void) {
        let old = manager          // придержим ссылку, чтобы освободить AsrManager в ФОНЕ (не на main)
        manager = nil
        ready = false
        decoderLayers = 0
        let dir = Self.modelDir
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if FileManager.default.fileExists(atPath: dir.path) {
                do { try FileManager.default.removeItem(at: dir); kbLog("parakeet: модель удалена (\(dir.path))") }
                catch { ok = false; kbLog("parakeet: удаление не удалось: \(error)") }
            } else {
                kbLog("parakeet: удалять нечего")
            }
            _ = old                // держим до конца блока → AsrManager освобождается ЗДЕСЬ, в фоне
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

#else
/// Intel-заглушка: Parakeet живёт на Neural Engine, FluidAudio собрана только под arm64 —
/// в x86-срезе universal-сборки его физически нет. Интерфейс идентичен боевому классу,
/// чтобы остальной код компилировался без единого #if: modelInstalled=false означает
/// «движок недоступен», и вся логика (willUseParakeet, каталог моделей, onNeedModel)
/// сама сводится к whisper-пути.
final class ParakeetEngine {
    static let shared = ParakeetEngine()
    private(set) var ready = false
    static var modelInstalled: Bool { false }
    func loadIfNeeded() async -> Bool { false }
    // Сигнатура обязана совпадать с arm64-версией: universal-сборка компилирует ОБЕ ветки,
    // и расхождение уронит именно x86-проход, то есть поддержку Intel.
    func transcribe(samples: [Float], language: String) async -> String { "" }
    func download(progress: @escaping (Double) -> Void) async -> Bool {
        kbLog("parakeet: недоступен на Intel (нет Neural Engine)"); return false
    }
    func deleteModel(completion: @escaping (Bool) -> Void) { DispatchQueue.main.async { completion(true) } }
}
#endif
