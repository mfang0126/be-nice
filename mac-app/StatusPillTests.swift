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
        c.show("已替换", target: field, undo: { undone += 1 }, cancel: nil)
        expect(c.frame.minY >= field.maxY && c.frame.maxX == field.maxX, "pill sits above field, right-aligned: \(c.frame)")
        expect(c.frame.height == 36, "single-line height 36")
        expect(c.buttonTitles == ["撤销替换"], "replaced shows only 撤销替换: \(c.buttonTitles)")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "撤销替换" }?.performClick(nil)
        expect(undone == 1, "undo callback fires")

        // Fallback: empty anchor → bottom-right of the screen.
        c.show("已恢复原文", target: .zero, undo: nil, cancel: nil)
        let vis = (NSScreen.screens.first { $0.frame.intersects(.zero) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        expect(c.frame.maxX <= vis.maxX && c.frame.minY == vis.minY + 24, "fallback bottom-right: \(c.frame) vs \(vis)")
        expect(c.buttonTitles == ["收起"], "info shows only 收起")

        // Loading: spinner + 取消 only, even when an undo exists.
        c.show("正在准备改写…", target: field, undo: { undone += 1 }, cancel: { cancelled += 1 })
        expect(c.buttonTitles == ["取消"], "loading shows only 取消: \(c.buttonTitles)")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "取消" }?.performClick(nil)
        expect(cancelled == 1, "cancel callback fires")

        // Error: 收起 hides the pill.
        c.show("替换失败：目标输入框已变化，请重试或取消。", target: field, undo: nil, cancel: nil)
        expect(c.buttonTitles == ["收起"], "error shows 收起")
        buttons(c.contentView!).first { $0.accessibilityLabel() == "收起" }?.performClick(nil)

        // Width bounds.
        let short = RewriteStatusController.size(message: "好", buttons: ["收起"])
        expect(short.width == 140 && short.height == 36, "min width: \(short)")
        let long = RewriteStatusController.size(message: String(repeating: "很长的错误信息", count: 20), buttons: ["收起"])
        expect(long.width == 420 && long.height == 52, "max width, two lines: \(long)")

        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
