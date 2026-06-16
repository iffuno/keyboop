import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Без иконки в Dock — живём в статус-баре рядом с часами.
app.setActivationPolicy(.accessory)
app.run()
