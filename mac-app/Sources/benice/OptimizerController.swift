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
    /// Called when no model source has been chosen yet; the shell opens Settings.
    var onNeedsSetup: (() -> Void)?
    // A failed replace may still have written; its Undo must outlive closing the window.
    private var uncertainWrite = false
    private var reanchor: Task<Void, Never>?

    init() {
        previewWindow.onRestyle = { [weak self] index, style in self?.regenerate(index, style: style, tweak: nil) }
        previewWindow.onTweak = { [weak self] index, tweak, current in
            self?.regenerate(index, style: nil, tweak: (tweak, current))
        }
    }

    func trigger(_ target: TriggerController.Target) {
        guard !busy else { return }
        cancelPreview()
        uncertainWrite = false
        reanchor?.cancel()
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
        // A fresh install has chosen nothing: send nothing, not even a `gh` token lookup.
        guard let provider = store.savedProvider() else {
            fail("Choose where your drafts are sent in Settings. Nothing is sent until you Save.", token: token)
            onNeedsSetup?()
            return
        }
        do {
            guard let client = try await Self.client(for: provider, store: store) else {
                return fail("Set up a model in Settings first.", token: token)
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
            // Copy-only never writes: release the capture now instead of holding it until close.
            if validationFailure != nil { pending = nil; Task { await core.cancel() } }
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
            if provider == .copilot, Self.dropExpiredToken(error) {
                return fail(CopilotAuth.AuthError.notLoggedIn.localizedDescription, token: token)
            }
            if provider == .copilot, case ModelClientError.http(let status, _) = error, status == 400 || status == 404 {
                return fail("Copilot doesn't accept this model. Open Settings and pick another.", token: token)
            }
            fail(error.localizedDescription, token: token)
        }
    }

    /// The saved provider's client; nil when the custom model is incomplete.
    nonisolated static func client(for provider: Provider, store: SettingsStore) async throws -> ModelClient? {
        switch provider {
        case .copilot:
            // The user's own `gh` login; the token is read per app run and never stored.
            let model = store.loadCopilotModel()
            let ghToken = try await Task.detached { try CopilotAuth.token() }.value
            return ModelClient(config: CopilotAuth.config(model: model), apiKey: ghToken)
        case .custom:
            let settings = store.load()
            guard let url = URL(string: settings.baseURL), ModelClient.endpoint(for: url) != nil,
                  !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let key = try await Task.detached { try CredentialStore.loadAPIKey() ?? "" }.value
            return ModelClient(config: ModelConfig(baseURL: url, model: settings.model), apiKey: key)
        }
    }

    /// No-Accessibility paths (Services, clipboard): same settings, client and style slots;
    /// no picker (`HandoffPolicy.defaultRewrite`).
    nonisolated static func firstRewrite(_ text: String) async throws -> String {
        let store = SettingsStore()
        guard let provider = store.savedProvider(),
              let client = try await client(for: provider, store: store) else { throw HandoffError.needsSetup }
        do {
            return try HandoffPolicy.defaultRewrite(try await client.rewriteOptions(text: text, styles: StyleSlots.load()))
        } catch {
            if provider == .copilot, dropExpiredToken(error) { throw CopilotAuth.AuthError.notLoggedIn }
            throw error
        }
    }

    /// On a Copilot 401, forget the cached `gh` token so the next request re-reads it.
    nonisolated private static func dropExpiredToken(_ error: Error) -> Bool {
        guard case ModelClientError.http(status: 401, _) = error else { return false }
        CopilotAuth.resetTokenCache()
        return true
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
                let expired = SettingsStore().loadProvider() == .copilot && Self.dropExpiredToken(error)
                self.previewWindow.showError(expired ? CopilotAuth.AuthError.notLoggedIn.localizedDescription
                                                     : error.localizedDescription)
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
                shown = nil  // holds the client and token
                previewWindow.dismiss()
                showStatus("Replaced", anchor: target.liveAnchorRect, refresh: { target.liveAnchorRect })
            case .failed(let error):
                uncertainWrite = recovery === core
                previewWindow.resumeCopyOnly(reason: error.message)
                showStatus(error.message, anchor: target.liveAnchorRect, refresh: { target.liveAnchorRect })
            }
        }
    }

    var canUndo: Bool { recovery != nil && !busy }

    func undoLast() {
        guard !busy, let core = recovery, let target = recoveryTarget else { return }
        cancelPreview()
        busy = true
        reanchor?.cancel()
        statusWindow.hide()
        Task {
            let restored = await restoreFocus(target)
            let outcome: UndoOutcome = restored ? await core.undo() : .failed(.targetChanged(.notFrontmost))
            busy = false
            switch outcome {
            case .restored:
                recovery = nil
                recoveryTarget = nil
                showStatus("Restored", anchor: target.liveAnchorRect, refresh: { target.liveAnchorRect })
            case .failed(let error): showStatus(error.message, anchor: target.liveAnchorRect, refresh: { target.liveAnchorRect })
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
        reanchor?.cancel()
        statusWindow.hide()
        // Only a possibly-written failed replace keeps its Undo on screen; a fresh rewrite never re-offers an old one.
        if returnToTarget, uncertainWrite, let target = recoveryTarget {
            showStatus("Undo last replace", anchor: target.liveAnchorRect, refresh: { target.liveAnchorRect })
        }
    }

    private func fail(_ message: String, token: UInt64) {
        guard generation == token else { return }
        if let core = pending { Task { await core.cancel() } }
        pending = nil
        shown = nil
        showStatus(message, anchor: pendingTarget?.anchorRect ?? .zero)
    }

    /// `refresh` re-reads the composer shortly after: Slack can resize it a frame after the text changes.
    private func showStatus(_ message: String, anchor: CGRect, refresh: (() -> CGRect)? = nil) {
        statusWindow.show(message, target: anchor,
                          undo: recovery == nil ? nil : { [weak self] in self?.undoLast() }, cancel: nil)
        reanchor?.cancel()
        reanchor = nil
        guard let refresh else { return }
        reanchor = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let rect = refresh()
            if !rect.isEmpty { self?.statusWindow.reanchor(rect) }  // unreadable: keep the pill where it is
        }
    }
}
