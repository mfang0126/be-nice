import AppKit

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Design B (docs/design/rewrite-directions/project/Compare.dc.html) in Slack's palette (user, 2026-10-27):
/// selection blue, send-button green for the replace action. Pinned to Aqua so it stays readable.
private enum Palette {
    static let accent = rgb(0x1264A3)    // Slack selection/link blue: card ring, radio
    static let action = rgb(0x007A5A)    // Slack send-button green: primary replace/copy button
    static let body = rgb(0xF5F5F7)
    static let line = rgb(0xE4E4E7)
    static let cardLine = rgb(0xE0E0E5)
    static let primaryText = rgb(0x1D1C1D)
    static let secondaryText = rgb(0x3A3A3C)
    static let hint = rgb(0x6B6B70)
    static let warning = rgb(0xB3261E)
    static let editing = rgb(0xEEF6FB)
}

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

/// Tab leaves the text instead of inserting a tab character, so keyboard focus can reach the buttons.
@MainActor
private final class RewriteTextView: NSTextView {
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
}

@MainActor
private final class RewriteButton: NSButton {
    private let primary: Bool
    private var restyling = false

    init(title: String, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = (primary ? Palette.action : .white).cgColor
        if !primary {
            layer?.borderWidth = 1
            layer?.borderColor = rgb(0xD1D1D6).cgColor
        }
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var title: String { didSet { restyle() } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + (primary ? 40 : 36), height: 36)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    private func restyle() {
        guard !restyling else { return }
        restyling = true
        defer { restyling = false }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: primary ? .semibold : .regular),
            .foregroundColor: primary ? NSColor.white : Palette.primaryText,
            .paragraphStyle: paragraph])
        setAccessibilityLabel(title)
    }
}

/// One candidate. Clicking anywhere on an unselected card selects it; the selected card's text is
/// the editor, so per-card drafts live in `text` itself.
@MainActor
private final class RewriteCard: NSView {
    let text = RewriteTextView()
    let scroll = NSScrollView()
    var onPick: (() -> Void)?
    private let radio = NSView()
    private let name: String
    private var chosen = false
    private var enabled = true

    init(name: String, hint: String, body: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.cgColor
        radio.wantsLayer = true
        radio.layer?.cornerRadius = 9
        radio.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([radio.widthAnchor.constraint(equalToConstant: 18),
                                     radio.heightAnchor.constraint(equalToConstant: 18)])
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = Palette.primaryText
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = Palette.hint
        hintLabel.isSelectable = false
        hintLabel.alignment = .left
        text.isRichText = false
        text.font = .systemFont(ofSize: 16)
        text.textColor = Palette.secondaryText
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = body
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        let titleRow = NSStackView(views: [title, radio])
        let stack = NSStackView(views: [titleRow, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [titleRow, hintLabel] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            // The scroll view reaches 10 pt past the title column so the text (inset 10) lines up with it.
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(name), \(hint)")
        focusRingType = .exterior
        apply(chosen: false, enabled: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(chosen: Bool, enabled: Bool) {
        let changed = self.chosen != chosen
        self.chosen = chosen
        self.enabled = enabled
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
        layer?.borderWidth = chosen ? 2 : 1
        layer?.borderColor = (chosen ? Palette.accent : Palette.cardLine).cgColor
        radio.layer?.borderWidth = chosen ? 5 : 1.5
        radio.layer?.borderColor = (chosen ? Palette.accent : rgb(0xB8B8BE)).cgColor
        radio.layer?.backgroundColor = NSColor.white.cgColor
        text.isEditable = chosen && enabled
        text.isSelectable = chosen
        text.drawsBackground = chosen
        text.backgroundColor = Palette.editing
        text.textColor = chosen ? Palette.primaryText : Palette.secondaryText
        text.setAccessibilityLabel(chosen ? "Edit rewrite" : "\(name) full text")
        alphaValue = enabled ? 1 : 0.7
    }

    override var acceptsFirstResponder: Bool { enabled }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    /// Unselected cards swallow every click (and scroll) so the whole card acts as one button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit != nil && !chosen ? self : hit
    }
    override func mouseDown(with event: NSEvent) { if enabled { onPick?() } }
    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, enabled { onPick?() } else { super.keyDown(with: event) }
    }
    override func isAccessibilitySelected() -> Bool { chosen }
    override func accessibilityValue() -> Any? { chosen ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onPick?()
        return true
    }
}

@MainActor
final class RewriteWindowController: NSWindowController, NSWindowDelegate {
    private let originalView = RewriteWindowController.staticTextView()
    private let status = RewriteWindowController.staticTextView()
    private let cancelButton = RewriteButton(title: "Cancel", primary: false)
    private let primaryButton = RewriteButton(title: "Replace", primary: true)
    private let panel = NSView()
    private let cardsRow = NSStackView()
    // Reserved for the single-line "How should it change?" instruction field; hidden and unwired (PLAN「试用版之后第一项」).
    private let instructionSlot = NSView()
    private let instructionField = NSTextField()
    private var originalHeight: NSLayoutConstraint!
    private var bodyHeight: NSLayoutConstraint!
    private var bodyContainer: NSView!
    private var cards: [RewriteCard] = []
    private let presentsWindows: Bool
    private let copyText: (String) -> Bool
    private var copyOnlyReason: String?
    private let copyOnlyHelp = "You can view, edit or copy this rewrite, but not replace."
    private let hintText = "←→ switch · edit the selected card · ⌘↩ replace · esc close · undo available, nothing is sent"
    private var options: [RewriteOption] = []
    private var selected = 0
    private var notice: String?
    private var noticeIsError = false
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
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
        selected = 0
        notice = nil
        active = true
        submitAction = onSubmit
        cancelAction = onCancel
        panel.setAccessibilityLabel("Rewrite · \(appName)")
        originalView.string = original
        rebuildCards()
        sizePanel(original: original, screenFrame: screenFrame)
        updateControls()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.setFrame(screenFrame, display: presentsWindows)
        if self.options.isEmpty { showError("No rewrites available. Close this and try again.") }
        guard presentsWindows else { return }
        activateApp()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(cards.first ?? cancelButton)
    }

    func suspendForApply() {
        setBusy(true)
        window?.orderOut(nil)
    }

    func resumeCopyOnly(reason: String) {
        copyOnlyReason = reason
        setBusy(false)
        guard presentsWindows else { return }
        activateApp()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(cards.indices.contains(selected) ? cards[selected].text : cancelButton)
    }

    func showError(_ message: String) {
        setNotice(message, isError: true)
        guard presentsWindows else { return }
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        notice = nil
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

    private func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func setNotice(_ text: String?, isError: Bool) {
        notice = text
        noticeIsError = isError
        updateControls()
    }

    private func updateControls() {
        let usable = active && !busy
        for (index, card) in cards.enumerated() {
            card.apply(chosen: index == selected, enabled: usable)
            card.text.identifier = NSUserInterfaceItemIdentifier(index == selected ? "rewrite-editor" : "rewrite-text-\(index)")
        }
        cancelButton.isEnabled = usable
        if copyOnlyReason != nil {
            primaryButton.title = "Copy rewrite"
        } else {
            let name = options.indices.contains(selected) ? Self.label(options[selected].style) : ""
            primaryButton.title = name.isEmpty ? "Replace" : "Replace with \(name)"
        }
        primaryButton.isEnabled = usable && !options.isEmpty
        var parts: [String] = []
        if busy { parts.append("Checking and replacing…") }
        else if let notice { parts.append(notice) }
        if let copyOnlyReason, !busy { parts.append("\(copyOnlyReason) \(copyOnlyHelp)") }
        let emphasized = !busy && (copyOnlyReason != nil || (notice != nil && noticeIsError))
        status.string = parts.isEmpty ? hintText : parts.joined(separator: " ")
        status.textColor = emphasized ? Palette.warning : Palette.hint
    }

    private func select(_ index: Int, focusEditor: Bool) {
        guard active, !busy, cards.indices.contains(index) else { return }
        selected = index
        setNotice(nil, isError: false)
        guard presentsWindows else { return }
        window?.makeFirstResponder(focusEditor ? cards[index].text : cards[index])
    }

    @objc private func primaryAction() {
        if copyOnlyReason == nil { submit() } else { copyCandidate() }
    }

    /// The only path that reports text to the caller; copy-only mode can never reach it.
    @objc private func submit() {
        guard active, !busy, copyOnlyReason == nil, cards.indices.contains(selected) else { return }
        let text = cards[selected].text.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Enter some text first.")
            if presentsWindows { window?.makeFirstResponder(cards[selected].text) }
            return
        }
        setBusy(true)
        submitAction?(text)
    }

    private func copyCandidate() {
        guard active, !busy, cards.indices.contains(selected) else { return }
        let copied = copyText(cards[selected].text.string)
        setNotice(copied ? "Copied." : "Copy failed. Try again.", isError: !copied)
    }

    @objc private func cancel() {
        guard active, !busy else { return }
        let callback = cancelAction
        dismiss()
        callback?()
    }

    /// Esc closes, ⌘↩ replaces. ←/→ switch cards and Return enters the editor only while focus is NOT
    /// inside the editor, so caret movement and newlines in the text are never hijacked; Tab/click
    /// leave or enter the editor.
    func handleKey(_ event: NSEvent) -> Bool {
        guard active else { return false }
        // Let the input method see Esc/⌘↩ while composing (e.g. Chinese IME marked text).
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 {
            cancel(); return true
        }
        if isReturn, modifiers == .command {
            if copyOnlyReason == nil { submit() }
            return true
        }
        guard modifiers.isEmpty, !((window?.firstResponder as? NSTextView)?.isEditable ?? false) else { return false }
        if event.keyCode == 123 || event.keyCode == 124 {
            if !busy, !cards.isEmpty {
                let step = event.keyCode == 124 ? 1 : cards.count - 1
                select((selected + step) % cards.count, focusEditor: false)
                if presentsWindows { window?.makeFirstResponder(cards[selected]) }
            }
            return true
        }
        if isReturn {
            if let button = window?.firstResponder as? NSButton {
                if !busy { button.performClick(nil) }
                return true
            }
            if let card = window?.firstResponder as? RewriteCard, !busy {
                window?.makeFirstResponder(card.text)
                return true
            }
        }
        return false
    }

    private func rebuildCards() {
        for card in cards { cardsRow.removeArrangedSubview(card); card.removeFromSuperview() }
        cards = options.enumerated().map { index, option in
            let card = RewriteCard(name: Self.label(option.style), hint: Self.hint(option.style), body: option.text)
            card.identifier = NSUserInterfaceItemIdentifier("card-\(index)")
            card.onPick = { [weak self] in self?.select(index, focusEditor: true) }
            card.translatesAutoresizingMaskIntoConstraints = false
            cardsRow.addArrangedSubview(card)
            // Always a third of the row, so fewer options mean fewer cards of the same width.
            card.widthAnchor.constraint(equalTo: bodyContainer.widthAnchor, multiplier: 1.0 / 3,
                                        constant: -88.0 / 3).isActive = true
            return card
        }
    }

    /// Long originals scroll inside the header and long options inside their card, so the footer
    /// always stays on screen; heights are estimated from the text and capped by the screen.
    private func sizePanel(original: String, screenFrame: NSRect) {
        let panelWidth = min(1120, screenFrame.width - 40)
        func height(_ text: String, width: CGFloat, size: CGFloat) -> CGFloat {
            ceil(NSString(string: text).boundingRect(
                with: NSSize(width: max(width, 60), height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: size)]).height * 1.1)
        }
        // Whole lines only (at most three) so a scrolling original is never cut mid-line.
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 16))
        let lines = min(3, max(1, Int(ceil(height(original, width: panelWidth - 56 - 16 - 48, size: 16) / 1.1 / lineHeight))))
        let originalH = ceil(CGFloat(lines) * lineHeight) + 3
        originalHeight.constant = originalH
        let cardTextWidth = (panelWidth - 88) / 3 - 32 - 20
        let wanted = 77 + 20 + (options.map { height($0.text, width: cardTextWidth, size: 16) }.max() ?? 0)
        let room = screenFrame.height - 50 - (originalH + 44) - 72 - 48
        bodyHeight.constant = 48 + min(max(240, wanted), max(160, room))
    }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = rgb(0x141416, alpha: 0.5).cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrim)

        panel.wantsLayer = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.35
        panel.layer?.shadowRadius = 40
        panel.layer?.shadowOffset = CGSize(width: 0, height: -30)
        panel.setAccessibilityRole(.group)
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 18
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = Palette.body.cgColor
        clip.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(clip)

        // Header: white band with the original text.
        originalView.textColor = Palette.secondaryText
        originalView.setAccessibilityLabel("Your draft")
        originalView.isSelectable = true
        let originalScroll = Self.scroll(originalView)
        originalScroll.scrollerStyle = .legacy  // always-visible scroller signals a long original
        originalScroll.autohidesScrollers = false
        originalHeight = originalScroll.heightAnchor.constraint(equalToConstant: 24)
        originalHeight.isActive = true
        let originalLabel = NSTextField(labelWithString: "Your draft")
        originalLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        originalLabel.textColor = Palette.hint
        originalLabel.setContentHuggingPriority(.required, for: .horizontal)
        let header = Self.band([originalLabel, originalScroll], insets: NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28),
                               spacing: 16, alignment: .top)

        instructionSlot.isHidden = true
        instructionField.placeholderString = "How should it change?"
        instructionField.translatesAutoresizingMaskIntoConstraints = false
        instructionSlot.addSubview(instructionField)
        NSLayoutConstraint.activate([
            instructionField.leadingAnchor.constraint(equalTo: instructionSlot.leadingAnchor, constant: 28),
            instructionField.trailingAnchor.constraint(equalTo: instructionSlot.trailingAnchor, constant: -28),
            instructionField.topAnchor.constraint(equalTo: instructionSlot.topAnchor, constant: 12),
            instructionField.bottomAnchor.constraint(equalTo: instructionSlot.bottomAnchor, constant: -12)])

        // Body: cards centered in an equal-thirds row.
        let body = NSView()
        bodyContainer = body
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 16
        cardsRow.distribution = .fill
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(cardsRow)
        bodyHeight = body.heightAnchor.constraint(equalToConstant: 300)
        NSLayoutConstraint.activate([
            bodyHeight,
            cardsRow.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            cardsRow.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 28),
            cardsRow.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -28),
            cardsRow.topAnchor.constraint(equalTo: body.topAnchor, constant: 24),
            cardsRow.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -24)])

        // Footer: plain hint/status text (not a box) and the two actions.
        status.identifier = NSUserInterfaceItemIdentifier("rewrite-status")
        status.setAccessibilityLabel("Rewrite status")
        status.font = .systemFont(ofSize: 12)
        status.textContainerInset = NSSize(width: 0, height: 6)
        let statusScroll = Self.scroll(status)
        statusScroll.heightAnchor.constraint(equalToConstant: 44).isActive = true
        statusScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        statusScroll.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for (button, action, id) in [(cancelButton, #selector(cancel), "cancel"),
                                     (primaryButton, #selector(primaryAction), "primary")] {
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let footer = Self.band([statusScroll, cancelButton, primaryButton],
                               insets: NSEdgeInsets(top: 14, left: 28, bottom: 14, right: 28), spacing: 10, alignment: .centerY)

        let stack = NSStackView(views: [header, Self.rule(), instructionSlot, body, Self.rule(), footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        for view in [body, instructionSlot] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 1120)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrim.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: root.topAnchor), scrim.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: panel.leadingAnchor), clip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            clip.topAnchor.constraint(equalTo: panel.topAnchor), clip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor), stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor), stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 1120), preferredWidth,
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            panel.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 20),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)])
    }

    private static func band(_ views: [NSView], insets: NSEdgeInsets, spacing: CGFloat,
                             alignment: NSLayoutConstraint.Attribute) -> NSView {
        let band = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.white.cgColor
        let row = NSStackView(views: views)
        row.spacing = spacing
        row.alignment = alignment
        row.edgeInsets = insets
        row.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: band.leadingAnchor), row.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            row.topAnchor.constraint(equalTo: band.topAnchor), row.bottomAnchor.constraint(equalTo: band.bottomAnchor)])
        return band
    }

    private static func rule() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.line.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private static func label(_ style: RewriteStyle) -> String {
        switch style {
        case .direct: return NSLocalizedString("Direct", comment: "Direct rewrite style")
        case .friendly: return NSLocalizedString("Friendly", comment: "Friendly rewrite style")
        case .clear: return NSLocalizedString("Clear", comment: "Clear rewrite style")
        }
    }

    private static func hint(_ style: RewriteStyle) -> String {
        switch style {
        case .direct: return "For busy readers: lead with the point"
        case .friendly: return "For teammates: relaxed, not stiff"
        case .clear: return "For anyone who needs it spelled out: one idea per sentence"
        }
    }

    private static func staticTextView() -> NSTextView {
        let view = RewriteTextView()
        view.isEditable = false
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = .zero
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
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }
}
