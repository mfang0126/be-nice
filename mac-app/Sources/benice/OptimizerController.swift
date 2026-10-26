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

    func trigger(_ target: TriggerController.Target) {
        guard !busy else { return }
        cancelPreview()
        generation &+= 1
        let token = generation
        pendingTarget = target
        statusWindow.show("正在准备改写…", target: target.anchorRect,
                          undo: recovery == nil ? nil : { [weak self] in self?.undoLast() },
                          cancel: { [weak self] in self?.cancelPreview() })
        request = Task { [weak self] in await self?.start(target, token: token) }
    }

    private func start(_ target: TriggerController.Target, token: UInt64) async {
        let settings = SettingsStore().load()
        guard let url = URL(string: settings.baseURL), ModelClient.endpoint(for: url) != nil,
              !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("请先在 Settings 配置模型。", token: token)
        }
        do {
            let key = try await Task.detached { try CredentialStore.loadAPIKey() ?? "" }.value
            guard generation == token, !Task.isCancelled else { return }
            let client = ModelClient(config: ModelConfig(baseURL: url, model: settings.model),
                                     apiKey: key)
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
            let options = try await client.rewriteOptions(text: captured.original)
            guard generation == token, !Task.isCancelled else { return }
            let validationFailure = await core.validatePreparedTarget()
            guard generation == token, !Task.isCancelled else { return }
            // UI activation is deliberate and happens only after capture.
            let screen = NSScreen.screens.first { $0.frame.intersects(target.anchorRect) } ?? NSScreen.main
            guard let screen else { return fail("无法确定目标屏幕。", token: token) }
            statusWindow.hide()
            previewWindow.present(original: captured.original,
                appName: NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? target.bundleID,
                options: options, screenFrame: screen.frame,
                copyOnlyReason: validationFailure?.message,
                onSubmit: { [weak self] text in self?.apply(text, token: token) },
                onCancel: { [weak self] in self?.cancelPreview(returnToTarget: true) })
        } catch {
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription, token: token)
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
                showStatus("已替换", anchor: target.anchorRect)
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
                showStatus("已恢复原文", anchor: target.anchorRect)
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
        if let target = recoveryTarget { showStatus("可撤销上次替换", anchor: target.anchorRect) }
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

@MainActor
private final class RewriteStatusController {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    private var undoAction: (() -> Void)?
    private var cancelAction: (() -> Void)?

    init() {
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
    }

    func show(_ message: String, target: CGRect, undo: (() -> Void)?, cancel: (() -> Void)?) {
        undoAction = undo
        cancelAction = cancel
        let label = NSTextField(wrappingLabelWithString: message)
        label.setAccessibilityLabel("改写状态")
        let undoButton = NSButton(title: "撤销上次替换", target: self, action: #selector(performUndo))
        undoButton.isHidden = undo == nil
        let close = NSButton(title: cancel == nil ? "收起" : "取消生成", target: self, action: #selector(performClose))
        let row = NSStackView(views: [undoButton, close])
        let stack = NSStackView(views: [label, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        panel.contentView = stack
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 356, y: frame.minY + 24, width: 340, height: 100), display: true)
        }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    @objc private func performUndo() { undoAction?() }
    @objc private func performClose() { if let cancelAction { cancelAction() } else { hide() } }
}
