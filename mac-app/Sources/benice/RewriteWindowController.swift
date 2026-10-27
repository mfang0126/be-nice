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
    static let draft = rgb(0xF8F8F8)     // background of the read-only original
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
    let styleButton = NSButton()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let radio = NSView()
    private var name = ""
    private var chosen = false
    private var instruction = ""
    private static let editHint = "Edit, then ⌘↩"
    private var enabled = true
    private var savedText: String?
    var isRegenerating: Bool { savedText != nil }

    init(style: RewriteStyle, body: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.cgColor
        radio.wantsLayer = true
        radio.layer?.cornerRadius = 9
        radio.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([radio.widthAnchor.constraint(equalToConstant: 18),
                                     radio.heightAnchor.constraint(equalToConstant: 18)])
        styleButton.isBordered = false
        styleButton.alignment = .left
        styleButton.target = self
        styleButton.action = #selector(showStyleMenu)
        styleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        let titleRow = NSStackView(views: [styleButton, radio])
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
        configure(style: style, menu: nil)
        setAccessibilityRole(.radioButton)
        focusRingType = .exterior
        apply(chosen: false, enabled: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(style: RewriteStyle, menu: NSMenu?) {
        name = style.name
        styleButton.attributedTitle = NSAttributedString(string: "\(style.name) ▾", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: Palette.primaryText])
        styleButton.setAccessibilityLabel("\(style.name), change style")
        styleButton.toolTip = "Use a different style for this version. Only this rewrite changes; your defaults are set in Settings."
        styleButton.menu = menu
        instruction = style.instruction
        hintLabel.stringValue = chosen ? Self.editHint : style.instruction
        setAccessibilityLabel("\(style.name), \(style.instruction)")
    }

    func setStyleEnabled(_ on: Bool) {
        styleButton.isEnabled = on
        styleButton.alphaValue = on ? 1 : 0.45
    }

    func beginRegenerating() {
        guard savedText == nil else { return }
        savedText = text.string
        text.string = "Rewriting…"
        apply(chosen: chosen, enabled: enabled)
    }

    /// Without `newText` the pre-regeneration text comes back (failure path).
    func endRegenerating(newText: String? = nil) {
        if let newText { text.string = newText } else if let savedText { text.string = savedText }
        savedText = nil
        apply(chosen: chosen, enabled: enabled)
    }

    @objc private func showStyleMenu() {
        guard let menu = styleButton.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: styleButton.bounds.height + 2), in: styleButton)
    }

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
        hintLabel.stringValue = chosen ? Self.editHint : instruction
        text.isEditable = chosen && enabled && !isRegenerating
        text.isSelectable = chosen
        text.drawsBackground = chosen
        text.backgroundColor = Palette.editing
        text.textColor = isRegenerating ? Palette.hint : chosen ? Palette.primaryText : Palette.secondaryText
        text.setAccessibilityLabel(chosen ? "Edit rewrite" : "\(name) full text")
        alphaValue = enabled ? 1 : 0.7
    }

    override var acceptsFirstResponder: Bool { enabled }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    /// Unselected cards swallow every click (and scroll) so the whole card acts as one button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === styleButton, styleButton.isEnabled { return hit }
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
final class RewriteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let originalView = RewriteWindowController.staticTextView()
    private let status = RewriteWindowController.staticTextView()
    private let cancelButton = RewriteButton(title: "Cancel", primary: false)
    private let primaryButton = RewriteButton(title: "Replace", primary: true)
    private let panel = NSView()
    private let cardsRow = NSStackView()
    private let instructionSlot = NSView()
    private var panelCenterX = NSLayoutConstraint()
    private var panelCenterY = NSLayoutConstraint()
    private let instructionField = NSTextField()
    private var originalHeight: NSLayoutConstraint!
    private var bodyHeight: NSLayoutConstraint!
    private var bodyContainer: NSView!
    private var cards: [RewriteCard] = []
    private let presentsWindows: Bool
    private let copyText: (String) -> Bool
    private var copyOnlyReason: String?
    private let copyOnlyHelp = "You can view, edit or copy this rewrite, but not replace."
    private let hintText = "⌘↩ replace · esc close · nothing is sent"
    private var options: [RewriteOption] = []
    private var selected = 0
    private var notice: String?
    private var noticeIsError = false
    private var busy = false
    private var regenerating: Int?
    private var active = false
    private var submitAction: ((String) -> Void)?
    private var cancelAction: (() -> Void)?
    var onRestyle: ((Int, RewriteStyle) -> Void)?
    var onTweak: ((Int, String, String) -> Void)?

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
                 anchor: NSRect? = nil, copyOnlyReason: String? = nil, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard !busy else { return }
        self.copyOnlyReason = copyOnlyReason
        self.options = Array(options.prefix(3))
        selected = 0
        notice = nil
        regenerating = nil
        instructionField.stringValue = ""
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
        placePanel(near: anchor, in: screenFrame)
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

    /// Marks one card as being rewritten (nil ends it, restoring that card's previous text).
    func setRegenerating(_ index: Int?) {
        if let old = regenerating, old != index, cards.indices.contains(old) { cards[old].endRegenerating() }
        regenerating = index.flatMap { cards.indices.contains($0) ? $0 : nil }
        if let regenerating { cards[regenerating].beginRegenerating() }
        updateControls()
    }

    /// Replaces one card's style and text, ends regeneration and keeps the selection.
    func updateOption(_ index: Int, _ option: RewriteOption) {
        guard options.indices.contains(index), cards.indices.contains(index) else { return }
        options[index] = option
        cards[index].configure(style: option.style, menu: styleMenu(for: index))
        cards[index].endRegenerating(newText: option.text)
        instructionField.stringValue = ""  // kept until success so a failed tweak needn't be retyped
        if regenerating == index { regenerating = nil }
        updateControls()
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
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }  // "Describe your own…"
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
        let interactive = usable && regenerating == nil
        for (index, card) in cards.enumerated() {
            card.apply(chosen: index == selected, enabled: usable)
            card.text.identifier = NSUserInterfaceItemIdentifier(index == selected ? "rewrite-editor" : "rewrite-text-\(index)")
        }
        cancelButton.isEnabled = usable
        for card in cards { card.setStyleEnabled(interactive) }
        instructionField.isEnabled = interactive && !options.isEmpty
        if copyOnlyReason != nil {
            primaryButton.title = "Copy rewrite"
        } else {
            let name = options.indices.contains(selected) ? options[selected].style.name : ""
            primaryButton.title = name.isEmpty ? "Replace" : "Replace with \(name)"
        }
        let target = options.indices.contains(selected) ? options[selected].style.name : ""
        instructionField.placeholderString = target.isEmpty ? "How should it change? e.g. more polite, shorter" : "Change \(target): e.g. more polite, shorter"
        primaryButton.isEnabled = interactive && !options.isEmpty
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
        guard active, !busy, regenerating == nil, copyOnlyReason == nil, cards.indices.contains(selected) else { return }
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
        guard active, !busy, regenerating == nil, cards.indices.contains(selected) else { return }
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

    private func styleMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for preset in RewriteStyle.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = preset
            item.state = options[index].style == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Describe your own…", action: #selector(describeOwn(_:)), keyEquivalent: "")
        custom.target = self
        custom.tag = index
        menu.addItem(custom)
        return menu
    }

    @objc private func pickStyle(_ item: NSMenuItem) {
        guard let style = item.representedObject as? RewriteStyle else { return }
        restyle(item.tag, style)
    }

    private func restyle(_ index: Int, _ style: RewriteStyle) {
        guard active, !busy, regenerating == nil, options.indices.contains(index),
              options[index].style != style else { return }
        onRestyle?(index, style)
    }

    @objc private func describeOwn(_ item: NSMenuItem) {
        let index = item.tag
        guard presentsWindows, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Describe your own style"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. Polite English, under 2 sentences"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.restyleCustom(index, field.stringValue) }
        }
    }

    func restyleCustom(_ index: Int, _ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        restyle(index, RewriteStyle(name: "Custom", instruction: String(line.prefix(RewriteStyle.maxInstructionLength))))
    }

    /// Return in the tweak field submits unless the input method is composing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if textView.hasMarkedText() { return false }
        submitTweak()
        return true
    }

    private func submitTweak() {
        let tweak = instructionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !busy, regenerating == nil, !tweak.isEmpty, cards.indices.contains(selected) else { return }
        onTweak?(selected, tweak, cards[selected].text.string)
    }

    private func rebuildCards() {
        for card in cards { cardsRow.removeArrangedSubview(card); card.removeFromSuperview() }
        cards = options.enumerated().map { index, option in
            let card = RewriteCard(style: option.style, body: option.text)
            card.configure(style: option.style, menu: styleMenu(for: index))
            card.styleButton.identifier = NSUserInterfaceItemIdentifier("style-\(index)")
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

    /// Puts the panel's bottom edge on the field's bottom edge and centres it on the field, so the
    /// conversation above stays visible; the screen-edge constraints keep it fully on screen.
    private func placePanel(near anchor: NSRect?, in screenFrame: NSRect) {
        guard let anchor, !anchor.isEmpty, let root = window?.contentView else {
            panelCenterX.constant = 0
            panelCenterY.constant = 0
            return
        }
        // The panel's height can still settle after the first pass, so place it twice.
        for _ in 0..<2 {
            root.layoutSubtreeIfNeeded()
            let size = panel.frame.size
            panelCenterX.constant = anchor.midX - screenFrame.midX
            // The panel's layout y runs top-down here, so the offset is measured from the screen's centre downwards.
            panelCenterY.constant = screenFrame.midY - (anchor.minY + size.height / 2)
        }
        root.layoutSubtreeIfNeeded()
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
        // Lay the draft out like the text view does (CJK fallback fonts make lines taller than the
        // system font's line height), capped at five lines; longer drafts scroll.
        func laidOut(_ text: String) -> CGFloat {
            let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16)])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: panelWidth - 56 - 4 - 15 - 28, height: 100_000))
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
        let originalH = ceil(min(laidOut(original), laidOut("国\n国\n国\n国\n国"))) + 20 + 2
        originalHeight.constant = originalH
        let cardTextWidth = (panelWidth - 88) / 3 - 32 - 20
        let wanted = 77 + 20 + (options.map { height($0.text, width: cardTextWidth, size: 16) }.max() ?? 0)
        // 58 = instruction row (56) plus its rule.
        let room = screenFrame.height - 50 - (originalH + 67) - 72 - 48 - 58
        bodyHeight.constant = 48 + min(max(200, wanted), max(160, room))
    }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = rgb(0x141416, alpha: 0.28).cgColor
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

        // Header: label above the original, shown full width in a light box at card text size.
        originalView.textColor = Palette.primaryText
        originalView.textContainerInset = NSSize(width: 14, height: 10)
        originalView.setAccessibilityLabel("Your draft")
        originalView.isSelectable = true
        let originalScroll = Self.scroll(originalView)
        originalScroll.scrollerStyle = .legacy  // scroller appears only when the original is long
        originalScroll.autohidesScrollers = true
        let draftBox = NSView()
        draftBox.wantsLayer = true
        draftBox.layer?.backgroundColor = Palette.draft.cgColor
        draftBox.layer?.borderColor = Palette.cardLine.cgColor
        draftBox.layer?.borderWidth = 1
        draftBox.layer?.cornerRadius = 8
        originalScroll.translatesAutoresizingMaskIntoConstraints = false
        draftBox.addSubview(originalScroll)
        NSLayoutConstraint.activate([
            originalScroll.leadingAnchor.constraint(equalTo: draftBox.leadingAnchor),
            originalScroll.trailingAnchor.constraint(equalTo: draftBox.trailingAnchor, constant: -4),
            originalScroll.topAnchor.constraint(equalTo: draftBox.topAnchor),
            originalScroll.bottomAnchor.constraint(equalTo: draftBox.bottomAnchor)])
        originalHeight = originalScroll.heightAnchor.constraint(equalToConstant: 24)
        originalHeight.isActive = true
        let originalLabel = NSTextField(labelWithString: "YOUR DRAFT")
        originalLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        originalLabel.textColor = Palette.hint
        originalLabel.alignment = .left
        let header = Self.band([originalLabel, draftBox], insets: NSEdgeInsets(top: 18, left: 28, bottom: 20, right: 28),
                               spacing: 8, alignment: .leading, vertical: true)
        draftBox.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -56).isActive = true

        instructionSlot.wantsLayer = true
        instructionSlot.layer?.backgroundColor = Palette.body.cgColor
        instructionField.placeholderString = "How should it change? e.g. more polite, shorter"
        instructionField.font = .systemFont(ofSize: 16)
        instructionField.isBezeled = true
        instructionField.bezelStyle = .roundedBezel
        instructionField.focusRingType = .default
        instructionField.toolTip = "Say how the selected version should change, then press Return. Only that version is rewritten."
        instructionField.usesSingleLineMode = true
        instructionField.lineBreakMode = .byTruncatingTail
        instructionField.delegate = self
        instructionField.identifier = NSUserInterfaceItemIdentifier("rewrite-tweak")
        instructionField.setAccessibilityLabel("How should it change?")
        instructionField.translatesAutoresizingMaskIntoConstraints = false
        instructionSlot.addSubview(instructionField)
        NSLayoutConstraint.activate([
            instructionField.leadingAnchor.constraint(equalTo: instructionSlot.leadingAnchor, constant: 28),
            instructionField.trailingAnchor.constraint(equalTo: instructionSlot.trailingAnchor, constant: -28),
            instructionField.topAnchor.constraint(equalTo: instructionSlot.topAnchor, constant: 10),
            instructionField.bottomAnchor.constraint(equalTo: instructionSlot.bottomAnchor, constant: -10),
            instructionSlot.heightAnchor.constraint(equalToConstant: 56)])

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

        let stack = NSStackView(views: [header, Self.rule(), instructionSlot, Self.rule(), body, Self.rule(), footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        for view in [header, body, instructionSlot] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // Below the required screen-edge limits, so a panel near an edge is pushed back on screen.
        panelCenterX = panel.centerXAnchor.constraint(equalTo: root.centerXAnchor)
        panelCenterY = panel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        panelCenterX.priority = .defaultHigh
        panelCenterY.priority = .defaultHigh
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 1120)
        preferredWidth.priority = NSLayoutConstraint.Priority(760)  // above the centring, so edges shift the panel, not narrow it
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrim.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: root.topAnchor), scrim.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: panel.leadingAnchor), clip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            clip.topAnchor.constraint(equalTo: panel.topAnchor), clip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor), stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor), stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            panelCenterX, panelCenterY,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 1120), preferredWidth,
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            panel.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 20),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)])
    }

    private static func band(_ views: [NSView], insets: NSEdgeInsets, spacing: CGFloat,
                             alignment: NSLayoutConstraint.Attribute, vertical: Bool = false) -> NSView {
        let band = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.white.cgColor
        let row = NSStackView(views: views)
        row.orientation = vertical ? .vertical : .horizontal
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
