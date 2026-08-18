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
    /// ОСТРОВ В ВЫРЕЗЕ (задача 144) — третий вариант размещения, рядом с «у каретки» и «вверху».
    /// Своя панель, своя форма, своё раскрытие; знак, волна и текст у них с обычной плашкой ОБЩИЕ и
    /// переезжают из контейнера в контейнер. Так все три состояния (запись, распознавание, тост)
    /// работают в острове сами собой, а не требуют второго комплекта вёрстки.
    /// `lazy`: остров заводит собственное окно, а включён он у единиц. Тем, кто им не пользуется,
    /// лишняя панель в процессе не нужна вовсе.
    private lazy var island = NotchIsland()
    /// Текущий показ идёт в острове.
    private var islandOn = false
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

    private let H: CGFloat = 38         // высота обычной плашки

    /// ВЫСОТА СТРОКИ В ОСТРОВЕ — НИЖЕ, ЧЕМ У ПЛАШКИ (автор 13.08: «отступ от реального выреза убрать
    /// вообще, прижаться вплотную вверх, снизу оставить небольшой отступ по чёрному, и в целом
    /// уменьшить панель по высоте»).
    ///
    /// У обычной плашки 38 пунктов, и внутри них знак высотой 20 стоит по центру — то есть сверху и
    /// снизу по девять пунктов воздуха. В отдельно висящей плашке это правильно, а в острове верхние
    /// девять складываются с чёрной полосой самого выреза, и содержимое выглядит провалившимся вниз.
    /// ⚠️ РОВНО ПО ВЫСОТЕ ЗНАКА, БЕЗ ВОЗДУХА СВЕРХУ (автор 13.08, второй заход: «прижимаемся вверх
    /// вплотную, а снизу отступ в половину высоты логотипа»). Сначала я поставил 30 и оставил по
    /// пять пунктов с каждой стороны — этого мало: верхние пять всё равно складываются с чёрной
    /// полосой выреза, и знак читается осевшим. Двадцать это высота самого знака, то есть строка
    /// прижата к кромке выреза вплотную, а весь чёрный воздух собран внизу, где он и нужен.
    private let islandRowH: CGFloat = 20
    /// Высота строки для текущего места показа.
    private var rowH: CGFloat { islandOn ? islandRowH : H }
    /// ЖИВОЙ ТЕКСТ В ОСТРОВЕ ЖИВЁТ ВТОРОЙ СТРОКОЙ (решение автора 13.08.2026: «вырез останется
    /// примерно такой же ширины, а строкой ниже добавится ещё одна, где будет бежать текст»).
    /// Иначе речь пришлось бы класть в тот же ряд, что знак, волну и кнопки, и остров расползался бы
    /// вширь на каждом уточнении гипотезы — то есть перестал бы быть островом.
    private let liveRowH: CGFloat = 17
    /// Воздух между первым рядом и строкой речи (автор 13.08: «текст прилип к нашим значкам»).
    /// Прибавляется к высоте острова, а не отъедает её у строки: свисать ниже он может, а вот
    /// налезать на знак и волну не должен.
    private let liveGap: CGFloat = 6
    /// Показываем ли сейчас вторую строку.
    private var liveRowOn: Bool { islandOn && mode == .recording && !liveText.isEmpty }
    /// Потолок ширины живого текста у ОБЫЧНОЙ плашки, в пунктах. Три-четыре средних слова
    /// (автор 13.08): плашка стоит поверх чужого документа, и растягивать её в баннер на пол-экрана
    /// нельзя. В острове потолок другой и считается от корпуса, см. `relayout`.
    private let maxLiveCaretW: CGFloat = 200
    /// ЕДИНЫЙ ОТСТУП: и от краёв плашки, и между всеми её элементами (автор 12.08, по снимку).
    ///
    /// До этого отступов было три разных: 13 от краёв, 9 до текста и 5 после знака. Знак от этого
    /// липнул к волне и выглядел приклеенным сбоку, тогда как область таймера справа читалась ровно.
    /// Ритм из одного числа снимает вопрос целиком: четыре элемента в строке и одинаковый воздух
    /// между ними.
    ///
    /// 12, а не 13 или 9: чётное значение даёт целые пиксели на retina, и от «хорошего» правого
    /// поля (13) и зазора перед таймером (9) оно отличается на пункт, то есть незаметно.
    private let pad: CGFloat = 12
    /// ⚠️ У ТОСТА ЗАЗОР ДО ТЕКСТА УЖЕ ВНЕШНЕГО ПОЛЯ, И ЭТО ТРЕБОВАНИЕ ИВАНА ОТ 08.08. Там элементов
    /// всего два, знак и сообщение, и при одинаковых отступах глаз видел «три равноудалённых пятна»,
    /// а знак читался как отдельный элемент, а не часть сообщения. В плашке записи элементов четыре,
    /// они образуют строку, и там равенство наоборот работает.
    private let toastGap: CGFloat = 8
    private let waveW: CGFloat = 54     // ширина waveform
    private let dotW: CGFloat = 7       // диаметр точки-статуса у тоста
    /// ⚠️ БЫЛ БЕЗЫМЯННЫЙ КРУЖОК (автор 08.08). Коралловая точка ничего не означала и занимала место,
    /// где по смыслу стоит знак того, кто говорит. Берём тот же рисунок, что в строке меню, значит
    /// плашка узнаётся как наша с первого взгляда и без подписи.
    private let dot = NSImageView()

    /// КНОПКИ «ОТМЕНА» И «ГОТОВО» НА ОСТРОВЕ (автор 13.08).
    ///
    /// Слева крестик, справа галочка. Названия выбраны им же и не случайно: «стоп» рядом с крестиком
    /// читается двусмысленно, а пара «отмена / готово» разводит потерю и результат.
    ///
    /// ⚠️ ЗНАКАМИ, А НЕ СЛОВАМИ. «Отмена» и «Готово» это девять и шесть букв, остров вырос бы вдвое.
    /// Тонкая линия того же веса, что у нашего знака, — единственное начертание, которое не спорит с
    /// минимализмом плашки.
    ///
    /// ⚠️ КОРАЛЛ ТОЛЬКО ПОД МЫШЬЮ. В покое обе кнопки приглушены до цвета таймера, иначе на острове
    /// станет три ярких пятна вместо одного, и волна перестанет быть акцентом.
    ///
    /// ⚠️ ТОЛЬКО ВО ВРЕМЯ ЗАПИСИ. В распознавании отменять уже нечего, у тоста кнопок быть не может.
    private lazy var cancelBtn = IslandButton(symbol: "xmark") { [weak self] in
        self?.hide(); VoiceController.shared.cancel()
    }
    private lazy var doneBtn = IslandButton(symbol: "checkmark") { VoiceController.shared.end() }
    private var buttonsShown = false

    /// Знак Keyboop для плашки. Рисунок общий со строкой меню (`menubar-mark.png`), поэтому он и
    /// там, и тут один и тот же, а не две похожие картинки.
    ///
    /// ⚠️ БЕЛЫЙ, КАК В ОРИГИНАЛЕ (автор 08.08: «логотип в оригинале белым, без вольностей»). Сначала
    /// я перекрасил его в коралловый, чтобы он занял место коралловой точки. Это была отсебятина:
    /// знак есть знак, и перекрашивать его под соседний элемент нельзя.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        // ⚠️ РАЗМЕР ЗНАКА ПОДБИРАЛСЯ ГЛАЗАМИ, ДВА ЗАХОДА (автор 12.08). Было 13, стало 16, потом 20.
        // Держим ЧЁТНОЕ число пунктов: на retina это целые пиксели (20 → 40), а знак весь состоит
        // из тонких линий, и половина пикселя размывает ему рамку. 19.2 «ровно двадцать процентов»
        // дали бы 38.4 и мыло, поэтому округляем вверх до 20.
        //
        // 20 это ровно высота волны рядом, и совпадение полезное: знак и волна читаются как две
        // части одной строки, а не как значок с картинкой возле него.
        let h: CGFloat = 20, w = (h * (src.size.width / max(src.size.height, 1))).rounded()
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        return img
    }()
    private let maxLiveW: CGFloat = 460 // потолок для живого текста стриминга (дальше режем хвостом)

    /// ТАЙМЕР ЗАПИСИ (задача 125, решение автора 11.08.2026). Слова «Слушаю» на плашке больше нет:
    /// оно занимало половину ширины и сообщало ровно то, что и так видно по живой волне. На его
    /// месте справа идёт время записи, а слева появился наш знак — то есть плашка наконец говорит
    /// три разные вещи вместо одной.
    private var recStart: Date?
    private var ticker: Timer?
    /// Живой текст потоковой расшифровки. Пока он есть, справа стоит он, а не таймер: сказанные
    /// слова важнее секунд.
    private var liveText = ""
    /// Строка живого текста в острове. Отдельная от `label` намеренно: в острове справа продолжает
    /// тикать таймер, а речь идёт ниже, и две роли в одной метке не уживаются.
    private lazy var liveLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 11, weight: .regular)
        // ⚠️ ПРИГЛУШЁННЫЙ, КАК ТАЙМЕР (автор 13.08). Белым он спорил бы с коралловой волной за
        // внимание, а черновик распознавания это ещё не текст, а намёк на него: гипотеза каждую
        // секунду переписывается. Цвет тот же, что у времени, чтобы обе служебные строки читались
        // как один слой под главным.
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.lineBreakMode = .byTruncatingHead
        return l
    }()

    func showRecording() {
        DispatchQueue.main.async {
            self.liveText = ""
            self.recStart = Date()
            self.present("", .recording)
        }
    }

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
            guard self.mode == .recording, self.onScreen else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t != self.liveText else { return }   // партиал повторился — окно не трогаем
            self.liveText = t
            // Пока сказанного нет, справа тикает таймер: пустое место на его месте выглядело бы
            // сломанной плашкой.
            self.label.stringValue = self.recordingRightText()
            // Сказанное это содержание, а служебное время — фон: цвет переключаем вместе со смыслом.
            // В острове справа всегда время, значит там колонка всегда приглушённая.
            self.label.textColor = (self.islandOn || t.isEmpty) ? .secondaryLabelColor : .labelColor
            // Позицию НЕ пересчитываем: плашка уже стоит у каретки, а переставлять её на каждом
            // уточнении текста значит дёргать её под рукой у говорящего. Растём только вправо.
            self.relayout(text: self.label.stringValue, showWave: true)
            self.recenterIfDocked()
        }
    }

    /// Обрезать слева до maxLiveW, добавив «…». Считаем по фактической ширине шрифта, а не по числу
    /// символов: у кириллицы и латиницы разная ширина, и счёт «по буквам» дал бы прыгающую плашку.
    private func tail(_ s: String, max maxW: CGFloat, font: NSFont? = nil) -> String {
        let font = font ?? label.font ?? .systemFont(ofSize: 12, weight: .medium)
        func w(_ x: String) -> CGFloat { (x as NSString).size(withAttributes: [.font: font]).width }
        guard w(s) > maxW else { return s }
        var chars = Array(s)
        while !chars.isEmpty, w("…" + String(chars)) > maxW { chars.removeFirst() }
        // ⚠️ РЕЖЕМ ПО СЛОВУ, А НЕ ПО БУКВЕ (13.08.2026, поймано хуком KEYBOOP_LIVESHOT). Посимвольная
        // обрезка оставляла «…ак это выглядит» вместо «как это выглядит», и обрубок читался как
        // опечатка распознавания, то есть плашка врала про качество модели. Досдвигаем до ближайшего
        // пробела, но только если после него что-то остаётся: на одном длинном слове во всю ширину
        // сдвиг съел бы строку целиком, и лучше показать обрубок, чем пустоту.
        if let sp = chars.firstIndex(of: " "), sp + 1 < chars.count {
            chars = Array(chars[(sp + 1)...])
        }
        return "…" + String(chars)
    }
    func showProcessing() { DispatchQueue.main.async { self.present(L10n.t("voice.recognizing"), .processing) } }
    func hide() {
        DispatchQueue.main.async {
            if self.onScreen { kbLog("hud: спрятал") }
            self.presentGen += 1          // всё отложенное, что целилось в текущий показ, отменяется
            self.stopTimers(); self.wave.stop()
            self.recStart = nil; self.liveText = ""
            // Остров не гасим щелчком: он вырос из выреза, значит и уйти обязан туда же. Панель
            // убирает он сам, когда доиграет.
            if self.islandOn { self.island.collapse() } else { self.panel?.orderOut(nil) }
        }
    }

    /// Живой уровень микрофона (RMS) → waveform. Зовётся часто; вне записи молча игнорируем.
    func pushLevel(_ rms: Float) {
        DispatchQueue.main.async { guard self.mode == .recording, self.onScreen else { return }; self.wave.push(rms) }
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
            // ⚠️ СПРАШИВАЕМ «ПЛАШКА НА ЭКРАНЕ», А НЕ «ВИДНА ЛИ ОБЫЧНАЯ ПАНЕЛЬ». Тут стояло
            // `panel?.isVisible`, и с приходом острова (задача 144) это молча вернуло тот самый
            // дефект, ради которого весь этот метод и написан: в островном режиме обычная панель
            // спрятана, `wasRecording` выходил ложью, и тост посреди диктовки гасил запись насовсем.
            // В логе это видно как лишнее «спрятал» ровно через 2.2 с после тоста.
            let wasRecording = (self.mode == .recording && self.onScreen)
            self.present(text, .toast)
            let gen = self.presentGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, self.presentGen == gen else { return }   // показали что-то новее — не наше дело
                if wasRecording {
                    // Запись всё ещё идёт: если бы она кончилась, VoiceController уже позвал бы
                    // showProcessing или hide, а это сменило бы номер показа и мы бы сюда не дошли.
                    kbLog("hud: тост отыграл, возвращаю плашку записи (запись продолжается)")
                    self.present("", .recording)
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
        guard let p = activePanel, let v = p.contentView else { return }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        if islandOn, let ctx = NSGraphicsContext.current?.cgContext {
            // ⚠️ У ОСТРОВА ПОДЛОЖКА ЭТО ЕГО СИЛУЭТ. Форма живёт в слое (чёрный фон + маска), а в
            // битмап слои не попадают — то же место, где обычной плашке не достаётся размытия.
            // Нарисуй тут прямоугольник, и снимок покажет ровно ту фигуру, которой на экране нет,
            // то есть смотреть на него станет незачем. Путь берём у самого острова, не свой.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(island.silhouette())
            ctx.fillPath()
        } else {
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()   // тон HUD-плашки, чтобы снимок читался
            NSBezierPath(roundedRect: v.bounds, xRadius: 10, yRadius: 10).fill()
        }
        rep.draw(in: v.bounds)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        kbLog("hud: снимок плашки сохранён (\(Int(v.bounds.width))×\(Int(v.bounds.height)))")
    }

    // MARK: -

    private func present(_ raw: String, _ m: Mode) {
        let p = panel ?? makePanel(); panel = p
        presentGen += 1
        mode = m
        stopTimers()
        // Куда показываем — решаем ДО раскладки: от этого зависит и минимальная ширина строки, и
        // то, в чьём контейнере эта строка будет лежать.
        prepareHost()
        // У записи правую колонку собираем сами: звавшему нечего сюда передать, время он не считает.
        let text = (m == .recording) ? recordingRightText() : raw
        label.stringValue = text
        // ⚠️ ТАЙМЕР ПРИГЛУШЁН, А СООБЩЕНИЯ НЕТ. На плашке записи и так два ярких пятна — коралловая
        // волна и белый текст, — и в паре с волной таймер начинал спорить с ней за внимание. Время
        // это фон происходящего, а не событие: приглушённый серый оставляет единственным акцентом
        // волну. Сказанное вслух (потоковый текст), «Распознаю» и тосты остаются белыми: это уже
        // содержание, а не служебная цифра.
        // ⚠️ БЫЛ СИСТЕМНЫЙ ЗЕЛЁНЫЙ (автор 06.08: «очень странный цвет»). Зелёный не наш: во всём
        // приложении статус показывает коралловый акцент, а текст остаётся белым.
        label.textColor = (m == .recording && liveText.isEmpty) ? .secondaryLabelColor : .labelColor
        // ⚠️ ЗНАК ТЕПЕРЬ ВИДЕН ВСЕГДА, А НЕ ТОЛЬКО У ТОСТА (задача 125). Плашка записи была
        // единственной поверхностью приложения без нашего знака, то есть ровно та, которую человек
        // видит чаще всего, ничем не подписана. Теперь скелет один на все три состояния:
        // знак → волна → правая колонка (таймер, статус или сказанное).
        dot.isHidden = false

        let showWave = (m != .toast)
        relayout(text: text, showWave: showWave)

        switch m {
        case .recording:
            wave.color = Self.coral
            wave.start(shimmer: false)
            startTicker()
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

        if islandOn {
            island.show()
        } else {
            positionAtCursor(p)
            p.orderFrontRegardless()
        }
    }

    // MARK: - Остров в вырезе (задача 144)

    /// Форс острова для dev-хука, минуя настройку — как `forceTop`. Плюс переменная окружения:
    /// хуки снимков живут в `AppDelegate`, а лезть туда ради одного режима незачем.
    var forceIsland = false

    /// Просят ли остров.
    ///
    /// ⚠️ ВРЕМЕННЫЙ КЛЮЧ. Пока это сырой `voiceHudIsland` в UserDefaults, а не настройка: строку в
    /// интерфейсе и переводы автор подключает сам, и заводить сюда второй, свой вариант той же
    /// настройки значило бы разойтись с ним на ровном месте.
    private var islandWanted: Bool {
        if forceIsland { return true }
        // Переменная работает в ОБЕ стороны: «1» просит остров, «0» просит обычную плашку. Второе
        // нужно снимкам: настройка человека может стоять на острове, а посмотреть надо на плашку у
        // курсора, и трогать ради снимка чужие настройки нельзя.
        if let e = ProcessInfo.processInfo.environment["KEYBOOP_ISLAND"] { return e == "1" }
        return AppSettings.shared.voiceHudIsland
    }

    /// Панель, которая показывает плашку прямо сейчас.
    private var activePanel: NSPanel? { islandOn ? island.panel : panel }
    /// Плашка (любая из двух) на экране.
    private var onScreen: Bool { islandOn ? island.isVisible : (panel?.isVisible == true) }

    /// Экран, на котором ищем вырез: тот, где сейчас работают. У тоста каретки нет по определению,
    /// поэтому там сразу мышь.
    private func islandTargetScreen() -> NSScreen? {
        let caret = (mode != .toast) ? CaretLocator.caretScreenRect() : nil
        return caret.flatMap { c in NSScreen.screens.first { $0.frame.intersects(c) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    /// Выбрать хозяина для знака, волны и текста: остров или обычная плашка.
    ///
    /// ⚠️ ОСТРОВ БЕЗ ВЫРЕЗА НЕ СУЩЕСТВУЕТ, И ЭТО НЕ ОШИБКА. У внешнего монитора, у MacBook Air до
    /// 2022 и у машин на Intel выреза нет; рисовать «остров» там значит показать чёрную плашку,
    /// приклеенную к пустому месту. Молча возвращаемся к тому, что было (`voiceHudTop` или
    /// каретка) — человек видит привычное поведение, а не поломку.
    private func prepareHost() {
        // ⚠️ ТОСТ ПОСРЕДИ ДИКТОВКИ ОСТАЁТСЯ В ОСТРОВЕ, И ЭТО НЕ МЕЛОЧЬ (задача 144 требует все три
        // состояния). У тоста нет каретки, значит экран ему выбирает мышь — а она в этот момент где
        // угодно, хоть на внешнем мониторе. Без этой строки «Скопировано» посреди записи схлопывало
        // остров и показывало сообщение обычной плашкой у курсора, то есть остров жил ровно два
        // состояния из трёх. Поймано снимком 13.08.2026.
        if islandOn, island.isVisible, mode == .toast { return }
        var on = false
        if islandWanted {
            if let s = islandTargetScreen(), island.prepare(screen: s, contentHeight: islandRowH) {
                on = true
            } else {
                kbLog("hud: остров просили, но выреза на этом экране нет → обычная плашка")
            }
        }
        guard on != islandOn else { return }
        // Переезд содержимого. Один комплект видов на оба места: два одинаковых набора рано или
        // поздно разъезжаются, и правку внешнего вида приходится делать дважды.
        let host: NSView = on ? island.content : (bg ?? panel!.contentView!)
        // ⚠️ КНОПКИ ПЕРЕЕЗЖАЮТ ВМЕСТЕ СО ВСЕМИ. Забыл их здесь при первой сборке — они остались в
        // обычной плашке, а в острове не появились вовсе, и на снимке выглядело так, будто их не
        // нарисовали. Список переезжающих видов ровно один, и новый элемент строки обязан попадать
        // именно в него.
        for v in [dot as NSView, wave as NSView, label as NSView,
                  cancelBtn as NSView, doneBtn as NSView, liveLabel as NSView] {
            v.removeFromSuperview()
            host.addSubview(v)
        }
        if on { panel?.orderOut(nil) } else { island.hideNow() }
        islandOn = on
        kbLog(on ? "hud: остров в вырезе" : "hud: обычная плашка")
    }

    /// РАСКЛАДКА ПЛАШКИ. Один скелет на все состояния (задача 125):
    ///
    ///     pad | знак | pad | [волна | pad] | правая колонка | pad
    ///
    /// Правая колонка это таймер записи, слово «Распознаю» или текст тоста. Волны нет только у
    /// тоста: ему нечего показывать уровнем, а бары рядом с сообщением читались бы как «пишем».
    ///
    /// ⚠️ ЗАЗОР ПОСЛЕ ЗНАКА УЖЕ ВНЕШНЕГО ПОЛЯ, И ЭТО НЕ ПРОИЗВОЛ (замер 08.08.2026, жалоба пользователя
    /// «плохо выравнивание точки и текста»). Померил плашку по пикселям: по вертикали знак стоял
    /// ровно, поля слева и справа были равны. Кривым выглядело другое: зазор до текста был 10.5 пт
    /// при внешнем поле 13, то есть почти такой же. Глаз видел не «значок и сообщение», а три
    /// равноудалённых пятна. Группировка требует, чтобы внутренний зазор был ЗАМЕТНО меньше внешнего
    /// поля, иначе элементы распадаются.
    private func relayout(text: String, showWave: Bool) {
        let font = label.font ?? .systemFont(ofSize: 12, weight: .medium)
        let lblW = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        let markSize = Self.markImage?.size ?? NSSize(width: dotW, height: dotW)
        let markGap = showWave ? pad : toastGap
        let waveBlock = showWave ? (waveW + pad) : 0
        // Кнопки живут только в острове и только на записи: в обычной плашке им не место, там нет
        // ни повода (её не надо завершать мышью), ни площади.
        let btns = islandOn && mode == .recording
        let btnBlock = btns ? (IslandButton.side + pad) : 0
        let total = pad + btnBlock + markSize.width + markGap + waveBlock + lblW + btnBlock + pad

        // Сдвиг строки внутри контейнера. У обычной плашки его нет: она ровно по содержимому. У
        // острова корпус не бывает уже выреза с плечами, значит бывает шире строки — и строку в нём
        // надо центровать, иначе она липнет к левой дуге.
        var x0: CGFloat = 0
        var bodyW: CGFloat = total
        if islandOn {
            // Высоту меняем ДО ширины: обе правки уезжают в одну перерисовку фигуры, и порядок
            // «сначала форма, потом расстановка» избавляет от кадра, где строка уже вторая, а
            // корпус ещё однострочный.
            island.setContentHeight(islandRowH + (liveRowOn ? liveGap + liveRowH : 0))
            bodyW = island.layout(contentWidth: total)
            x0 = ((bodyW - total) / 2).rounded()
        } else if let p = panel {
            var f = p.frame
            f.size = NSSize(width: total, height: rowH)
            p.setFrame(f, display: false)
            bg?.frame = NSRect(x: 0, y: 0, width: total, height: rowH)
        }

        // Низ ПЕРВОГО ряда. В острове со второй строкой первый ряд поднимается над ней: сверху он
        // прижат к кромке выреза, и двигать надо не его, а то, что под ним.
        let rowY = liveRowOn ? (liveRowH + liveGap) : 0

        cancelBtn.isHidden = !btns
        doneBtn.isHidden = !btns
        if btns {
            let y = rowY + ((rowH - IslandButton.side) / 2).rounded()
            cancelBtn.frame = NSRect(x: x0 + pad, y: y, width: IslandButton.side, height: IslandButton.side)
            doneBtn.frame = NSRect(x: x0 + total - pad - IslandButton.side, y: y,
                                   width: IslandButton.side, height: IslandButton.side)
        }
        dot.frame = NSRect(x: x0 + pad + btnBlock, y: rowY + ((rowH - markSize.height) / 2).rounded(),
                           width: markSize.width, height: markSize.height)
        let waveX = x0 + pad + btnBlock + markSize.width + markGap
        wave.isHidden = !showWave
        if showWave { wave.frame = NSRect(x: waveX, y: rowY + (rowH - 20) / 2, width: waveW, height: 20) }
        label.frame = NSRect(x: waveX + waveBlock, y: rowY + (rowH - 18) / 2, width: lblW, height: 18)

        // ВТОРАЯ СТРОКА. Ширину ей задаёт КОРПУС, а не текст: остров уже расставлен по первому ряду,
        // и речь обязана уместиться в то, что есть. Поэтому обрезаем по фактической ширине корпуса
        // минус поля, и корпус от длины речи не зависит вовсе.
        liveLabel.isHidden = !liveRowOn
        if liveRowOn {
            let w = max(60, bodyW - 2 * pad)
            liveLabel.stringValue = tail(liveText, max: w, font: liveLabel.font)
            liveLabel.frame = NSRect(x: ((bodyW - w) / 2).rounded(), y: 0, width: w, height: liveRowH)
        }
    }

    // MARK: - Таймер записи

    /// «0:07», «1:42», «12:05». Минуты не обрезаем: диктовка на час это странно, но врать про неё
    /// хуже, чем показать «63:20».
    private func elapsedString() -> String {
        let s = Int(Date().timeIntervalSince(recStart ?? Date()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Что стоит справа во время записи: сказанное, если оно есть, иначе время.
    /// ⚠️ В ОСТРОВЕ СПРАВА ВСЕГДА ВРЕМЯ. Речь там идёт второй строкой, и если положить её ещё и
    /// сюда, корпус начнёт разъезжаться вширь на каждом партиале — ровно то, чего просили избежать.
    /// У плашки у курсора второй строки нет, там речь по-прежнему занимает правую колонку.
    private func recordingRightText() -> String {
        if islandOn { return elapsedString() }
        return liveText.isEmpty ? elapsedString() : tail(liveText, max: maxLiveCaretW)
    }

    /// Обновляем раз в полсекунды, а не раз в секунду: при секундном шаге между началом записи и
    /// первым тиком проходит до секунды, и «0:00» успевает застояться настолько, что читается как
    /// зависший таймер.
    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.mode == .recording, self.onScreen else { return }
            guard self.liveText.isEmpty else { return }        // справа сейчас речь, таймеру там места нет
            let s = self.elapsedString()
            guard s != self.label.stringValue else { return }  // секунда не сменилась — не трогаем окно
            self.label.stringValue = s
            self.relayout(text: s, showWave: true)
            self.recenterIfDocked()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // HUD-плашка всегда тёмная (.hudWindow) — пиннем тёмную тему, чтобы .labelColor в светлой
        // системной теме не резолвился в тёмный (тёмный текст на тёмном HUD). См. AppBanner.
        p.appearance = NSAppearance(named: .darkAqua)
        // ⚠️ ФЛАГ ПЕРЕД УРОВНЕМ, а не наоборот: сеттер `isFloatingPanel` сам выставляет уровень
        // `.floating` (3) и затирает всё, что поставили до него. На острове это стоило дня разбора
        // (см. NotchIsland), здесь та же пара строк в том же порядке, поэтому чиним заодно: плашка
        // в верхнем режиме обязана лежать над строкой меню, а не под ней.
        p.isFloatingPanel = true
        p.level = .statusBar
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

        // Наш знак слева — во всех состояниях (задача 125). До 0.4 он стоял только у тоста, и
        // плашка записи, самая частая поверхность приложения, была единственной ничем не подписана.
        dot.image = Self.markImage
        dot.imageScaling = .scaleNone
        v.addSubview(dot)

        // ⚠️ МОНОШИРИННЫЕ ЦИФРЫ. Обычная системная восьмёрка шире единицы, и таймер на плашке
        // дёргал бы её ширину каждую секунду. На буквы шрифт не влияет: у `monospacedDigit` фиксирована
        // только ширина цифр, поэтому «Распознаю» и тосты выглядят ровно как раньше.
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        v.addSubview(label)
        v.addSubview(cancelBtn)
        v.addSubview(doneBtn)

        p.contentView?.addSubview(v)
        return p
    }

    /// Плашку ставим у КАРЕТКИ ВВОДА (место, куда пойдёт текст), а не у курсора мыши. Если каретка
    /// недоступна (Electron/web, нет фокуса) — падаем на прежнее поведение (по мыши). Тосты (обучение
    /// на отмене) — всегда по мыши: там нет «места ввода».
    private func positionAtCursor(_ p: NSPanel) {
        dockedTop = false
        let caret = (mode != .toast) ? CaretLocator.caretScreenRect() : nil

        // РЕЖИМ «ВВЕРХУ ПО ЦЕНТРУ, ПОД ЧЁЛКОЙ» (задача 125). Тосты сюда не попадают: сообщение об
        // отмене или о пароле относится к тому месту, где человек работает, а не к верху экрана.
        if mode != .toast, AppSettings.shared.voiceHudTop || forceTop {
            let target = caret.flatMap { c in NSScreen.screens.first { $0.frame.intersects(c) } }
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
            if let s = target, Self.isBuiltIn(s) {
                dockedTop = true
                kbLog("hud: под чёлкой (встроенный экран)")
                positionAtTop(p, s)
                return
            }
            // ⚠️ Внешний монитор выреза не имеет, и плашка под несуществующей чёлкой выглядит
            // чужеродно (решение автора 11.08.2026). Молча падаем к каретке, а не показываем её на
            // другом экране: смотрят туда, где печатают.
            kbLog("hud: режим «вверху», но экран не встроенный → к каретке")
        }

        if let caret {
            kbLog("hud: у каретки (\(Int(caret.minX)),\(Int(caret.minY)))")
            positionNearCaret(p, caret)
        } else {
            if mode != .toast { kbLog("hud: каретка недоступна → по курсору мыши") }
            positionNearMouse(p)
        }
    }

    /// Встроенный ли это экран. Спрашиваем CoreGraphics, а не гадаем по наличию выреза: у MacBook
    /// Air 2020 и у Intel-машин чёлки нет, но плашка вверху им идёт ровно так же.
    private static func isBuiltIn(_ s: NSScreen) -> Bool {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) != 0
    }

    /// Вверху по центру ЭКРАНА, сразу под строкой меню.
    ///
    /// ⚠️ Центр берём у `frame`, а не у `visibleFrame`: вырез прорезан посередине физического экрана,
    /// а `visibleFrame` съезжает от Дока сбоку, и плашка уехала бы вместе с ним.
    /// По вертикали, наоборот, нужен именно `visibleFrame`: его верх у машины с чёлкой уже опущен
    /// под неё, то есть система сама сказала нам, где кончается вырез.
    private func positionAtTop(_ p: NSPanel, _ s: NSScreen) {
        let x = (s.frame.midX - p.frame.width / 2).rounded()
        let y = (s.visibleFrame.maxY - p.frame.height - 4).rounded()
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Верхний режим ДЛЯ DEV-ХУКА, в обход настроек. Смотреть на место плашки надо глазами, а
    /// единственный другой способ включить верх — переписать чужую настройку и не забыть вернуть.
    /// Забыть легко, поэтому здесь отдельный флаг, который живёт только в памяти процесса.
    var forceTop = false

    /// Плашка стоит вверху по центру ПРЯМО СЕЙЧАС. Нужно тем, кто меняет её ширину на ходу (таймер
    /// перевалил за десять минут, приехал живой текст): у каретки плашка растёт вправо и это верно,
    /// а по центру она обязана расти в обе стороны, иначе центр перестаёт быть центром.
    private var dockedTop = false
    private func recenterIfDocked() {
        // Остров центруется по вырезу сам, внутри своей раскладки — тут ему делать нечего.
        guard !islandOn, dockedTop, let p = panel,
              let s = NSScreen.screens.first(where: { $0.frame.intersects(p.frame) }) else { return }
        positionAtTop(p, s)
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
        ticker?.invalidate(); ticker = nil
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


/// Тонкая кнопка острова: только глиф, без подложки и рамки.
///
/// Рисуем сами, а не берём NSButton: у кнопки AppKit своя геометрия, свои отступы и своя реакция на
/// нажатие, и подогнать её под строку высотой в двадцать пунктов дороже, чем нарисовать две линии.
/// Плюс здесь важна ровно одна вещь — вес линии, и он должен совпадать с нашим знаком.
private final class IslandButton: NSView {
    static let side: CGFloat = 20
    private let symbol: String
    private let action: () -> Void
    private var hot = false { didSet { needsDisplay = true } }

    init(symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hot = true }
    override func mouseExited(with e: NSEvent)  { hot = false }
    /// ⚠️ Панель не активна (`nonactivatingPanel`), поэтому ПЕРВЫЙ клик по ней система по умолчанию
    /// тратит на активацию окна. Человеку пришлось бы жать дважды, а у него в этот момент идёт
    /// запись — второго шанса нет.
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {}          // гасим, чтобы не уехало в окно
    override func mouseUp(with e: NSEvent) {
        guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let c: NSColor = hot ? VoiceIndicator.coral : .secondaryLabelColor
        c.setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.6                 // тот же вес, что у линий знака Keyboop
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let m: CGFloat = 5.5              // поля внутри кнопки
        let r = bounds.insetBy(dx: m, dy: m)
        if symbol == "xmark" {
            p.move(to: NSPoint(x: r.minX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.maxY))
            p.move(to: NSPoint(x: r.minX, y: r.maxY)); p.line(to: NSPoint(x: r.maxX, y: r.minY))
        } else {
            // Галочка: короткое плечо вниз-влево, длинное вверх-вправо. Пропорции 1:2, как в SF.
            p.move(to: NSPoint(x: r.minX, y: r.midY))
            p.line(to: NSPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.12))
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - r.height * 0.06))
        }
        p.stroke()
    }
}
