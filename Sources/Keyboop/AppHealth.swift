import AppKit
import Foundation

/// Состояния, в которых Keyboop не может делать свою работу, — в одном месте.
///
/// Зачем (разбор 34 репортов, 28.07): кластер «не работает» оказался НЕ одним багом, а минимум
/// четырьмя разными состояниями, и ни одно из них человек не видел:
///   • Secure Input держит другое приложение — macOS системно прячет клавиатуру от всех тапов;
///   • Accessibility не выдан — движок вообще не стартовал, а в логе три строки за семь минут;
///   • микрофон отдаёт побитовые нули при выданном доступе;
///   • тап отключён системой по таймауту.
/// Человек в каждом из них видит одно и то же: приложение молчит. Отсюда репорты вида «не работает»
/// без единой зацепки — и наша полная беспомощность при разборе.
///
/// Поэтому: одно хранилище, из которого читают и диагностика багрепорта, и строка меню. Правило —
/// если Keyboop не может работать, это должно быть ВИДНО, а не выводиться из чтения логов.
enum AppHealth {
    /// Движок реально работает ПРЯМО СЕЙЧАС. Не «когда-то стартовал»: система может отключить тап
    /// по таймауту, и тогда молчание вернётся, а мы бы рапортовали «всё хорошо» (найдено ревью 28.07).
    /// Замыкание ставит EventTap при старте; nil до первого старта.
    static var isEngineLive: (() -> Bool)?
    static var engineRunning: Bool { isEngineLive?() ?? false }

    /// Мы САМИ сняли перехват, потому что система вырубала его штормом (см. предохранитель в
    /// EventTap). Это не поломка, а сознательная сдача: активный тап держит весь ввод системы,
    /// и лучше временно не работать, чем морозить человеку клавиатуру и мышь.
    static var tapSuspended = false
    /// Дёргается один раз в момент сдачи — чтобы строка меню обновилась немедленно, не дожидаясь тика.
    static var onTapSuspended: (() -> Void)?

    /// Держатель Secure Input, если сейчас включён и мы успели его найти. nil — не включён.
    static var secureInputHolder: String?
    /// Secure Input включён прямо сейчас (флаг ставим на переходах, отдельно от имени держателя:
    /// имя ищется асинхронно через ioreg и может не успеть).
    static var secureInputOn = false

    /// ⚠️ ТОЛЬКО ДЛЯ DEV-ХУКА `KEYBOOP_FAKEHOLD`, и заведён отдельным полем не для красоты.
    /// Сначала хук ставил боевой `secureInputOn`, и это было не «понарошку»: тот же флаг читает
    /// `EventTap` и снимает со взвода жесты по одиночному модификатору. То есть инструмент для
    /// разглядывания надписи молча ломал хоткеи на всю сессию (ревью 07.08). Показывающие пути
    /// (`iconState`, `problem`) смотрят на оба флага, перехват — только на настоящий.
    static var fakeSecureInput = false
    private static var secureInputForDisplay: Bool { secureInputOn || fakeSecureInput }

    /// Когда приложение запустилось — чтобы отличать «только что стартовал» от «работает неделями».
    static let launchedAt = ProcessInfo.processInfo.systemUptime
    static var uptimeDescription: String {
        let s = Int(ProcessInfo.processInfo.systemUptime - launchedAt)
        if s < 90 { return "\(s)с" }
        if s < 5400 { return "\(s / 60)мин" }
        return "\(s / 3600)ч \((s % 3600) / 60)мин"
    }

    /// Короткая сводка «что мешает работать» — для строки меню и шапки диагностики.
    /// nil — всё в порядке.
    /// ⚠️ ПОРЯДОК ПРОВЕРОК ВАЖЕН, И ОН НЕ ИНТУИТИВНЫЙ (найдено ревью 28.07).
    /// Спрашивать `AXIsProcessTrusted()` первым НЕЛЬЗЯ: он залипает на false в живом процессе после
    /// выдачи доступа (баг macOS 13+, ради которого гейт на нём убран в AppDelegate). У работающего
    /// приложения меню писало бы «нет доступа, движок не запущен», человек шёл бы передёргивать
    /// галку в системных настройках — и это РЕАЛЬНО убивает живой тап. То есть диагностика
    /// инструктировала бы сломать рабочую программу.
    /// Поэтому живой детектор здесь — состояние тапа, а TCC спрашиваем только чтобы отличить
    /// «доступа не дали» от «дали, но старт не удался».
    static var blockingProblem: String? { problem(rowWidth: nil) }

    /// `rowWidth` — ширина в пунктах, в которую обязана уложиться ВСЯ строка. nil = не ограничивать.
    ///
    /// Ограничение нужно ровно одному потребителю, строке меню: имя держателя приходит от чужой
    /// программы и бывает какой угодно длины, а меню растягивается по самому широкому пункту.
    /// «Битрикс24 Рабочий стол» в этой строке раздувал всё меню вдвое. Подсказка значка и
    /// диагностика отзыва берут имя ЦЕЛИКОМ: там место есть, а в отчёте обрезанное имя это потеря
    /// улики.
    static func problem(rowWidth: CGFloat?) -> String? {
        // Сдача проверяется ПЕРВОЙ: это наше собственное решение, а не отказ системы, и человеку
        // надо сказать именно это, иначе он пойдёт чинить доступы, которые в полном порядке.
        if tapSuspended { return L10n.t("health.tapSuspended") }
        if !engineRunning {
            return Permissions.isTrusted() ? L10n.t("health.engineDown") : L10n.t("health.noAccessibility")
        }
        if secureInputForDisplay {
            guard let h = secureInputHolder else { return L10n.t("health.secureInput") }
            let fmt = L10n.t("health.secureInputHolder")
            guard let budget = rowWidth else { return String(format: fmt, h) }
            // Сколько остаётся имени, считаем от САМОЙ строки, а не от числа в коде: у английского
            // текста зачин другой длины, и зашитая константа врала бы ровно наполовину случаев.
            let room = budget - width(String(format: fmt, ""))
            return String(format: fmt, fit(h, into: room))
        }
        return nil
    }

    private static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }

    /// Уложить имя в отведённую ширину, обрезая ПО ГРАНИЦЕ СЛОВА.
    /// «Системные…» читается как сокращение, «Системные н…» — как сбой отрисовки.
    /// Если в лимит не влезает даже первое слово, режем по буквам: это лучше пустоты.
    private static func fit(_ name: String, into limit: CGFloat) -> String {
        guard width(name) > limit else { return name }
        var acc = ""
        for word in name.split(separator: " ") {
            let next = acc.isEmpty ? String(word) : acc + " " + word
            if width(next + "…") > limit { break }
            acc = next
        }
        if !acc.isEmpty { return acc + "…" }
        var s = ""
        for ch in name {
            if width(s + String(ch) + "…") > limit { break }
            s.append(ch)
        }
        return s + "…"
    }

    // MARK: - Что значок говорит о себе (P3.4)

    /// Состояние значка в строке меню. Ровно одно за раз.
    enum IconState: Equatable { case ok, tapSuspended, engineDown, secureInput, paused, autoOff }

    /// ⚠️ ЗДЕСЬ ТОЛЬКО ЧТЕНИЯ ПОЛЕЙ, НИКАКОГО TCC. Это читает тик значка дважды в секунду, а
    /// `Permissions.isTrusted()` — это IPC в TCC. Опрос TCC по таймеру в этом проекте уже однажды
    /// подвесил ВЕСЬ ввод в системе, включая мышь: разбор в `EventTap`, вывод там сформулирован как
    /// «пробник обязан быть бесплатным». Дорогое различение «доступа не дали» против «дали, но старт
    /// не удался» живёт в `iconTip`, а он зовётся только в момент СМЕНЫ состояния.
    ///
    /// Порядок совпадает с `blockingProblem`, и это не случайность: значок и строка меню обязаны об
    /// одном симптоме говорить одно и то же. Сначала то, с чем надо что-то делать, потом то, что
    /// человек выбрал сам.
    static var iconState: IconState {
        if tapSuspended { return .tapSuspended }
        if !engineRunning { return .engineDown }
        if secureInputForDisplay { return .secureInput }
        if Pause.active { return .paused }
        if !AppSettings.shared.autoEnabled { return .autoOff }
        return .ok
    }

    /// Гасить ли значок. Гасим, только когда молчит ВСЁ.
    ///
    /// ⚠️ При выключенном авто НЕ гасим, хотя соблазн есть. Диктовка, хоткеи и сниппеты в этом
    /// состоянии живы, а у того, кто держит авто выключенным намеренно, вечно приглушённый значок за
    /// неделю превратится в фон и перестанет что-либо значить. Тогда он не сработает и в тот раз,
    /// когда сломается по-настоящему, а это единственное, ради чего он заводится.
    static func iconDimmed(_ s: IconState) -> Bool {
        switch s {
        case .ok, .autoOff:                                  return false
        case .tapSuspended, .engineDown, .secureInput, .paused: return true
        }
    }

    /// Подсказка под состояние. Зовётся ТОЛЬКО при смене состояния, поэтому тут уже можно позволить
    /// себе и TCC внутри `blockingProblem`, и разбор даты.
    static func iconTip(_ s: IconState) -> String {
        switch s {
        case .ok:      return L10n.t("health.ok")
        case .autoOff: return L10n.t("health.autoOff")
        case .paused:
            guard let until = Pause.until else { return L10n.t("health.ok") }
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return String(format: L10n.t("menu.pausedUntil"), f.string(from: until))
        case .tapSuspended, .engineDown, .secureInput:
            // Берём ТУ ЖЕ строку, что показывает меню: один симптом — одно объяснение.
            // Регистр не трогаем: с 07.08 строки health.* написаны с заглавной прямо в каталоге,
            // потому что каждая стоит самостоятельной строкой меню, а не фрагментом общего ряда.
            return blockingProblem ?? L10n.t("health.ok")
        }
    }
}
