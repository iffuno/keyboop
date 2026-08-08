import AppKit

/// Плавающая плашка у курсора во время диктовки. «Слушаю» — живой оранжевый waveform по громкости
/// микрофона; «Распознаю» — спокойное «дыхание» баров + периодический декодер-эффект на тексте.
/// Ширина плашки — ПО СОДЕРЖИМОМУ (а не фикс), чтобы не была шире текста.
final class VoiceIndicator {
    static let shared = VoiceIndicator()
    /// Фирменный коралл #FF7A59 («наш оранжевый»).
    static let coral = NSColor(srgbRed: 1.0, green: 0.478, blue: 0.349, alpha: 1)

    private var panel: NSPanel?
    private var bg: NSVisualEffectView?
    private let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 54, height: 20))
    private let label = NSTextField(labelWithString: "")
    private var decoderLoop: Timer?     // раз в 3с запускает вспышку-декодер
    private var decoderAnim: Timer?     // текущая вспышка

    private enum Mode { case recording, processing, toast }
    private var mode: Mode = .recording
    /// Номер текущего показа. Растёт на КАЖДЫЙ present. Нужен отложенным действиям (тост прячет себя
    /// через 2.2с), чтобы понять: то, что я собирался спрятать, всё ещё на экране, или его давно
    /// сменили. Без этого отложенное «спрятать» гасило чужую, более свежую плашку.
    private var presentGen = 0

    private let H: CGFloat = 38         // высота плашки
    private let pad: CGFloat = 13       // боковые отступы
    private let gap: CGFloat = 9        // зазор иконка↔текст
    private let waveW: CGFloat = 54     // ширина waveform
    private let dotW: CGFloat = 7       // диаметр точки-статуса у тоста
    /// ⚠️ БЫЛ БЕЗЫМЯННЫЙ КРУЖОК (автор 08.08). Коралловая точка ничего не означала и занимала место,
    /// где по смыслу стоит знак того, кто говорит. Берём тот же рисунок, что в строке меню, значит
    /// плашка узнаётся как наша с первого взгляда и без подписи.
    private let dot = NSImageView()

    /// Знак Keyboop для плашки. Рисунок общий со строкой меню (`menubar-mark.png`), поэтому он и
    /// там, и тут один и тот же, а не две похожие картинки.
    ///
    /// ⚠️ БЕЛЫЙ, КАК В ОРИГИНАЛЕ (автор 08.08: «логотип в оригинале белым, без вольностей»). Сначала
    /// я перекрасил его в коралловый, чтобы он занял место коралловой точки. Это была отсебятина:
    /// знак есть знак, и перекрашивать его под соседний элемент нельзя.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = 13, w = (h * (src.size.width / max(src.size.height, 1))).rounded()
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        return img
    }()
    private let maxLiveW: CGFloat = 460 // потолок для живого текста стриминга (дальше режем хвостом)

    func showRecording() { DispatchQueue.main.async { self.present(L10n.t("voice.listening"), .recording) } }

    /// Живой текст потоковой диктовки прямо на плашке, вместо слова «Слушаю».
    ///
    /// Зачем не печатать его сразу в поле (решение автора 30.07): потоковая расшифровка ПОСТОЯННО
    /// переписывается, пока модель уточняет гипотезу. На плашке меняющаяся строка — это норма, а в
    /// чужом документе это значит писать и стирать чужой текст. Плюс в Electron-приложениях наша
    /// синтетика молча игнорируется, и «печать на лету» там не работала вовсе. Финальный текст
    /// вставляется один раз, в конце.
    ///
    /// Показываем ХВОСТ строки: интересны последние сказанные слова, а не начало фразы, уехавшее за
    /// край. Ширину ограничиваем, иначе плашка растёт на весь экран и перестаёт быть плашкой.
    func showLive(_ text: String) {
        DispatchQueue.main.async {
            guard self.mode == .recording, let p = self.panel, p.isVisible else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.label.stringValue = t.isEmpty ? L10n.t("voice.listening") : self.tail(t)
            // Позицию НЕ пересчитываем: плашка уже стоит у каретки, а переставлять её на каждом
            // уточнении текста значит дёргать её под рукой у говорящего. Растём только вправо.
            self.relayout(text: self.label.stringValue, showWave: true, panel: p)
        }
    }

    /// Обрезать слева до maxLiveW, добавив «…». Считаем по фактической ширине шрифта, а не по числу
    /// символов: у кириллицы и латиницы разная ширина, и счёт «по буквам» дал бы прыгающую плашку.
    private func tail(_ s: String) -> String {
        let font = label.font ?? .systemFont(ofSize: 12, weight: .medium)
        func w(_ x: String) -> CGFloat { (x as NSString).size(withAttributes: [.font: font]).width }
        guard w(s) > maxLiveW else { return s }
        var chars = Array(s)
        while !chars.isEmpty, w("…" + String(chars)) > maxLiveW { chars.removeFirst() }
        return "…" + String(chars)
    }
    func showProcessing() { DispatchQueue.main.async { self.present(L10n.t("voice.recognizing"), .processing) } }
    func hide() {
        DispatchQueue.main.async {
            if self.panel?.isVisible == true { kbLog("hud: спрятал") }
            self.presentGen += 1          // всё отложенное, что целилось в текущий показ, отменяется
            self.stopTimers(); self.wave.stop()
            self.panel?.orderOut(nil)
        }
    }

    /// Живой уровень микрофона (RMS) → waveform. Зовётся часто; вне записи молча игнорируем.
    func pushLevel(_ rms: Float) {
        DispatchQueue.main.async { guard self.mode == .recording, self.panel?.isVisible == true else { return }; self.wave.push(rms) }
    }

    /// Короткий тост у курсора (обучение на отмене и т.п.) — сам прячется через ~2.2с.
    ///
    /// ⚠️ ДВА ДЕФЕКТА, ПОЙМАННЫЕ 04.08.2026 ПО ЖАЛОБЕ «плашка „Слушаю“ иногда пропадает во время
    /// диктовки». Оба здесь.
    ///
    /// Первый: отложенное `hide()` не проверяло НИЧЕГО. Показали тост, через 2.2с гасим — а за эти
    /// 2.2 секунды человек мог начать диктовать, и таймер убивал уже другую, живую плашку. Лечится
    /// номером показа: гасим только если с тех пор ничего нового не показывали.
    ///
    /// Второй: тост во время записи затирал «Слушаю» насовсем. А тосты приходят и ПОСРЕДИ диктовки
    /// (микрофон отдал тишину, расшифровка зависла, поле оказалось паролем). Человек видел, как
    /// индикатор записи молча исчезал, хотя запись шла. Теперь после тоста возвращаемся в «Слушаю».
    func showToast(_ text: String) {
        DispatchQueue.main.async {
            let wasRecording = (self.mode == .recording && self.panel?.isVisible == true)
            self.present(text, .toast)
            let gen = self.presentGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, self.presentGen == gen else { return }   // показали что-то новее — не наше дело
                if wasRecording {
                    // Запись всё ещё идёт: если бы она кончилась, VoiceController уже позвал бы
                    // showProcessing или hide, а это сменило бы номер показа и мы бы сюда не дошли.
                    kbLog("hud: тост отыграл, возвращаю «Слушаю» (запись продолжается)")
                    self.present(L10n.t("voice.listening"), .recording)
                } else {
                    self.hide()
                }
            }
        }
    }

    /// СНИМОК ПЛАШКИ В ФАЙЛ (dev-хук `KEYBOOP_TOAST=1`, 08.08.2026).
    ///
    /// Хук показывал плашку, но снимка не сохранял, а поймать её снаружи не выходит: она живёт две
    /// секунды и ускользает между опросами списка окон (проверено). Для переделки внешнего вида на
    /// неё надо смотреть много раз, а «на память» мы уже смотрели — так в ней до 06.08 жил чужой
    /// зелёный цвет.
    ///
    /// ⚠️ Подложку рисуем САМИ. Фон плашки это `NSVisualEffectView` с размытием ПОЗАДИ окна, и в
    /// битмап он приходит пустым: размывать в отрыве от экрана нечего. Без подложки снимок выходит
    /// прозрачным, и белый текст на нём не виден вовсе.
    func saveShot(to path: String) {
        guard let p = panel, let v = p.contentView else { return }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()   // тон HUD-плашки, чтобы снимок читался
        NSBezierPath(roundedRect: v.bounds, xRadius: 10, yRadius: 10).fill()
        rep.draw(in: v.bounds)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        kbLog("hud: снимок плашки сохранён (\(Int(v.bounds.width))×\(Int(v.bounds.height)))")
    }

    // MARK: -

    private func present(_ text: String, _ m: Mode) {
        let p = panel ?? makePanel(); panel = p
        presentGen += 1
        mode = m
        stopTimers()
        label.stringValue = text
        // ⚠️ БЫЛ СИСТЕМНЫЙ ЗЕЛЁНЫЙ (автор 06.08: «очень странный цвет»). Зелёный не наш: во всём
        // приложении статус показывает коралловый акцент, а текст остаётся белым. Зелёная строка на
        // тёмной плашке читалась как чужой элемент, попавший сюда по ошибке.
        label.textColor = .labelColor
        dot.isHidden = (m != .toast)

        let showWave = (m != .toast)
        relayout(text: text, showWave: showWave, panel: p)

        switch m {
        case .recording:
            wave.color = Self.coral
            wave.start(shimmer: false)
        case .processing:
            wave.color = Self.coral.withAlphaComponent(0.9)
            wave.start(shimmer: true)
            startDecoderLoop(text)
        case .toast:
            wave.stop()
            // ⚠️ ОДНА ВСПЫШКА, А НЕ ЦИКЛ. У «распознаю» декодер повторяется раз в три секунды, потому
            // что ожидание там длинное и его надо чем-то занять. Тост живёт 2.2 с, и повтор съел бы
            // время у самого сообщения: вспышка тратит 0.34 с, читать остаётся полторы секунды.
            decoderFlash(text)
        }

        positionAtCursor(p)
        p.orderFrontRegardless()
    }

    /// Ширина плашки = pad + [waveform + gap] + ширина-текста + pad. Текст меряем по шрифту.
    private func relayout(text: String, showWave: Bool, panel p: NSPanel) {
        let font = label.font ?? .systemFont(ofSize: 12, weight: .medium)
        let lblW = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        // У записи слева waveform, у тоста точка. Ширина считается одинаково, поэтому боковые
        // отступы у всех состояний совпадают и плашка не «прыгает» при смене режима.
        let markSize = Self.markImage?.size ?? NSSize(width: dotW, height: dotW)
        let iconW = showWave ? waveW : markSize.width
        // ⚠️ У ТОСТА ЗАЗОР УЖЕ, ЧЕМ У ЗАПИСИ, И ЭТО НЕ ПРОИЗВОЛ (замер 08.08.2026, жалоба пользователя
        // «плохо выравнивание точки и текста»). Померил плашку по пикселям: по вертикали точка
        // стоит ровно (расхождение 0.2 пт, невидимо), поля слева и справа равны. Кривым выглядело
        // другое: зазор до текста был 10.5 пт при внешнем поле 13, то есть почти такой же. Глаз
        // видел не «значок и текст», а три равноудалённых пятна, и точка читалась как отдельный
        // элемент, а не часть сообщения. Группировка требует, чтобы внутренний зазор был заметно
        // меньше внешнего поля.
        // У waveform зазор оставлен прежним: он широкий сам по себе и в отдельный элемент не
        // распадается.
        let iconGap = showWave ? gap : gap - 4
        let total = pad + iconW + iconGap + lblW + pad

        var f = p.frame
        f.size = NSSize(width: total, height: H)
        p.setFrame(f, display: false)
        bg?.frame = NSRect(x: 0, y: 0, width: total, height: H)

        wave.isHidden = !showWave
        if showWave { wave.frame = NSRect(x: pad, y: (H - 20) / 2, width: waveW, height: 20) }
        dot.frame = NSRect(x: pad, y: ((H - markSize.height) / 2).rounded(),
                           width: markSize.width, height: markSize.height)
        let lx = pad + iconW + iconGap
        label.frame = NSRect(x: lx, y: (H - 18) / 2, width: lblW, height: 18)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // HUD-плашка всегда тёмная (.hudWindow) — пиннем тёмную тему, чтобы .labelColor в светлой
        // системной теме не резолвился в тёмный (тёмный текст на тёмном HUD). См. AppBanner.
        p.appearance = NSAppearance(named: .darkAqua)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let v = NSVisualEffectView(frame: p.contentView!.bounds)
        v.autoresizingMask = [.width, .height]
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 11
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        bg = v

        v.addSubview(wave)

        // Точка-статус для тостов: у плашки записи роль индикатора играет waveform, а тост без
        // него выглядел голым текстом в прямоугольнике. Одна коралловая точка возвращает ему вид
        // сообщения и держит ту же ритмику отступов, что у остальных состояний.
        dot.image = Self.markImage
        dot.imageScaling = .scaleNone
        v.addSubview(dot)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        v.addSubview(label)

        p.contentView?.addSubview(v)
        return p
    }

    /// Плашку ставим у КАРЕТКИ ВВОДА (место, куда пойдёт текст), а не у курсора мыши. Если каретка
    /// недоступна (Electron/web, нет фокуса) — падаем на прежнее поведение (по мыши). Тосты (обучение
    /// на отмене) — всегда по мыши: там нет «места ввода».
    private func positionAtCursor(_ p: NSPanel) {
        if mode != .toast, let caret = CaretLocator.caretScreenRect() {
            kbLog("hud: у каретки (\(Int(caret.minX)),\(Int(caret.minY)))")
            positionNearCaret(p, caret)
        } else {
            if mode != .toast { kbLog("hud: каретка недоступна → по курсору мыши") }
            positionNearMouse(p)
        }
    }

    /// Плашка чуть НИЖЕ каретки (как системная диктовка), не заслоняя текст; если снизу не влезает —
    /// над кареткой. Клампим в границы того экрана, где каретка.
    private func positionNearCaret(_ p: NSPanel, _ caret: NSRect) {
        var origin = NSPoint(x: caret.minX, y: caret.minY - p.frame.height - 6)
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        if let f = screen?.frame {
            if origin.y < f.minY + 8 { origin.y = caret.maxY + 6 }   // снизу нет места → над кареткой
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - p.frame.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - p.frame.height - 8)
        }
        p.setFrameOrigin(origin)
    }

    private func positionNearMouse(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - p.frame.height - 16)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.frame {
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - p.frame.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - p.frame.height - 8)
        }
        p.setFrameOrigin(origin)
    }

    // MARK: - Декодер-эффект (распознавание)

    private func startDecoderLoop(_ finalText: String) {
        decoderLoop?.invalidate()
        // Первая вспышка — сразу при входе в распознавание, затем раз в 3с (если оно долгое).
        decoderFlash(finalText)
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.decoderFlash(finalText) }
        RunLoop.main.add(t, forMode: .common)
        decoderLoop = t
    }

    /// Быстрая декодер-вспышка: текст «дешифруется» слева-направо за ~0.34с.
    private func decoderFlash(_ finalText: String) {
        decoderAnim?.invalidate()
        let chars = Array(finalText)
        let n = chars.count
        guard n > 0 else { return }
        // ⚠️ ШУМ ПОДБИРАЕМ ПОД ПИСЬМЕННОСТЬ ТЕКСТА. Набор был только кириллическим, и на английском
        // интерфейсе латинская фраза «дешифровалась» бы русскими буквами — читается как сбой шрифта,
        // а не как эффект.
        let cyr = finalText.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let glyphs = Array(cyr ? "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЭЮЯ#%&@$/\\?01"
                               : "ABCDEFGHIJKLMNOPQRSTUVWXYZ#%&@$/\\?01")
        let frames = 12
        var fr = 0
        let t = Timer(timeInterval: 0.028, repeats: true) { [weak self] timer in
            // Тост тоже «дешифруется»: одна вспышка на появлении (автор 08.08).
            guard let self, self.mode == .processing || self.mode == .toast else { timer.invalidate(); return }
            fr += 1
            let lockUntil = Int((CGFloat(fr) / CGFloat(frames)) * CGFloat(n))
            var s = String(); s.reserveCapacity(n)
            for i in 0..<n {
                let c = chars[i]
                if i < lockUntil || c == "…" || c == " " || c == "." || c == "," {
                    s.append(c)
                } else {
                    s.append(glyphs.randomElement() ?? c)
                }
            }
            self.label.stringValue = s
            if fr >= frames {
                self.label.stringValue = finalText
                timer.invalidate(); self.decoderAnim = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        decoderAnim = t
    }

    private func stopTimers() {
        decoderLoop?.invalidate(); decoderLoop = nil
        decoderAnim?.invalidate(); decoderAnim = nil
    }
}

/// Компактный waveform: ряд закруглённых баров. «Слушаю» — высоты по громкости микрофона (с авто-
/// гейном через peak-follower); «Распознаю» — синтетическое спокойное «дыхание». Рендер ~30 fps,
/// бары плавно тянутся к целям. Цвет — коралл.
private final class WaveformView: NSView {
    private let barCount = 16
    private var targets: [CGFloat]
    private var shown: [CGFloat]
    private var render: Timer?
    private var shimmer = false
    private var phase: CGFloat = 0
    private var peak: Float = 0.03
    var color: NSColor = VoiceIndicator.coral { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        targets = Array(repeating: 0.06, count: barCount)
        shown = targets
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    /// Новый уровень микрофона (RMS) → правый край ленты (бары едут влево).
    func push(_ rms: Float) {
        peak = Swift.max(rms, peak * 0.92)               // следящий пик → авто-гейн под любой микрофон
        let n = Swift.min(1, rms / Swift.max(peak, 0.02))
        let v = CGFloat(0.08 + 0.92 * pow(n, 0.65))      // лёгкая кривая + минимальная высота
        targets.removeFirst(); targets.append(v)
    }

    func start(shimmer: Bool) {
        self.shimmer = shimmer
        if !shimmer { peak = 0.03; for i in 0..<barCount { targets[i] = 0.08 } }
        guard render == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        render = t
    }
    func stop() { render?.invalidate(); render = nil }

    private func tick() {
        if shimmer {
            phase += 0.16
            for i in 0..<barCount {
                let s = sin(phase + CGFloat(i) * 0.55)
                targets[i] = 0.16 + 0.14 * (s * 0.5 + 0.5)   // тихое дыхание
            }
        }
        var changed = false
        for i in 0..<barCount {
            let d = targets[i] - shown[i]
            if abs(d) > 0.002 { shown[i] += d * 0.34; changed = true }
        }
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let bw: CGFloat = 2.0
        guard barCount > 1 else { return }
        let gap = (w - CGFloat(barCount) * bw) / CGFloat(barCount - 1)
        color.setFill()
        for i in 0..<barCount {
            let bh = Swift.max(bw, shown[i] * h)
            let x = CGFloat(i) * (bw + gap)
            let y = (h - bh) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bw, height: bh),
                         xRadius: bw / 2, yRadius: bw / 2).fill()
        }
    }
}
