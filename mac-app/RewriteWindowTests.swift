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
        func card(_ index: Int) -> NSView {
            descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "card-\(index)" }!
        }
        func pick(_ index: Int) { _ = card(index).accessibilityPerformPress() }
        func statusText() -> String {
            (descendants(controller.window!.contentView!).first { $0.identifier?.rawValue == "rewrite-status" } as! NSTextView).string
        }
        present()
        print("Frame actual: \(controller.window!.frame), expected: \(frame)")
        expect(controller.window!.frame == frame, "window covers supplied negative-coordinate screen")
        expect(controller.window!.canBecomeKey, "borderless window can become key")
        expect(!controller.window!.styleMask.contains(.fullScreen), "no fullscreen Space")
        expect(!controller.window!.isOpaque, "window is non-opaque for the scrim")
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let widths = options.indices.map { card($0).frame.width }
        expect(widths.allSatisfy { abs($0 - widths[0]) < 1 }, "three cards have equal width")
        expect(descendants(controller.window!.contentView!).contains { ($0 as? NSTextView)?.string == "Second option" },
               "every option shows its full text without a second stage")
        expect(card(0).isAccessibilitySelected() && !card(1).isAccessibilitySelected(), "first card selected initially")
        expect(editor().string == "First option" && editor().isEditable, "selected card text is the editor")
        expect(button("primary").title == "用「简洁直接」替换", "primary names the selected style")
        pick(1)
        expect(card(1).isAccessibilitySelected() && !card(0).isAccessibilitySelected(), "pressing a card selects it")
        expect(editor().string == "Second option" && button("primary").title == "用「友好自然」替换", "selection moves editor and primary title")
        expect(submissions.isEmpty && cancellations == 0, "selecting never submits or cancels")
        key(124, "\u{f703}")
        expect(card(2).isAccessibilitySelected(), "right arrow selects next card")
        key(123, "\u{f702}")
        key(123, "\u{f702}")
        expect(card(0).isAccessibilitySelected(), "left arrow wraps to previous card")
        pick(1)
        editor().string = "Friendly draft"
        pick(0)
        editor().string = "Direct draft"
        pick(1)
        expect(editor().string == "Friendly draft", "per-option draft preserved")
        pick(0)
        expect(editor().string == "Direct draft", "other option draft remains independent")
        pick(1)
        editor().setSelectedRange(NSRange(location: editor().string.utf16.count, length: 0))
        key(36, "\r")
        expect(editor().string == "Friendly draft\n", "ordinary Return inserts newline")
        expect(submissions.isEmpty, "ordinary Return never submits")
        editor().string = " \n\t "
        button("primary").performClick(nil)
        expect(submissions.isEmpty, "blank text rejected")
        expect(statusText() == "请输入改写内容。", "blank rejection visible inline")
        editor().string = "Edited submission\nwith newline"
        key(36, "\r", modifiers: .command)
        key(36, "\r", modifiers: .command)
        button("primary").performClick(nil)
        expect(submissions == ["Edited submission\nwith newline"], "submit fires once with exact edited text")
        expect(!button("primary").isEnabled && !button("cancel").isEnabled && !editor().isEditable,
               "busy disables replace, cancel and editing")
        expect(statusText().contains("正在确认并替换"), "busy shows a clear status")
        pick(0)
        expect(card(1).isAccessibilitySelected(), "busy ignores card selection")
        key(124, "\u{f703}")
        expect(card(1).isAccessibilitySelected(), "busy ignores arrow keys")
        controller.window!.performClose(nil)
        controller.window!.close()
        button("cancel").performClick(nil)
        key(53, "\u{1b}")
        expect(cancellations == 0 && !controller.window!.isVisible, "busy guards every user exit")
        controller.showError("Synthetic write failure")
        expect(!button("cancel").isEnabled, "error does not silently clear busy")
        controller.setBusy(false)
        expect(button("cancel").isEnabled, "after failure the user can leave")
        controller.showError("Second failure")
        expect(statusText() == "Second failure" && button("cancel").isEnabled, "error text readable and keeps a way out")
        controller.dismiss()
        expect(cancellations == 0 && !controller.window!.isVisible, "programmatic dismiss is not cancellation")
        present()
        expect(statusText().contains("⌘↩ 替换") && statusText().contains("不会发送"), "footer hint shown")
        controller.setBusy(true)
        key(36, "\r", modifiers: .command)
        expect(submissions.count == 1, "busy rejects keyboard replace")
        controller.dismiss()
        expect(cancellations == 0, "success can dismiss while busy")
        present()
        key(53, "\u{1b}")
        expect(cancellations == 1, "Escape cancellation exactly once")
        present()
        controller.window!.performClose(nil)
        expect(cancellations == 2, "window close cancels")
        present()
        button("cancel").performClick(nil)
        expect(cancellations == 3, "visible cancel button works")
        present()
        expect(controller.window!.makeFirstResponder(button("cancel")), "Cancel accepts keyboard focus")
        key(36, "\r")
        expect(cancellations == 4 && !controller.window!.isVisible, "Return on focused Cancel cancels")
        expect(submissions.count == 1, "Cancel Return never submits")
        controller.present(original: "Synthetic original", appName: "Fixture", options: Array(options.prefix(2)),
                           screenFrame: NSRect(x: 0, y: 0, width: 640, height: 480),
                           onSubmit: { submissions.append($0) }, onCancel: { cancellations += 1 })
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let root = controller.window!.contentView!
        let two = [card(0).frame.width, card(1).frame.width]
        expect(abs(two[0] - two[1]) < 1 && descendants(root).filter { $0.identifier?.rawValue.hasPrefix("card-") == true }.count == 2,
               "fewer options mean fewer cards")
        for id in ["cancel", "primary"] {
            let control = button(id)
            expect(root.bounds.contains(control.convert(control.bounds, to: root)), "small-screen \(id) stays within window")
        }
        let panel = card(0).superview!.superview!.superview!.superview!
        expect(root.bounds.contains(panel.convert(panel.bounds, to: root)), "small-screen panel stays within window")
        // Accessibility, card keyboard/mouse paths and IME safety.
        present()
        expect(card(0).accessibilityRole() == .radioButton, "card exposes radio button role")
        expect((card(0).accessibilityValue() as? Int) == 1 && (card(1).accessibilityValue() as? Int) == 0, "card value reflects selection")
        expect((card(1).accessibilityLabel() ?? "").contains("友好自然") && (card(1).accessibilityLabel() ?? "").contains("给同事"), "card label is style plus hint")
        pick(2)
        expect((card(2).accessibilityValue() as? Int) == 1 && (card(1).accessibilityValue() as? Int) == 0, "value refreshes on selection change")
        _ = controller.window!.makeFirstResponder(card(1))
        func mouse(_ clickCount: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0,
                               clickCount: clickCount, pressure: 1)!
        }
        card(0).mouseDown(with: mouse(1))
        card(0).mouseDown(with: mouse(2))
        expect(card(0).isAccessibilitySelected() && submissions.count == 1, "double-click selects but never submits")
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: controller.window!.windowNumber, context: nil, characters: " ",
                                     charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        card(1).keyDown(with: space)
        expect(card(1).isAccessibilitySelected() && submissions.count == 1, "Space on a card selects without submitting")
        _ = controller.window!.makeFirstResponder(card(1))
        key(36, "\r")
        expect(submissions.count == 1 && cancellations == 4, "Return on a card only enters edit")
        class Composing: NSTextView { override func hasMarkedText() -> Bool { true } }
        let composing = Composing()
        controller.window!.contentView!.addSubview(composing)
        _ = controller.window!.makeFirstResponder(composing)
        key(53, "\u{1b}")
        key(36, "\r", modifiers: .command)
        expect(cancellations == 4 && submissions.count == 1, "Esc and ⌘↩ pass through to the IME while composing")
        composing.removeFromSuperview()
        _ = controller.window!.makeFirstResponder(nil)
        key(53, "\u{1b}")
        expect(cancellations == 5, "Esc cancels again once composition ends")
        controller.dismiss()
        let longOption = RewriteOption(style: .direct, text: String(repeating: "很长的改写内容。", count: 200))
        controller.present(original: String(repeating: "很长的原文。", count: 300), appName: "Fixture", options: [longOption],
                           screenFrame: frame, onSubmit: { _ in }, onCancel: {})
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        expect(root.bounds.contains(button("primary").convert(button("primary").bounds, to: root)), "long content keeps footer on screen")
        expect(editor().string.count == longOption.text.count, "long option is not truncated")
        controller.dismiss()
        if failures == 0 { print("RewriteWindowTests PASS"); exit(0) }
        print("RewriteWindowTests FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
