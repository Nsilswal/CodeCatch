import AppKit
import SwiftUI

// MARK: - Draggable app icon

/// The app's icon. Dragging it drags the app bundle's file URL, so the user
/// can drop it into the Full Disk Access list in System Settings.
final class AppIconDragView: NSView, NSDraggingSource {
    private let bundleURL = Bundle.main.bundleURL
    private lazy var icon = NSWorkspace.shared.icon(forFile: bundleURL.path)

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView()
        view.toolTip = "Drag into the Full Disk Access list"
        view.setAccessibilityLabel("CodeCatch app icon. Drag into the Full Disk Access list in System Settings.")
        return view
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

/// The app icon with a soft floating motion that says "pick me up".
struct FloatingAppIcon: View {
    var size: CGFloat
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DraggableAppIcon()
            .frame(width: size, height: size)
            .offset(y: up ? -3 : 3)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

// MARK: - Drop guide panel

/// A small floating panel that sits beside the System Settings window.
/// It holds the draggable icon and an arrow that points at the list.
@MainActor
final class DropGuide {
    private final class Model: ObservableObject {
        @Published var pointsLeft = true
    }

    private let model = Model()
    private var panel: NSPanel?
    private var timer: Timer?
    private var missingTicks = 0

    private let size = NSSize(width: 300, height: 104)
    private let gap: CGFloat = 14
    private let settingsBundleID = "com.apple.systempreferences"

    var isShown: Bool { panel != nil }

    func show() {
        if panel == nil { makePanel() }
        missingTicks = 0
        follow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: GuideView(model: model) { [weak self] in self?.hide() })
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
    }

    /// Keeps the panel next to the System Settings window. It waits a few
    /// seconds for Settings to open, and goes away when Settings closes.
    private func follow() {
        guard let panel else { return }
        guard let frame = settingsWindowFrame() else {
            missingTicks += 1
            if panel.isVisible && missingTicks > 8 { hide() }   // Settings closed
            if !panel.isVisible && missingTicks > 40 { hide() } // never opened
            return
        }
        missingTicks = 0
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.maxX + gap, y: frame.midY - size.height / 2)
        var pointsLeft = true
        if origin.x + size.width > visible.maxX {
            origin.x = frame.minX - gap - size.width
            pointsLeft = false
        }
        if origin.x < visible.minX {
            // No room on either side: tuck it inside the bottom right corner.
            origin = NSPoint(x: frame.maxX - size.width - 20, y: frame.minY + 20)
            pointsLeft = true
        }
        if model.pointsLeft != pointsLeft { model.pointsLeft = pointsLeft }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The main System Settings window in Cocoa screen coordinates. Window
    /// bounds and owners are readable without Screen Recording permission.
    private func settingsWindowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frames: [NSRect] = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict),
                  cg.width > 300, cg.height > 200
            else { return nil }
            return NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }

    private struct GuideView: View {
        @ObservedObject var model: Model
        var close: () -> Void
        @State private var nudge = false

        var body: some View {
            HStack(spacing: 14) {
                if model.pointsLeft { arrow }
                FloatingAppIcon(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Drag CodeCatch into the list")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Drop it on the Full Disk Access list, then make sure its switch is on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.pointsLeft { arrow }
            }
            .padding(.horizontal, 16)
            .frame(width: 300, height: 104)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close guide")
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { nudge = true }
            }
        }

        private var arrow: some View {
            Image(systemName: model.pointsLeft ? "arrow.left" : "arrow.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.teal)
                .offset(x: nudge ? (model.pointsLeft ? -4 : 4) : 0)
        }
    }
}
