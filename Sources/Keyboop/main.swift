import AppKit

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
