import AppKit

private final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
}

@main
struct StyleWindowTests {
    @MainActor
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func textView(_ label: String, in window: NSWindow) -> NSTextView? {
            views(window.contentView!).compactMap { $0 as? NSTextView }
                .first { $0.accessibilityLabel() == label }
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let defaults = InMemoryDefaults()
        let store = StyleStore(defaults: defaults)
        let extracted = StyleProfile(guide: "Warm and concise")
        var base = "http://127.0.0.1:11434"
        let controller = StyleWindowController(store: store, endpoint: { base }) { samples in
            samples == "fixture samples" ? extracted : StyleProfile()
        }
        guard let window = controller.window,
              let samples = textView("Sample messages", in: window),
              let guide = textView("Personal style", in: window),
              let status = views(window.contentView!).compactMap({ $0 as? NSTextField })
                .first(where: { $0.accessibilityLabel() == "Style status" }),
              let privacy = views(window.contentView!).compactMap({ $0 as? NSTextField })
                .first(where: { $0.accessibilityLabel() == "Style privacy" }) else {
            print("SELFTEST FAIL: style window hierarchy missing"); exit(1)
        }
        controller.present()
        expect(privacy.stringValue.contains("Local endpoint"), "initial privacy text identifies a local endpoint")
        base = "https://api.example.com"
        samples.string = "fixture samples"
        controller.extractStyle()
        expect(privacy.stringValue.contains("Remote endpoint: https://api.example.com"),
               "Extract refreshes privacy text from the current endpoint before sending")
        let deadline = Date().addingTimeInterval(2)
        while !status.stringValue.contains("Review and edit") && Date() < deadline { await Task.yield() }
        expect(guide.string == extracted.guide, "Extract fills the single editable guide")
        expect(store.load().isEmpty, "Extract does not auto-save or overwrite persisted style")
        expect(samples.string == "fixture samples", "unsaved samples remain available for review")

        controller.saveStyle()
        expect(store.load() == extracted, "Save persists the reviewed guide")
        expect(samples.string.isEmpty, "Save clears raw samples")

        samples.string = "must survive empty save"
        guide.string = ""
        controller.saveStyle()
        expect(store.load() == extracted && samples.string == "must survive empty save",
               "blank Save neither erases the saved style nor clears samples")

        samples.string = "must survive rejected save"
        guide.string = String(repeating: "x", count: 4_001)
        controller.saveStyle()
        expect(store.load() == extracted && samples.string == "must survive rejected save",
               "invalid manual edits neither persist nor clear samples")

        guide.string = "Keep this edit"
        samples.string = "empty extraction"
        controller.extractStyle()
        let emptyDeadline = Date().addingTimeInterval(2)
        while status.stringValue != "The model could not extract a style from these samples."
                && Date() < emptyDeadline { await Task.yield() }
        expect(guide.string == "Keep this edit", "empty extraction preserves the current edit")
        controller.close()

        let closing = StyleWindowController(store: store, endpoint: { "http://127.0.0.1:11434" }) { _ in
            try await Task.sleep(for: .milliseconds(50))
            return extracted
        }
        guard let closingWindow = closing.window,
              let closingSamples = textView("Sample messages", in: closingWindow) else {
            print("SELFTEST FAIL: closing style window hierarchy missing"); exit(1)
        }
        closing.present()
        closingSamples.string = "fixture samples"
        closing.extractStyle()
        closing.close()
        expect(closingSamples.string.isEmpty, "programmatic close runs the sample-clearing close path")
        let unlockDeadline = Date().addingTimeInterval(2)
        while !closing.windowShouldClose(closingWindow) && Date() < unlockDeadline { await Task.yield() }
        expect(closing.windowShouldClose(closingWindow),
               "a stale extraction completion cannot leave the window permanently busy")
        closing.close()

        if failures == 0 { print("StyleWindowTests PASS"); exit(0) }
        print("StyleWindowTests FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
