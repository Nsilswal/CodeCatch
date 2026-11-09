import AppKit
import CodeCatchCore
import ServiceManagement

private struct CaughtCode {
    let code: String
    let sender: String?
    let date: Date
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let watcher = MessageWatcher()
    private let settings = Settings()
    private lazy var hud = CopiedHUD()
    private lazy var onboarding = OnboardingController(settings: settings)

    private var recent: [CaughtCode] = []  // memory only, never written to disk
    private var flashUntil: Date?
    private var clearTask: DispatchWorkItem?
    private var shownAccessAlert = false

    private let clearDelay: TimeInterval = 120
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Running as a real .app bundle (not `swift run`). Launch at login
    /// only works inside a bundle.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        watcher.onCode = { [weak self] code, message in
            self?.caught(code: code, sender: message.sender)
        }
        watcher.onStateChange = { [weak self] state in
            self?.updateIcon()
            if case .noAccess = state { self?.showAccessAlertOnce() }
        }

        onboarding.onAccessGranted = { [weak self] in
            self?.watcher.check()
            self?.updateIcon()
        }
        onboarding.onTryPopup = { [weak self] in
            guard let self else { return }
            self.hud.show(code: "482913", under: self.statusItem.button)
        }

        if settings.enabled { watcher.start() }
        updateIcon()

        let args = ProcessInfo.processInfo.arguments
        if !settings.onboarded || args.contains("--onboarding") {
            onboarding.show()
        }

        // Development aid: `CODECATCH_DEMO=1` shows the copied popup at launch.
        if ProcessInfo.processInfo.environment["CODECATCH_DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.caught(code: "482913", sender: nil)
            }
        }
    }

    // MARK: - Code handling

    private func caught(code: String, sender: String?) {
        copy(code)
        recent.insert(CaughtCode(code: code, sender: sender, date: Date()), at: 0)
        recent = Array(recent.prefix(5))

        flashUntil = Date().addingTimeInterval(3)
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.updateIcon() }

        if settings.notify { hud.show(code: code, under: statusItem.button) }
    }

    private func copy(_ code: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        // Clipboard history apps that follow nspasteboard.org skip this item.
        pb.setString("", forType: concealedType)

        clearTask?.cancel()
        guard settings.autoClear else { return }
        let count = pb.changeCount
        let task = DispatchWorkItem {
            if pb.changeCount == count { pb.clearContents() }
        }
        clearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay, execute: task)
    }

    // MARK: - Menu bar icon

    private func updateIcon() {
        let symbol: String
        let tip: String
        if let until = flashUntil, until > Date() {
            symbol = "checkmark.shield.fill"; tip = "Code copied"
        } else {
            switch watcher.state {
            case .watching: symbol = "lock.shield"; tip = "CodeCatch: watching Messages"
            case .stopped: symbol = "lock.slash"; tip = "CodeCatch: paused"
            case .noAccess, .failed: symbol = "exclamationmark.shield"; tip = "CodeCatch: needs attention"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch watcher.state {
        case .watching: status = "Watching Messages"
        case .stopped: status = "Paused"
        case .noAccess: status = "Needs Full Disk Access"
        case .failed(let msg): status = "Error: \(msg)"
        }
        menu.addItem(disabled("CodeCatch: \(status)"))

        if case .noAccess = watcher.state {
            menu.addItem(item("Grant Full Disk Access…", #selector(showAccessStep)))
        }

        menu.addItem(.separator())

        if recent.isEmpty {
            menu.addItem(disabled("No codes caught yet"))
        } else {
            menu.addItem(disabled("Recent codes (click to copy)"))
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            for (i, c) in recent.enumerated() {
                var title = c.code
                if let s = c.sender { title += "  ·  \(s)" }
                title += "  ·  \(rel.localizedString(for: c.date, relativeTo: Date()))"
                let mi = item(title, #selector(copyRecent(_:)))
                mi.tag = i
                menu.addItem(mi)
            }
            menu.addItem(item("Clear History", #selector(clearHistory)))
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Enabled", settings.enabled, #selector(toggleEnabled)))
        menu.addItem(toggle("Show Copied Popup", settings.notify, #selector(toggleNotify)))
        menu.addItem(toggle("Clear Clipboard After 2 Minutes", settings.autoClear, #selector(toggleAutoClear)))
        let login = toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        login.isEnabled = isBundled
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Welcome & Setup…", #selector(showOnboarding)))
        let quit = item("Quit CodeCatch", #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let mi = item(title, action)
        mi.state = on ? .on : .off
        return mi
    }

    // MARK: - Actions

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard recent.indices.contains(sender.tag) else { return }
        copy(recent[sender.tag].code)
    }

    @objc private func clearHistory() { recent.removeAll() }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if settings.enabled { watcher.start() } else { watcher.stop() }
        updateIcon()
    }

    @objc private func toggleNotify() {
        settings.notify.toggle()
    }

    @objc private func toggleAutoClear() {
        settings.autoClear.toggle()
        if !settings.autoClear { clearTask?.cancel() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Could not change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func showOnboarding() { onboarding.show() }

    @objc private func showAccessStep() { onboarding.show(at: .access) }

    // MARK: - Alerts

    /// Full Disk Access is missing (first launch, or the user turned it off).
    /// Opens the drag-and-drop access step once per launch.
    private func showAccessAlertOnce() {
        guard !shownAccessAlert, settings.onboarded, !onboarding.isOpen else { return }
        shownAccessAlert = true
        onboarding.show(at: .access)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
