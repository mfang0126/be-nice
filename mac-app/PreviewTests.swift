import AppKit

@main
struct PreviewTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: 440, height: 280)
        let below = PreviewLayout.frame(
            anchor: CGRect(x: 100, y: 500, width: 400, height: 100), size: size, visibleFrame: screen)
        expect(below.origin == CGPoint(x: 100, y: 212), "card appears below the input with an 8-point gap")
        let above = PreviewLayout.frame(
            anchor: CGRect(x: 100, y: 100, width: 400, height: 50), size: size, visibleFrame: screen)
        expect(above.origin == CGPoint(x: 100, y: 158), "card flips above when space below is insufficient")
        let clamped = PreviewLayout.frame(
            anchor: CGRect(x: 1_300, y: 500, width: 100, height: 50), size: size, visibleFrame: screen)
        expect(clamped.origin == CGPoint(x: 992, y: 212), "card stays inside the screen's visible frame")

        if failures == 0 { print("PreviewTests PASS"); exit(0) }
        print("PreviewTests FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
