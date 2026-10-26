import AppKit

@main
struct RewriteWindowTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }
        let controller = RewriteWindowController(presentsWindows: false, copyText: { _ in true })
        let options = [RewriteOption(style: .direct, text: "First option"),
                       RewriteOption(style: .friendly, text: "Second option"),
                       RewriteOption(style: .clear, text: "第三种表达\n保留事实。")]
        let frame = NSRect(x: -1200, y: 0, width: 1200, height: 800)
        var submissions: [String] = []
        var cancellations = 0
        func present() {
            controller.present(original: "Synthetic original", appName: "Fixture", options: options,
                               screenFrame: frame, onSubmit: { submissions.append($0) },
                               onCancel: { cancellations += 1 })
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ id: String) -> NSButton {
            descendants(controller.window!.contentView!).first {
                $0.identifier?.rawValue == id
            } as! NSButton
        }
        func editor() -> NSTextView {
            descendants(controller.window!.contentView!).first {
                $0.identifier?.rawValue == "rewrite-editor"
            } as! NSTextView
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: controller.window!.windowNumber,
                                        context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            if !controller.handleKey(event), code == 36, modifiers.isEmpty {
                editor().insertNewline(nil)
            }
        }
        present()
        print("Frame actual: \(controller.window!.frame), expected: \(frame)")
        expect(controller.window!.frame == frame, "window covers supplied negative-coordinate screen")
        expect(controller.window!.canBecomeKey, "borderless window can become key")
        expect(!controller.window!.styleMask.contains(.fullScreen), "no fullscreen Space")
        let previews = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextField }
            .filter { options.map(\.text).contains($0.stringValue) }
        expect(previews.count == 3 && previews.allSatisfy { $0.maximumNumberOfLines == 2 },
               "each option preview is limited to two lines")
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        for index in options.indices {
            let candidate = button("option-\(index)")
            expect(abs(candidate.frame.width - candidate.superview!.bounds.width) < 1,
                   "candidate \(index) fills choice width")
            expect(candidate.frame.width >= 680, "candidate uses preferred content width minus scroller")
        }
        expect(controller.window!.makeFirstResponder(button("option-1")), "second option accepts keyboard focus")
        expect(button("option-0").state == .on, "keyboard focus alone leaves first option selected")
        key(36, "\r")
        expect(editor().string == "Second option", "Return opens focused option instead of previous selection")
        expect(submissions.isEmpty && cancellations == 0, "focused option Return only opens editor")
        controller.dismiss()
        present()
        _ = controller.window!.makeFirstResponder(nil)
        key(125, "\u{f701}")
        expect(button("option-1").state == .on, "down arrow selects second option")
        key(36, "\r")
        expect(editor().string == "Second option", "Return opens selected full text")
        editor().string = "Friendly draft"
        button("back").performClick(nil)
        button("option-0").performClick(nil)
        editor().string = "Direct draft"
        key(53, "\u{1b}")
        button("option-1").performClick(nil)
        expect(editor().string == "Friendly draft", "back preserves per-option draft")
        editor().setSelectedRange(NSRange(location: editor().string.utf16.count, length: 0))
        key(36, "\r")
        expect(editor().string == "Friendly draft\n", "ordinary Return inserts newline")
        expect(submissions.isEmpty, "ordinary Return never submits")
        editor().string = " \n\t "
        button("submit").performClick(nil)
        expect(submissions.isEmpty, "blank text rejected")
        expect(descendants(controller.window!.contentView!).compactMap { $0 as? NSTextView }
            .contains { $0.string == "请输入改写内容。" }, "blank rejection visible inline")
        editor().string = "Edited submission\nwith newline"
        key(36, "\r", modifiers: .command)
        key(36, "\r", modifiers: .command)
        button("submit").performClick(nil)
        expect(submissions == ["Edited submission\nwith newline"], "submit fires once with exact edited text")
        expect(!button("submit").isEnabled && !button("cancel").isEnabled && !editor().isEditable,
               "busy disables submit, cancel and editing")
        button("back").performClick(nil)
        button("close").performClick(nil)
        controller.window!.performClose(nil)
        controller.window!.close()
        key(53, "\u{1b}")
        expect(cancellations == 0 && !controller.window!.isVisible, "busy guards every user exit")
        controller.showError("Synthetic write failure")
        expect(!button("cancel").isEnabled, "error does not silently clear busy")
        controller.setBusy(false)
        button("back").performClick(nil)
        button("option-0").performClick(nil)
        expect(editor().string == "Direct draft", "other option draft remains independent")
        controller.dismiss()
        expect(cancellations == 0 && !controller.window!.isVisible, "programmatic dismiss is not cancellation")
        present()
        controller.setBusy(true)
        key(36, "\r")
        expect(button("submit").isHidden, "busy list cannot open editor")
        controller.dismiss()
        expect(cancellations == 0, "success can dismiss while busy")
        present()
        key(53, "\u{1b}")
        button("cancel").performClick(nil)
        expect(cancellations == 1, "Escape cancellation exactly once")
        present()
        controller.window!.performClose(nil)
        expect(cancellations == 2, "window close cancels")
        present()
        button("cancel").performClick(nil)
        expect(cancellations == 3, "visible cancel button works")
        present()
        button("close").performClick(nil)
        expect(cancellations == 4, "visible close button works")
        present()
        expect(controller.window!.makeFirstResponder(button("cancel")), "Cancel accepts keyboard focus")
        key(36, "\r")
        expect(cancellations == 5 && !controller.window!.isVisible,
               "Return on focused Cancel cancels instead of opening editor")
        expect(submissions.count == 1, "Cancel Return never submits")
        controller.present(original: "Synthetic original", appName: "Fixture", options: options,
                           screenFrame: NSRect(x: 0, y: 0, width: 640, height: 480),
                           onSubmit: { submissions.append($0) }, onCancel: { cancellations += 1 })
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let root = controller.window!.contentView!
        for id in ["close", "cancel", "open"] {
            let control = button(id)
            expect(root.bounds.contains(control.convert(control.bounds, to: root)),
                   "small-screen \(id) stays within window")
        }
        button("option-0").performClick(nil)
        root.layoutSubtreeIfNeeded()
        let style = descendants(root).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "简洁直接" && $0.superview?.superview === editor().enclosingScrollView?.superview }!
        expect(abs(style.convert(style.bounds, to: root).minX + style.alignmentRectInsets.left - editor().enclosingScrollView!.convert(editor().enclosingScrollView!.bounds, to: root).minX) < 1,
               "editor style label aligns with content leading edge")
        for id in ["close", "cancel", "back", "copy", "submit"] {
            let control = button(id)
            expect(root.bounds.contains(control.convert(control.bounds, to: root)),
                   "small-screen editor \(id) stays within window")
        }
        controller.dismiss()
        if failures == 0 { print("RewriteWindowTests PASS"); exit(0) }
        print("RewriteWindowTests FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
