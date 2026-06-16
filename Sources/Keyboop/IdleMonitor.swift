import CoreGraphics
import Foundation
import AppKit

/// Следит за «простоем»: сколько секунд не было НИКАКОГО ввода (клавиатура + мышь + трекпад).
/// Нужен, чтобы тихо доустановить обновление ТОЛЬКО когда человек реально отошёл — не мешая работе.
/// Системный счётчик macOS, без каких-либо разрешений (проверено: растёт сам, пока никто не трогает ввод).
final class IdleMonitor {
    static let shared = IdleMonitor()

    /// Секунды с последнего любого пользовательского ввода. `~0` = «любое событие» (клавиатура+мышь).
    static var secondsSinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    private var timer: Timer?
    private var threshold: TimeInterval = 300       // 5 минут простоя по умолчанию (см. waitForIdle)
    private var onIdle: (() -> Void)?
    private var armed = true                          // false после срабатывания, пока снова не будет активности

    /// Ждать окно простоя ≥ `threshold` секунд; когда наступит — один раз дёрнуть `onIdle`.
    /// Если после срабатывания снова был ввод — перевзводимся и ждём следующего окна (на случай, если
    /// установку в прошлый раз отложили: шла диктовка / открыто окно настроек).
    func waitForIdle(threshold: TimeInterval = 300, every interval: TimeInterval = 20,
                     onIdle: @escaping () -> Void) {
        self.threshold = threshold
        self.onIdle = onIdle
        self.armed = true
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil; onIdle = nil }

    private func tick() {
        let idle = Self.secondsSinceInput
        if idle >= threshold {
            if armed { armed = false; onIdle?() }   // одно срабатывание на окно простоя
        } else {
            armed = true                            // снова активность → перевзвести
        }
    }
}
