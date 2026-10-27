import AppKit

/// Owns the captured transaction independently of the presentation lifetime.
@MainActor
final class OptimizerController {
    private let previewWindow = RewriteWindowController()
    private var pending: WriteBackController?
    private var recovery: WriteBackController?
    private var pendingTarget: TriggerController.Target?
    private var recoveryTarget: TriggerController.Target?
    private var request: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var busy = false
    private let statusWindow = RewriteStatusController()
    // What the open rewrite window was built from, for one-card restyle/tweak.
    private var shown: (client: ModelClient, original: String, options: [RewriteOption])?
    private var regenerate: Task<Void, Never>?

    init() {
        previewWindow.onRestyle = { [weak self] index, style in self?.regenerate(index, style: style, tweak: nil) }
        previewWindow.onTweak = { [weak self] index, tweak, current in
            self?.regenerate(index, style: nil, tweak: (tweak, current))
        }
    }

    func trigger(_ target: TriggerController.Target) {
        guard !busy else { return }
        cancelPreview()
        generation &+= 1
        let token = generation
        pendingTarget = target
        statusWindow.show("Rewriting…", target: target.anchorRect,
                          undo: recovery == nil ? nil : { [weak self] in self?.undoLast() },
                          cancel: { [weak self] in self?.cancelPreview() })
        request = Task { [weak self] in await self?.start(target, token: token) }
    }

    private func start(_ target: TriggerController.Target, token: UInt64) async {
        let store = SettingsStore()
        let provider = store.loadProvider()
        do {
            let client: ModelClient
            switch provider {
            case .copilot:
                // The user's own `gh` login; the token is read per app run and never stored.
                let model = store.loadCopilotModel()
                let ghToken = try await Task.detached { try CopilotAuth.token() }.value
                client = ModelClient(config: CopilotAuth.config(model: model), apiKey: ghToken)
            case .custom:
                let settings = store.load()
                guard let url = URL(string: settings.baseURL), ModelClient.endpoint(for: url) != nil,
                      !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return fail("Set up a model in Settings first.", token: token)
                }
                let key = try await Task.detached { try CredentialStore.loadAPIKey() ?? "" }.value
                client = ModelClient(config: ModelConfig(baseURL: url, model: settings.model), apiKey: key)
            }
            guard generation == token, !Task.isCancelled else { return }
            let core = WriteBackController(access: SystemTextTargetAccess(), client: client)
            let outcome = await core.prepare(target: WriteBackTarget(
                pid: target.pid, bundleID: target.bundleID, element: TargetElement(target.element),
                forceWholeValue: true))
            guard generation == token, !Task.isCancelled else { return }
            guard case .ready(let captured) = outcome else {
                if case .failed(let error) = outcome { fail(error.message, token: token) }
                return
            }
            pending = core
            let options = try await client.rewriteOptions(text: captured.original, styles: StyleSlots.load())
            guard generation == token, !Task.isCancelled else { return }
            let validationFailure = await core.validatePreparedTarget()
            guard generation == token, !Task.isCancelled else { return }
            // UI activation is deliberate and happens only after capture.
            let screen = NSScreen.screens.first { $0.frame.intersects(target.anchorRect) } ?? NSScreen.main
            guard let screen else { return fail("Couldn't find the screen for this window.", token: token) }
            statusWindow.hide()
            shown = (client, captured.original, options)
            previewWindow.present(original: captured.original,
                appName: NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? target.bundleID,
                options: options, screenFrame: screen.frame, anchor: target.anchorRect,
                copyOnlyReason: validationFailure?.message,
                onSubmit: { [weak self] text in self?.apply(text, token: token) },
                onCancel: { [weak self] in self?.cancelPreview(returnToTarget: true) })
        } catch {
            guard !Task.isCancelled else { return }
            // A 401 from Copilot means the `gh` login expired; re-read it next time.
            if provider == .copilot, case ModelClientError.http(status: 401, _) = error {
                Task.detached { _ = try? CopilotAuth.token(refresh: true) }  // never block the main actor
                return fail(CopilotAuth.AuthError.notLoggedIn.localizedDescription, token: token)
            }
            if provider == .copilot, case ModelClientError.http(let status, _) = error, status == 400 || status == 404 {
                return fail("Copilot doesn't accept this model. Open Settings and pick another.", token: token)
            }
            fail(error.localizedDescription, token: token)
        }
    }

    /// Rewrites one card with a new style (this rewrite only; defaults live in Settings) or a tweak of its text.
    private func regenerate(_ index: Int, style newStyle: RewriteStyle?, tweak: (String, String)?) {
        guard !busy, regenerate == nil, let shown, shown.options.indices.contains(index) else { return }
        let token = generation
        let oldStyle = shown.options[index].style
        let style = newStyle ?? oldStyle
        previewWindow.setRegenerating(index)
        regenerate = Task { [weak self] in
            do {
                let text = try await shown.client.rewriteOne(original: shown.original, style: style,
                                                             current: tweak?.1, instruction: tweak?.0)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.regenerate = nil
                let option = RewriteOption(style: style, text: text)
                self.shown?.options[index] = option
                self.previewWindow.updateOption(index, option)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.regenerate = nil
                self.previewWindow.setRegenerating(nil)
                self.previewWindow.showError(error.localizedDescription)
            }
        }
    }

    private func apply(_ text: String, token: UInt64) {
        guard generation == token, !busy, let core = pending, let target = pendingTarget else {
            previewWindow.setBusy(false)  // the window went busy on submit; never leave it stuck
            return
        }
        busy = true
        previewWindow.suspendForApply()
        Task {
            let restored = await restoreFocus(target)
            let outcome: ApplyOutcome = restored
                ? await core.apply(replacement: text)
                : .failed(.targetChanged(.notFrontmost))
            if await core.undoAvailable {
                recovery = core
                recoveryTarget = target
            }
            busy = false
            pending = nil
            // Copy-only retains the return-focus target, never the write controller.
            switch outcome {
            case .applied:
                pendingTarget = nil
                previewWindow.dismiss()
                showStatus("Replaced", anchor: target.anchorRect)
            case .failed(let error):
                previewWindow.resumeCopyOnly(reason: error.message)
                showStatus(error.message, anchor: target.anchorRect)
            }
        }
    }

    var canUndo: Bool { recovery != nil && !busy }

    func undoLast() {
        guard !busy, let core = recovery, let target = recoveryTarget else { return }
        cancelPreview()
        busy = true
        statusWindow.hide()
        Task {
            let restored = await restoreFocus(target)
            let outcome: UndoOutcome = restored ? await core.undo() : .failed(.targetChanged(.notFrontmost))
            busy = false
            switch outcome {
            case .restored:
                recovery = nil
                recoveryTarget = nil
                showStatus("Restored", anchor: target.anchorRect)
            case .failed(let error): showStatus(error.message, anchor: target.anchorRect)
            }
        }
    }

    /// Activate only the captured app. The core still checks focused element,
    /// original text and selection; never force focus onto a different document.
    private func restoreFocus(_ target: TriggerController.Target) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleID else { return false }
        app.activate(options: [])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func cancelPreview(returnToTarget: Bool = false) {
        guard !busy else { return }
        let target = pendingTarget
        generation &+= 1
        request?.cancel()
        request = nil
        regenerate?.cancel()
        regenerate = nil
        shown = nil
        if let core = pending { Task { await core.cancel() } }
        pending = nil
        pendingTarget = nil
        previewWindow.dismiss()
        if returnToTarget, let target,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let app = NSRunningApplication(processIdentifier: target.pid),
           app.bundleIdentifier == target.bundleID {
            app.activate(options: [])
        }
        statusWindow.hide()
        // Closing a fresh rewrite must not offer the previous replace again; the menu still has Undo.
        if !returnToTarget, let target = recoveryTarget { showStatus("Undo last replace", anchor: target.anchorRect) }
    }

    private func fail(_ message: String, token: UInt64) {
        guard generation == token else { return }
        showStatus(message, anchor: pendingTarget?.anchorRect ?? .zero)
    }

    private func showStatus(_ message: String, anchor: CGRect) {
        statusWindow.show(message, target: anchor,
                          undo: recovery == nil ? nil : { [weak self] in self?.undoLast() }, cancel: nil)
    }
}
