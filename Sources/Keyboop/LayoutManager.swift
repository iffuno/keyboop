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

    /// Полный TIS ID последнего источника, который Keyboop точно выбрал или принял как внешний
    /// выбор. Это отдельная память: Bool не различает Norwegian и ABC и потому не годится для
    /// цикла из трёх и более раскладок.
    private var opinionExactID: String?
    private var opinionExactAt: TimeInterval = 0
    private var selectedNotificationGeneration: UInt64 = 0

    private func setExactOpinion(_ id: String?) {
        opinionExactID = id
        opinionExactAt = id == nil ? 0 : ProcessInfo.processInfo.systemUptime
    }

    /// Вызывается на каждую selected-source нотификацию, включая подавленные grace-окном. Само
    /// уведомление не доказывает источник, но позволяет verifier-у не спорить с более поздним
    /// ручным выбором человека.
    func noteSelectedSourceNotification() {
        selectedNotificationGeneration &+= 1
    }

    /// Текущая раскладка — кириллическая? (сырое чтение TIS; может отставать, см. opinionCyr)
    func currentIsCyrillic() -> Bool { Self.systemIsCyrillic() }

    /// То же без экземпляра — для индикатора на лампочке Caps Lock (CapsLED живёт статикой).
    ///
    /// ⚠️ СНАЧАЛА HIToolbox, И ТОЛЬКО ПОТОМ СЫРОЙ TIS (ревью 17.08). Первая версия читала голый
    /// `TISCopyCurrentKeyboardInputSource`, а про него в этом же файле записан замер 25.07: в
    /// фоновом агенте оно НЕ следует за внешними переключениями. Лампочка на этом чтении не
    /// догоняла ⌃Space/🌐 и врала — при том что весь смысл фичи это правдивая лампочка. Настройки
    /// HIToolbox отстают на ~11 мс, но ОТСТАЮТ, а не замирают.
    static func systemIsCyrillic() -> Bool {
        if let code = languageFromSystemPrefs() { return code.lowercased().hasPrefix("ru") }
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return languages(of: src).first?.hasPrefix("ru") ?? false
    }

    /// ПИСЬМЕННОСТЬ ТЕКУЩЕЙ РАСКЛАДКИ (задачи 105/106).
    ///
    /// ⚠️ ДО 0.4 МИР БЫЛ ДВОИЧНЫМ: всё, что не кириллица, считалось латиницей. У человека с
    /// армянской раскладкой (отзыв @Tigran1963) это значит, что мы принимали армянский за латиницу
    /// и рассуждали о нём словарями, которые про него ничего не знают. Замер по отзывам: из 37 форм
    /// с полем раскладок у 34 ровно две, у двух три — то есть третья письменность редка, но это не
    /// повод считать её вторым английским.
    ///
    /// `.other` значит «мы про эту письменность ничего не знаем». Автоматика в этом состоянии
    /// молчит: любое наше решение там было бы гаданием, а класс жалоб «программа ломает систему»
    /// дороже любой несделанной конверсии.
    enum Script { case cyrillic, latin, other }

    /// Код языка → письменность. Набор раскладок у человека меняется раз в жизни, а звать эту
    /// функцию приходится на каждой границе слова, поэтому редкие коды считаем один раз.
    private static var scriptByCode: [String: Script] = [:]

    /// ⚠️ СПРАШИВАЕМ HIToolbox, А НЕ TIS. `TISCopyCurrentKeyboardInputSource` в фоновом агенте не
    /// следует за внешними переключениями (замер 25.07: система щёлкала RU→EN→RU→EN, чтение всё
    /// время отвечало «RU»), а нам нужно знать реальность именно тогда, когда человек ушёл в третью
    /// раскладку сам. Сырое чтение остаётся запасным вариантом на случай, если настройки молчат.
    ///
    /// Неизвестное трактуем как латиницу, то есть как вело себя приложение до 0.4. Замолчать по
    /// ошибке хуже, чем не заметить экзотическую раскладку: первое ломает главную функцию у всех,
    /// второе оставляет как было у единиц.
    func currentScript() -> Script {
        if let code = Self.languageFromSystemPrefs() {
            if code == "RU" { return .cyrillic }
            if code == "EN" { return .latin }
            if let cached = Self.scriptByCode[code] { return cached }
            let want = code.lowercased()
            let s = enabledKeyboardSources()
                .first { (Self.languages(of: $0).first ?? "").hasPrefix(want) }
                .map { Self.script(of: $0) } ?? .latin
            Self.scriptByCode[code] = s
            return s
        }
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return .latin }
        return Self.script(of: src)
    }
    private static func script(of src: TISInputSource) -> Script {
        if languages(of: src).first?.hasPrefix("ru") ?? false { return .cyrillic }
        // Латиницей считаем то же, что и `selectLayout`: ASCII-способность, а не язык «en».
        // Кириллические, армянские, греческие, ивритские и грузинские раскладки её не имеют.
        return isUsableLatinLayout(src) ? .latin : .other
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
    func noteExternalLayoutChange() {
        opinionCyr = nil
        setExactOpinion(nil)
        CapsLED.refreshSoon()   // язык сменили мимо нас — лампочка-индикатор должна догнать
    }

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
        if let live = Self.liveSelectedSource(),
           let id = Self.stringProp(live, kTISPropertyInputSourceID) {
            setExactOpinion(id)
        }
        let real = currentIsCyrillic()
        // Момент выбран вызывающим — чтение достоверно. Но окно подавления НЕ взводим
        // (authoritative: false): сверка идёт на каждой границе слова, и взведённое окно
        // съедало бы внешние переключения (🌐/⌃Space) — лампочка замирала. См. CapsLED.set.
        CapsLED.set(cyrillic: real, authoritative: false)
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
    /// Последняя раскладка, на которой человек РЕАЛЬНО был с каждой стороны (ID источника).
    ///
    /// ⚠️ Заведено по задачам 105/106: раньше «латиница» означала «первая попавшаяся ASCII-способная
    /// из включённых», и у человека с несколькими латинскими раскладками мы возвращали его не туда,
    /// куда он уходил. Теперь помним сторону поимённо и возвращаем именно её.
    /// ⚠️ ЧИТАЕТСЯ И ПИШЕТСЯ В НАСТРОЙКИ, а не живёт в процессе (отзыв #143). Раскладку человек
    /// выбирает один раз и надолго, а мы забывали её при каждом перезапуске.
    private var lastUsedID: [Bool: String] = {
        var m: [Bool: String] = [:]
        let s = AppSettings.shared
        if !s.lastLayoutCyr.isEmpty { m[true] = s.lastLayoutCyr }
        if !s.lastLayoutLat.isEmpty { m[false] = s.lastLayoutLat }
        return m
    }()

    /// Запомнить сторону и в настройках. Пишем только на смену: внешние переключения приходят
    /// пачками, а `UserDefaults` на каждое из них дёргать незачем.
    private func remember(_ id: String, cyrillic: Bool) {
        guard lastUsedID[cyrillic] != id else { return }
        lastUsedID[cyrillic] = id
        if cyrillic { AppSettings.shared.lastLayoutCyr = id } else { AppSettings.shared.lastLayoutLat = id }
        kbLog("layout: запомнил \(cyrillic ? "кириллическую" : "латинскую") раскладку \(id)")
    }

    /// Сопоставить запись HIToolbox живому TIS-объекту. Когда настройки дают полный ID, он всегда
    /// главнее локализованного имени; имя остаётся фолбэком для обычных Keyboard Layout entries.
    private static func matchLiveSource(forEntry entry: [String: Any],
                                        pool: [TISInputSource]) -> TISInputSource? {
        if let sourceID = (entry["Input Source ID"] as? String)
            ?? (entry["InputSourceID"] as? String),
           !sourceID.isEmpty,
           let source = pool.first(where: {
               stringProp($0, kTISPropertyInputSourceID) == sourceID
           }) {
            return source
        }

        let modeID = entry["Input Mode"] as? String
        let bundleID = entry["Bundle ID"] as? String
        if let modeID, !modeID.isEmpty {
            let modeMatches = pool.filter {
                stringProp($0, kTISPropertyInputModeID) == modeID
            }
            if let bundleID, !bundleID.isEmpty,
               let source = modeMatches.first(where: {
                   stringProp($0, kTISPropertyBundleID) == bundleID
               }) {
                return source
            }
            if let source = modeMatches.first { return source }
        }
        if let bundleID, !bundleID.isEmpty,
           let source = pool.first(where: {
               stringProp($0, kTISPropertyBundleID) == bundleID
           }) {
            return source
        }

        let name = (entry["KeyboardLayout Name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let key = nameKey(name)
        for source in pool {
            if let id = stringProp(source, kTISPropertyInputSourceID),
               nameKey(String(id.split(separator: ".").last ?? "")) == key {
                return source
            }
            if let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
                let localized = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
                if nameKey(localized) == key { return source }
            }
        }
        return nil
    }

    /// Живой ВЫБРАННЫЙ источник: запись из HIToolbox (не страдает стейл-кэшем TIS в фоновом
    /// агенте), сам объект — из списка включённых источников.
    private static func liveSelectedSource() -> TISInputSource? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        guard let raw = CFPreferencesCopyAppValue("AppleSelectedInputSources" as CFString,
                                                 "com.apple.HIToolbox" as CFString) as? [[String: Any]]
        else { return nil }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        else { return nil }
        for entry in raw {
            if let source = matchLiveSource(forEntry: entry, pool: list) { return source }
        }
        return nil
    }

    /// Запомнить, на чём человек оказался сам (внешняя смена раскладки).
    ///
    /// ⚠️ НЕ СЫРЫМ TIS-ЧТЕНИЕМ (ревью 17.08). В момент уведомления оно возвращает раскладку,
    /// которую человек только что ПОКИНУЛ (kawa PR#21), и «выбором» записывалась бы прежняя —
    /// теперь ещё и на диск, то есть ошибка #143 не чинилась бы, а консервировалась. Для сценария
    /// «Русская → Русская ПК» это единственный честный путь: обе стороны кириллические, и никакой
    /// сверкой письменности стейл тут не ловится.
    func noteCurrentAsUserChoice() {
        guard let src = Self.liveSelectedSource() ?? TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = Self.stringProp(src, kTISPropertyInputSourceID) else { return }
        setExactOpinion(id)
        switch Self.script(of: src) {
        case .cyrillic: remember(id, cyrillic: true)
        case .latin:    remember(id, cyrillic: false)
        case .other:    break   // третью письменность не запоминаем: мы её и не выбираем
        }
    }

    @discardableResult
    func selectLayout(cyrillic: Bool) -> Bool {
        let sources = enabledKeyboardSources()
        let src: TISInputSource?
        // Сначала — та самая раскладка, на которой человек был с этой стороны в прошлый раз.
        let remembered = lastUsedID[cyrillic].flatMap { id in
            sources.first { Self.stringProp($0, kTISPropertyInputSourceID) == id }
        }
        if let remembered, Self.script(of: remembered) == (cyrillic ? .cyrillic : .latin) {
            src = remembered
        } else if cyrillic {
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
        // ⚠️ НЕ ЗОВЁМ TIS, ЕСЛИ МЫ И ТАК НА НУЖНОМ ИСТОЧНИКЕ (задачи 105/106). Каждый вызов
        // `TISSelectInputSource` переписывает системный порядок недавно использованных источников,
        // а от него зависят системные же «предыдущий источник» и «следующий в меню». У человека с
        // тремя раскладками это и выглядит как «после установки keyboop клавиатура сама уходит в
        // третью»: мы толкали очередь сотни раз в день, в том числе там, где переключать было
        // нечего. Пропуск бесполезного вызова ничего не меняет для нас и убирает целый класс
        // побочных эффектов у системы.
        // ⛔️ ЗДЕСЬ БЫЛ ПРОПУСК ВЫЗОВА «мы и так на нужной стороне» — ОТКАЧЕНО 12.08.2026 В ДЕНЬ
        // ВЫПУСКА ПРАВКИ, по живой жалобе автора: «переключаю, а индикатор показывает другое».
        //
        // Замысел был правильный: каждый `TISSelectInputSource` переписывает системный порядок
        // недавних источников, и лишние вызовы могли быть причиной жалобы про три раскладки (105).
        // Сторону я спрашивал у HIToolbox, потому что сырое чтение TIS в фоновом агенте врёт.
        //
        // Чего я не учёл: настройкам HIToolbox нужно около 11 мс, чтобы догнать переключение (это
        // измерено и записано прямо ниже, в `verifySelect`). А 🌐 нажимают очередью, по три раза в
        // секунду — и тогда чтение отдаёт ПРЕЖНЮЮ сторону. Мы решали «мы и так там», пропускали
        // настоящее переключение, но память и индикатор двигали. Раскладка оставалась одна, значок
        // показывал другую, и следующее нажатие считало направление уже от испорченной памяти.
        // Ровно то, что человек называет «инверсия».
        //
        // Мораль на будущее: оптимизация, которая ЧИТАЕТ состояние, чтобы не делать работу, стоит
        // ровно столько, сколько стоит свежесть этого чтения. Здесь свежести нет, а цена ошибки —
        // главная функция приложения. Экономия вызова того не стоила.
        let ok = TISSelectInputSource(src) == noErr
        if !ok {
            kbLog("layout: TISSelectInputSource отказал (\(Self.stringProp(src, kTISPropertyInputSourceID) ?? "?"))")
        }
        if ok {
            opinionCyr = cyrillic   // память против стейл-чтения (см. opinionCyr)
            setExactOpinion(Self.stringProp(src, kTISPropertyInputSourceID))
            CapsLED.set(cyrillic: cyrillic)   // лампочка-индикатор языка (если включена)
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
                self.setExactOpinion(Self.liveSelectedSource().flatMap {
                    Self.stringProp($0, kTISPropertyInputSourceID)
                })
                KeyboardLayoutCache.refreshOnMain()
                kbLog("layout: поправка отклонена системой, принимаю реальность (\(code))")
                return
            }
        }
    }

    // MARK: - Цикл всех включённых раскладок (задача 226)

    private var cycleMissCount = 0

    /// Выбрать следующий enabled/select-capable keyboard input source в системном порядке.
    /// Кандидаты перестраиваются на каждый шаг, а быстрые нажатия идут от точной памяти ID, не от
    /// запаздывающего TISCopyCurrentKeyboardInputSource.
    @discardableResult
    func cycleLayout() -> Bool {
        let sources = enabledKeyboardSources()
        let ids = cycleCandidateIDs(sources: sources)
        guard !ids.isEmpty else {
            kbLog("layout: цикл нечему — среди включённых нет select-capable раскладок")
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        let remembered = opinionExactID.flatMap { ids.contains($0) ? $0 : nil }
        let liveID = Self.liveSelectedSource().flatMap {
            Self.stringProp($0, kTISPropertyInputSourceID)
        }.flatMap { ids.contains($0) ? $0 : nil }

        // В коротком окне быстрых повторов TIS/HIToolbox ещё могут показывать прошлый источник —
        // после settling-окна живое значение главнее и лечит потерянное системное уведомление.
        let rememberedIsFresh = remembered != nil && now - opinionExactAt < 0.15
        let anchor = LayoutCycle.anchorID(remembered: remembered,
                                          live: liveID,
                                          rememberedIsFresh: rememberedIsFresh,
                                          in: ids)
        if !rememberedIsFresh, anchor == liveID, let liveID {
            setExactOpinion(liveID)
        }

        guard let nextID = LayoutCycle.nextID(afterCurrent: anchor, in: ids),
              let source = sources.first(where: {
                  Self.stringProp($0, kTISPropertyInputSourceID) == nextID
              })
        else { return false }

        guard TISSelectInputSource(source) == noErr else {
            kbLog("layout: TISSelectInputSource (цикл) отказал")
            return false
        }

        setExactOpinion(nextID)
        let script = Self.script(of: source)
        let cyrillic = script == .cyrillic
        opinionCyr = cyrillic
        switch script {
        case .cyrillic: remember(nextID, cyrillic: true)
        case .latin:    remember(nextID, cyrillic: false)
        case .other:    break
        }
        CapsLED.set(cyrillic: cyrillic)
        lastSelectAt = ProcessInfo.processInfo.systemUptime
        if Thread.isMainThread {
            KeyboardLayoutCache.refresh(fromSelected: source)
        } else {
            DispatchQueue.main.async { KeyboardLayoutCache.refresh(fromSelected: source) }
        }
        verifyCycleSelect(requestedID: nextID,
                          previousID: anchor,
                          notificationGeneration: selectedNotificationGeneration,
                          source: source)
        return true
    }

    /// Сначала берём порядок AppleEnabledInputSources. Источники, которых в preferences нет, но
    /// TIS считает их включёнными, дописываем по полному ID — так фолбэк детерминирован.
    private func cycleCandidateIDs(sources: [TISInputSource]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ source: TISInputSource) {
            guard let id = Self.stringProp(source, kTISPropertyInputSourceID),
                  seen.insert(id).inserted else { return }
            ordered.append(id)
        }

        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        if let entries = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString,
                                                   "com.apple.HIToolbox" as CFString)
            as? [[String: Any]] {
            for entry in entries {
                if let source = Self.matchLiveSource(forEntry: entry, pool: sources) {
                    append(source)
                }
            }
        }

        let remaining = sources.compactMap {
            Self.stringProp($0, kTISPropertyInputSourceID)
        }.filter { !seen.contains($0) }.sorted()
        for id in remaining where seen.insert(id).inserted { ordered.append(id) }
        return ordered
    }

    /// Через тот же 60-мс settling interval убеждаемся, что система выбрала именно requested ID.
    /// Если нет — повторяем TISSelectInputSource ровно один раз, без бесконечного self-heal.
    private func acceptCycleReality(_ source: TISInputSource) {
        guard let id = Self.stringProp(source, kTISPropertyInputSourceID) else { return }
        setExactOpinion(id)
        let script = Self.script(of: source)
        let cyrillic = script == .cyrillic
        opinionCyr = cyrillic
        switch script {
        case .cyrillic: remember(id, cyrillic: true)
        case .latin:    remember(id, cyrillic: false)
        case .other:    break
        }
        CapsLED.set(cyrillic: cyrillic, authoritative: false)
        KeyboardLayoutCache.refresh(fromSelected: source)
    }

    private func verifyCycleSelect(requestedID: String,
                                   previousID: String?,
                                   notificationGeneration: UInt64,
                                   source: TISInputSource) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self, self.opinionExactID == requestedID else { return }
            guard let live = Self.liveSelectedSource(),
                  let liveID = Self.stringProp(live, kTISPropertyInputSourceID),
                  liveID != requestedID else { return }

            let notificationSeen = self.selectedNotificationGeneration != notificationGeneration
            // Третий ID — точно не простой лаг предыдущего состояния. Это внешний выбор либо
            // изменившийся список: принимаем его и не возвращаем пользователя назад.
            if liveID != previousID {
                self.acceptCycleReality(live)
                return
            }
            // Нотификация могла быть нашей и прийти раньше обновления preferences, либо внешней.
            // Дадим HIToolbox ещё одно окно, но не будем повторно select-ить поверх пользователя.
            if notificationSeen {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                    guard let self, self.opinionExactID == requestedID,
                          let settled = Self.liveSelectedSource(),
                          let settledID = Self.stringProp(settled, kTISPropertyInputSourceID),
                          settledID != requestedID else { return }
                    self.acceptCycleReality(settled)
                }
                return
            }

            self.cycleMissCount += 1
            if self.cycleMissCount == 1 || self.cycleMissCount % 10 == 0 {
                kbLog("layout: циклическое переключение не применилось, поправка №\(self.cycleMissCount)")
            }
            guard TISSelectInputSource(source) == noErr else {
                self.acceptCycleReality(live)
                kbLog("layout: поправка цикла отклонена системой, принимаю реальность")
                return
            }
            self.lastSelectAt = ProcessInfo.processInfo.systemUptime
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
