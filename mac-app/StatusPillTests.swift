import AppKit

/// swiftc -swift-version 6 -parse-as-library mac-app/Sources/benice/TriggerController.swift \
///     mac-app/Sources/benice/StatusPill.swift mac-app/StatusPillTests.swift -o /tmp/benice-pill
@main
struct StatusPillTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ c: Bool, _ m: String) { if !c { failures += 1; print("SELFTEST FAIL: \(m)") } }
        func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

        // Placement above a field, within the screen.
        let field = CGRect(x: 400, y: 300, width: 600, height: 60)
        let c = RewriteStatusController()
        var undone = 0, cancelled = 0
        c.show("Replaced", target: field, undo: { undone += 1 }, cancel: nil)
        expect(c.frame.minY == field.maxY + 6 && c.frame.minX == field.minX,
               "pill sits on the button row, left-aligned with the field: \(c.frame)")
        let button = TriggerGeometry.buttonFrame(field: field, within: NSScreen.screens.first { $0.frame.intersects(field) }?.visibleFrame ?? .zero)
        expect(button.map { !$0.intersects(c.frame) } ?? true, "pill never covers the entry button when both fit")
        expect(c.frame.height == 32, "single-line height matches the 32 pt button")
        let narrow = TriggerGeometry.pillFrame(field: CGRect(x: 400, y: 300, width: 200, height: 60),
                                               within: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                               size: CGSize(width: 175, height: 32))
        expect(narrow == CGRect(x: 425, y: 366, width: 175, height: 32),
               "too narrow for both: pill takes the button's spot (got \(String(describing: narrow)))")
        expect(c.buttonTitles == ["Undo", "Dismiss"], "replaced shows Undo and Dismiss: \(c.buttonTitles)")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "Undo" }?.performClick(nil)
        expect(undone == 1, "undo callback fires")

        // Fallback: empty anchor → bottom-right of the screen.
        c.show("Restored", target: .zero, undo: nil, cancel: nil)
        let vis = (NSScreen.screens.first { $0.frame.intersects(.zero) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        expect(c.frame.maxX <= vis.maxX && c.frame.minY == vis.minY + 24, "fallback bottom-right: \(c.frame) vs \(vis)")
        expect(c.buttonTitles == ["Dismiss"], "info shows only Dismiss")

        // Loading: spinner + Cancel only, even when an undo exists.
        c.show("Rewriting…", target: field, undo: { undone += 1 }, cancel: { cancelled += 1 })
        expect(c.buttonTitles == ["Cancel"], "loading shows only Cancel: \(c.buttonTitles)")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "Cancel" }?.performClick(nil)
        expect(cancelled == 1, "cancel callback fires")

        // Error: Dismiss hides the pill.
        c.show("The draft changed. Rewrite it again.", target: field, undo: nil, cancel: nil)
        expect(c.buttonTitles == ["Dismiss"], "error shows Dismiss")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "Dismiss" }?.performClick(nil)

        // Success hides itself; hovering pauses the countdown; Dismiss and dropUndo work.
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let auto = RewriteStatusController()
        auto.successLifetime = 0.2
        auto.show("Replaced", target: field, undo: {}, cancel: nil)
        expect(auto.isVisible, "success pill is shown")
        auto.hoverChanged(true)
        spin(0.4)
        expect(auto.isVisible, "hovering keeps the pill")
        auto.hoverChanged(false)
        spin(0.4)
        expect(!auto.isVisible, "success pill hides itself after its lifetime")
        auto.show("Replaced", target: field, undo: {}, cancel: nil)
        auto.dropUndo()
        expect(auto.buttonTitles == ["Dismiss"] && auto.isVisible, "dropUndo keeps the pill without Undo: \(auto.buttonTitles)")
        buttons(auto.contentView!).first { $0.accessibilityLabel() == "Dismiss" }?.performClick(nil)
        expect(!auto.isVisible, "Dismiss hides a success pill")
        auto.show("The draft changed. Rewrite it again.", target: field, undo: nil, cancel: nil)
        spin(0.4)
        expect(auto.isVisible, "errors stay until dismissed")
        auto.show("Rewriting…", target: field, undo: nil, cancel: {})
        spin(0.4)
        expect(auto.isVisible, "loading stays")
        auto.hide()

        // Width bounds.
        let short = RewriteStatusController.size(message: "好", buttons: ["Dismiss"])
        expect(short.width == 140 && short.height == 32, "min width: \(short)")
        let long = RewriteStatusController.size(message: String(repeating: "很长的错误信息", count: 20), buttons: ["Dismiss"])
        expect(long.width == 420 && long.height == 48, "max width, two lines: \(long)")

        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
