import AppKit

@MainActor
final class StyleWindowController: NSWindowController, NSWindowDelegate {
    typealias ExtractAction = @Sendable (String) async throws -> StyleProfile

    private let store: StyleStore
    private let endpoint: () -> String
    private let extract: ExtractAction
    private let samplesView = NSTextView()
    private let guideView = NSTextView()
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var generation: UInt64 = 0
    private var isBusy = false

    private lazy var extractButton = NSButton(title: "Extract Style", target: self, action: #selector(extractStyle))
    private lazy var saveButton = NSButton(title: "Save Style", target: self, action: #selector(saveStyle))
    private lazy var closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))

    init(store: StyleStore = StyleStore(), endpoint: @escaping () -> String,
         extract: @escaping ExtractAction) {
        self.store = store
        self.endpoint = endpoint
        self.extract = extract
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "be-nice Personal Style"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent(in: window)
    }

    required init?(coder: NSCoder) { fatalError("StyleWindowController does not load from a nib") }

    func present() {
        if !isBusy, window?.isVisible != true {
            guideView.string = store.load().guide
            samplesView.string = ""
            statusLabel.stringValue = ""
        }
        updatePrivacy()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func updatePrivacy() {
        let base = endpoint()
        let local = URL(string: base).flatMap { url in
            ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") ? true : nil
        } != nil
        privacyLabel.stringValue = local
            ? "Local endpoint: \(base). Samples are sent only when you click Extract; raw samples are never saved."
            : "Remote endpoint: \(base). Samples leave this Mac only when you click Extract; raw samples are never saved."
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isBusy }

    func windowWillClose(_ notification: Notification) {
        generation &+= 1
        samplesView.string = ""
    }

    private func buildContent(in window: NSWindow) {
        for (view, label) in [(samplesView, "Sample messages"), (guideView, "Personal style")] {
            view.font = .systemFont(ofSize: NSFont.systemFontSize)
            view.isRichText = false
            view.setAccessibilityLabel(label)
        }
        privacyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        privacyLabel.textColor = .secondaryLabelColor
        privacyLabel.setAccessibilityLabel("Style privacy")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Style status")
        let buttons = NSStackView(views: [closeButton, extractButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let content = NSStackView(views: [
            leadingRow(label("Manual samples (transient)")), scroll(samplesView, height: 120),
            privacyLabel,
            leadingRow(label("Your style")), scroll(guideView, height: 150),
            statusLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -20),
        ])
        window.contentView = host
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    private func leadingRow(_ view: NSView) -> NSStackView {
        let row = NSStackView(views: [view, NSView()])
        row.orientation = .horizontal
        return row
    }

    private func scroll(_ view: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        samplesView.isEditable = !busy
        guideView.isEditable = !busy
        for control in [extractButton, saveButton, closeButton] { control.isEnabled = !busy }
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
    }

    @objc func extractStyle() {
        guard !isBusy else { return }
        updatePrivacy()
        let samples = samplesView.string
        generation &+= 1
        let token = generation
        setBusy(true)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Extracting…"
        Task {
            defer { setBusy(false) }
            do {
                let profile = try await extract(samples)
                guard !profile.isEmpty else { throw StyleExtractionError.emptyProfile }
                guard token == generation else { return }
                guideView.string = profile.guide
                statusLabel.stringValue = "Review and edit your style, then Save Style."
            } catch {
                guard token == generation else { return }
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc func saveStyle() {
        guard !isBusy else { return }
        guard !StyleProfile(guide: guideView.string).isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Add or extract a style before saving."
            return
        }
        do { _ = try ModelClient.validatedStyleGuide(guideView.string) } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
            return
        }
        store.save(StyleProfile(guide: guideView.string))
        samplesView.string = ""
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Style saved. Raw samples cleared."
    }

    @objc private func closeWindow() { window?.performClose(nil) }
}
