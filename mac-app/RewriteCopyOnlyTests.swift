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
        let options = [RewriteOption(style: .direct, text: "First candidate"),
                       RewriteOption(style: .friendly, text: "Second candidate")]
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
        expect(button("primary").title == "复制改写" && button("primary").isEnabled, "primary becomes copy")
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
        expect(statusView().string.contains("不能直接替换") && statusView().string.contains("重新生成"),
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
        expect(statusView().accessibilityLabel() == "改写状态", "reason has accessible name")
        expect(editor().accessibilityLabel() == "编辑改写全文" && editor().isEditable, "candidate remains accessible and editable")
        expect(root.bounds.contains(statusView().enclosingScrollView!.convert(statusView().enclosingScrollView!.bounds, to: root)),
               "status viewport stays in bounds")
        controller.dismiss()
        present()
        pick(0)
        expect(button("primary").title == "用「简洁直接」替换", "normal mode primary is replace")
        editor().string = "Edited before apply validation"
        commandReturn()
        expect(submitted == ["Edited before apply validation"], "valid submit uses edit once")
        controller.suspendForApply()
        commandReturn()
        expect(submitted.count == 1, "busy rejects repeated keyboard submission")
        controller.resumeCopyOnly(reason: "目标已变化。")
        expect(editor().string == "Edited before apply validation", "failed apply retains edited result")
        expect(button("primary").title == "复制改写" && !controller.window!.isVisible, "failed apply becomes copy-only and stays hidden in test")
        commandReturn()
        click("primary")
        expect(submitted.count == 1 && copied.last == "Edited before apply validation", "failed apply permits copy only")
        click("cancel")
        expect(cancelled == 1, "copy-only can cancel")
        present()
        expect(button("primary").title == "用「简洁直接」替换", "new generation resets copy-only state")
        expect(copied.count == 2, "no lifecycle action copies implicitly")
        controller.dismiss()
        if failures == 0 { print("RewriteCopyOnlyTests PASS"); exit(0) }
        print("RewriteCopyOnlyTests FAILED (\(failures))"); exit(1)
    }
}
