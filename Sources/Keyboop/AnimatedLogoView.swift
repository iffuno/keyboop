import AppKit
import AVFoundation

/// Анимированный логотип Keyboop — «сборка» blueprint-K из видео (keyboop-logo-anim.mp4):
/// чертёжные направляющие проявляются и уходят, остаётся чистая K-клавиша. Белые линии на чёрном.
///
/// Чёрный фон видео гасится композитингом `plusLighter` (additive): чёрное (0) ничего не добавляет к
/// подложке → растворяется, остаётся только свечение белой K. Поэтому кладётся на ЛЮБОЙ тёмный фон
/// (графитовый герой онбординга) и одинаково работает в светлой и тёмной теме окна.
///
/// Играет ОДИН раз и замирает на последнем кадре (не loop, не уход в чёрный). Если видео в бандле
/// нет — тихий фолбэк на статичную иконку приложения (онбординг не ломается).
final class AnimatedLogoView: NSView {
    /// Вызывается на главном потоке, когда видео доиграло до конца (для кроссфейда интро → контент).
    /// В фолбэк-режиме (видео нет) вызывается через короткую паузу, чтобы интро не зависло.
    var onFinished: (() -> Void)?

    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var fallback: NSImageView?
    private var endObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        guard let url = Bundle.main.url(forResource: "keyboop-logo-anim", withExtension: "mp4") else {
            installFallback(); return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause          // замереть на финальном кадре (чистая K), не зацикливать
        p.isMuted = true
        playerLayer.player = p
        playerLayer.videoGravity = .resizeAspect
        playerLayer.compositingFilter = "plusL"   // additive: чёрный фон → невидим, K светится
        layer?.addSublayer(playerLayer)
        player = p
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.onFinished?()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { if let o = endObserver { NotificationCenter.default.removeObserver(o) } }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        fallback?.frame = bounds
    }

    /// Проиграть анимацию один раз с начала. Безопасно дёргать повторно (перезапуск).
    func play() {
        guard let p = player else {
            // Фолбэк (видео нет) — не держим интро: «закончили» через короткую паузу.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.onFinished?() }
            return
        }
        p.seek(to: .zero)
        p.play()
    }

    private func installFallback() {
        let iv = NSImageView()
        iv.image = NSApp.applicationIconImage
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor),
            iv.topAnchor.constraint(equalTo: topAnchor),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        fallback = iv
    }
}
