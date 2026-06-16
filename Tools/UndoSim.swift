import Foundation

// Машинные тесты «обучения на отмене» (UndoLearner). Прогоняют РЕАЛЬНЫЙ конечный автомат отката
// над виртуальными последовательностями клавиш — без Engine/AppKit. Запуск: bash run-undosim.sh.
//
// Главная проверка (приоритет Ивана): СЛУЧАЙНО не выучить нормальное слово. Поэтому отдельные кейсы
// на «удалил и набрал другое», истёкшее окно, затухание счётчика, тумблер OFF.

@main
struct UndoSimMain {
static func main() {

// Чистое окружение: до первого обращения к синглтонам сносим персист в UserDefaults.
UserDefaults.standard.removeObject(forKey: "undoStrikeStats")
UserDefaults.standard.removeObject(forKey: "learnedWords")
UserDefaults.standard.set(true, forKey: "learnOnUndoEnabled")

let learner = UndoLearner.shared
let exc = ExceptionStore.shared

var pass = 0, fail = 0
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✓  \(name)") }
    else    { fail += 1; print("  ✗  \(name)") }
}
func reset() {
    learner._resetForTests()
    exc.clearLearned()
    learner.nowProvider = { Date() }
}

// U1 — ручной ре-флип: авто W→C, юзер хоткеем флипнул C→W.
func u1Undo(_ o: String, _ c: String) -> String? {
    learner.noteConversion(original: o, converted: c)
    return learner.noteManualConvert(from: c, to: o)
}
// U2 — стереть вывод C целиком и перенабрать `retype` посимвольно. Возвращает (был ли откат подтверждён).
func u2(_ o: String, _ c: String, retype: String) -> Bool {
    learner.noteConversion(original: o, converted: c)
    var cur = c
    while !cur.isEmpty { cur.removeLast(); learner.observe(current: cur) }   // стираем C по букве
    cur = ""
    var undone = false
    for ch in retype { cur.append(ch); if learner.observe(current: cur) { undone = true } }
    return undone
}

print("── UndoLearner: обучение на отмене ──")

// 1. U1 ×3 одного слова → выучено ровно на 3-м.
reset()
check(u1Undo("links", "дштлы") == "links", "U1 откат №1 распознан")
check(!exc.learned.contains("links"), "после 1 отката НЕ выучено")
_ = u1Undo("links", "дштлы")
check(!exc.learned.contains("links"), "после 2 откатов НЕ выучено")
_ = u1Undo("links", "дштлы")
check(exc.learned.contains("links"), "после 3 откатов ВЫУЧЕНО")

// 2. U2 ×3 (стереть+перенабрать точный оригинал) → выучено.
reset()
check(u2("sania", "ыфтшф", retype: "sania"), "U2 точный перенабор = откат")
_ = u2("sania", "ыфтшф", retype: "sania")
let learnedOnThird = u2("sania", "ыфтшф", retype: "sania")
check(learnedOnThird && exc.learned.contains("sania"), "U2 ×3 → выучено")

// 3. ЛОЖНОЕ обучение НЕ происходит: стёр наш вывод и набрал ДРУГОЕ слово.
reset()
check(!u2("links", "дштлы", retype: "hello"), "удалил+набрал другое ≠ откат")
check(learner._strikeCount("links") == 0, "страйк за «links» не начислен")
check(!exc.learned.contains("links") && !exc.learned.contains("hello"), "ничего не выучено")

// 4. Принял конверсию (продолжил печатать после неё) ≠ откат.
reset()
learner.noteConversion(original: "links", converted: "дштлы")
learner.observe(current: "дштлы!")     // дописал символ — принял
check(learner._strikeCount("links") == 0, "продолжил печатать ≠ откат")

// 5. Истёкшее окно: откат позже undoWindow не считается.
reset()
let base = Date(timeIntervalSince1970: 1_000_000)
learner.nowProvider = { base }
learner.noteConversion(original: "links", converted: "дштлы")
learner.nowProvider = { base.addingTimeInterval(10) }   // +10с > окна 4с
check(learner.noteManualConvert(from: "дштлы", to: "links") == nil, "откат вне окна не засчитан")
check(learner._strikeCount("links") == 0, "страйк вне окна не начислен")

// 6. Затухание: 2 страйка, затем +8 дней, ещё 1 → счётчик сбросился (1, не 3) → НЕ выучено.
reset()
let t0 = Date(timeIntervalSince1970: 2_000_000)
learner.nowProvider = { t0 }
_ = u1Undo("foo", "ащщ"); _ = u1Undo("foo", "ащщ")
check(learner._strikeCount("foo") == 2, "накопилось 2 страйка")
learner.nowProvider = { t0.addingTimeInterval(8 * 24 * 3600) }   // +8 дней > 7
_ = u1Undo("foo", "ащщ")
check(learner._strikeCount("foo") == 1 && !exc.learned.contains("foo"), "после затухания счётчик сброшен, не выучено")

// 7. sessionProtected: после отката слово защищено в этом контексте, resetContext снимает.
reset()
_ = u1Undo("links", "дштлы")
check(learner.isSessionProtected("links"), "после отката слово session-protected")
learner.resetContext()
check(!learner.isSessionProtected("links"), "resetContext снял session-защиту")

// 8. shouldSuppress во время перенабора оригинала (анти-«драка»).
reset()
learner.noteConversion(original: "links", converted: "дштлы")
var cur = "дштлы"
while !cur.isEmpty { cur.removeLast(); learner.observe(current: cur) }
learner.observe(current: "l"); learner.observe(current: "li"); learner.observe(current: "lin")
check(learner.shouldSuppress(current: "lin"), "во время перенабора оригинала конверсия глушится")

// 9. Тумблер OFF — фича молчит.
reset()
UserDefaults.standard.set(false, forKey: "learnOnUndoEnabled")
check(u1Undo("links", "дштлы") == nil, "при OFF откат не распознаётся")
check(!u2("links", "дштлы", retype: "links"), "при OFF U2 не работает")
UserDefaults.standard.set(true, forKey: "learnOnUndoEnabled")

print("\n── ИТОГ ──")
print("Пройдено: \(pass)   Провалено: \(fail)")
exit(fail == 0 ? 0 : 1)

}   // static func main
}   // struct UndoSimMain
