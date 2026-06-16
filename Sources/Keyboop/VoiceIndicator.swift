import AppKit

/// Плавающая плашка у курсора во время диктовки. Временный стиль (HUD-стекло,
/// пульсирующая точка) — финальный визуал определим позже.
final class VoiceIndicator {
    static let shared = VoiceIndicator()
    private var panel: NSPanel?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var pulse: Timer?

    func showRecording() { DispatchQueue.main.async { self.present("Слушаю…", recording: true) } }
    func showProcessing() { DispatchQueue.main.async { self.present("Распознаю…", recording: false) } }
    func hide() {
        DispatchQueue.main.async {
            self.pulse?.invalidate(); self.pulse = nil
            self.panel?.orderOut(nil)
        }
    }

    /// Короткий тост у курсора (обучение на отмене и т.п.) — сам прячется через ~2.2с.
    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.present(text, recording: false)
            self.pulse?.invalidate(); self.pulse = nil
            self.dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.hide() }
        }
    }

    private func present(_ text: String, recording: Bool) {
        let p = panel ?? makePanel()
        panel = p
        label.stringValue = text
        dot.layer?.backgroundColor = (recording ? NSColor.systemRed : NSColor.systemOrange).cgColor
        dot.alphaValue = 1.0
        positionAtCursor(p)
        p.orderFrontRegardless()

        pulse?.invalidate()
        guard recording else { return }
        var on = true
        let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            on.toggle()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self?.dot.animator().alphaValue = on ? 1.0 : 0.2
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pulse = t
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 152, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 11
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true

        dot.frame = NSRect(x: 16, y: 14.5, width: 9, height: 9)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.addSubview(dot)

        label.frame = NSRect(x: 34, y: 10, width: 112, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        bg.addSubview(label)

        p.contentView?.addSubview(bg)
        return p
    }

    private func positionAtCursor(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - p.frame.height - 16)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.frame {
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - p.frame.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - p.frame.height - 8)
        }
        p.setFrameOrigin(origin)
    }
}
