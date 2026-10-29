import AppKit

/// swiftc -swift-version 6 -parse-as-library mac-app/Sources/benice/TriggerController.swift \
///     mac-app/Sources/benice/StatusPill.swift mac-app/Sources/benice/NoAXMode.swift \
///     mac-app/NoAXModeTests.swift -o /tmp/benice-noax
/// Private named pasteboards only: the user's clipboard is never read or written.
@main
struct NoAXModeTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ c: Bool, _ m: String) { if !c { failures += 1; print("SELFTEST FAIL: \(m)") } }
        func board() -> NSPasteboard { NSPasteboard(name: .init("com.benice.selftest.\(UUID().uuidString)")) }
        let rich = NSPasteboard.PasteboardType("com.benice.selftest.rich")

        // Mode.
        expect(AccessMode(trusted: true) == .accessibility, "trusted = accessibility")
        expect(AccessMode(trusted: false) == .noAccessibility, "untrusted = no-accessibility")

        // B: rewrite lands on the clipboard; restore brings back every original type.
        let pb = board()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("draft", forType: .string)
        item.setData(Data([1, 2, 3]), forType: rich)
        pb.writeObjects([item])
        let b = ClipboardRewriter(pasteboard: pb) { "nice " + $0 }
        try? await b.run()
        expect(pb.string(forType: .string) == "nice draft", "rewrite copied: \(String(describing: pb.string(forType: .string)))")
        expect(b.canRestore, "restore offered")
        expect(b.restore(), "restore succeeds")
        expect(pb.string(forType: .string) == "draft" && pb.data(forType: rich) == Data([1, 2, 3]), "all types restored")
        expect(!b.restore(), "restore is one-shot")

        // B: a copy made after ours is never clobbered by restore.
        try? await b.run()
        pb.clearContents()
        pb.setString("user copied later", forType: .string)
        expect(!b.canRestore && !b.restore(), "restore refused after a newer copy")
        expect(pb.string(forType: .string) == "user copied later", "newer copy kept")

        // B: clipboard changes while the model runs: nothing is written.
        nonisolated(unsafe) let racing = board()
        racing.clearContents()
        racing.setString("draft", forType: .string)
        let raced = ClipboardRewriter(pasteboard: racing) { text in
            await MainActor.run { racing.clearContents(); _ = racing.setString("other", forType: .string) }
            return "nice " + text
        }
        do { try await raced.run(); expect(false, "race should throw") } catch {
            expect(error as? HandoffError == .clipboardChanged, "race error: \(error)")
        }
        expect(racing.string(forType: .string) == "other" && !raced.canRestore, "racing copy kept")

        // B: empty clipboard never calls the model.
        let empty = board()
        empty.clearContents()
        nonisolated(unsafe) var calls = 0
        let none = ClipboardRewriter(pasteboard: empty) { calls += 1; return $0 }
        do { try await none.run(); expect(false, "empty should throw") } catch {
            expect(error as? HandoffError == .noClipboardText && calls == 0, "empty clipboard: \(error), calls \(calls)")
        }

        // A: service handler input → output.
        let service = NoAXController(pasteboard: board()) { "nice " + $0 }
        let sp = board()
        sp.clearContents()
        sp.setString("draft", forType: .string)
        expect(service.handleService(sp) == nil, "service succeeds")
        expect(sp.string(forType: .string) == "nice draft", "service returns rewrite")

        let failing = NoAXController(pasteboard: board()) { _ in throw HandoffError.needsSetup }
        sp.clearContents()
        sp.setString("draft", forType: .string)
        expect(failing.handleService(sp) == HandoffError.needsSetup.message, "service reports model error")
        expect(sp.string(forType: .string) == "draft", "failed service leaves selection")

        sp.clearContents()
        sp.setString("  \n", forType: .string)
        expect(service.handleService(sp) == HandoffError.noSelection.message, "blank selection refused")

        let slow = NoAXController(pasteboard: board()) { try await Task.sleep(for: .seconds(5)); return $0 }
        sp.clearContents()
        sp.setString("draft", forType: .string)
        expect(slow.handleService(sp, timeout: 0.2) == HandoffError.timedOut.message, "service times out")
        expect(sp.string(forType: .string) == "draft", "timed-out service leaves selection")

        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
