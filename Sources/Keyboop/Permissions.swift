import Foundation
import ApplicationServices
import AppKit
import IOKit.hid

enum Permissions {
    // MARK: Accessibility (нужен для постинга синтетических событий — замены текста)

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: App Translocation / расположение бандла
    //
    // App Translocation (Gatekeeper Path Randomisation): если .app запущен из смонтированного DMG
    // или из ~/Downloads (с quarantine-xattr, не перенесён через Finder), macOS копирует его в
    // эфемерный read-only путь /private/var/folders/.../AppTranslocation/<UUID>/d/. Грант
    // Accessibility, выданный такому экземпляру, НЕ переживает перезапуск (путь исчезает при выходе),
    // → AXIsProcessTrusted=false, tapCreate=nil. Это одна из причин «заработало только после reboot»
    // (reboot = перезапуск из уже-перенесённого /Applications/Keyboop.app). Лечение — переехать в
    // /Applications и запускаться оттуда. Детект: маркер AppTranslocation в пути бандла (эвристика
    // без private SecTranslocate* — надёжно отличает транслоцированный запуск).

    /// Запущены ли мы из транслоцированной (рандомизированной read-only) копии.
    static func isTranslocated() -> Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Откуда запущено приложение — короткой строкой для отчёта об ошибке.
    ///
    /// ⚠️ ЗАВЕДЕНО ПО РЕПОРТУ #71 (03.08.2026). Человек на Intel-маке дал доступы, а движок не
    /// поднялся, и в логе висело сообщение Sparkle «can't be updated if it's running from the
    /// location it was downloaded to» — то есть приложение работало НЕ из «Программ». Проверить
    /// догадку было нечем: путь запуска в диагностику не попадал вовсе, а он объясняет сразу
    /// класс жалоб (доступы не держатся, обновления не ставятся).
    /// Полный путь НЕ пишем: в нём бывает имя пользователя, а отчёт уходит на сервер.
    static func launchLocationForDiagnostics() -> String {
        if isTranslocated() { return "временная копия (App Translocation) — НЕ из Программ" }
        if isInApplications() { return "Программы ✓" }
        let p = Bundle.main.bundlePath
        if p.contains("/Downloads/") { return "папка «Загрузки» — НЕ из Программ" }
        if p.contains("/Desktop/")   { return "рабочий стол — НЕ из Программ" }
        if p.hasPrefix("/Volumes/")  { return "смонтированный образ — НЕ из Программ" }
        return "другое место — НЕ из Программ"
    }

    /// Стабильное ли расположение (/Applications или ~/Applications) — где грант TCC переживёт перезапуск.
    static func isInApplications() -> Bool {
        let p = Bundle.main.bundlePath
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/")
        return p.hasPrefix("/Applications/") || p.hasPrefix(userApps)
    }

    /// Подписка на изменение списка Accessibility. `com.apple.accessibility.api` — недокументированное,
    /// но рабочее уведомление TCC (так делают AltTab/Hammerspoon). Для Developer-ID-бинаря доставка ок.
    /// ВАЖНО: тайминг «когда именно стреляет» не охарактеризован → держать ещё и поллинг-бэкстоп.
    /// Возвращает токен — держать сильную ссылку, иначе наблюдатель отвалится.
    static func observeAXChanges(_ block: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { block() }
        }
    }

    // MARK: Input Monitoring (нужен для listen-only event tap — чтения клавиш)

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: открыть нужные панели System Settings

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Объекты входа (Login Items) — чтобы убрать чужой автозапуск (напр. Punto Switcher).
    /// Отключить автозапуск ДРУГОГО приложения программно нельзя — ведём пользователя в панель.
    static func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    /// Панель «Клавиатура» в Настройках системы — там живёт «При нажатии 🌐» (фича 24.07).
    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// Телеграм-канал с новостями релизов (@keyboop; анонсы публикуются автоматически).
    /// Бот @keyboop_bot с личными уведомлениями больше не рекламируем — все новости в канале.
    static func openTelegramChannel() {
        open("https://t.me/keyboop")
    }

    /// Диагностический лог (~/Library/Logs/Keyboop.log) — открыть для отлова багов.
    /// Лог локальный, без сети и без текста распознавания (только поток/метаданные).
    static func openDiagnosticLog() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Keyboop.log")
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))   // откроется в Console
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")))
        }
    }

    /// Почта разработчику для фидбэка (открывает почтовый клиент с готовой темой).
    static func openFeedbackMail() {
        let subject = "Keyboop — отзыв".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Keyboop"
        open("mailto:hi@keyboop.com?subject=\(subject)")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
