import AppKit

/// Compact dark pill anchored at the Rewrite entry. Never activates the app.
@MainActor
final class RewriteStatusController {
    enum Kind { case loading, success, error }

    static let height: CGFloat = 32  // same height as the Rewrite entry button
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 420
    private static let pad: CGFloat = 14
    private static let gap: CGFloat = 8
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let successMessages = ["Replaced", "Undo last replace", "Restored"]

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 36),
        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    private var undoAction: (() -> Void)?
    private var cancelAction: (() -> Void)?
    private(set) var buttonTitles: [String] = []
    var frame: NSRect { panel.frame }

    init() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)  // above the entry button
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
    }

    var contentView: NSView? { panel.contentView }

    static func kind(message: String, cancel: Bool) -> Kind {
        cancel ? .loading : (successMessages.contains(message) ? .success : .error)
    }

    /// Pill size for the given content; long text wraps to at most two lines.
    static func size(message: String, buttons: [String]) -> CGSize {
        let buttonsW = buttons.reduce(0) { $0 + buttonWidth($1) + gap }
        let chrome = pad + 16 + gap + buttonsW + pad
        let textW = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let width = min(maxWidth, max(minWidth, chrome + textW))
        let avail = width - chrome
        let lines = textW <= avail ? 1 : 2
        return CGSize(width: width, height: lines == 1 ? height : height + 16)
    }

    private static func buttonWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + (title == "Undo" ? 24 : 8)
    }

    func show(_ message: String, target: CGRect, undo: (() -> Void)?, cancel: (() -> Void)?) {
        undoAction = undo
        cancelAction = cancel
        let kind = Self.kind(message: message, cancel: cancel != nil)
        var titles: [String] = []
        if kind == .loading { titles = ["Cancel"] }
        else {
            if undo != nil { titles.append("Undo") }
            if kind == .error || undo == nil { titles.append("Dismiss") }
        }
        buttonTitles = titles
        let size = Self.size(message: message, buttons: titles)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0x1D / 255, green: 0x1C / 255, blue: 0x1D / 255, alpha: 1).cgColor
        root.layer?.cornerRadius = size.height / 2
        root.setAccessibilityElement(false)

        let leading: NSView
        if kind == .loading {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.isIndeterminate = true
            spin.appearance = NSAppearance(named: .darkAqua)
            spin.startAnimation(nil)
            leading = spin
        } else {
            leading = Self.label(kind == .success ? "✓" : "!", bold: true)
        }
        leading.frame = NSRect(x: Self.pad, y: (size.height - 16) / 2, width: 16, height: 16)
        root.addSubview(leading)

        var x = size.width - Self.pad
        for title in titles.reversed() {
            let w = Self.buttonWidth(title)
            x -= w
            let b = title == "Undo" ? Self.pillButton(title) : Self.plainButton(title)
            b.target = self
            b.action = title == "Undo" ? #selector(performUndo) : #selector(performClose)
            b.frame = NSRect(x: x, y: (size.height - 24) / 2, width: w, height: 24)
            b.setAccessibilityLabel(title)
            root.addSubview(b)
            x -= Self.gap
        }
        let textX = Self.pad + 16 + Self.gap
        let label = Self.label(message, bold: false)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.frame = NSRect(x: textX, y: 0, width: max(0, x + Self.gap - textX), height: size.height)
        label.cell?.usesSingleLineMode = false
        (label.cell as? NSTextFieldCell)?.isScrollable = false
        label.setAccessibilityLabel("Rewrite status: \(message)")
        let h = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height)
        label.frame.origin.y = (size.height - h) / 2
        label.frame.size.height = h
        root.addSubview(label)
        panel.contentView = root

        place(target, size: size)
        panel.orderFrontRegardless()
    }

    private func place(_ target: CGRect, size: CGSize) {
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let placed = target.isEmpty ? nil
            : TriggerGeometry.pillFrame(field: target, within: bounds, size: size)
        let f = placed ?? NSRect(x: bounds.maxX - size.width - 16, y: bounds.minY + 24,
                                 width: size.width, height: size.height)
        panel.setFrame(f, display: true)
    }

    /// Moves a visible pill to a re-measured anchor; never shows a hidden one, never jumps on an unreadable rect.
    func reanchor(_ target: CGRect) {
        guard panel.isVisible, !target.isEmpty else { return }
        place(target, size: panel.frame.size)
    }

    func hide() { panel.orderOut(nil) }
    @objc func performUndo() { undoAction?() }
    @objc func performClose() { if let cancelAction { cancelAction() } else { hide() } }

    private static func label(_ s: String, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: 13) : font
        l.textColor = .white
        l.alignment = bold ? .center : .left
        return l
    }

    private static func plainButton(_ title: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.72)])
        return b
    }

    private static func pillButton(_ title: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.cgColor
        b.layer?.cornerRadius = 12
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0x1D / 255, green: 0x1C / 255, blue: 0x1D / 255, alpha: 1)])
        return b
    }
}
