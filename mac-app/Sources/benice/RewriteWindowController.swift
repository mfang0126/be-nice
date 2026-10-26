import AppKit

@MainActor
private final class RewriteWindow: NSWindow {
    var handleKey: ((NSEvent) -> Bool)?
    var handleClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) { handleClose?() }
    override func close() { handleClose?() }
}

@MainActor
private final class RewriteOptionButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

@MainActor
final class RewriteWindowController: NSWindowController, NSWindowDelegate {
    private let originalView = RewriteWindowController.textView(editable: false)
    private let editor = RewriteWindowController.textView(editable: true)
    private let heading = NSTextField(labelWithString: "")
    private let styleLabel = NSTextField(labelWithString: "")
    private let status = RewriteWindowController.textView(editable: false)
    private let choices = NSStackView()
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let backButton = NSButton(title: "返回选项", target: nil, action: nil)
    private let openButton = NSButton(title: "查看全文 ↵", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制改写", target: nil, action: nil)
    private let presentsWindows: Bool
    private let copyText: (String) -> Bool
    private var copyOnlyReason: String?
    private let copyOnlyHelp = "仅可查看、编辑和复制，不能直接替换。请返回目标草稿重新生成。"
    private let submitButton = NSButton(title: "确认替换 ⌘↵", target: nil, action: nil)
    private var editorScroll: NSScrollView!
    private var originalHeight: NSLayoutConstraint!
    private var editorHeight: NSLayoutConstraint!
    private var optionButtons: [NSButton] = []
    private var options: [RewriteOption] = []
    private var drafts: [String] = []
    private var selected = 0
    private var editing = false
    private var busy = false
    private var active = false
    private var submitAction: ((String) -> Void)?
    private var cancelAction: (() -> Void)?

    init(presentsWindows: Bool = true, copyText: @escaping (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.presentsWindows = presentsWindows
        self.copyText = copyText
        let window = RewriteWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        window.handleClose = { [weak self] in self?.cancel() }
        buildContent(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(original: String, appName: String, options: [RewriteOption], screenFrame: NSRect,
                 copyOnlyReason: String? = nil, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard !busy else { return }
        self.copyOnlyReason = copyOnlyReason
        self.options = Array(options.prefix(3))
        drafts = self.options.map(\.text)
        selected = 0
        editing = false
        active = true
        submitAction = onSubmit
        cancelAction = onCancel
        heading.stringValue = "Rewrite · \(appName)"
        originalView.string = original
        status.string = "↑ ↓ 选择 · Enter 查看全文 · Esc 取消"
        for view in choices.arrangedSubviews { choices.removeArrangedSubview(view); view.removeFromSuperview() }
        optionButtons = self.options.enumerated().map { index, option in
            let button = RewriteOptionButton(title: "", target: self, action: #selector(openOption(_:)))
            let label = NSTextField(labelWithString: Self.label(option.style))
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            let preview = NSTextField(wrappingLabelWithString: option.text)
            preview.maximumNumberOfLines = 2
            preview.lineBreakMode = .byTruncatingTail
            preview.font = .systemFont(ofSize: 16)
            let text = NSStackView(views: [label, preview])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4
            text.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
                text.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                preview.widthAnchor.constraint(equalTo: text.widthAnchor)
            ])
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("option-\(index)")
            button.bezelStyle = .regularSquare
            button.setButtonType(.pushOnPushOff)
            button.alignment = .left
            button.font = .systemFont(ofSize: 16)
            button.cell?.wraps = true
            button.cell?.truncatesLastVisibleLine = true
            button.heightAnchor.constraint(equalToConstant: 78).isActive = true
            button.setAccessibilityLabel("\(Self.label(option.style))，查看全文")
            button.setAccessibilityHelp(option.text)
            choices.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: choices.widthAnchor).isActive = true
            return button
        }
        originalHeight.constant = min(130, max(48, screenFrame.height * 0.16))
        editorHeight.constant = min(300, max(80, screenFrame.height * 0.30))
        updateControls()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.setFrame(screenFrame, display: presentsWindows)
        if self.options.isEmpty { showError("没有可用的改写，请关闭后重试。") }
        guard presentsWindows else { return }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(optionButtons.first ?? cancelButton)
    }

    func suspendForApply() {
        setBusy(true)
        window?.orderOut(nil)
    }

    func resumeCopyOnly(reason: String) {
        copyOnlyReason = reason
        setBusy(false)
        guard presentsWindows else { return }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        if presentsWindows { window?.makeFirstResponder(editor) }
    }

    func showError(_ message: String) {
        status.string = message
        guard presentsWindows else { return }
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        status.string = busy ? "正在确认并替换，请稍候…" : "可编辑 · ⌘Enter 确认替换"
        updateControls()
    }

    /// Success dismissal is allowed while busy and never reports cancellation.
    func dismiss() {
        active = false
        busy = false
        submitAction = nil
        cancelAction = nil
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    private func updateControls() {
        for (index, button) in optionButtons.enumerated() {
            button.state = index == selected ? .on : .off
            button.isEnabled = !busy && active
        }
        choices.isHidden = editing
        editorScroll.isHidden = !editing
        styleLabel.superview?.isHidden = !editing
        backButton.isHidden = !editing
        submitButton.isHidden = !editing
        copyButton.isHidden = !editing
        openButton.isHidden = editing
        for button in [closeButton, cancelButton, backButton, openButton, submitButton, copyButton] {
            button.isEnabled = active && !busy
        }
        submitButton.isEnabled = active && !busy && copyOnlyReason == nil
        if !busy, let copyOnlyReason { status.string = "\(copyOnlyReason) \(copyOnlyHelp)" }
        openButton.isEnabled = active && !busy && !options.isEmpty
        editor.isEditable = active && !busy
    }

    @objc private func openOption(_ sender: NSButton) {
        guard active, !busy, options.indices.contains(sender.tag) else { return }
        selected = sender.tag
        openSelected()
    }

    @objc private func openSelected() {
        guard active, !busy, !editing, drafts.indices.contains(selected) else { return }
        editing = true
        editor.string = drafts[selected]
        styleLabel.stringValue = Self.label(options[selected].style)
        status.string = "可编辑 · ⌘Enter 确认替换 · 替换后仅可撤销本次修改"
        updateControls()
        if presentsWindows { window?.makeFirstResponder(editor) }
    }

    @objc private func back() {
        guard active, !busy, editing else { return }
        drafts[selected] = editor.string
        editing = false
        status.string = "↑ ↓ 选择 · Enter 查看全文 · Esc 取消"
        updateControls()
        if presentsWindows { window?.makeFirstResponder(optionButtons[selected]) }
    }

    @objc private func submit() {
        guard active, !busy, editing, copyOnlyReason == nil else { return }
        let text = editor.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("请输入改写内容。")
            if presentsWindows { window?.makeFirstResponder(editor) }
            return
        }
        drafts[selected] = text
        setBusy(true)
        submitAction?(text)
    }

    @objc private func copyCandidate() {
        guard active, !busy, editing else { return }
        drafts[selected] = editor.string
        showError(copyText(editor.string) ? "已复制改写。" : "复制失败，请重试。")
        if let copyOnlyReason { status.string += " \(copyOnlyReason) \(copyOnlyHelp)" }
    }

    @objc private func cancel() {
        guard active, !busy else { return }
        let callback = cancelAction
        dismiss()
        callback?()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard active else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 {
            if !busy { editing ? back() : cancel() }
            return true
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            submit(); return true
        }
        guard !editing, modifiers.isEmpty else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let button = window?.firstResponder as? NSButton {
                if !busy { button.performClick(nil) }
            } else { openSelected() }
            return true
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            if !busy, !options.isEmpty {
                selected = (selected + (event.keyCode == 125 ? 1 : options.count - 1)) % options.count
                updateControls()
                if presentsWindows { window?.makeFirstResponder(optionButtons[selected]) }
            }
            return true
        }
        return false
    }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        status.setAccessibilityLabel("改写状态")
        originalView.setAccessibilityLabel("原文")
        editor.setAccessibilityLabel("编辑改写全文")
        editor.identifier = NSUserInterfaceItemIdentifier("rewrite-editor")
        let originalScroll = Self.scroll(originalView)
        editorScroll = Self.scroll(editor)
        originalHeight = originalScroll.heightAnchor.constraint(equalToConstant: 100)
        editorHeight = editorScroll.heightAnchor.constraint(equalToConstant: 240)
        originalHeight.isActive = true
        editorHeight.isActive = true
        choices.orientation = .vertical
        choices.alignment = .width
        choices.spacing = 8
        let actions: [(NSButton, Selector, String)] = [
            (closeButton, #selector(cancel), "close"), (cancelButton, #selector(cancel), "cancel"),
            (backButton, #selector(back), "back"), (openButton, #selector(openSelected), "open"),
            (submitButton, #selector(submit), "submit"),
            (copyButton, #selector(copyCandidate), "copy")]
        for (button, action, id) in actions {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setAccessibilityLabel(button.title)
        }
        let header = NSStackView(views: [heading, NSView(), closeButton])
        let footer = NSStackView(views: [backButton, NSView(), cancelButton, openButton, copyButton, submitButton])
        footer.spacing = 8
        let originalLabel = NSTextField(labelWithString: "原文")
        let originalRow = NSStackView(views: [originalLabel, NSView()])
        status.identifier = NSUserInterfaceItemIdentifier("rewrite-status")
        status.font = .systemFont(ofSize: 13)
        let statusRow = Self.scroll(status)
        statusRow.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let styleRow = NSStackView(views: [styleLabel, NSView()])
        let body = NSStackView(views: [originalRow, originalScroll, choices, styleRow, editorScroll])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        let bodyScroll = NSScrollView()
        bodyScroll.hasVerticalScroller = true
        bodyScroll.documentView = body
        let preferredBodyHeight = bodyScroll.heightAnchor.constraint(equalTo: body.heightAnchor)
        preferredBodyHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
            body.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            preferredBodyHeight
        ])
        let content = NSStackView(views: [header, bodyScroll, statusRow, footer])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        for view in [header, bodyScroll, statusRow, footer] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for view in [originalRow, originalScroll, choices, styleRow, editorScroll!] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let preferredWidth = content.widthAnchor.constraint(equalToConstant: 700)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 700), preferredWidth,
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])
        // Opaque semantic system colors also respect reduced transparency and increased contrast.
        originalView.textColor = .labelColor
        editor.textColor = .textColor
    }

    private static func label(_ style: RewriteStyle) -> String {
        switch style {
        case .direct: return NSLocalizedString("简洁直接", comment: "Direct rewrite style")
        case .friendly: return NSLocalizedString("友好自然", comment: "Friendly rewrite style")
        case .clear: return NSLocalizedString("温和清晰", comment: "Clear rewrite style")
        }
    }

    private static func textView(editable: Bool) -> NSTextView {
        let view = NSTextView()
        view.isEditable = editable
        view.isRichText = false
        view.font = .systemFont(ofSize: 17)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        return view
    }

    private static func scroll(_ view: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }
}
