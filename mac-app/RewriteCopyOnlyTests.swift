import AppKit

/// Hidden controls only: no window presentation, OS input, AX, network or real clipboard.
@main
struct RewriteCopyOnlyTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }
        var copied: [String] = []
        var submitted: [String] = []
        var cancelled = 0
        let controller = RewriteWindowController(presentsWindows: false, copyText: {
            copied.append($0); return true
        })
        let options = [RewriteOption(style: RewriteStyle.presets[0], text: "First candidate"),
                       RewriteOption(style: RewriteStyle.presets[1], text: "Second candidate")]
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ id: String) -> NSButton {
            descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == id } as! NSButton
        }
        func click(_ id: String) {
            let control = button(id)
            // Invoke the action directly; disabled actions must guard themselves too.
            _ = control.target?.perform(control.action!, with: control)
        }
        func editor() -> NSTextView {
            descendants(controller.window!.contentView!).first {
                $0.identifier?.rawValue == "rewrite-editor"
            } as! NSTextView
        }
        func present(_ reason: String? = nil) {
            controller.present(original: "Whole original draft", appName: "Fixture", options: options,
                screenFrame: NSRect(x: 0, y: 0, width: 640, height: 480), copyOnlyReason: reason,
                onSubmit: { submitted.append($0) }, onCancel: { cancelled += 1 })
        }
        func commandReturn() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            expect(controller.handleKey(event), "command Return handled directly")
        }
        func pick(_ index: Int) {
            let card = descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "card-\(index)" }!
            _ = card.accessibilityPerformPress()
        }
        func statusView() -> NSTextView {
            descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "rewrite-status" } as! NSTextView
        }
        let reason = String(repeating: "原草稿已变化，请检查目标会话。", count: 50)
        present(reason)
        expect(!controller.window!.isVisible, "presentation suppressed")
        expect(copied.isEmpty && submitted.isEmpty, "stale generation does not copy or apply")
        expect(button("primary").title == "Copy rewrite" && button("primary").isEnabled, "primary becomes copy")
        pick(1)
        expect(editor().string == "Second candidate", "stale candidate retained and viewable")
        expect(editor().isEditable, "copy-only still allows editing")
        editor().string = "用户编辑的全文\nwith newline"
        commandReturn()
        expect(submitted.isEmpty && copied.isEmpty, "keyboard replace cannot bypass copy-only and never copies implicitly")
        let focusedCard = descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "card-1" }!
        _ = controller.window!.makeFirstResponder(focusedCard)
        commandReturn()
        expect(submitted.isEmpty && copied.isEmpty, "command Return on a focused card never submits in copy-only")
        click("primary")
        expect(submitted.isEmpty, "primary button never submits in copy-only")
        expect(copied == ["用户编辑的全文\nwith newline"], "primary copies exact edited candidate")
        pick(0)
        expect(editor().string == "First candidate", "other candidate remains independent")
        pick(1)
        expect(editor().string == "用户编辑的全文\nwith newline", "edited candidate survives navigation")
        expect(statusView().string.contains("but not replace") && statusView().string.contains("view, edit or copy"),
               "copy-only explanation persists through navigation")
        let root = controller.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let controls = ["cancel", "primary"].map(button)
        let frames = controls.map { $0.convert($0.bounds, to: root) }
        for (index, control) in controls.enumerated() {
            expect(!control.isHidden && root.bounds.contains(frames[index]), "small-screen action stays in bounds: \(control.title)")
            expect(!(control.accessibilityLabel() ?? "").isEmpty, "action has accessible name")
        }
        expect(!frames[0].intersects(frames[1]), "action controls do not overlap")
        expect(statusView().string.contains(reason), "full long reason remains available")
        expect(statusView().enclosingScrollView!.hasVerticalScroller, "long reason is scrollable")
        expect(statusView().accessibilityLabel() == "Rewrite status", "reason has accessible name")
        expect(editor().accessibilityLabel() == "Edit rewrite" && editor().isEditable, "candidate remains accessible and editable")
        expect(root.bounds.contains(statusView().enclosingScrollView!.convert(statusView().enclosingScrollView!.bounds, to: root)),
               "status viewport stays in bounds")
        // Restyle and tweak only change text, so they work in copy-only mode.
        var restyled: [Int] = []
        var tweaked: [String] = []
        controller.onRestyle = { i, _ in restyled.append(i) }
        controller.onTweak = { _, t, _ in tweaked.append(t) }
        let restyleMenu = button("style-1").menu!
        _ = NSApp.sendAction(restyleMenu.items[0].action!, to: restyleMenu.items[0].target, from: restyleMenu.items[0])
        let field = descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "rewrite-tweak" } as! NSTextField
        field.stringValue = "shorter"
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        expect(restyled == [1] && tweaked == ["shorter"], "copy-only still restyles and tweaks")
        expect(button("primary").title == "Copy rewrite", "primary stays copy in copy-only after regenerate")
        controller.updateOption(1, RewriteOption(style: RewriteStyle.presets[3], text: "Regenerated"))
        expect(editor().string == "Regenerated" && button("primary").title == "Copy rewrite", "updateOption in copy-only keeps copy")
        controller.dismiss()
        present()
        pick(0)
        expect(button("primary").title == "Replace with Direct", "normal mode primary is replace")
        editor().string = "Edited before apply validation"
        commandReturn()
        expect(submitted == ["Edited before apply validation"], "valid submit uses edit once")
        controller.suspendForApply()
        commandReturn()
        expect(submitted.count == 1, "busy rejects repeated keyboard submission")
        controller.resumeCopyOnly(reason: "目标已变化。")
        expect(editor().string == "Edited before apply validation", "failed apply retains edited result")
        expect(button("primary").title == "Copy rewrite" && !controller.window!.isVisible, "failed apply becomes copy-only and stays hidden in test")
        commandReturn()
        click("primary")
        expect(submitted.count == 1 && copied.last == "Edited before apply validation", "failed apply permits copy only")
        click("cancel")
        expect(cancelled == 1, "copy-only can cancel")
        present()
        expect(button("primary").title == "Replace with Direct", "new generation resets copy-only state")
        expect(copied.count == 2, "no lifecycle action copies implicitly")
        controller.dismiss()
        if failures == 0 { print("RewriteCopyOnlyTests PASS"); exit(0) }
        print("RewriteCopyOnlyTests FAILED (\(failures))"); exit(1)
    }
}
