import AppKit
import CodeCatchCore
import ServiceManagement
import SwiftUI

enum Brand {
    static let teal = Color(red: 0.059, green: 0.463, blue: 0.431)   // #0F766E, from the app icon
    static let orange = Color(red: 0.984, green: 0.573, blue: 0.235) // #FB923C
}

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, access, setup, done
    }

    @Published var step: Step
    @Published private(set) var hasAccess: Bool
    @Published var showPopup: Bool { didSet { settings.notify = showPopup } }
    @Published var autoClear: Bool { didSet { settings.autoClear = autoClear } }
    @Published var launchAtLogin: Bool
    @Published var loginError: String?

    let canLaunchAtLogin = Bundle.main.bundleIdentifier != nil

    var onAccessGranted: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTryPopup: (() -> Void)?
    var onFinish: (() -> Void)?

    private let settings: Settings
    private let store = MessageStore()

    init(settings: Settings, step: Step) {
        self.settings = settings
        self.step = step
        hasAccess = store.hasAccess()
        showPopup = settings.notify
        autoClear = settings.autoClear
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshAccess() {
        let now = store.hasAccess()
        guard now != hasAccess else { return }
        hasAccess = now
        if now { onAccessGranted?() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func next() {
        if let s = Step(rawValue: step.rawValue + 1) { step = s } else { onFinish?() }
    }

    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { step = s }
    }
}

// MARK: - Window controller

/// Shows the onboarding window. It opens on the first launch, from the menu,
/// and when Full Disk Access goes missing later.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var timer: Timer?
    private let guide = DropGuide()
    private let settings: Settings

    var onAccessGranted: (() -> Void)?
    var onTryPopup: (() -> Void)?

    var isOpen: Bool { window != nil }

    init(settings: Settings) {
        self.settings = settings
    }

    func show(at step: OnboardingModel.Step = .welcome) {
        if let window, let model {
            model.step = step
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(settings: settings, step: step)
        model.onOpenSettings = { [weak self] in self?.openFullDiskAccess() }
        model.onTryPopup = { [weak self] in self?.onTryPopup?() }
        model.onFinish = { [weak self] in self?.window?.close() }
        model.onAccessGranted = { [weak self] in self?.accessGranted() }
        self.model = model

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to CodeCatch"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: OnboardingView(model: model))
        w.center()
        window = w

        // Poll so the access step turns green as soon as the user flips the switch.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.refreshAccess() }
        }

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settings.onboarded = true
        timer?.invalidate()
        timer = nil
        guide.hide()
        model = nil
        window = nil
    }

    private func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
        guide.show()
    }

    private func accessGranted() {
        guide.hide()
        onAccessGranted?()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: model.step)
                .padding(.top, 22)

            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .access: AccessStep(model: model)
                case .setup: SetupStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            .id(model.step)

            footer
        }
        .frame(width: 580, height: 500)
        .tint(Brand.teal)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: model.step)
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .controlSize(.large)
            }
            Spacer()
            if model.step == .access && !model.hasAccess {
                Button("Skip for Now") { model.next() }
                    .buttonStyle(.link)
                    .padding(.trailing, 10)
            }
            Button(primaryTitle) { model.next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.step == .access && !model.hasAccess)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .done: return "Done"
        default: return "Continue"
        }
    }
}

private struct StepDots: View {
    var current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Brand.teal : Color.primary.opacity(0.12))
                    .frame(width: step == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }
}

private struct StepHeader: View {
    var symbol: String?
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Brand.teal)
                    .frame(width: 64, height: 64)
                    .background(Brand.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }
}

// Step 1

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Welcome to CodeCatch")
                    .font(.system(size: 26, weight: .bold))
                Text("Verification codes from Messages, copied the moment they arrive.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "message", title: "Catches codes from iMessage and SMS",
                        detail: "It wakes up only when a new message arrives.")
                Feature(symbol: "doc.on.clipboard", title: "Copies each code for you",
                        detail: "Press ⌘V in any browser or app.")
                Feature(symbol: "lock.shield", title: "Stays private",
                        detail: "Read-only access. No network. Codes are never saved.")
            }
            .frame(maxWidth: 380)
            Spacer(minLength: 0)
        }
    }

    private struct Feature: View {
        var symbol: String
        var title: String
        var detail: String

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.teal)
                    .frame(width: 34, height: 34)
                    .background(Brand.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// Step 2

private struct AccessStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            StepHeader(symbol: nil,
                       title: "Allow Full Disk Access",
                       subtitle: "CodeCatch reads your Messages database to find codes. macOS keeps that file behind Full Disk Access. CodeCatch opens it read-only and sends nothing anywhere.")

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.teal)
                        .frame(width: 30, height: 30)
                        .background(Brand.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Full Disk Access").font(.system(size: 13, weight: .semibold))
                        Text("Needed to read new messages").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(granted: model.hasAccess)
                }
                .padding(14)

                Divider()

                if model.hasAccess {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                        Text("CodeCatch can read new messages. You're good to go.")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(18)
                    .transition(.opacity)
                } else {
                    HStack(spacing: 18) {
                        FloatingAppIcon(size: 64)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Brand.teal.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            )
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Open System Settings.\n2. Drag this icon into the Full Disk Access list.")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open System Settings") { model.onOpenSettings?() }
                                .buttonStyle(.borderedProminent)
                            Text("Already in the list? Turn on the switch next to CodeCatch.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .transition(.opacity)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .animation(.easeInOut(duration: 0.25), value: model.hasAccess)
            Spacer(minLength: 0)
        }
    }

    private struct StatusPill: View {
        var granted: Bool

        var body: some View {
            Label(granted ? "Granted" : "Not granted",
                  systemImage: granted ? "checkmark" : "circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background((granted ? Color.green : Color.primary).opacity(0.12), in: Capsule())
        }
    }
}

// Step 3

private struct SetupStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            StepHeader(symbol: "slider.horizontal.3",
                       title: "Make it yours",
                       subtitle: "You can change these at any time from the menu bar icon.")
            VStack(spacing: 0) {
                OptionRow(title: "Launch at Login",
                          detail: model.loginError ?? (model.canLaunchAtLogin
                              ? "Start CodeCatch when you log in, so codes are always caught."
                              : "Available when CodeCatch runs as an app bundle."),
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(!model.canLaunchAtLogin)
                Divider().padding(.leading, 14)
                OptionRow(title: "Show Copied Popup",
                          detail: "A small popup drops from the menu bar when a code is copied.",
                          isOn: $model.showPopup)
                Divider().padding(.leading, 14)
                OptionRow(title: "Clear Clipboard After 2 Minutes",
                          detail: "Remove the code from the clipboard if you have not copied anything else.",
                          isOn: $model.autoClear)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            Spacer(minLength: 0)
        }
    }

    private struct OptionRow: View {
        var title: String
        var detail: String
        @Binding var isOn: Bool

        var body: some View {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .padding(14)
        }
    }
}

// Step 4

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            StepHeader(symbol: "checkmark",
                       title: "You're all set",
                       subtitle: model.hasAccess
                           ? "CodeCatch lives in your menu bar. When a code arrives in Messages, it is already on your clipboard."
                           : "CodeCatch lives in your menu bar. It starts catching codes as soon as you allow Full Disk Access.")

            MenuBarPreview(hasAccess: model.hasAccess)

            if model.showPopup {
                Button {
                    model.onTryPopup?()
                } label: {
                    Label("Show the Copied Popup", systemImage: "sparkles")
                }
                .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
    }

    /// A small drawing of the menu bar that points out the CodeCatch icon.
    private struct MenuBarPreview: View {
        var hasAccess: Bool

        var body: some View {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: hasAccess ? "lock.shield" : "exclamationmark.shield")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Brand.teal.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Brand.teal)
                    Image(systemName: "battery.75")
                    Text("9:41").font(.system(size: 12, weight: .medium))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(width: 300, height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                HStack {
                    Spacer()
                    Text(hasAccess ? "Click it for recent codes and settings" : "Click it to grant access later")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 300)
            }
        }
    }
}
