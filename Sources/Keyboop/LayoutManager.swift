import Foundation
import Carbon

/// Чтение и переключение системной раскладки через Text Input Source (TIS).
final class LayoutManager {

    /// НАШЕ МНЕНИЕ о текущей раскладке. Известный баг macOS (kawa PR #21, подтверждён нашим логом
    /// 24.07: «→ EN» ×6 подряд): при быстрых переключениях БЕЗ нажатий клавиш между ними
    /// TISCopyCurrentKeyboardInputSource возвращает УСТАРЕВШЕЕ значение — процесс читает свой
    /// замороженный кэш, пока его не синхронизирует нажатие/смена окна. Из-за этого мгновенный
    /// переключатель считал «всё ещё RU» и шесть раз подряд «переключал» в EN.
    /// Лекарство то же, что у kawa: ПОМНИТЬ последний выбранный источник самим и верить памяти,
    /// а не чтению. Память обновляется нашими select'ами и TIS-уведомлениями (внешняя смена).
    private var opinionCyr: Bool?

    /// Текущая раскладка — кириллическая? (сырое чтение TIS; может отставать, см. opinionCyr)
    func currentIsCyrillic() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return Self.languages(of: src).first?.hasPrefix("ru") ?? false
    }

    /// Текущая раскладка с поправкой на баг стейл-чтения: если мы недавно переключали сами —
    /// отвечает память, иначе честное чтение TIS.
    func currentIsCyrillicOpinion() -> Bool { opinionCyr ?? currentIsCyrillic() }

    /// Внешняя смена раскладки (TIS-уведомление): обновляем мнение свежим чтением.
    /// ⚠️ Чтение прямо в момент уведомления МОЖЕТ быть стейлым (24.07: ручная смена раскладки →
    /// уведомление → чтение вернуло старую → мнение и кэш дружно зарядились неправдой, и целая
    /// строка «cyjdf drk.xbk…» осталась латиницей при идеально-русском буфере). Поэтому мнение
    /// здесь только помечается сомнительным, а правду устанавливает reconcileWithReality() на
    /// ближайшей границе слова — в момент, когда чтение достоверно (kawa: «после нажатия»).
    /// (Финал аудита 24.07, R2): чтению в момент уведомления НЕ доверяем вовсе — мнение честно
    /// сбрасывается в «не знаю», правду установят boundary-сверка (следующее слово) или фоновая
    /// (2.5с простоя). Пока мнения нет, currentIsCyrillicOpinion() отвечает сырым чтением — хуже
    /// самосогласованной лжи оно не бывает.
    func noteExternalLayoutChange() { opinionCyr = nil }

    /// Когда мы сами переключали в последний раз (для сверки: свежий свой select не проверяем —
    /// чтение в этот момент само стейлится и дало бы ложное «не применилось»).
    private var lastSelectAt: TimeInterval = 0

    /// Последний источник, выбранный фолбэком латиницы, — чтобы не писать одну строку сотни раз.
    private var lastFallbackLatinID: String?

    /// Мы в grace-окне собственного переключения: любые чтения «текущего» из TIS недостоверны,
    /// а правда уже установлена детерминированно (кэш из выбранного объекта + мнение).
    var withinOwnSelectGrace: Bool { ProcessInfo.processInfo.systemUptime - lastSelectAt < 1.0 }

    /// Сверить мнение с реальностью. Звать ТОЛЬКО в моменты, когда чтение TIS достоверно:
    /// на границе слова (только что было реальное нажатие) или в глубоком простое.
    /// true = расходились, мнение и кэш приведены к реальности.
    @discardableResult
    func reconcileWithReality() -> Bool {
        guard ProcessInfo.processInfo.systemUptime - lastSelectAt > 0.8 else { return false }
        let real = currentIsCyrillic()
        guard let op = opinionCyr else {
            // Мнение сброшено (внешняя смена раскладки, R2): принимаем реальность. Слово подозрительно
            // ТОЛЬКО если блоб декодера при этом реально сменился — иначе декод шёл верной раскладкой
            // и пропускать конверсию незачем.
            opinionCyr = real
            return KeyboardLayoutCache.refreshOnMain()
        }
        guard real != op else { return false }
        opinionCyr = real
        KeyboardLayoutCache.refreshOnMain()   // чтение здесь достоверно — момент выбран вызывающим
        return true
    }

    /// Короткий код текущей раскладки для индикатора ("RU"/"EN"/…).
    /// Язык АКТИВНОЙ раскладки для индикатора — с поправкой на фоновую природу приложения.
    ///
    /// ⚠️ Почему не просто `currentCode()`: `TISCopyCurrentKeyboardInputSource` в агенте без окон
    /// отдаёт раскладку СВОЕГО процесса и не следует за внешними переключениями. Замер 25.07.2026:
    /// система щёлкала RU→EN→RU→EN, чтение всё это время возвращало «RU», а системное уведомление
    /// `kTISNotifySelectedKeyboardInputSourceChanged` в наш процесс не пришло ни разу (0 из 4).
    /// Настройки HIToolbox при этом менялись мгновенно и без ошибок — их и спрашиваем.
    /// Из-за этого индикатор RU/EN давно показывал устаревший язык, если раскладку меняли не через
    /// Keyboop; со флагом это стало заметно сразу.
    func currentCodeLive() -> String {
        Self.languageFromSystemPrefs() ?? currentCode()
    }

    /// Нормализованное имя раскладки → код языка. Строим один раз по списку установленных раскладок:
    /// в настройках лежит имя («U.S.», «Russian — PC»), а язык знает только TIS-объект.
    private static var nameToLang: [String: String] = [:]

    /// Имена в настройках и в TIS пишутся по-разному («U.S.» против «US» в идентификаторе), поэтому
    /// сравниваем по «скелету»: только буквы и цифры в нижнем регистре.
    private static func nameKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func buildNameMap() {
        guard nameToLang.isEmpty else { return }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        for src in list {
            guard let lang = languages(of: src).first else { continue }
            let code = String(lang.prefix(2)).uppercased()
            var names: [String] = []
            if let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
                names.append(Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
            }
            if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
                names.append(String(id.split(separator: ".").last ?? ""))   // «com.apple.keylayout.Russian-PC» → «Russian-PC»
            }
            for n in names where !n.isEmpty { nameToLang[nameKey(n)] = code }
        }
    }

    /// Что система САМА считает выбранной раскладкой. `Synchronize` обязателен: без него значение
    /// в нашем процессе кэшируется (тот же урок, что с AppleFnUsageType в GlobeKey).
    private static func languageFromSystemPrefs() -> String? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        guard let raw = CFPreferencesCopyAppValue("AppleSelectedInputSources" as CFString,
                                                 "com.apple.HIToolbox" as CFString) as? [[String: Any]]
        else { return nil }
        buildNameMap()
        for entry in raw {
            let name = (entry["KeyboardLayout Name"] as? String) ?? (entry["Input Mode"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            // ⚠️ СНАЧАЛА ЦЕЛОЕ ИМЯ, и только потом хвост после точки (найдено трассировкой 05.08.2026).
            //
            // Хвост придуман для методов ввода, где в поле лежит идентификатор вида
            // «com.apple.inputmethod.Kotoeri». Но резался он БЕЗУСЛОВНО, а имя американской раскладки
            // это «U.S.» — с точками внутри. Хвост от неё равен «S», такого ключа в карте нет, и
            // функция отдавала nil ровно для латиницы, честно отвечая только про русскую.
            //
            // Тихо это не проходило: `currentCodeLive()` при nil падает на `currentCode()`, то есть на
            // сырое чтение TIS, которое в фоновом агенте не следует за внешними переключениями (замер
            // 25.07, ради него весь этот путь и появился). Значит индикатор языка был достоверен в одну
            // сторону и угадывал в другую. Тот же nil слепил и сверку переключения (`verifySelect`):
            // для латиницы она не срабатывала вовсе.
            if let code = nameToLang[nameKey(name)] { return code }
            if name.contains("."),
               let tail = name.split(separator: ".").last,
               let code = nameToLang[nameKey(String(tail))] { return code }
        }
        return nil
    }

    func currentCode() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "??" }
        let lang = Self.languages(of: src).first ?? "en"
        return String(lang.prefix(2)).uppercased()
    }

    /// Переключить системную раскладку на кириллицу/латиницу (если такая включена).
    ///
    /// ⚠️ ЛАТИНИЦУ ИЩЕМ ПО ASCII-СПОСОБНОСТИ, А НЕ ПО ЯЗЫКУ «en» (28.07, репорты #11 и #15 от одного
    /// человека на 0.2.67 и 0.2.69). Раньше здесь было `languages.first.hasPrefix("en")`, и в его
    /// логах лежат 45 строк «среди включённых раскладок нет EN» при НУЛЕ успешных переключений
    /// RU→EN и пяти успешных EN→RU. То есть мгновенное переключение работало ровно в одну сторону:
    /// человек уходил в русский и обратно уже не возвращался. Причина в том, что штатные латинские
    /// раскладки macOS объявляют первым языком вовсе не английский: ABC-AZERTY → fr, ABC-QWERTZ → de,
    /// испанская → es, чешская → cs, польская → pl. Флаг `IsASCIICapable` описывает ровно то, что нам
    /// нужно («на этой раскладке можно набрать латиницу»), и кириллические раскладки его не имеют.
    /// Настоящий английский всё равно предпочитаем первым — у большинства он и есть.
    @discardableResult
    func selectLayout(cyrillic: Bool) -> Bool {
        let sources = enabledKeyboardSources()
        let src: TISInputSource?
        if cyrillic {
            src = sources.first { (Self.languages(of: $0).first ?? "").hasPrefix("ru") }
        } else {
            src = sources.first { (Self.languages(of: $0).first ?? "").hasPrefix("en") }
                ?? sources.first { Self.isUsableLatinLayout($0) }
        }
        guard let src else {
            // Разводим два РАЗНЫХ отказа: «подходящей раскладки нет вовсе» и «TIS отказался
            // переключать» (ниже). Раньше обе писали одну строку, из-за чего этот баг и баг с
            // перехватом на macOS 27 beta невозможно было отличить в логе друг от друга.
            kbLog("layout: не нашёл \(cyrillic ? "кириллическую" : "латинскую") раскладку среди включённых (\(sources.count) шт.)")
            return false
        }
        // Сработал фолбэк — пишем об этом. Ради разведения логов правку и делали, а самая рискованная
        // ветка не должна быть немой: если человек придёт с «переключает не туда», нам нужен ID.
        // ⚠️ Но ровно ОДИН раз на источник. У человека без английской раскладки фолбэк срабатывает
        // на КАЖДОЕ переключение языка, то есть сотни раз в день, а в багрепорт уходит хвост из 300
        // строк: строка-на-каждое-переключение вытеснила бы оттуда всё остальное. Как с причинами
        // отказа тихого обновления — логируем смену состояния, а не его наличие.
        if !cyrillic, (Self.languages(of: src).first ?? "").hasPrefix("en") == false {
            let id = Self.stringProp(src, kTISPropertyInputSourceID) ?? "?"
            if id != lastFallbackLatinID {
                lastFallbackLatinID = id
                kbLog("layout: EN-раскладки нет, беру ASCII-способную \(id)")
            }
        }
        let ok = TISSelectInputSource(src) == noErr
        if !ok {
            kbLog("layout: TISSelectInputSource отказал (\(Self.stringProp(src, kTISPropertyInputSourceID) ?? "?"))")
        }
        if ok {
            opinionCyr = cyrillic   // память против стейл-чтения (см. opinionCyr)
            lastSelectAt = ProcessInfo.processInfo.systemUptime
            // Кэш — из ТОГО источника, который мы только что выбрали (объект в руках). НЕ через
            // чтение «текущего»: сразу после TISSelect оно возвращает СТАРЫЙ источник (стейл-баг
            // kawa PR#21) — 24.07 кэш заряжался старьём, сверка алфавитов портила правильные буквы
            // (50 ложных подмен за 9с), а отложенный перечит мог заражать кэш повторно. TIS — main-only.
            if Thread.isMainThread { KeyboardLayoutCache.refresh(fromSelected: src) }
            else { DispatchQueue.main.async { KeyboardLayoutCache.refresh(fromSelected: src) } }
            verifySelect(cyrillic: cyrillic, source: src)
        }
        return ok
    }

    /// Сколько раз система НЕ применила наше переключение. Для лога: событие должно быть редким, и
    /// если счётчик растёт быстро, это само по себе находка.
    private var selectMissCount = 0

    /// СВЕРКА: применилось ли переключение на самом деле (задача 9 / P1.3, 05.08.2026).
    ///
    /// `TISSelectInputSource` возвращает `noErr` как «команда принята», а не как «раскладка сменилась».
    /// Дальше мы оптимистично записывали `opinionCyr` и заряжали кэш декодера из ЗАПРОШЕННОГО
    /// источника. Если переключение не состоялось, мы начинали верить собственной неправде, и это
    /// корень сразу двух жалоб: перевёрнутого индикатора и «печатает не в той раскладке».
    ///
    /// ⚠️ Спрашиваем HIToolbox, а НЕ `TISCopyCurrentKeyboardInputSource`. Сырое чтение сразу после
    /// select отдаёт СТАРЫЙ источник (стейл-баг, описан вверху файла), проверка увидела бы «не
    /// применилось» на исправном переключении и щёлкнула бы ещё раз, воспроизведя шторм «→ EN ×6»
    /// от 24.07. Настройки HIToolbox этим не страдают, и их же читает индикатор.
    ///
    /// Замеры 05.08, из которых взяты числа: чтение настроек стоит **0.06 мс**, то есть на цену
    /// смотреть незачем; систему устраивает **11 мс**, чтобы признать переключение. Ждём 60 мс,
    /// пятикратный запас.
    ///
    /// ⚠️ Поправка РОВНО ОДНА, и повторной сверки за ней нет. Неограниченный цикл здесь это тот самый
    /// шторм. Если и вторая попытка не прошла, честнее принять реальность, чем настаивать.
    private func verifySelect(cyrillic: Bool, source src: TISInputSource) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self else { return }
            // Мнение сбито (`noteExternalLayoutChange`) — значит человек переключился сам, пока мы
            // ждали. Спорить с хозяином нельзя: он выбрал позже нас, его выбор и главнее.
            guard self.opinionCyr == cyrillic else { return }
            guard let code = Self.languageFromSystemPrefs() else { return }   // не знаем — молчим
            let real = (code == "RU")
            guard real != cyrillic else { return }                            // всё применилось
            self.selectMissCount += 1
            if self.selectMissCount == 1 || self.selectMissCount % 10 == 0 {
                kbLog("layout: переключение не применилось (просили \(cyrillic ? "RU" : "латиницу"), система показывает \(code)), поправка №\(self.selectMissCount)")
            }
            guard TISSelectInputSource(src) == noErr else {
                // Вторая попытка даже не принята. Дальше врать себе хуже, чем признать: выравниваем
                // мнение и кэш по тому, что реально выбрано, иначе декодер продолжит считать буквы
                // не тем алфавитом.
                self.opinionCyr = real
                KeyboardLayoutCache.refreshOnMain()
                kbLog("layout: поправка отклонена системой, принимаю реальность (\(code))")
                return
            }
        }
    }

    // MARK: - Внутреннее

    private func enabledKeyboardSources() -> [TISInputSource] {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(cf)
        var result: [TISInputSource] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard Self.stringProp(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsEnabled) else { continue }
            result.append(src)
        }
        return result
    }

    /// Годится ли источник как «латиница» для фолбэка мгновенного переключения.
    ///
    /// Мало быть ASCII-способным — нужен ещё блоб раскладки (`kTISPropertyUnicodeKeyLayoutData`).
    /// ⚠️ Найдено ревью 28.07 живым опросом TIS: среди установленных источников есть ASCII-способные
    /// БЕЗ блоба — вьетнамские методы ввода (Telex/VNI/VIQR). Если бы фолбэк выбрал такой источник,
    /// `TISSelectInputSource` вернул бы noErr, мнение стало бы «мы в латинице», а
    /// `KeyboardLayoutCache.refresh(fromSelected:)` молча вышел бы по своему guard — и в кэше остался
    /// бы РУССКИЙ блоб. Дальше тап декодирует каждое нажатие русской раскладкой (кэш непустой, значит
    /// фолбэк на CG-строку не включается), движок видит кириллицу там, где человек печатает латиницу,
    /// и «чинит» нормальный текст в мусор во всех программах. Самолечения у этого состояния нет.
    /// Пустой список языков тоже отбрасываем: так отсеивается Unicode Hex Input, при выборе которого
    /// у человека молча пропадают Option-акценты и мёртвые клавиши.
    private static func isUsableLatinLayout(_ src: TISInputSource) -> Bool {
        guard boolProp(src, kTISPropertyInputSourceIsASCIICapable) else { return false }
        guard TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) != nil else { return false }
        return !languages(of: src).isEmpty
    }

    /// Названия ВКЛЮЧЁННЫХ раскладок — для шапки багрепорта.
    ///
    /// Прямая улика для класса «переключает только в одну сторону»: у людей с ABC-AZERTY, QWERTZ,
    /// испанской и подобными первый объявленный язык не «en», и старый поиск латиницы их не находил.
    /// Отдаём языковый тег, признак ASCII и — только для ШТАТНЫХ раскладок — название.
    ///
    /// ⚠️ Название своей раскладки придумывает не Apple, а тот, кто её собрал (Ukelele, корпоративные
    /// сборки, самоделки): там регулярно встречаются имя человека, название работодателя, внутренние
    /// кодовые слова. Багрепорт уходит на наш сервер, поэтому имя не-эппловского источника мы не
    /// отправляем вовсе — пишем «своя». Диагностическая ценность в теге языка и признаке ASCII, а
    /// они остаются на месте: класс «переключает только в одну сторону» по ним и виден.
    static func enabledLayoutNamesForDiagnostics() -> [String] {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        var out: [String] = []
        for i in 0..<CFArrayGetCount(cf) {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard stringProp(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  boolProp(src, kTISPropertyInputSourceIsEnabled) else { continue }
            let isApple = (stringProp(src, kTISPropertyInputSourceID) ?? "").hasPrefix("com.apple.")
            let name = isApple ? (stringProp(src, kTISPropertyLocalizedName) ?? "?") : "своя"
            let lang = languages(of: src).first ?? "—"
            let ascii = boolProp(src, kTISPropertyInputSourceIsASCIICapable) ? "+ascii" : ""
            out.append("\(name)[\(lang)\(ascii)]")
        }
        return out
    }

    private static func languages(of src: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray
        return arr.compactMap { $0 as? String }
    }

    private static func stringProp(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(src, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }
}
