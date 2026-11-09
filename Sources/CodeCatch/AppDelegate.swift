import AppKit
import CodeCatchCore
import ServiceManagement
import UserNotifications

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

    private var recent: [CaughtCode] = []  // memory only, never written to disk
    private var flashUntil: Date?
    private var clearTask: DispatchWorkItem?
    private var shownAccessAlert = false

    private let clearDelay: TimeInterval = 120
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Running as a real .app bundle (not `swift run`). Notifications and
    /// launch-at-login only work inside a bundle.
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

        if settings.enabled { watcher.start() }
        if settings.notify { requestNotificationPermission() }
        updateIcon()
    }

    // MARK: - Code handling

    private func caught(code: String, sender: String?) {
        copy(code)
        recent.insert(CaughtCode(code: code, sender: sender, date: Date()), at: 0)
        recent = Array(recent.prefix(5))

        flashUntil = Date().addingTimeInterval(3)
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.updateIcon() }

        if settings.notify { notify(code: code, sender: sender) }
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
            menu.addItem(item("Grant Full Disk Access…", #selector(openFullDiskAccess)))
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
        menu.addItem(toggle("Show Notifications", settings.notify, #selector(toggleNotify)))
        menu.addItem(toggle("Clear Clipboard After 2 Minutes", settings.autoClear, #selector(toggleAutoClear)))
        let login = toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        login.isEnabled = isBundled
        menu.addItem(login)

        menu.addItem(.separator())
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
        if settings.notify { requestNotificationPermission() }
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

    @objc private func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Alerts & notifications

    private func showAccessAlertOnce() {
        guard !shownAccessAlert else { return }
        shownAccessAlert = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "CodeCatch needs Full Disk Access"
        a.informativeText = """
            To read incoming verification codes, CodeCatch needs read-only access to your Messages database.

            Open System Settings → Privacy & Security → Full Disk Access and turn on CodeCatch. \
            CodeCatch checks again on its own every few seconds.
            """
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openFullDiskAccess() }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func requestNotificationPermission() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(code: String, sender: String?) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Copied code \(code)"
        content.body = sender.map { "From \($0). Press ⌘V to paste." } ?? "Press ⌘V to paste."
        let req = UNNotificationRequest(identifier: "code", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
