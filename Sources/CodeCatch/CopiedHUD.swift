import AppKit
import QuartzCore
import SwiftUI

/// A small popup that drops down from the menu bar icon when a code is copied.
///
/// It never takes focus, so ⌘V still pastes into the app the user is in.
/// It floats above other windows, including full-screen apps and the
/// Messages banner, and fades out on its own.
@MainActor
final class CopiedHUD {
    fileprivate final class Model: ObservableObject {
        @Published var code = ""
        @Published var sender: String?
        @Published var token = UUID()
    }

    private let panel: NSPanel
    private let model = Model()
    private var hideWork: DispatchWorkItem?

    private let size = NSSize(width: 320, height: 68)
    private let showFor: TimeInterval = 2.8

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

        // The window is clear, so its shadow follows the card's rounded shape.
        let host = NSHostingView(rootView: CopiedCard(model: model, showFor: showFor) { [weak self] in
            self?.dismiss()
        })
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    /// Shows the popup under `anchor` (the status item button).
    func show(code: String, sender: String? = nil, under anchor: NSStatusBarButton?) {
        model.code = code
        model.sender = sender
        model.token = UUID()  // restarts the check pop and the countdown bar
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

/// The popup's content. It uses the same card style, teal accent, and
/// type as the onboarding window, and follows light and dark mode.
private struct CopiedCard: View {
    @ObservedObject var model: CopiedHUD.Model
    var showFor: TimeInterval
    var dismiss: () -> Void

    @State private var checkScale: CGFloat = 1
    @State private var remaining: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.teal)
                .frame(width: 38, height: 38)
                .background(Brand.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .scaleEffect(checkScale)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.code)
                    .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            VStack(spacing: 3) {
                Text("⌘V")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14)))
                Text("to paste")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(width: 320, height: 68)
        .background(.regularMaterial, in: shape)
        .overlay(alignment: .bottom) {
            // Time left before the popup goes away.
            // The card's rounded corners clip it into a thin edge.
            GeometryReader { geo in
                Rectangle()
                    .fill(Brand.teal.opacity(0.75))
                    .frame(width: max(0, geo.size.width * remaining), height: 3)
            }
            .frame(height: 3)
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copied \(model.code). Press Command V to paste.")
        .onChange(of: model.token) { _ in restart() }
        .onAppear(perform: restart)
    }

    private var subtitle: String {
        if let sender = model.sender, !sender.isEmpty { return "Copied from \(sender)" }
        return "Copied from Messages"
    }

    private func restart() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            remaining = 1
            checkScale = reduceMotion ? 1 : 0.4
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { checkScale = 1 }
            withAnimation(.linear(duration: showFor)) { remaining = 0 }
        }
    }
}
