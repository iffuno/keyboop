import AppKit

// СТОРОЖ КЛАВИШИ 🌐 — до всего остального (задача 96). Запуск с `--globe-guard <pid>` это не
// приложение: ни перехватчика, ни строки меню, ни разрешений, ни охраны единственного экземпляра.
// Процесс ждёт смерти родителя, возвращает системе клавишу и выходит. Проверка стоит первой строкой
// именно затем, чтобы сторож не тащил за собой ничего из того, что делает Keyboop.
GlobeGuard.runIfRequested()

// Dev-хук: вернуть клавише 🌐 системное действие и выйти (`KEYBOOP_GLOBEFIX=1`). То же, что кнопка
// в настройках, но без окна: кнопку иначе не проверить, а проверять её надо — она чинит клавиатуру
// человеку, у которого приложение уже вело себя не так, как обещало.
if ProcessInfo.processInfo.environment["KEYBOOP_GLOBEFIX"] == "1" {
    GlobeKey.restoreSystemAction()
    Thread.sleep(forTimeInterval: 0.3)   // дать логу дописаться (см. GlobeGuard)
    exit(0)
}

// ggml/Metal: ВЫКЛЮЧАЕМ residency sets ДО первого касания Metal (первый whisper_init).
// Иначе при выходе с загруженной моделью статический деструктор ggml бьёт осознанный ассерт
// GGML_ASSERT([rsets->data count] == 0) → SIGABRT при квите (реальный краш-репорт 20.07;
// llama.cpp #19137 — апстрим закрыл как «not a bug: освободи контекст до exit»). С этим env
// (vendor .../ggml-metal-device.m:823-826) rsets вообще не создаются → ассерт невозможен и
// heartbeat-поток не поднимается. Цена — wiring-оптимизация памяти на простое (macOS 15+),
// которая нам не нужна: мы сами выгружаем модель на простое. Второй слой защиты —
// whisper_free в applicationWillTerminate (AppDelegate).
setenv("GGML_METAL_NO_RESIDENCY", "1", 1)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Без иконки в Dock — живём в статус-баре рядом с часами.
app.setActivationPolicy(.accessory)
app.run()
