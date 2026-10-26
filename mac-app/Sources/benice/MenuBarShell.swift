import AppKit
import ApplicationServices

/// Literal key documented for `AXIsProcessTrustedWithOptions`; the CLI uses the
/// same constant key rather than the imported CFString symbol.
private let trustedPromptKey = "AXTrustedCheckOptionPrompt"
private let grantedOnceDefaultsKey = "be-nice.accessibility.grantedOnce"
private let requestedOnceDefaultsKey = "be-nice.accessibility.requestedOnce"
private let pollInterval: TimeInterval = 2.0

enum AccessibilityState {
    case denied
    case granted
    case revoked
}

/// Pure permission state machine. "Revoked" is distinct from "never granted"
/// so the menu can warn when access that was working disappears.
struct AccessibilityTracker {
    private(set) var state: AccessibilityState = .denied
    private(set) var grantedOnce: Bool

    init(grantedOnce: Bool = false) {
        self.grantedOnce = grantedOnce
        state = grantedOnce ? .revoked : .denied
    }

    mutating func update(trusted: Bool) {
        if trusted {
            grantedOnce = true
            state = .granted
        } else {
            state = grantedOnce ? .revoked : .denied
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var tracker: AccessibilityTracker
    private var statusMenuItem: NSMenuItem?
    private var requestMenuItem: NSMenuItem?
    private var shortcutMenuItem: NSMenuItem?
    private var settingsController: SettingsWindowController?
    private var optimizerController: OptimizerController?
    private var triggerController: TriggerController?
    private var pollTimer: Timer?
    private var refreshGeneration = 0
    #if DEBUG
    private var diagnosticGeneration = 0
    #endif

    override init() {
        tracker = AccessibilityTracker(
            grantedOnce: UserDefaults.standard.bool(forKey: grantedOnceDefaultsKey))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageOnly
        setupMainMenu()
        setupMenu()
        let optimizer = OptimizerController()
        optimizerController = optimizer
        let triggers = TriggerController { [weak self] target in
            self?.optimizerController?.trigger(target)
        }
        triggerController = triggers
        triggers.start()
        updateShortcutMenu()
        updateStatusItem()
        updateMenu()

        // Initial state comes from the persisted flag; the real state is then
        // resolved asynchronously, and rechecked on a timer so granted ->
        // revoked transitions show up without relaunching the app.
        refreshPermission()
        let timer = Timer(timeInterval: pollInterval, target: self,
                          selector: #selector(pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Returning from System Settings is the common grant/revoke moment.
        NotificationCenter.default.addObserver(
            self, selector: #selector(pollTick),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        triggerController?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Menu

    private func setupMainMenu() {
        // Accessory apps still need a responder-chain menu for Cmd-V/Cmd-C in
        // settings and for Cmd-, while a be-nice window is key.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "be-nice")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openModelSettings),
                                  keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit be-nice", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let request = NSMenuItem(title: "Request Accessibility Access…",
                                 action: #selector(requestAccess), keyEquivalent: "")
        request.target = self
        menu.addItem(request)
        requestMenuItem = request

        let settings = NSMenuItem(title: "Open Accessibility Settings…",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let check = NSMenuItem(title: "Check Again",
                               action: #selector(pollTick), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "Optimize shortcut", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        shortcutMenuItem = shortcut
        let modelSettings = NSMenuItem(title: "Settings…",
                                       action: #selector(openModelSettings), keyEquivalent: ",")
        modelSettings.target = self
        menu.addItem(modelSettings)
        let undo = NSMenuItem(title: "Undo Last Replace", action: #selector(undoLastRewrite), keyEquivalent: "")
        undo.target = self
        menu.addItem(undo)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit be-nice",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateMenu() {
        statusMenuItem?.title = statusText
        requestMenuItem?.isHidden = tracker.state == .granted ||
            UserDefaults.standard.bool(forKey: requestedOnceDefaultsKey)
    }

    private func updateShortcutMenu() {
        guard let triggerController else { return }
        switch triggerController.hotKeyStatus {
        case .registered:
            shortcutMenuItem?.title = "Optimize shortcut: \(TriggerController.HotKey.defaultShortcutDescription)"
        case .failed(let status):
            shortcutMenuItem?.title = "Shortcut unavailable (\(status)); use the floating dot"
        case .notStarted:
            shortcutMenuItem?.title = "Optimize shortcut: starting…"
        }
    }

    private var statusText: String {
        switch tracker.state {
        case .granted:
            return "Accessibility: Granted"
        case .denied:
            return "Accessibility: Not granted"
        case .revoked:
            return "Accessibility: Revoked — re-enable in System Settings"
        }
    }

    private func updateStatusItem() {
        let symbol = tracker.state == .revoked
            ? "exclamationmark.triangle.fill"
            : "wand.and.stars"
        let label = "be-nice — \(statusText)"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = "be-nice"
        }
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    // MARK: - Permission

    /// Async recheck: discovery happens off the main thread, the UI update is
    /// applied on the main actor. Stale results are dropped by generation.
    private func refreshPermission() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task {
            let trusted = await Task.detached { AXIsProcessTrusted() }.value
            guard generation == self.refreshGeneration else { return }
            self.apply(trusted: trusted)
        }
    }

    private func apply(trusted: Bool) {
        let shouldPersistGrant = trusted && !tracker.grantedOnce
        tracker.update(trusted: trusted)
        if shouldPersistGrant {
            UserDefaults.standard.set(true, forKey: grantedOnceDefaultsKey)
        }
        updateStatusItem()
        updateMenu()
        #if DEBUG
        writeDebugPermissionStatus(trusted: trusted)
        #endif
        triggerController?.refresh()
    }

    #if DEBUG
    /// Only operational metadata; never target text, model output or credentials.
    private func writeDebugPermissionStatus(trusted: Bool) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/be-nice/debug", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "bundleID": bundleID,
                "bundlePath": Bundle.main.bundlePath,
                "accessibilityTrusted": trusted,
                "updatedAt": Date().timeIntervalSince1970
            ], options: [.sortedKeys])
            let file = directory.appendingPathComponent(bundleID + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let request = directory.appendingPathComponent("slack-request.json")
            if FileManager.default.fileExists(atPath: request.path) {
                // Consume explicit, short-lived local requests; never survey Slack automatically.
                let requestData = try Data(contentsOf: request)
                try FileManager.default.removeItem(at: request)
                if requestData.count <= 1024,
                   let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                   let id = object["id"] as? String, UUID(uuidString: id) != nil,
                   let requestedAt = object["requestedAt"] as? Double,
                   (0...10).contains(Date().timeIntervalSince1970 - requestedAt) {
                    diagnosticGeneration &+= 1
                    let generation = diagnosticGeneration
                    Task {
                        do {
                            let data = try await Task.detached {
                                try SlackDiagnostic.response(requestID: id)
                            }.value
                            // A newer accepted diagnostic owns the shared response file.
                            guard generation == self.diagnosticGeneration else { return }
                            let result = directory.appendingPathComponent("slack-result.json")
                            try data.write(to: result, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
                        } catch {
                            NSLog("be-nice Slack diagnostic unavailable")
                        }
                    }
                }
            }
        } catch {
            NSLog("be-nice debug permission status unavailable")
        }
    }
    #endif

    @objc private func pollTick() {
        refreshPermission()
    }

    /// Shows the system Accessibility prompt. Non-blocking: the result arrives
    /// through the poll timer (or the next "Check Again").
    @objc private func requestAccess() {
        UserDefaults.standard.set(true, forKey: requestedOnceDefaultsKey)
        updateMenu()
        Task {
            await Task.detached {
                let options = [trustedPromptKey: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }.value
            self.refreshPermission()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLastRewrite) { return optimizerController?.canUndo == true }
        return true
    }

    @objc private func undoLastRewrite() { optimizerController?.undoLast() }

    @objc private func openModelSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.present()
    }

    @objc private func openAccessibilitySettings() {
        // Newer pane id first, older id as fallback for macOS 13.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// Pure-logic check run by `benice --selftest`; no NSApplication, no TCC call.
enum ShellSelfCheck {
    static func run() -> Int32 {
        var failures = 0

        func expect(_ actual: AccessibilityState, _ expected: AccessibilityState,
                    _ label: String) {
            if actual == expected {
                print("PASS \(label)")
            } else {
                print("FAIL \(label): got \(actual), want \(expected)")
                failures += 1
            }
        }

        var fresh = AccessibilityTracker()
        expect(fresh.state, .denied, "never granted + untrusted = denied")
        fresh.update(trusted: false)
        expect(fresh.state, .denied, "still untrusted = still denied")
        fresh.update(trusted: true)
        expect(fresh.state, .granted, "trusted = granted")
        expect(fresh.grantedOnce ? .granted : .denied, .granted, "grant is remembered")
        fresh.update(trusted: false)
        expect(fresh.state, .revoked, "lost trust after grant = revoked")
        fresh.update(trusted: true)
        expect(fresh.state, .granted, "re-grant recovers")

        var persisted = AccessibilityTracker(grantedOnce: true)
        expect(persisted.state, .revoked, "persisted grant starts revoked until trust is known")
        persisted.update(trusted: false)
        expect(persisted.state, .revoked, "persisted grant + untrusted = revoked")

        return failures == 0 ? 0 : 1
    }
}
