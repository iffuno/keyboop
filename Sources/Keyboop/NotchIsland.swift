import AppKit

/// ОСТРОВ В ВЫРЕЗЕ — плашка диктовки, растущая из чёлки MacBook (задача 144).
///
/// Это ТРЕТИЙ вариант размещения плашки, рядом с «у каретки» и «вверху по центру». Всё, что знает
/// про вырез, форму и раскрытие, живёт здесь; `VoiceIndicator` кладёт в `content` те же знак, волну
/// и текст, что и в обычную плашку, и больше ни о чём не думает.
///
/// ## Что рисуем
///
/// Одна фигура, а не «панель под чёлкой»:
///
///     ┌───────────┐        полоска шириной РОВНО в вырез (её никто не видит: там железо)
///  ┌──┘           └──┐     вогнутые плечи — из-за них корпус читается продолжением выреза
///  │    содержимое   │
///  └─────────────────┘     скруглённые нижние углы
///
/// ⚠️ ПОЛОСКА В ВЫРЕЗЕ ОБЯЗАНА БЫТЬ ШИРИНОЙ РОВНО В ВЫРЕЗ. Соблазн нарисовать корпус во всю высоту
/// (от самой кромки экрана) велик — фигура выходит проще. Но строка меню занимает весь верх экрана,
/// и всё, что шире выреза, легло бы поверх часов и значков, а это прямой запрет из плана. Точные
/// края выреза система отдаёт сама (`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), гадать не надо.
///
/// ⚠️ КЛИКИ НЕ ВОРУЕМ: `ignoresMouseEvents`. Панель формально накрывает кусок строки меню (её рамка
/// прямоугольная), но пиксели там прозрачные, а события уходят насквозь — по значкам под островом
/// по-прежнему можно попасть.
final class NotchIsland {

    // MARK: - Геометрия выреза

    /// Вырез экрана в координатах экрана, или nil, если выреза нет (внешний монитор, Air до 2022,
    /// машины на Intel).
    ///
    /// Ширину выреза Apple напрямую не отдаёт — отдаёт две области СЛЕВА и СПРАВА от камеры. Вырез
    /// это ровно щель между ними. Высота = `safeAreaInsets.top`: система сама говорит, докуда сверху
    /// нельзя класть содержимое.
    ///
    /// ⚠️ ПРОВЕРЯЕМ ЧИСЛА, А НЕ ВЕРИМ ИМ. Если завтра какая-нибудь машина отдаст щель во весь экран
    /// или высоту с ладонь, лучше молча остаться без острова, чем закрасить пол-экрана чёрным.
    static func notchRect(of s: NSScreen) -> NSRect? {
        let h = s.safeAreaInsets.top
        guard h > 0, h < 80,
              let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea else { return nil }
        let x0 = left.maxX, x1 = right.minX
        let w = x1 - x0
        guard w > 40, w < s.frame.width * 0.5 else { return nil }
        return NSRect(x: x0, y: s.frame.maxY - h, width: w, height: h)
    }

    /// Есть ли у экрана вырез ФИЗИЧЕСКИ. Не зависит от `safeAreaInsets`, и в этом весь смысл.
    ///
    /// ⚠️ У НУЛЯ В `safeAreaInsets.top` ДВА РАЗНЫХ СМЫСЛА, И ПУТАТЬ ИХ ДОРОГО (13.08.2026).
    /// Первый: выреза нет вовсе — внешний монитор, Air до 2022, машины на Intel. Второй: вырез есть,
    /// но система включила режим совместимости с корпусом камеры и сдвинула активную область ниже
    /// него. Второе Apple делает САМА, как только приложение, которому режим нужен (собранное до
    /// macOS 12 или с галочкой «Подогнать под встроенную камеру»), положит окно за корпусом камеры
    /// на текущем рабочем столе. Тогда строка меню становится сплошной полосой во всю ширину, вырез
    /// под ней не виден, и `safeAreaInsets.top` честно равен нулю: класть туда содержимое больше
    /// нельзя. Ловится это состояние только так, потому что режим дисплея при этом НЕ меняется.
    ///
    /// Приём: у панели с вырезом в таблице режимов лежат ПАРЫ с одинаковой шириной в пикселях и
    /// двумя высотами — 16:10 без камеры и на несколько строк выше с камерой (на 16" это
    /// 3456×2160 против 3456×2234). Панель без выреза таких пар не имеет. Публичный API,
    /// никаких приватных вызовов.
    static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        guard let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              CGDisplayIsBuiltin(n) != 0 else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(n, opts) as? [CGDisplayMode] else { return false }
        var heights: [Int: Set<Int>] = [:]
        for m in modes { heights[m.pixelWidth, default: []].insert(m.pixelHeight) }
        for (w, hs) in heights where hs.count >= 2 {
            let sorted = hs.sorted()
            for i in 0..<(sorted.count - 1) {
                let plain = sorted[i], notched = sorted[i + 1]
                // Нижняя из пары обязана быть ровно 16:10, а надбавка — маленькой: это полоса
                // камеры, а не соседнее разрешение из того же списка.
                guard abs(Double(w) / Double(plain) - 1.6) < 0.005 else { continue }
                let extra = notched - plain
                if extra > 0, extra < plain / 20 { return true }
            }
        }
        return false
    }

    // MARK: - Пропорции фигуры

    /// Нижние углы корпуса. Крупнее верхних: корпус свисает, и глаз читает именно нижнюю кромку.
    private let bodyCorner: CGFloat = 15
    /// Внешние верхние углы корпуса. Маленькие: там фигура прижата к строке меню, и большое
    /// скругление превратило бы её в отдельную «таблетку», висящую под чёлкой.
    private let topCorner: CGFloat = 5
    /// Вогнутое плечо у края выреза — то самое, из-за чего фигура выглядит выросшей ИЗ чёлки, а не
    /// приложенной к ней.
    private let shoulder: CGFloat = 9
    /// ЧЁРНОЕ ПОЛЕ ПОД СОДЕРЖИМЫМ (автор 13.08: «под логотипом должно быть ещё чёрное поле
    /// высотой примерно в пол логотипа, при этом графику не двигать»).
    ///
    /// ⚠️ ЭТО ДВА РАЗНЫХ ЧИСЛА, И РАНЬШЕ ОНО БЫЛО ОДНИМ — В ЭТОМ И БЫЛА ОШИБКА. Одно число задавало
    /// одновременно и низ чёрной фигуры, и `content.frame.y`, поэтому его увеличение опускало
    /// содержимое вместе с кромкой: поле под знаком оставалось нулевым, сколько ни прибавляй.
    /// Комментарий рядом при этом утверждал обратное, и поверить ему стоило трёх заходов — увидеть
    /// разницу можно было только на снимке всего экрана.
    ///
    /// `bottomPad` — видимый чёрный воздух между низом строки и нижней кромкой фигуры. Сверху
    /// воздуха нет вовсе: там кромка выреза, содержимое прижато к ней вплотную.
    private let bottomPad: CGFloat = 10
    /// Прозрачный запас ПОД фигурой, только под «перелёт» пружины. Раскрытие идёт с небольшим
    /// перелётом вниз (около 10% высоты), и без запаса окно обрезало бы его ровно по кромке —
    /// пружина превращалась бы в стук. Ничего не рисует и на вид не влияет.
    private let overshoot: CGFloat = 20
    /// Дополнительный воздух по бокам содержимого: у острова кромка круглая, и текст, посаженный
    /// вплотную, как в прямоугольной плашке, начинает липнуть к дуге.
    private let sidePad: CGFloat = 8

    // MARK: - Состав

    let panel: NSPanel
    /// Куда `VoiceIndicator` кладёт знак, волну и текст. Высота — та же, что у обычной плашки,
    /// поэтому вся вёрстка содержимого работает без изменений.
    /// Контейнер содержимого. `hitTest` пропускает мышь насквозь везде, кроме самих кнопок:
    /// фигура острова лежит на строке меню, и щёлкать по ней человек хочет НЕ по нам.
    let content = PassThroughView()
    /// Корпус: чёрный фон + маска-силуэт. Маска нужна не для красоты — содержимое обязано
    /// ПОЯВЛЯТЬСЯ из-под выреза вместе с фигурой, а не висеть в воздухе, пока она растёт.
    private let shape = NSView()
    private let maskLayer = CAShapeLayer()
    /// Тень рисуется своим слоем по тому же контуру: тень ОКНА прямоугольная и легла бы серой
    /// рамкой поперёк строки меню.
    private let shadowLayer = CAShapeLayer()

    // MARK: - Текущее состояние

    private var notch = NSRect.zero
    private var screenTop: CGFloat = 0
    private var screenW: CGFloat = 0
    private var contentH: CGFloat = 38
    /// Ширина корпуса, к которой идём.
    private var bodyW: CGFloat = 0
    /// Ширина корпуса на текущем кадре (во время раскрытия и разъезда отличается от `bodyW`).
    private var drawnW: CGFloat = 0
    /// Доля высоты корпуса, 0…~1.1 (больше единицы — перелёт пружины).
    private var openH: CGFloat = 0

    private var anim: Timer?
    private var animStart = Date()
    private var animDur: CGFloat = 0.34
    private var openFrom: CGFloat = 0, openTo: CGFloat = 1
    private var widthFrom: CGFloat = 0, widthTo: CGFloat = 0
    private var expanding = true
    private var collapsing = false
    private var onFinish: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    /// ⚠️ ПАНЕЛЬ, КОТОРУЮ НЕ СТАСКИВАЮТ ПОД СТРОКУ МЕНЮ. Обычный `NSWindow` пропускает КАЖДЫЙ
    /// `setFrame` через `constrainFrameRect` и молча опускает окно так, чтобы оно не лезло под
    /// строку меню. Замерено 13.08.2026: просим y = −80, получаем y = −113, ровно на высоту строки
    /// меню ниже. Для острова это смертельно — он обязан начинаться от САМОЙ кромки экрана, иначе
    /// его верхняя полоска встаёт под чёлкой, плечи повисают в воздухе и вся фигура читается как
    /// обычная панель под строкой меню, то есть как то, что уже было до задачи 144.
    ///
    /// Ошибка молчит вдвойне: `setFrame` ничего не возвращает, а в коде стоят правильные числа —
    /// увидеть её можно только на снимке экрана либо распечатав `panel.frame` ПОСЛЕ установки.
    private final class FreePanel: NSPanel {
        override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
    }

    init() {
        panel = FreePanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Тёмную тему пиннем, как у обычной плашки: иначе в светлой системной теме `.labelColor`
        // резолвится в тёмный, и текст пропадает на чёрном корпусе.
        panel.appearance = NSAppearance(named: .darkAqua)
        // ⚠️ ПОРЯДОК ЭТИХ ДВУХ СТРОК ЗНАЧИМ, И ОН СТОИЛ ОТДЕЛЬНОГО РАССЛЕДОВАНИЯ (16.08.2026).
        // `isFloatingPanel = true` не просто помечает панель плавающей: его сеттер ВЫСТАВЛЯЕТ
        // уровень окна в `.floating` (3). Стоя после `level = .statusBar` (25), он молча затирал
        // уровень, и остров оказывался НИЖЕ системной строки меню (24). Снаружи это выглядело как
        // «остров не дотягивается до верха»: верхние 33 пункта фигуры просто закрывались строкой
        // меню, а геометрия при этом была правильной до пикселя (диагностика показывала панель
        // ровно от кромки экрана). Сначала флаг, потом уровень.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // ⚠️ КЛИКИ ПРИНИМАЕМ ТОЛЬКО КНОПКАМИ (13.08, вместе с «Отмена/Готово»). Раньше панель была
        // сквозной целиком, и это было правильно: она накрывает кусок строки меню, воровать там
        // клики нельзя. Теперь на ней есть кнопки, поэтому сквозным остаётся ВСЁ, кроме них —
        // за это отвечает hitTest контейнера ниже.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let root = panel.contentView!
        root.wantsLayer = true
        root.layer?.addSublayer(shadowLayer)

        shadowLayer.fillColor = NSColor.black.cgColor
        // ⚠️ ТЕНИ У ОСТРОВА НЕТ (автор 13.08: «слева и справа, и по всему периметру видна какая-то
        // полупрозрачная линия, типа тени, давай от неё избавимся»).
        //
        // Тень задумывалась как объём, а получилась обводка: остров прижат к кромке экрана и лежит
        // на строке меню, то есть его контур идёт по границе двух тёмных поверхностей — там тень
        // читается не глубиной, а грязной каймой. И это правильно по сути: настоящий вырез экрана
        // тени не отбрасывает, он ДЫРКА. Остров притворяется вырезом, значит и вести себя должен
        // как дырка.
        shadowLayer.shadowOpacity = 0

        shape.wantsLayer = true
        shape.layer?.backgroundColor = NSColor.black.cgColor
        shape.layer?.mask = maskLayer
        root.addSubview(shape)

        content.wantsLayer = true
        content.alphaValue = 0
        shape.addSubview(content)
    }

    // MARK: - Подготовка и раскладка

    /// Привязать остров к экрану. `false` — выреза там нет, острова не будет (звавший обязан молча
    /// вернуться к обычному поведению).
    /// Текущая высота содержимого. Нужна снаружи: строку в острове расставляет `VoiceIndicator`,
    /// и ему надо знать, где верх контейнера, когда строк стало две.
    var contentHeight: CGFloat { contentH }

    /// Сменить высоту содержимого у УЖЕ показанного острова: под текстом появилась вторая строка.
    ///
    /// Растём вниз, поэтому верх фигуры остаётся приклеенным к кромке экрана, а меняется только то,
    /// насколько глубоко она свисает. Анимации тут нет намеренно: строка живого текста появляется
    /// один раз за диктовку, а вот приходит она в тот же момент, когда идут партиалы, и плавный
    /// разъезд высоты попал бы ровно в поток обновлений ширины, где мы анимацию уже отключили.
    func setContentHeight(_ h: CGFloat) {
        guard abs(h - contentH) > 0.5 else { return }
        contentH = h
        applyFrame(panelWidth: bodyW)
        redraw()
    }

    @discardableResult
    func prepare(screen s: NSScreen, contentHeight h: CGFloat) -> Bool {
        guard let n = Self.notchRect(of: s) else { return false }
        notch = n
        screenTop = s.frame.maxY
        screenW = s.frame.width
        contentH = h
        return true
    }

    /// Ширина корпуса под содержимое ширины `w`.
    ///
    /// ⚠️ КОРПУС НЕ БЫВАЕТ УЖЕ ВЫРЕЗА С ПЛЕЧАМИ. Содержимое плашки записи узкое (знак, волна и
    /// «0:07» — около полутора сотен пунктов), и без нижней границы остров вышел бы уже чёлки, то
    /// есть плечам стало бы некуда лечь, а фигура превратилась бы в огрызок под вырезом. Побочная
    /// польза: ширина при этом почти всегда одна и та же, и остров не дёргается на каждой секунде.
    /// ⚠️ ПОТОЛОК ШИРИНЫ — ЭТО НЕ ШИРИНА ЭКРАНА (13.08.2026). Здесь стояло `screenW - 24`, то есть
    /// потолка фактически не было: любая длинная строка превращала остров в чёрную полосу почти во
    /// всю верхнюю кромку. Пока в острове живут знак, волна и таймер, до этого не доходило, но с
    /// живым текстом первая же фраза туда приезжает, и это перестаёт быть островом.
    ///
    /// Половина экрана выбрана как то, что глаз ещё читает как объект у чёлки, а не как панель:
    /// на 16" это 864 пункта против выреза в 185. Число одно на все диагонали, потому что доля
    /// экрана переносится между машинами, а пункты нет.
    private var maxBodyW: CGFloat { max(notch.width + 2 * (shoulder + topCorner + 6), screenW * 0.5) }

    func bodyWidth(for w: CGFloat) -> CGFloat {
        let minW = notch.width + 2 * (shoulder + topCorner + 6)
        return min(max(w + 2 * sidePad, minW), maxBodyW)
    }

    /// Поставить корпус под содержимое ширины `w`. Возвращает ширину контейнера `content`, чтобы
    /// звавший отцентровал в нём свою строку.
    @discardableResult
    func layout(contentWidth w: CGFloat) -> CGFloat {
        let target = bodyWidth(for: w)
        let prev = bodyW
        bodyW = target
        if !panel.isVisible || openH <= 0.001 {
            drawnW = target
            applyFrame(panelWidth: target)
            redraw()
        } else if abs(target - prev) > 0.5 {
            // Остров уже на экране и меняет состояние (запись → распознавание → тост): ширину
            // разъезжаем, а не переставляем скачком. Пока едем, панель держим по БОЛЬШЕЙ из
            // ширин, иначе съезжающийся корпус обрезался бы кромкой окна.
            //
            // Цель по высоте — единица, а не текущее `openH`: состояние может смениться, пока
            // остров ещё раскрывается, и «доехать до того, где стоим» заморозило бы его
            // полураскрытым.
            applyFrame(panelWidth: max(prev, target))
            animate(toOpen: 1, fromWidth: drawnW, toWidth: target, dur: 0.22, expanding: true)
        }
        return target
    }

    // MARK: - Раскрытие и схлопывание

    /// Раскрыть сверху вниз. Повторный вызов на уже раскрытом острове ничего не переигрывает:
    /// состояния сменяются часто, и «дышащая» на каждом тосте чёлка выглядела бы поломкой.
    func show() {
        // ⚠️ ИДУЩУЮ АНИМАЦИЮ НЕ ТРОГАЕМ. `present` зовёт сначала раскладку (а она на смене
        // состояния запускает разъезд ширины), и только потом `show`. Пока здесь стояло безусловное
        // `anim?.invalidate()`, этот разъезд умирал первым же кадром, и остров навсегда застревал на
        // ширине ПРЕДЫДУЩЕГО состояния: тост «Скопировано» показывался в корпусе от длинной строки
        // речи. Поймано снимком 13.08.2026.
        if panel.isVisible, !collapsing, anim != nil || openH > 0.999 {
            panel.orderFrontRegardless()
            return
        }
        anim?.invalidate(); anim = nil
        let fresh = !panel.isVisible
        collapsing = false
        if fresh {
            openH = 0
            drawnW = notch.width
            content.alphaValue = 0
        }
        applyFrame(panelWidth: max(bodyW, drawnW))
        redraw()
        panel.orderFrontRegardless()
        // Из схлопывания разворачиваемся с того места, где застали, а не с нуля.
        animate(toOpen: 1, fromWidth: drawnW, toWidth: bodyW, dur: 0.34, expanding: true)
    }

    /// Схлопнуть обратно в вырез и убрать панель.
    func collapse() {
        guard panel.isVisible else { return }
        anim?.invalidate(); anim = nil
        collapsing = true
        animate(toOpen: 0, fromWidth: drawnW, toWidth: notch.width, dur: 0.20, expanding: false) {
            [weak self] in
            guard let self, self.collapsing else { return }
            self.collapsing = false
            self.panel.orderOut(nil)
        }
    }

    /// Убрать немедленно, без анимации (сменили место показа посреди сеанса).
    func hideNow() {
        anim?.invalidate(); anim = nil
        collapsing = false
        openH = 0
        content.alphaValue = 0
        panel.orderOut(nil)
    }

    // MARK: - Анимация

    private func animate(toOpen: CGFloat, fromWidth: CGFloat, toWidth: CGFloat,
                         dur: CGFloat, expanding e: Bool, done: (() -> Void)? = nil) {
        // Старый таймер гасим ЗДЕСЬ, а не у каждого звавшего: забытый `invalidate` не падает и не
        // предупреждает, он просто оставляет два таймера, которые дальше дерутся за одни и те же
        // поля и дают дрожь на кадр.
        anim?.invalidate()
        openFrom = openH; openTo = toOpen
        widthFrom = fromWidth; widthTo = toWidth
        animDur = dur
        expanding = e
        onFinish = done
        animStart = Date()
        // 60 кадров в секунду и обычный Timer в `.common`: у плашки уже так нарисована волна, а
        // фигура мелкая — заводить ради неё CVDisplayLink не за чем.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        anim = t
    }

    private func tick() {
        let t = min(1, CGFloat(Date().timeIntervalSince(animStart)) / max(animDur, 0.001))
        // Высота — с перелётом (пружина), ширина — без. Перелёт по ширине выглядел бы как рывок
        // плеч в стороны, а по высоте это ровно то «живое» движение, ради которого всё затевалось.
        let hE = expanding ? easeOutBack(t) : easeInCubic(t)
        openH = openFrom + (openTo - openFrom) * hE
        drawnW = widthFrom + (widthTo - widthFrom) * easeOutCubic(t)
        // ⚠️ ПРОЯВЛЕНИЕ И ГАШЕНИЕ СЧИТАЮТСЯ ПО-РАЗНОМУ (автор 13.08: «когда плашка уезжает, значок,
        // волна и логотип гаснут странно, слишком поздно — нужно чуть пораньше и плавно, вместе со
        // схлопыванием»).
        //
        // Причина была в том, что прозрачность считалась от ВЫСОТЫ корпуса, а высота на схлопывании
        // идёт с ускорением (`easeInCubic`): первую половину времени она почти не меняется, потом
        // проваливается. Содержимое из-за этого стояло на месте, пока остров уже поехал, и в конце
        // моргало. На раскрытии привязка к высоте верна — там нельзя показать содержимое раньше, чем
        // ему нашлось место, — а на схлопывании считать надо по ВРЕМЕНИ.
        //
        // Гасим за первые 55% хода: содержимое исчезает заметно раньше, чем схлопнется фигура, и
        // глазу это читается как одно движение, а не как два.
        if expanding {
            content.alphaValue = min(1, max(0, (openH - 0.25) / 0.5))
        } else {
            content.alphaValue = max(0, 1 - easeOutCubic(min(1, t / 0.55)))
        }
        redraw()
        guard t >= 1 else { return }
        anim?.invalidate(); anim = nil
        openH = openTo
        drawnW = widthTo
        // Панель могли держать шире, чтобы съезжающийся корпус не обрезало — теперь по месту.
        applyFrame(panelWidth: bodyW)
        redraw()
        let f = onFinish; onFinish = nil; f?()
    }

    private func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
    private func easeInCubic(_ t: CGFloat) -> CGFloat { t * t * t }
    /// Перелёт ≈ 10% высоты (около четырёх пунктов) — заметно глазу и укладывается в `overshoot`.
    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.7, c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    // MARK: - Рисование

    private func applyFrame(panelWidth pw: CGFloat) {
        // ⚠️ ОКНО ШИРЕ КОРПУСА НА ДВЕ ФАСКИ (автор 13.08: «в верхней части нет скруглений, нужны
        // скругления по внутренним углам»). Фаски у кромки экрана рисуются СНАРУЖИ корпуса, и когда
        // окно было ровно по корпусу, им просто не было места: радиус ужимался до нуля, и фигура
        // упиралась в кромку прямым углом. Лишние пункты по бокам прозрачны и ничего не перекрывают.
        let w = (max(pw, notch.width) + 2 * shoulder).rounded()
        let totalH = (notch.height + contentH + bottomPad + overshoot).rounded()
        // По ГОРИЗОНТАЛИ центруемся по ВЫРЕЗУ, а не по экрану: они почти совпадают, но «почти» тут
        // видно — фигура обязана выходить из чёлки симметрично.
        let x = (notch.midX - w / 2).rounded()
        let y = (screenTop - totalH).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: w, height: totalH), display: false)
        shape.frame = NSRect(x: 0, y: 0, width: w, height: totalH)
        // Содержимое центруем в корпусе: пока корпус съезжается, панель шире него, и содержимое,
        // прибитое к левому краю окна, уехало бы вбок относительно фигуры.
        content.frame = NSRect(x: ((w - bodyW) / 2).rounded(), y: overshoot + bottomPad, width: bodyW, height: contentH)
    }

    private func redraw() {
        let p = silhouette()
        if ProcessInfo.processInfo.environment["KEYBOOP_ISLDIAG"] == "1" {
            let b = p.boundingBox
            kbLog(String(format: "остров-диаг: вырез %.0f,%.0f %.0fx%.0f · экранТоп %.0f · панель %@ · фигура %.0f..%.0f (h=%.0f) · openH %.2f · contentH %.0f",
                         notch.minX, notch.minY, notch.width, notch.height, screenTop,
                         NSStringFromRect(panel.frame), b.minY, b.maxY, b.height, openH, contentH))
        }
        // Слои сами анимируют смену `path` за четверть секунды, и поверх нашей анимации это даёт
        // кисель. Каждый кадр ставим путь как есть.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = shape.bounds
        maskLayer.path = p
        shadowLayer.frame = shape.frame
        shadowLayer.path = p
        shadowLayer.shadowPath = p
        CATransaction.commit()
    }

    /// Силуэт острова на текущем кадре, в координатах `shape` (снизу вверх). Наружу нужен снимку
    /// плашки: без него в PNG вместо фигуры получается прямоугольник, то есть не то, что на экране.
    func silhouette() -> CGPath {
        let W = shape.bounds.width, totalH = shape.bounds.height
        let nW = notch.width, nH = notch.height
        let w = max(nW, min(drawnW, W))

        // ⚠️ ОСТРОВ — ЭТО ВЫРЕЗ, КОТОРЫЙ ВЫРОС, А НЕ ПАНЕЛЬ ПОД НИМ (автор 13.08, по живому виду:
        // «сейчас он как будто нависает над вырезом, а нужно, чтобы края доходили до верха и
        // скруглялись влево и вправо, как будто это реальный вырез»).
        //
        // Было: полоска ровно в ширину выреза сверху, ниже плечи, и уже под ними корпус. Из-за этого
        // фигура читалась как отдельная плашка, приклеенная снизу к чёлке, а шов между ними видно.
        // Стало: боковины корпуса идут ДО САМОЙ КРОМКИ ЭКРАНА, а у кромки уходят наружу вогнутой
        // фаской — ровно так выглядит настоящий вырез там, где он встречается со строкой меню.
        //
        // Побочная выгода, ради которой автор это и предложил: форма перестала зависеть от точной
        // ширины выреза. У разных диагоналей MacBook она разная, и подгонять полоску под каждую
        // означало бы верить числам, которые Apple не обещает. Теперь ширину задаёт СОДЕРЖИМОЕ, а
        // «вырезом» фигуру делает то, что она начинается от кромки.
        // Низ корпуса растёт вниз по мере раскрытия: от кромки выреза (нулевая высота) до «строка
        // плюс поле под ней». Считаем от доли раскрытия, а не от высоты строки: иначе поле под
        // содержимым пришлось бы раскрывать отдельным множителем и оно моргало бы в конце.
        let byBot = (overshoot + bottomPad + contentH) - openH * (contentH + bottomPad)
        let nyTop = totalH                    // кромка экрана

        let bx0 = (W - w) / 2, bx1 = (W + w) / 2

        // Радиусы ужимаем под фактический размер: в начале раскрытия корпус нулевой высоты, и
        // скругление «как задумано» вывернуло бы фигуру наизнанку.
        // Фаске нужно место снаружи корпуса (его даёт applyFrame) и хоть какая-то высота фигуры:
        // в самом начале раскрытия корпус нулевой, и полноразмерная дуга вывернулась бы наизнанку.
        let sr = min(shoulder, max(0, (W - w) / 2), max(0, nyTop - byBot))
        let r  = min(bodyCorner, max(0, nyTop - byBot) / 2, w / 2)

        let p = CGMutablePath()
        // Левая фаска: от кромки экрана внутрь и вниз (вогнутая).
        p.move(to: CGPoint(x: bx0 - sr, y: nyTop))
        p.addArc(center: CGPoint(x: bx0 - sr, y: nyTop - sr), radius: sr,
                 startAngle: .pi / 2, endAngle: 0, clockwise: true)
        // Левая боковина вниз и нижний левый угол.
        p.addLine(to: CGPoint(x: bx0, y: byBot + r))
        p.addArc(center: CGPoint(x: bx0 + r, y: byBot + r), radius: r,
                 startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        // Низ и нижний правый угол.
        p.addLine(to: CGPoint(x: bx1 - r, y: byBot))
        p.addArc(center: CGPoint(x: bx1 - r, y: byBot + r), radius: r,
                 startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: false)
        // Правая боковина вверх и правая фаска у кромки.
        p.addLine(to: CGPoint(x: bx1, y: nyTop - sr))
        p.addArc(center: CGPoint(x: bx1 + sr, y: nyTop - sr), radius: sr,
                 startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// Вид, сквозь который мышь проходит везде, кроме дочерних элементов.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}
