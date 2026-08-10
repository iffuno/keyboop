import AVFoundation
import AppKit

/// ПЛЕЕР КЛИПА В КАРТОЧКЕ ИСТОРИИ (задача 101).
///
/// Своё оформление, а не `NSSound` и не системный контрол: карточка истории это наша поверхность, и
/// чужой плеер в ней выглядел бы вставным зубом. Всё, что здесь есть: кнопка, тонкая дорожка и время.
///
/// ⚠️ ОДНОВРЕМЕННО ИГРАЕТ РОВНО ОДИН КЛИП. Иначе достаточно кликнуть по трём карточкам подряд, чтобы
/// получить хор из трёх собственных голосов и ни одной кнопки, которая его останавливает: карточки
/// не знают друг о друге. Держим текущего игрока статически и глушим предыдущего (`current`).
///
/// ⚠️ Клип НЕ ЛЕЖИТ НА ДИСКЕ РАСШИФРОВАННЫМ. `AVAudioPlayer(data:)` получает байты из памяти, см.
/// `VoiceClips.data(for:)`. Соблазн «распакуем во временный файл, так проще» стоил бы нам того же
/// обещания, ради которого история вообще шифруется.
final class VoiceClipPlayerView: NSView {

    private static weak var current: VoiceClipPlayerView?

    private let clipID: String
    private let wave: [UInt8]
    fileprivate var player: AVAudioPlayer?
    private var ticker: Timer?

    private let button = NSButton()
    private let track = NSView()
    private let fill = NSView()
    private var waveView: ClipWaveView?
    private let time = NSTextField(labelWithString: "0:00")
    /// Фиксированные ступени, как в Telegram: трёх хватает, а плавный ползунок на карточке
    /// шириной в триста точек превратился бы в игру в снайпера.
    ///
    /// ⚠️ САМА КНОПКА ЖИВЁТ НЕ ЗДЕСЬ, а в заголовке окна истории (решение автора 10.08). Скорость
    /// общая для всех записей: человек выбирает, как ему удобно слушать, а не настраивает каждую
    /// заметку отдельно. Плеер только читает настройку и умеет подхватить её на лету (`applyRate`).
    static let rates: [Double] = [1.0, 1.5, 2.0]

    init(clipID: String, wave: [UInt8]? = nil) {
        self.clipID = clipID
        self.wave = wave ?? []
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    deinit { ticker?.invalidate() }

    private func build() {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L10n.t("clip.play"))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = L10n.t("clip.play")
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false

        if wave.isEmpty {
            // Запись сделана до появления волны — рисуем прежнюю полоску. Так старые карточки не
            // превращаются в пустое место, а новые получают картинку.
            track.wantsLayer = true
            track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            track.layer?.cornerRadius = 2
            fill.wantsLayer = true
            fill.layer?.backgroundColor = DS.coral.cgColor
            fill.layer?.cornerRadius = 2
            track.addSubview(fill)
            fill.translatesAutoresizingMaskIntoConstraints = false
        } else {
            waveView = ClipWaveView(wave: wave)
            waveView!.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(waveView!)
        }
        track.translatesAutoresizingMaskIntoConstraints = false

        // Моноширинные цифры: без них время дёргает дорожку туда-сюда на каждой смене секунды.
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        time.translatesAutoresizingMaskIntoConstraints = false

        addSubview(button); addSubview(track); addSubview(time)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),

            track.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: wave.isEmpty ? 4 : 18),
            track.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -8),


            time.trailingAnchor.constraint(equalTo: trailingAnchor),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        if let wv = waveView {
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: track.trailingAnchor),
                wv.topAnchor.constraint(equalTo: track.topAnchor),
                wv.bottomAnchor.constraint(equalTo: track.bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fillWidth
            ])
        }
        // Длительность показываем ДО первого воспроизведения: пустая дорожка без числа выглядит как
        // «файла нет». Тянем её из заголовка клипа, звук при этом не декодируется.
        if let d = duration() { time.stringValue = Self.mmss(d) }
    }

    private lazy var fillWidth: NSLayoutConstraint = fill.widthAnchor.constraint(equalToConstant: 0)

    // MARK: - Воспроизведение

    private func duration() -> Double? {
        if let p = player { return p.duration }
        guard let data = VoiceClips.data(for: clipID), let p = try? AVAudioPlayer(data: data) else { return nil }
        return p.duration
    }

    @objc private func toggle() {
        if let p = player, p.isPlaying { pause(); return }
        if player == nil {
            guard let data = VoiceClips.data(for: clipID), let p = try? AVAudioPlayer(data: data) else {
                // Файл пропал или не расшифровывается (перевыпуск ключа). Честно гасим кнопку вместо
                // тишины в ответ на клик: «нажал и ничего» читается как поломка приложения.
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                button.toolTip = L10n.t("clip.gone")
                button.isEnabled = false
                kbLog("аудио диктовки: клип не открывается (\(clipID))")
                return
            }
            // ⚠️ `enableRate` ОБЯЗАН быть выставлен ДО `prepareToPlay()`: после подготовки
            // AVAudioPlayer уже собрал цепочку без изменения темпа, и `rate` молча ничего не делает.
            p.enableRate = true
            p.rate = Float(AppSettings.shared.voiceClipRate)
            p.prepareToPlay()
            player = p
            time.stringValue = Self.mmss(p.duration)
        }
        Self.current?.pause()          // чужой клип замолкает, прежде чем заговорит наш
        Self.current = self
        player?.play()
        button.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: L10n.t("clip.pause"))
        button.toolTip = L10n.t("clip.pause")
        button.contentTintColor = DS.coral
        startTicker()
    }

    /// Подхватить общую скорость. Зовётся у ИГРАЮЩЕГО клипа, когда человек щёлкнул кнопку в
    /// заголовке окна: темп меняется прямо посреди фразы, без остановки и перемотки.
    static func applyRateToCurrent() { current?.player?.rate = Float(AppSettings.shared.voiceClipRate) }

    private func pause() {
        player?.pause()
        stopTicker()
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L10n.t("clip.play"))
        button.toolTip = L10n.t("clip.play")
        button.contentTintColor = .secondaryLabelColor
    }

    /// Дорожка обновляется 10 раз в секунду. Чаще не нужно: полоска шириной в сотню точек всё равно
    /// не покажет разницы, а окно истории умеет висеть открытым часами.
    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common — иначе полоска встаёт на время прокрутки списка
        ticker = t
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard let p = player else { return }
        let done = p.duration > 0 ? p.currentTime / p.duration : 0
        setProgress(done)
        time.stringValue = Self.mmss(p.duration - p.currentTime)
        guard !p.isPlaying else { return }
        // Доиграл: возвращаем в начало, чтобы вторая попытка не требовала перемотки.
        p.currentTime = 0
        setProgress(0)
        time.stringValue = Self.mmss(p.duration)
        pause()
    }

    /// Перемотка кликом по дорожке. Без ручки-кружка: она бы просила попадания в 8 точек на
    /// карточке, где и так тесно, а клип длиной в полминуты этого не стоит.
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard track.frame.contains(pt) else { super.mouseDown(with: event); return }
        if player == nil {
            guard let d = VoiceClips.data(for: clipID), let np = try? AVAudioPlayer(data: d) else { return }
            np.enableRate = true
            np.rate = Float(AppSettings.shared.voiceClipRate)
            np.prepareToPlay()
            player = np
        }
        guard let p = player else { return }
        let ratio = max(0, min(1, (pt.x - track.frame.minX) / max(1, track.frame.width)))
        p.currentTime = p.duration * Double(ratio)
        setProgress(Double(ratio))
        time.stringValue = Self.mmss(p.duration - p.currentTime)
    }

    private func setProgress(_ done: Double) {
        if let wv = waveView { wv.progress = CGFloat(done) }
        else { fillWidth.constant = track.bounds.width * CGFloat(done) }
    }

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Остановить всё, что играет (закрытие окна истории, очистка).
    static func stopAll() { current?.pause(); current = nil }
}

/// ВОЛНА ЗАПИСИ вместо ровной полоски прогресса (просьба автора 10.08).
///
/// ⚠️ Имя `ClipWaveView`, а не `WaveformView`: последнее уже занято живым индикатором уровня во
/// время диктовки (`VoiceIndicator`). Разные вещи: там уровень в реальном времени, здесь картинка
/// уже записанного.
///
/// Смысл не в красоте: по волне видно, **где в записи речь, а где пауза**, и на длинной заметке это
/// единственный способ ткнуть в нужное место, не переслушивая всё подряд.
///
/// Огибающая считается один раз при сохранении клипа (`VoiceClips.envelope`) и лежит рядом с
/// записью в истории. Здесь только рисование: ни декодирования, ни разбора звука.
final class ClipWaveView: NSView {
    private let wave: [UInt8]
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init(wave: [UInt8]) {
        self.wave = wave
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    override func draw(_ dirtyRect: NSRect) {
        guard !wave.isEmpty, bounds.width > 4 else { return }
        let barW: CGFloat = 2, gap: CGFloat = 1
        // Столбиков ровно столько, сколько влезает: при узком окне соседние корзины сливаем по
        // максимуму, а не выбрасываем, иначе короткий громкий слог мог бы пропасть из картинки.
        let count = max(1, Int((bounds.width + gap) / (barW + gap)))
        let played = bounds.width * max(0, min(1, progress))
        let mid = bounds.height / 2
        for i in 0..<count {
            let lo = i * wave.count / count, hi = max(lo + 1, (i + 1) * wave.count / count)
            let peak = CGFloat(wave[lo..<min(hi, wave.count)].max() ?? 0) / 15.0
            // Минимальная высота 2 точки: тишина обязана остаться видимой ниткой, иначе в паузах
            // волна распадается на куски и читается как «тут запись оборвалась».
            let h = max(2, peak * (bounds.height - 2))
            let x = CGFloat(i) * (barW + gap)
            let r = NSRect(x: x, y: mid - h / 2, width: barW, height: h)
            (x + barW <= played ? DS.coral : NSColor.white.withAlphaComponent(0.22)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }
}
