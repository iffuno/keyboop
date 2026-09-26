import Foundation

/// Затравка для whisper и срез её эха. Здесь только чистые функции без whisper.cpp, чтобы стенд
/// stands/run-whisperecho.sh (Tools/WhisperEchoSim.swift) проверял ровно тот код, что идёт в
/// приложение. Сборку затравки со словарём диктовки и сам вызов whisper делает WhisperBridge.
enum WhisperPrompt {
    /// Русская фраза-затравка: запятые, «ё», «!», «?», тире. Смысла не несёт, задаёт стиль.
    /// Текст не менять без нового замера: на нём держатся «ё» и запятые (см. WhisperBridge).
    static let ru = "Привет! Как дела? Сегодня хорошая погода, но, кажется, скоро пойдёт дождь. Ну что ж, подождём — время ещё есть."
    /// То же по-английски.
    static let en = "Hi! How are you? The weather is nice today, but it looks like it might rain. Well, let's wait — there's still time."

    /// С какой уверенности определения языка «Авто» берёт затравку только на этом языке.
    /// Ниже неё затравка остаётся двуязычной, как было до 25.09.2026. Замер 25.09.2026 на 550
    /// прогонах настоящей речи: ниже 0.5 определились 8, и в 4 из них детектор ошибся языком
    /// (en 0.22 на русском «сайт», fr 0.27 на «ваа»); из 20 клипов шума, щелчков и вздохов ниже 0.5
    /// ушли 14. То есть ниже порога детектор гадает, и лучше не менять того, что работало.
    /// Результаты одинаковы при любом пороге от 0.4 до 0.6.
    static let confidentLanguage: Float = 0.5

    /// Под какой язык собирать затравку.
    /// setting: выбор в настройках ("auto", "ru", "en"). detected и p: что whisper определил до
    /// расшифровки и насколько уверенно (nil, если не определял или не смог).
    static func promptLanguage(setting: String, detected: String?, p: Float) -> String {
        guard setting == "auto" else { return setting }            // явный выбор человека не трогаем
        guard let detected, p >= confidentLanguage else { return "auto" }
        return detected
    }

    /// Какие блоки затравки брать под язык: (начало, хвост). Словарь диктовки встаёт между ними.
    /// nil значит «без затравки».
    ///   "ru", "en": один блок на этом языке;
    ///   "auto": двуязычная, английская фраза ПОСЛЕДНЕЙ (как с 09.09.2026). Это «Авто», когда язык
    ///           определён неуверенно или не определён вовсе;
    ///   любой другой язык, определённый уверенно: без затравки. С русско-английской затравкой
    ///   испанская и французская речь выходила русским переводом (замер 25.09.2026), а без неё
    ///   выходит на своём языке.
    static func blocks(for language: String) -> (head: String, tail: String)? {
        switch language {
        case "ru":   return (ru, "")
        case "en":   return (en, "")
        case "auto": return (ru, " " + en)
        default:     return nil
        }
    }

    /// Куски, из которых собрана затравка: блоки фраз целиком (ru, en) и всё остальное одним
    /// куском, то есть фраза словаря диктовки. Длинные идут первыми.
    static func echoPieces(_ prompt: String) -> [String] {
        var pieces: [String] = []
        var rest = prompt
        for block in [ru, en] where rest.contains(block) {
            pieces.append(block)
            rest = rest.replacingOccurrences(of: block, with: " ")
        }
        let remainder = rest.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { pieces.append(remainder) }
        return pieces.sorted { $0.count > $1.count }
    }

    /// Срезает эхо затравки с НАЧАЛА расшифровки. Эхом считаем только дословный повтор ЦЕЛОГО
    /// куска затравки (весь блок фраз или вся фраза словаря), сколько бы таких кусков ни шло
    /// подряд. Отдельные предложения затравки не режем: «Привет!», «How are you?» и даже «Сегодня
    /// хорошая погода, но, кажется, скоро пойдёт дождь.» человек может сказать сам, а целый блок из
    /// четырёх предложений или «Часто встречаются слова: ...» не скажет никто.
    /// Внутри текста не трогаем ничего. Возвращает текст и сколько кусков срезано.
    static func stripEcho(_ text: String, prompt: String) -> (text: String, cut: Int) {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return (result, 0) }
        let pieces = echoPieces(prompt)
        var cut = 0
        while let piece = pieces.first(where: { result.hasPrefix($0) }) {
            result = String(result.dropFirst(piece.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            cut += 1
        }
        return (result, cut)
    }
}
