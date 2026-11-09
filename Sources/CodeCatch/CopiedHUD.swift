import AppKit
import QuartzCore

/// A small popup that drops down from the menu bar icon when a code is copied.
///
/// It never takes focus, so ⌘V still pastes into the app the user is in.
/// It floats above other windows, including full-screen apps and the
/// Messages banner, and fades out on its own.
@MainActor
final class CopiedHUD {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⌘V to paste")
    private var hideWork: DispatchWorkItem?

    private let size = NSSize(width: 220, height: 56)
    private let showFor: TimeInterval = 2.5

    init() {
        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver  // above banners and full-screen apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        // A solid rounded view. The window is clear, so its shadow follows
        // the pill shape and no square box shows behind it.
        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        pill.layer?.cornerRadius = size.height / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            .applying(.init(paletteColors: [.white, .systemGreen]))
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(config)
        iconView.wantsLayer = true

        titleLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.65)

        let text = NSStackView(views: [titleLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [iconView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(dismiss))
        pill.addGestureRecognizer(click)
        panel.contentView = pill
    }

    /// Shows the popup under `anchor` (the status item button).
    func show(code: String, under anchor: NSStatusBarButton?) {
        titleLabel.stringValue = "Copied \(code)"
        hideWork?.cancel()

        let final = frame(under: anchor)
        let start = final.offsetBy(dx: 0, dy: 10)

        if !panel.isVisible || panel.alphaValue < 1 {
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(final, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(final, display: true)
        }
        popCheckmark()

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showFor, execute: work)
    }

    @objc private func dismiss() {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        let up = panel.frame.offsetBy(dx: 0, dy: 6)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(up, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Springs the checkmark from small to full size.
    private func popCheckmark() {
        guard let layer = iconView.layer else { return }
        // Scale around the center, not the bottom-left corner.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: iconView.frame.midX, y: iconView.frame.midY)

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.3
        spring.toValue = 1.0
        spring.mass = 0.6
        spring.stiffness = 220
        spring.damping = 11
        spring.initialVelocity = 4
        spring.duration = spring.settlingDuration
        spring.beginTime = CACurrentMediaTime() + 0.08
        spring.fillMode = .backwards
        layer.add(spring, forKey: "pop")
    }

    /// Centers the popup under the menu bar icon. In full screen the menu bar
    /// is hidden, so it falls back to the top edge of the screen.
    private func frame(under anchor: NSStatusBarButton?) -> NSRect {
        let gap: CGFloat = 6
        if let button = anchor, let window = button.window,
           let screen = window.screen ?? NSScreen.main {
            let iconRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let menuBarBottom = screen.frame.maxY - NSStatusBar.system.thickness
            var x = iconRect.midX - size.width / 2
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
            return NSRect(x: x, y: menuBarBottom - gap - size.height, width: size.width, height: size.height)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return NSRect(
            x: screen.frame.maxX - size.width - 12,
            y: screen.frame.maxY - NSStatusBar.system.thickness - gap - size.height,
            width: size.width, height: size.height)
    }
}

/// A panel that can never become key or main, so it never steals focus.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
