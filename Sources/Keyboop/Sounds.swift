import AppKit
import AVFoundation

/// ЕДИНСТВЕННАЯ дверь, через которую Keyboop издаёт звуки.
///
/// ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (репорт #29, 27.07). Человек написал: «не работает настройка отключения
/// звука при переключении раскладки. Ни уведением ползунка громкости в ноль, ни выбором No sound,
/// ни прямым отключением звука». Он всё сделал правильно, и всё равно слышал звук.
///
/// Причина: помимо трёх НАСТРАИВАЕМЫХ звуков (конверсия / перевод / диктовка) движок звал
/// `NSSound.beep()` напрямую в четырёх местах, и системный бип не смотрит ни на один наш тумблер,
/// ни на громкость, ни на выбор «без звука». Один из этих вызовов стоит ровно на хоткее
/// переключения раскладки, когда конвертировать нечего — то есть человек жал хоткей, слышал звук,
/// шёл в настройки, выключал там всё подряд и не получал никакого эффекта. Классический молчаливый
/// отказ настройки: тумблер есть, а власти у него нет.
///
/// Теперь любое издание звука идёт отсюда, и глушитель один.
enum Sounds {

    /// Общий выключатель «вообще без звуков» (просьба автора 28.07: «в общих настройках, звук везде,
    /// типа вообще без звука»). Гасит ВСЁ, что издаём мы, включая системный бип и пасхалку.
    static var allMuted: Bool { AppSettings.shared.silentMode }

    /// Системный бип. Раньше звался напрямую и был неотключаем.
    static func beep() {
        guard !allMuted else { return }
        NSSound.beep()
    }

    /// Проиграть звук с громкостью. Нулевая громкость = НЕ ИГРАТЬ, а не «играть беззвучно»:
    /// ползунок в нуле должен выключать функцию, иначе он врёт (задача #60). Заодно не держим
    /// без нужды экземпляр NSSound и не будим аудиоустройство — на ноутбуке это слышимый щелчок
    /// реле у некоторых внешних карт.
    /// Возвращает созданный звук, чтобы вызывающий мог удержать ссылку (иначе оборвётся на середине).
    /// ⚠️ УДЕРЖИВАЕМ ССЫЛКУ (баг-репорт: «при быстром наборе иногда после первого
    /// срабатывания второй звук не срабатывает, потом снова начинает»). `NSSound.play()`
    /// асинхронный, а вызывающие создавали звук в ЛОКАЛЬНОЙ переменной — на выходе из области
    /// видимости объект освобождался, и проигрывание обрывалось или не начиналось вовсе. Свой
    /// синтезированный звук такого не показывал ровно потому, что его держали в свойстве.
    /// Держим по одному последнему на КАЖДЫЙ звук (ключ = имя): иначе перекрёстные звуки
    /// (конверсия + перевод подряд) глушили бы друг друга.
    private static var held: [String: NSSound] = [:]

    @discardableResult
    static func play(_ make: @autoclosure () -> NSSound?, volume: Double, as key: String = "default") -> NSSound? {
        guard !allMuted else { return nil }
        let v = max(0, min(1, volume))
        guard v > 0 else { return nil }
        guard let s = make() else { return nil }
        s.volume = Float(v)
        held[key]?.stop()      // быстрый повтор того же звука — переиграть с начала, а не наслаивать
        held[key] = s
        s.play()
        return s
    }

    // MARK: - Звук на горячем пути: мимо главного потока
    //
    // ⚠️ ЗАЧЕМ (19.11.2026, жалоба автора «конверсия скачкообразная, тормозит на фоне остального»).
    // В логе хвоста конверсии звук стоил 12–514 мс (обычно 50–230) — на главном потоке. А на главном
    // живёт наш АКТИВНЫЙ тап: пока `NSSound.play()` будит аудиоустройство, WindowServer ждёт колбэк,
    // и не проходит ни одна клавиша в системе. Человек печатал следующее слово, буквы зависали и
    // вываливались пачкой; значок раскладки перерисовывался тоже только после звука.
    //
    // Замер вне приложения (тот же Pop): NSSound — первый play 185 мс, дальше stop+play по 10–30 мс;
    // AVAudioPlayer заранее подготовленный — те же 9–34 мс. То есть сменой API это не лечится, лечится
    // только уходом с главного. С отдельной очереди вызывающему это стоит 0.01–0.2 мс.
    //
    // AVAudioPlayer, а не NSSound: про NSSound AppKit не обещает работы вне главного потока.
    // Плеер создаём заново на каждое срабатывание (как и NSSound раньше) — так он идёт в ТЕКУЩЕЕ
    // устройство вывода, если человек сменил наушники. Кэшируем только байты файла.

    private static let cueQueue = DispatchQueue(label: "ru.keyboop.sound", qos: .userInitiated)
    /// Только на cueQueue.
    private static var cueHeld: [String: AVAudioPlayer] = [:]
    /// Только на cueQueue. Байты звука по имени — диск читаем один раз.
    private static var cueBytes: [String: Data] = [:]

    /// Системный звук по имени («Pop») — мимо главного потока.
    static func playOffMain(named name: String, volume: Double, as key: String) {
        guard !allMuted else { return }
        let v = max(0, min(1, volume))
        guard v > 0 else { return }
        cueQueue.async {
            if cueBytes[name] == nil, let url = soundURL(named: name) {
                cueBytes[name] = try? Data(contentsOf: url)
            }
            guard let data = cueBytes[name] else {
                // Файл не нашли там, где ищет NSSound — играем по-старому, лишь бы не молчать.
                DispatchQueue.main.async { play(NSSound(named: name), volume: v, as: key) }
                return
            }
            startCue(data, volume: v, key: key)
        }
    }

    /// Свой синтезированный звук (байты в памяти) — мимо главного потока.
    static func playOffMain(data: Data, volume: Double, as key: String) {
        guard !allMuted else { return }
        let v = max(0, min(1, volume))
        guard v > 0 else { return }
        cueQueue.async { startCue(data, volume: v, key: key) }
    }

    private static func startCue(_ data: Data, volume: Double, key: String) {
        cueHeld[key]?.stop()   // быстрый повтор — переиграть с начала, а не наслаивать
        guard let p = try? AVAudioPlayer(data: data) else { cueHeld[key] = nil; return }
        p.volume = Float(volume)
        p.play()
        cueHeld[key] = p       // держим ссылку, иначе звук оборвётся
    }

    /// Те же папки, что просматривает `NSSound(named:)`.
    private static func soundURL(named name: String) -> URL? {
        let exts = ["aiff", "aif", "wav", "caf", "mp3", "m4a"]
        for ext in exts {
            if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        }
        let dirs = [NSHomeDirectory() + "/Library/Sounds", "/Library/Sounds",
                    "/Network/Library/Sounds", "/System/Library/Sounds"]
        for dir in dirs {
            for ext in exts {
                let path = "\(dir)/\(name).\(ext)"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
}
