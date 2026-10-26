import AppKit

enum PreviewLayout {
    static func frame(anchor: CGRect, size: NSSize, visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let x = min(max(anchor.minX, visibleFrame.minX + margin),
                    visibleFrame.maxX - size.width - margin)
        let below = anchor.minY - size.height - margin
        let above = anchor.maxY + margin
        let preferredY = below >= visibleFrame.minY + margin ? below : above
        let y = min(max(preferredY, visibleFrame.minY + margin),
                    visibleFrame.maxY - size.height - margin)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Preview-first surface. Rendering a suggestion never writes to the target.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private let suggestionView = PreviewWindowController.makeTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let closeButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private var applyAction: (() -> Void)?
    private var undoAction: (() -> Void)?
    private var closeAction: (() -> Void)?
    private var anchorRect: CGRect?
    private var isBusy = false
    private var isConfirmingDiscard = false

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
            styleMask: [.borderless, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        suggestionView.setAccessibilityLabel("Suggested text")
        statusLabel.setAccessibilityLabel("Optimizer status")
        statusLabel.preferredMaxLayoutWidth = 400
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showLoading(anchorRect: CGRect, onClose: @escaping () -> Void) {
        isBusy = false
        self.anchorRect = anchorRect
        suggestionView.string = ""
        statusLabel.stringValue = "Writing a suggestion…"
        applyButton.isHidden = true
        undoButton.isHidden = true
        applyButton.isEnabled = false
        undoButton.isEnabled = false
        closeButton.isEnabled = true
        applyAction = nil
        undoAction = nil
        closeAction = onClose
        show()
    }

    func showSuggestion(suggestion: String, onApply: @escaping () -> Void,
                        onClose: @escaping () -> Void) {
        isBusy = false
        suggestionView.string = suggestion
        statusLabel.stringValue = "Preview only. Nothing has been changed."
        applyAction = onApply
        undoAction = nil
        closeAction = onClose
        applyButton.isHidden = false
        undoButton.isHidden = true
        applyButton.isEnabled = true
        undoButton.isEnabled = false
        closeButton.isEnabled = true
        show()
    }

    func showApplying() {
        isBusy = true
        statusLabel.stringValue = "Validating and applying…"
        applyButton.isEnabled = false
        undoButton.isEnabled = false
        closeButton.isEnabled = false
    }

    func showApplied(onUndo: @escaping () -> Void) {
        isBusy = false
        statusLabel.stringValue = "Applied and verified."
        applyAction = nil
        undoAction = onUndo
        applyButton.isHidden = true
        undoButton.isHidden = false
        applyButton.isEnabled = false
        undoButton.isEnabled = true
        closeButton.isEnabled = true
    }

    func showUndoing() {
        isBusy = true
        statusLabel.stringValue = "Restoring the original…"
        applyButton.isEnabled = false
        undoButton.isEnabled = false
        closeButton.isEnabled = false
    }

    func showUndone() {
        isBusy = false
        statusLabel.stringValue = "Original restored and verified."
        applyAction = nil
        undoAction = nil
        applyButton.isHidden = true
        undoButton.isHidden = true
        applyButton.isEnabled = false
        undoButton.isEnabled = false
        closeButton.isEnabled = true
    }

    func showFailure(_ message: String, canRetryApply: Bool, canUndo: Bool,
                     onUndo: (() -> Void)? = nil) {
        isBusy = false
        statusLabel.stringValue = message
        if let onUndo { undoAction = onUndo }
        applyButton.isHidden = !(canRetryApply && applyAction != nil)
        undoButton.isHidden = !(canUndo && undoAction != nil)
        applyButton.isEnabled = canRetryApply && applyAction != nil
        undoButton.isEnabled = canUndo && undoAction != nil
        closeButton.isEnabled = true
    }

    /// Undo lasts while this preview flow is retained. Closing it or starting
    /// another flow must be an explicit choice when recovery is still possible.
    func confirmDiscardingUndo() -> Bool {
        guard !isBusy, !isConfirmingDiscard else { return false }
        guard undoButton.isEnabled, undoAction != nil else { return true }
        isConfirmingDiscard = true
        defer { isConfirmingDiscard = false }
        let alert = NSAlert()
        alert.messageText = "Discard product Undo?"
        alert.informativeText = "The current text will stay as it is. You won't be able to restore the original from be-nice."
        alert.addButton(withTitle: "Keep Undo Available")
        alert.addButton(withTitle: "Discard Undo")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardingUndo() }

    func windowWillClose(_ notification: Notification) {
        closeAction?()
        closeAction = nil
        applyAction = nil
        undoAction = nil
    }

    private func show() {
        guard let panel = window else { return }
        if let anchorRect {
            let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) }
                ?? NSScreen.main ?? NSScreen.screens[0]
            panel.setFrame(PreviewLayout.frame(
                anchor: anchorRect, size: panel.frame.size, visibleFrame: screen.visibleFrame), display: true)
        } else {
            panel.center()
        }
        showWindow(nil)
        panel.orderFrontRegardless()
    }

    private func buildContent(in panel: NSPanel) {
        let title = NSTextField(labelWithString: "SUGGESTED REWRITE")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .left
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let suggestionScroll = Self.scroll(containing: suggestionView)

        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.bezelStyle = .rounded
        applyButton.bezelColor = .systemGreen
        applyButton.keyEquivalent = "\r"
        undoButton.target = self
        undoButton.action = #selector(undo)
        closeButton.target = self
        closeButton.action = #selector(closePreview)
        closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), closeButton, undoButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        let content = NSStackView(views: [leadingRow(title), suggestionScroll, leadingRow(statusLabel), buttons])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSVisualEffectView()
        card.material = .popover
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            suggestionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
        panel.contentView = card
    }

    @objc private func apply() { applyAction?() }
    @objc private func undo() { undoAction?() }
    @objc private func closePreview() { window?.performClose(nil) }

    private func leadingRow(_ view: NSView) -> NSStackView {
        let row = NSStackView(views: [view, NSView()])
        row.orientation = .horizontal
        return row
    }

    private static func makeTextView() -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        return view
    }

    private static func scroll(containing view: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }
}
