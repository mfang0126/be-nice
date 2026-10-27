import AppKit
import Darwin
import Foundation

/// Deterministic self-check for the M1 write-back core. No live AX calls, no
/// network, no app writes. Run from the repository root:
///
///     swiftc -swift-version 6 -parse-as-library \
///         mac-app/Sources/benice/WriteBack.swift \
///         mac-app/Sources/benice/ModelClient.swift \
///         mac-app/WriteBackTests.swift \
///         -o /tmp/benice-writeback-tests
///     /tmp/benice-writeback-tests
@main
struct WriteBackTests {
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                print("SELFTEST FAIL: \(message)")
            }
        }

        let selectionRange = NSRange(location: 0, length: 5)

        func controller(_ access: FakeAccess,
                        _ suggestion: String = "HELLO") -> WriteBackController {
            WriteBackController(access: access,
                                client: ImmediateClient(suggestion: suggestion),
                                support: fixtureSupport)
        }

        /// TextEdit is selection-capable in the fixture policy (production is Slack only).
        func selectionSetup() -> FakeAccess {
            let access = FakeAccess()
            access.storedValue = "hello world"
            access.storedRange = selectionRange
            return access
        }

        /// Safari is whole-value-only in the fixture policy (production is Slack only).
        func wholeSetup() -> FakeAccess {
            let access = FakeAccess()
            access.bundles[100] = "com.apple.Safari"
            access.storedValue = "hello world"
            access.storedRange = NSRange(location: 0, length: 0)
            return access
        }

        // Activating rewrite UI captures first and submits edited text later.
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 100, bundleID: "com.apple.TextEdit",
                                         element: access.element, forceWholeValue: false)
            expect(await core.prepare(target: target) == .ready(SuggestionPreview(
                original: "hello", suggestion: "hello", mode: .selection)), "prepare captures exact selection")
            expect(access.writes.isEmpty, "prepare never writes")
            expect(await core.apply(replacement: "  ") == .failed(.emptySuggestion), "blank edit rejected")
            expect(await core.apply(replacement: "hello") == .failed(.noChange), "unchanged edit rejected")
            expect(await core.apply(replacement: "Greetings") == .applied, "edited candidate applied")
            expect(access.storedValue == "Greetings world", "edited text replaces only captured selection")
            await core.cancel()
            expect(await core.undoAvailable, "closing preview preserves undo")
            expect(await core.undo() == .restored, "edited candidate undo restores original")
        }
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 100, bundleID: "com.apple.TextEdit",
                                         element: access.element, forceWholeValue: false)
            _ = await core.prepare(target: target)
            expect(await core.validatePreparedTarget() == nil, "captured target valid before preview")
            access.storedValue = "new user text"
            expect(await core.validatePreparedTarget() == .targetChanged(.valueChanged),
                   "target mutation rejected before presentation")
            if case .failed = await core.apply(replacement: "Greetings") {} else {
                expect(false, "changed target refuses edited candidate")
            }
            expect(access.writes.isEmpty, "target change never writes")
        }

        // Trial capture explicitly uses the whole draft; legacy prepare above remains selection-based.
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 100, bundleID: "com.apple.TextEdit",
                                         element: access.element, forceWholeValue: true)
            expect(await core.prepare(target: target) == .ready(SuggestionPreview(
                original: "hello world", suggestion: "hello world", mode: .wholeValue)),
                   "trial prepare captures whole draft despite selected text")
            expect(!access.calls.contains("range"), "whole draft capture never reads selection")
            expect(await core.apply(replacement: "Whole rewritten draft") == .applied,
                   "whole draft candidate applies")
            expect(access.storedValue == "Whole rewritten draft", "whole draft replaces all text")
            _ = await core.prepare(target: target)
            access.storedValue = "later user edit"
            expect(await core.validatePreparedTarget() == .targetChanged(.valueChanged),
                   "later generation detects stale draft")
            expect(await core.apply(replacement: "Do not write") == .failed(.targetChanged(.valueChanged)),
                   "apply rechecks even after generation validation")
            await core.cancel()
            expect(await core.undoAvailable, "stale generation and cancellation preserve prior undo")
            expect(await core.undo() == .failed(.targetChanged(.valueChanged)),
                   "undo refuses subsequent user edits")
            access.storedValue = "Whole rewritten draft"
            expect(await core.undo() == .restored, "prior undo still restores exact original")
            expect(access.storedValue == "hello world", "whole draft undo preserves original")
        }

        // 1. Selection mode: preview, apply, verified undo.
        do {
            let access = selectionSetup()
            let core = controller(access)
            let outcome = await core.requestPreview()
            expect(outcome == .ready(SuggestionPreview(original: "hello",
                                                       suggestion: "HELLO",
                                                       mode: .selection)),
                   "selection preview uses the selected UTF-16 text")
            expect(await core.state == .idle, "preview leaves state idle")

            expect(await core.apply() == .applied, "selection apply verified")
            expect(access.storedValue == "HELLO world", "selection replaced in value")
            expect(access.writes.count == 1, "apply performs exactly one text write")
            expect(access.writes.first?.0 == .selectedText, "selection uses AXSelectedText")
            expect(await core.state == .verified, "state verified after apply")
            expect(await core.undoAvailable, "undo available after apply")

            expect(await core.undo() == .restored, "selection undo verified")
            expect(access.storedValue == "hello world", "undo restores original value")
            expect(access.writes.count == 2, "undo performs exactly one more text write")
            expect(access.rangeWrites == [selectionRange, selectionRange],
                   "apply and undo each reselect their exact replacement range")
            expect(await core.undoAvailable == false, "undo cleared after success")
        }

        // 2. Whole-value mode (Safari): no selection required, undo via AXValue.
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            let outcome = await core.requestPreview()
            expect(outcome == .ready(SuggestionPreview(original: "hello world",
                                                       suggestion: "hello, world.",
                                                       mode: .wholeValue)),
                   "whole-value-only app uses whole value")
            expect(access.calls.contains("range") == false,
                   "whole-value-only app does not read AXSelectedTextRange")
            expect(await core.apply() == .applied, "whole-value apply verified")
            expect(access.storedValue == "hello, world.", "whole value replaced")
            expect(access.writes.count == 1 && access.writes.first?.0 == .value,
                   "whole value uses exactly one AXValue write")

            expect(await core.undo() == .restored, "whole-value undo verified")
            expect(access.storedValue == "hello world", "whole-value undo restores original")
            expect(access.writes.count == 2 && access.writes.last?.0 == .value,
                   "whole-value undo performs one AXValue write")
            expect(access.rangeWrites.isEmpty, "whole-value undo does not touch selection")
        }

        // 3. Whole-value-only app with a nonempty selection is still whole.
        do {
            let access = wholeSetup()
            access.storedRange = NSRange(location: 0, length: 5)
            let core = controller(access, "hello, world.")
            let outcome = await core.requestPreview()
            expect(outcome == .ready(SuggestionPreview(original: "hello world",
                                                       suggestion: "hello, world.",
                                                       mode: .wholeValue)),
                   "nonempty selection does not force selection mode for whole-only apps")
        }

        // 4. Forced whole-value mode on a selection-capable app skips range.
        do {
            let access = selectionSetup()
            let core = controller(access, "hello, world.")
            let target = WriteBackTarget(pid: 100,
                                         bundleID: "com.apple.TextEdit",
                                         element: access.element,
                                         forceWholeValue: true)
            let outcome = await core.requestPreview(target: target)
            expect(outcome == .ready(SuggestionPreview(original: "hello world",
                                                       suggestion: "hello, world.",
                                                       mode: .wholeValue)),
                   "forceWholeValue overrides a nonempty selection")
        }

        // 5. Request identity: PID, bundle and element are checked before reads.
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 999,
                                         bundleID: "com.apple.TextEdit",
                                         element: access.element,
                                         forceWholeValue: false)
            let outcome = await core.requestPreview(target: target)
            expect(outcome == .failed(.targetChanged(.notFrontmost)),
                   "request PID mismatch is refused")
            expect(access.calls.contains("value") == false,
                   "PID mismatch reads no text")
        }
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 100,
                                         bundleID: "com.apple.Notes",
                                         element: access.element,
                                         forceWholeValue: false)
            let outcome = await core.requestPreview(target: target)
            expect(outcome == .failed(.targetChanged(.bundleChanged)),
                   "request bundle mismatch is refused")
            expect(access.calls.contains("value") == false,
                   "bundle mismatch reads no text")
        }
        do {
            let access = selectionSetup()
            let core = controller(access)
            let target = WriteBackTarget(pid: 100,
                                         bundleID: "com.apple.TextEdit",
                                         element: access.otherElement,
                                         forceWholeValue: false)
            let outcome = await core.requestPreview(target: target)
            expect(outcome == .failed(.targetChanged(.focusChanged)),
                   "request element mismatch is refused")
            expect(access.calls.contains("value") == false,
                   "element mismatch reads no text")
        }

        // 6. Stale response after cancel is discarded; cancel cancels the task.
        do {
            let access = selectionSetup()
            let client = BlockingClient()
            let core = WriteBackController(access: access, client: client, support: fixtureSupport)
            let request = Task { await core.requestPreview() }
            await client.waitUntilStarted()

            expect(await core.requestPreview() == .failed(.busy),
                   "second request while one is in flight is busy")

            await core.cancel()
            client.respond("HELLO")
            expect(await request.value == .stale, "superseded response is stale")
            expect(await core.state == .idle, "stale response does not change state")
            expect(await core.preview == nil, "stale response produces no preview")
            expect(access.writes.isEmpty, "stale response performs no write")
        }

        // 7. User edit while the model call is suspended is detected.
        do {
            let access = wholeSetup()
            let client = BlockingClient()
            let core = WriteBackController(access: access, client: client, support: fixtureSupport)
            let request = Task { await core.requestPreview() }
            await client.waitUntilStarted()
            access.storedValue = "hello world edited"
            client.respond("hello, world.")
            expect(await request.value == .failed(.targetChanged(.valueChanged)),
                   "edit during model request invalidates the preview")
            expect(await core.preview == nil, "no preview after suspended edit")
            expect(access.writes.isEmpty, "suspended edit performs no write")
        }

        // 8. Changed value between preview and apply is refused; preview cleared.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.storedValue = "hello world!"
            let apply = await core.apply()
            expect(apply == .failed(.targetChanged(.valueChanged)),
                   "changed value blocks apply")
            expect(access.writes.isEmpty, "changed value performs no write")
            expect(await core.preview == nil, "failed apply clears the preview")
            expect(await core.apply() == .failed(.nothingToApply),
                   "failed apply is not retryable without a new request")
        }

        // 9. Apply-time Secure Input is refused; no possible-write record.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.secureInput = true
            expect(await core.apply() == .failed(.secureInput),
                   "Secure Input at apply time blocks the write")
            expect(access.writes.isEmpty, "Secure Input performs no write")
            expect(await core.undoAvailable == false,
                   "pre-write failure creates no undo record")
            expect(await core.preview == nil, "Secure Input failure clears the preview")
        }

        // 10. Changed selection and focus between preview and apply are refused.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.storedRange = NSRange(location: 0, length: 0)
            expect(await core.apply() == .failed(.targetChanged(.selectionChanged)),
                   "changed selection blocks selection apply")
            expect(access.writes.isEmpty, "changed selection performs no write")
        }
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.focused = access.otherElement
            expect(await core.apply() == .failed(.targetChanged(.focusChanged)),
                   "element identity change blocks apply")
            expect(access.writes.isEmpty, "focus change performs no write")
        }

        // 11. Asynchronous read-back: old value for a while, then expected.
        do {
            let access = wholeSetup()
            access.applyOnSet = false
            // capture, preview recheck, apply recheck, read-back stale, settled
            access.valueReads = ["hello world", "hello world", "hello world",
                                 "hello world", "hello, world."]
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied,
                   "async setter confirmed by bounded read-back")
            expect(access.writes.count == 1, "async read-back never rewrites")
        }

        // 12. Unconfirmed apply keeps a possible-write undo record.
        do {
            let access = wholeSetup()
            access.applyOnSet = false
            access.valueReads = ["hello world", "hello world", "hello world"]
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            let apply = await core.apply()
            expect(apply == .failed(.writeUnconfirmed(0)),
                   "unobserved write is unconfirmed")
            expect(access.writes.count == 1, "unconfirmed write is not retried")
            expect(await core.undoAvailable,
                   "unconfirmed write keeps a possible-write undo record")
            expect(WriteBackFailure.writeUnconfirmed(0).message.contains("may have gone through"),
                   "unconfirmed message warns that a write may have occurred")

            // Simulate the late write becoming visible, then undo it.
            access.applyOnSet = true
            access.storedValue = "hello, world."
            access.storedRange = NSRange(location: 12, length: 0)
            expect(await core.undo() == .restored, "possible write can be undone")
            expect(access.storedValue == "hello world", "possible-write undo restores original")
            expect(access.writes.count == 2, "undo of possible write is one more write")
            expect(await core.undoAvailable == false, "undo record cleared after restore")
        }

        // 13. Third value during apply: writeUnexpected, possible-write record.
        do {
            let access = wholeSetup()
            access.applyOnSet = false
            access.valueReads = ["hello world", "hello world", "hello world", "garbage"]
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.writeUnexpected),
                   "third value stops the write")
            expect(access.writes.count == 1, "third value is not retried")
            expect(await core.undoAvailable, "third value keeps a possible-write record")
            expect(WriteBackFailure.writeUnexpected.message.contains("may have gone through"),
                   "unexpected message warns that a write may have occurred")
        }

        // 14. Unreadable read-back stops and keeps the possible-write record.
        do {
            let access = wholeSetup()
            access.applyOnSet = false
            access.valueReads = ["hello world", "hello world", "hello world", nil]
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.writeUnexpected),
                   "unreadable read-back stops the write")
            expect(access.writes.count == 1, "unreadable read-back is not retried")
            expect(await core.undoAvailable, "unreadable read-back keeps an undo record")
        }

        // 15. Undo accepts an already-restored value without writing.
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply")
            access.storedValue = "hello world"
            expect(await core.undo() == .restored, "already-restored value is accepted")
            expect(access.writes.count == 1, "already-restored undo performs no write")
            expect(await core.undoAvailable == false, "already-restored clears the record")
        }

        // 16. Undo refuses a third value.
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply")
            access.storedValue = "user edit"
            expect(await core.undo() == .failed(.targetChanged(.valueChanged)),
                   "third value blocks undo")
            expect(access.writes.count == 1, "refused undo performs no write")
            expect(await core.undoAvailable, "refused undo keeps the record")
        }

        // 17. Unconfirmed undo keeps the record.
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply")
            access.applyOnSet = false
            expect(await core.undo() == .failed(.writeUnconfirmed(0)),
                   "unobserved undo is unconfirmed")
            expect(access.writes.count == 2, "unconfirmed undo is not retried")
            expect(await core.undoAvailable, "unconfirmed undo keeps the record")
        }

        // 18. Selection undo requires AXSelectedTextRange and a verified range set.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply")
            access.rangeSetError = -25204
            expect(await core.undo() == .failed(.notSettable("selectedTextRange")),
                   "range setter error blocks selection undo")
            expect(access.writes.count == 1, "range failure performs no undo text write")
            expect(await core.undoAvailable, "range failure keeps the record")
        }
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply")
            access.applyOnRangeSet = false
            expect(await core.undo() == .failed(.selectionUnavailable),
                   "unverified range selection blocks selection undo")
            expect(access.writes.count == 1, "unverified range performs no undo text write")
        }

        // 19. Selection mode requires settable AXSelectedTextRange before apply.
        do {
            let access = selectionSetup()
            access.settable = [.value, .selectedText]
            let core = controller(access)
            let outcome = await core.requestPreview()
            expect(outcome == .failed(.notSettable("selectedTextRange")),
                   "selection mode requires settable AXSelectedTextRange")
        }

        // 20. Overflow-safe UTF-16 range validation.
        do {
            let access = selectionSetup()
            access.storedRange = NSRange(location: Int.max, length: Int.max)
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.selectionUnavailable),
                   "overflowing range is rejected without crashing")
            expect(access.writes.isEmpty, "overflowing range performs no write")
        }
        do {
            let access = selectionSetup()
            access.storedRange = NSRange(location: Int.max - 1, length: 5)
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.selectionUnavailable),
                   "range longer than the value is rejected")
        }

        // 21. No-op suggestion is rejected without writing.
        do {
            let access = selectionSetup()
            let core = controller(access, "hello")
            expect(await core.requestPreview() == .failed(.noChange),
                   "identical suggestion is a no-op")
            expect(await core.preview == nil, "no preview for a no-op suggestion")
            expect(access.writes.isEmpty, "no-op suggestion performs no write")
        }

        // 22. Policy: unsupported, excluded and non-text targets.
        do {
            let access = selectionSetup()
            access.bundles[100] = "com.example.Unverified"
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.unsupportedApp("com.example.Unverified")),
                   "unverified bundle is unsupported")
            expect(access.calls.contains("value") == false,
                   "unsupported bundle reads no text")
        }
        do {
            let access = selectionSetup()
            access.bundles[100] = "com.microsoft.VSCode"
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.excludedApp("com.microsoft.VSCode")),
                   "VS Code is explicitly excluded")
            expect(access.calls.contains("value") == false, "VS Code reads no text")
        }
        do {
            let access = selectionSetup()
            access.bundles[100] = "com.apple.Terminal"
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.excludedApp("com.apple.Terminal")),
                   "Terminal is excluded")
            expect(access.calls.contains("value") == false, "Terminal reads no text")
        }
        do {
            let access = wholeSetup()
            access.roleValue = "AXWebArea"
            let core = controller(access)
            expect(await core.requestPreview() == .failed(.notTextTarget("AXWebArea")),
                   "AXWebArea is not a text target")
        }

        // 23. Secure Input and secure fields are rejected before text reads.
        do {
            let access = selectionSetup()
            access.secureInput = true
            expect(await controller(access).requestPreview() == .failed(.secureInput),
                   "Secure Input blocks capture")
            expect(access.calls.contains("value") == false, "Secure Input reads no text")
        }
        do {
            let access = selectionSetup()
            access.roleValue = "AXSecureTextField"
            expect(await controller(access).requestPreview() == .failed(.secureField),
                   "secure field blocks capture")
            expect(access.calls.contains("value") == false, "secure field reads no text")
        }

        // 24. Empty suggestion is rejected; nonpositive read-back interval is clamped.
        do {
            let access = selectionSetup()
            let core = controller(access, "   \n")
            expect(await core.requestPreview() == .failed(.emptySuggestion),
                   "empty suggestion rejected")
            expect(await core.preview == nil, "no preview for empty suggestion")
        }
        do {
            let access = wholeSetup()
            access.applyOnSet = false
            access.valueReads = ["hello world", "hello world", "hello world"]
            let core = WriteBackController(access: access,
                                           client: ImmediateClient(suggestion: "hello, world."),
                                           config: WriteBackConfig(readBackTimeout: 0.01,
                                                                   readBackInterval: -5),
                                           support: fixtureSupport)
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.writeUnconfirmed(0)),
                   "nonpositive read-back interval is clamped and still terminates")
        }

        // 25. Apply re-selects the captured range immediately before writing.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.applyOnRangeSet = false
            expect(await core.apply() == .failed(.selectionUnavailable),
                   "unverified apply-time range blocks selection write")
            expect(access.writes.isEmpty, "range mismatch performs no text write")
            expect(access.rangeWrites == [selectionRange],
                   "apply attempts the captured range once")
            expect(await core.undoAvailable == false,
                   "pre-write range failure creates no recovery record")
        }

        // 26. Cancellation and a failed later request preserve recovery.
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply for cancel")
            await core.cancel()
            expect(await core.undoAvailable, "cancel preserves applied-text undo")
            expect(await core.undo() == .restored, "undo still works after cancel")
        }
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply for failed request")
            access.secureInput = true
            expect(await core.requestPreview() == .failed(.secureInput),
                   "later request fails before reading")
            expect(await core.undoAvailable, "failed later request preserves undo")
            access.secureInput = false
            expect(await core.undo() == .restored, "preserved undo remains usable")
        }

        // 27. Apply/undo recheck app identity; secure subroles block capture.
        do {
            let access = selectionSetup()
            let core = controller(access)
            _ = await core.requestPreview()
            access.frontmost = 200
            access.bundles[200] = "com.apple.TextEdit"
            expect(await core.apply() == .failed(.targetChanged(.notFrontmost)),
                   "app switch blocks apply")
            expect(access.writes.isEmpty, "app switch performs no apply write")
        }
        do {
            let access = wholeSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply for undo identity")
            access.focused = access.otherElement
            expect(await core.undo() == .failed(.targetChanged(.focusChanged)),
                   "focus change blocks undo")
            expect(access.writes.count == 1, "focus change performs no undo write")
            expect(await core.undoAvailable, "refused undo preserves its record")
        }
        do {
            let access = selectionSetup()
            access.subroleValue = "AXSecureTextField"
            expect(await controller(access).requestPreview() == .failed(.secureField),
                   "secure subrole blocks capture")
            expect(access.calls.contains("value") == false,
                   "secure subrole reads no text")
        }

        // 28. Default Electron is limited to the dedicated fixture window.
        do {
            let access = wholeSetup()
            access.bundles[100] = "com.github.Electron"
            access.windowTitle = "A real Electron app"
            expect(await controller(access).requestPreview() == .failed(.unsupportedApp("com.github.Electron")),
                   "non-fixture Electron window is refused")
            expect(!access.calls.contains("value"), "non-fixture Electron reads no document text")
        }
        do {
            let access = wholeSetup()
            access.bundles[100] = "com.github.Electron"
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "dedicated Electron fixture applies")
            expect(await core.undo() == .restored, "dedicated Electron fixture undoes")
        }
        do {
            let access = wholeSetup()
            access.bundles[100] = "com.github.Electron"
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            access.windowTitle = "Another window"
            expect(await core.apply() == .failed(.unsupportedApp("com.github.Electron")),
                   "window-title change blocks Electron apply")
            expect(access.writes.isEmpty, "blocked Electron apply performs no write")
        }
        do {
            let access = wholeSetup()
            access.bundles[100] = "com.github.Electron"
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup Electron apply for undo window check")
            access.windowTitle = "Another window"
            expect(await core.undo() == .failed(.unsupportedApp("com.github.Electron")),
                   "window-title change blocks Electron undo")
            expect(access.writes.count == 1, "blocked Electron undo performs no second write")
        }

        // 29. Slack pins the conversation (window title) per transaction.
        let slack = "com.tinyspeck.slackmacgap"
        func slackSetup(_ title: String? = "Ann (DM) - Work - Slack") -> FakeAccess {
            let access = wholeSetup()
            access.bundles[100] = slack
            access.windowTitle = title
            access.layout = [false]
            access.slackWrites = true
            return access
        }
        do {
            let access = slackSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "Slack apply succeeds with unchanged title")
            expect(access.writes.count == 1, "Slack unchanged-title apply writes once")
            expect(await core.undo() == .restored, "Slack undo succeeds with unchanged title")
        }
        do {
            let access = slackSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            access.windowTitle = "Bob (DM) - Work - Slack"
            expect(await core.apply() == .failed(.targetChanged(.focusChanged)),
                   "Slack apply refused after conversation switch")
            expect(access.writes.isEmpty, "refused Slack apply performs no write")
        }
        do {
            let access = slackSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup Slack apply for undo title check")
            access.windowTitle = "Bob (DM) - Work - Slack"
            expect(await core.undo() == .failed(.targetChanged(.focusChanged)),
                   "Slack undo refused after conversation switch")
            expect(access.writes.count == 1, "refused Slack undo performs no second write")
        }
        for title in [nil, ""] as [String?] {
            let access = slackSetup(title)
            expect(await controller(access).requestPreview() == .failed(.unsupportedApp(slack)),
                   "Slack capture refused with empty window title (\(title ?? "nil"))")
            expect(!access.calls.contains("value"), "empty-title Slack capture reads no text")
        }

        // 30. Slack drafts with emoji/mentions/links are never replaced.
        // Child-role shapes recorded from real Slack composers (S3 diagnosis 10-27).
        expect(WriteBackPolicy.childrenAreRich(["AXStaticText", "AXStaticText", "AXStaticText"]),
               "mention pill (paragraph split into several text runs) is rich")
        expect(WriteBackPolicy.childrenAreRich(["AXGroup", "AXGroup", "AXList", "AXGroup"]),
               "ordered list (AXList) is rich")
        expect(WriteBackPolicy.childrenAreRich(["AXStaticText", "AXImage"]), "emoji is rich")
        expect(WriteBackPolicy.childrenAreRich(["AXStaticText", "AXLink"]), "link is rich")
        expect(!WriteBackPolicy.childrenAreRich(["AXStaticText"]), "single text run is plain")
        expect(!WriteBackPolicy.childrenAreRich(["AXGroup", "AXGroup", "AXGroup"]),
               "plain paragraphs are plain")
        expect(!WriteBackPolicy.childrenAreRich([]), "empty composer is plain")
        expect(WriteBackPolicy.childrenAreRich(["AXGroup", "AXStaticText"],
                                               subroles: ["AXStrongStyleGroup"]),
               "bold at paragraph start (one text run + style group) is rich")
        expect(WriteBackPolicy.childrenAreRich(["AXGroup"], subroles: ["AXCodeStyleGroup"]),
               "fully inline-code paragraph is rich")
        // Paragraph layouts recorded in S3 6.4/6.5/7: Slack rebuilds any of them from
        // U+2028-joined paragraphs, so undo restores Shift+Return lines and blank lines.
        let p = "AXGroup", e = "AXEmptyGroup"
        expect(WriteBackPolicy.paragraphLayout([p, p, p], subroles: ["", e, ""]) == [false, true, false],
               "paragraph layout marks AXEmptyGroup as empty")
        expect(WriteBackPolicy.paragraphLayout([], subroles: []) == [], "no children is an empty layout")
        expect(WriteBackPolicy.paragraphLayout([p, "AXList"], subroles: ["", "AXContentList"]) == nil,
               "non-paragraph child at depth 0 has no layout")
        expect(WriteBackPolicy.paragraphLayout([p, "", p], subroles: ["", e, ""]) == nil,
               "unreadable role at depth 0 has no layout")
        expect(WriteBackPolicy.paragraphLayout([p, p], subroles: ["", e, ""]) == nil,
               "misaligned role/subrole arrays have no layout")
        expect(WriteBackPolicy.paragraphLayout([p], subroles: ["AXStrongStyleGroup"]) == nil,
               "unknown paragraph subrole has no layout")
        let ls = "\u{2028}"
        // AXValue read back for each layout in real Slack (S3 7.5).
        let recorded: [([String], String)] = [
            (["a", "b", "c"], "a\nb\nc"),          // Shift+Return lines
            (["a", "", "b", "", "c"], "a\nb\nc"),  // typed blank lines; setValue("a\nb\nc")
            (["a", "", "", "b"], "a\n\nb"),         // setValue("a\n\nb"); a + 3×U+2028 + b
            (["", "", "a", "", ""], "\n\na\n\n"),   // leading and trailing empties
        ]
        for (paragraphs, value) in recorded {
            expect(WriteBackPolicy.slackValue(paragraphs: paragraphs) == value,
                   "Slack AXValue model matches recorded \(paragraphs)")
            expect(WriteBackPolicy.slackEncoding(value: value, layout: paragraphs.map(\.isEmpty))
                   == paragraphs.joined(separator: ls), "encoding rebuilds recorded \(paragraphs)")
        }
        expect(WriteBackPolicy.slackEncoding(value: "a\nb", layout: [false]) == nil,
               "layout with too few text paragraphs is not encodable")
        expect(WriteBackPolicy.slackEncoding(value: "a\n\nb", layout: [false, true, false]) == nil,
               "AXValue with an extra empty line for the layout is not encodable")
        expect(WriteBackPolicy.slackEncoding(value: "a", layout: []) == nil, "empty layout is not encodable")
        expect(WriteBackPolicy.slackEncoding(suggestion: "x\ny\n\nz\r\nw") == "x\(ls)y\(ls)\(ls)z\(ls)w",
               "suggestion newlines become paragraph breaks")
        expect(WriteBackPolicy.slackNormalized("x\ny\n\nz\n\n\nw") == "x\ny\nz\n\nw",
               "suggestion reads back with Slack's AXValue rule")
        for (draft, layout) in [("a\nb\nc", [false, false, false]), ("a\nb", [false, true, false]),
                                ("a", [false]), ("\na\n\nb\n", [true, false, true, true, false, true])] {
            let access = slackSetup()
            access.storedValue = draft
            access.layout = layout
            let core = controller(access, "x\ny\n\nz")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "Slack replace applies over \(layout)")
            expect(access.writes.last?.1 == "x\(ls)y\(ls)\(ls)z" && access.storedValue == "x\ny\nz"
                   && access.layout == [false, false, true, false], "replace keeps soft and blank lines")
            expect(await core.undo() == .restored, "Slack undo restores \(layout)")
            expect(access.storedValue == draft && access.layout == layout, "undo rebuilds layout \(layout)")
        }
        do {
            let access = slackSetup()
            access.storedValue = "a\nb"
            access.layout = [false, false]
            access.slackPendingReads = 3
            let core = controller(access, "x\ny")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "Slack apply waits through the raw U+2028 value")
            expect(await core.undo() == .restored, "Slack undo waits through the raw U+2028 value")
            expect(access.storedValue == "a\nb" && access.layout == [false, false], "undo rebuilt soft lines")
            access.slackPendingReads = 0
            let other = controller(access, "x\ny")
            _ = await other.requestPreview()
            access.applyOnSet = false
            access.valueReads = ["a\nb", "x y"]
            expect(await other.apply() == .failed(.writeUnexpected),
                   "a value that is not the written text is still a third value")
        }
        do {
            let access = slackSetup()
            access.storedValue = "a\nb"
            access.layout = [false, false]
            let core = controller(access, "a\n\nb")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.noChange),
                   "Slack suggestion that reads back as the draft is refused")
            expect(access.writes.isEmpty, "read-back-identical refusal performs no write")
        }
        for layout in [nil, [false], [false, true]] as [[Bool]?] {
            let access = slackSetup()
            access.storedValue = "a\nb"
            access.layout = layout
            expect(await controller(access).requestPreview() == .failed(.richContent),
                   "layout that cannot rebuild the draft is copy-only (\(String(describing: layout)))")
        }
        do {
            let access = slackSetup()
            access.storedValue = "a\nb"
            access.layout = [false, false]
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            access.layout = [false, true, false]
            expect(await core.apply() == .failed(.targetChanged(.valueChanged)),
                   "Slack apply refused when the paragraph layout changed after preview")
            expect(access.writes.isEmpty, "layout-change refusal performs no write")
        }
        do {
            let access = slackSetup()
            access.rich = true
            expect(await controller(access).requestPreview() == .failed(.richContent),
                   "Slack draft with rich content is not offered for replace")
            expect(access.writes.isEmpty, "rich-content refusal performs no write")
        }
        do {
            let access = slackSetup()
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            access.rich = true
            expect(await core.apply() == .failed(.richContent),
                   "Slack apply refused when rich content appears before write")
            expect(access.writes.isEmpty, "late rich-content refusal performs no write")
        }
        do {
            let access = wholeSetup()
            access.rich = true
            let core = controller(access, "hello, world.")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "rich-content check is Slack-only")
        }

        // 31. Production policy is Slack only (user decision 10-27 22:49).
        for bundle in ["com.apple.TextEdit", "com.apple.Notes", "com.apple.Safari",
                       "com.google.Chrome", "com.github.Electron"] {
            expect(WriteBackPolicy.support(for: bundle) == .unsupported, "\(bundle) is not supported")
            let access = wholeSetup()
            access.bundles[100] = bundle
            let core = WriteBackController(access: access, client: ImmediateClient(suggestion: "HELLO"))
            expect(await core.requestPreview() == .failed(.unsupportedApp(bundle)),
                   "default controller refuses \(bundle)")
            expect(!access.calls.contains("value"), "\(bundle) reads no text")
        }
        expect(WriteBackPolicy.support(for: slack) == .wholeValue, "Slack is supported")
        do {
            let access = slackSetup()
            let core = WriteBackController(access: access, client: ImmediateClient(suggestion: "hello, world."))
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "default controller replaces in Slack")
            expect(await core.undo() == .restored, "default controller undoes in Slack")
        }

        // 32. Anchored on real Slack (S3 7.4/7.5): written string -> (AXValue, layout).
        let recordedSlack: [String: (String, [Bool])] = [
            "a": ("a", [false]),                                          // 7.5 c single line
            "a\(ls)b": ("a\nb", [false, false]),                          // 7.5 d, send test
            "a\(ls)b\(ls)c": ("a\nb\nc", [false, false, false]),          // 7.4 probe, 7.5 a undo
            "a\(ls)\(ls)b": ("a\nb", [false, true, false]),               // 7.5 table
            "a\(ls)\(ls)\(ls)b": ("a\n\nb", [false, true, true, false]),  // 7.5 table
            "\(ls)\(ls)a\(ls)\(ls)": ("\n\na\n\n", [true, true, false, true, true]),  // 7.5 table
            "a\(ls)\(ls)b\(ls)\(ls)c": ("a\nb\nc", [false, true, false, true, false]),  // 7.5 b undo
        ]
        func recordedSetup(_ draft: String, _ layout: [Bool]) -> FakeAccess {
            let access = slackSetup()
            access.storedValue = draft
            access.layout = layout
            access.slackRecorded = recordedSlack
            return access
        }
        for (draft, layout, candidate, after, afterLayout) in [
            ("a\nb\nc", [false, false, false], "a\n\nb", "a\nb", [false, true, false]),        // Shift+Return
            ("a\nb\nc", [false, true, false, true, false], "a\n\n\nb", "a\n\nb", [false, true, true, false]),
            ("\n\na\n\n", [true, true, false, true, true], "a\nb", "a\nb", [false, false]),
        ] {
            let access = recordedSetup(draft, layout)
            let core = controller(access, candidate)
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "recorded replace applies over \(layout)")
            expect(access.storedValue == after && access.layout == afterLayout,
                   "recorded replace reads back \(afterLayout)")
            expect(await core.undo() == .restored, "recorded undo restores \(layout)")
            expect(access.storedValue == draft && access.layout == layout, "recorded undo rebuilds \(layout)")
        }

        // 33. Read-back checks the layout, not only the string (review finding 1).
        do {
            // Undo of Shift+Return [a, b] that Slack rebuilds as [a, empty, b].
            let access = recordedSetup("a\nb", [false, false])
            access.slackRecorded?["a\(ls)b"] = ("a\nb", [false, true, false])
            let core = controller(access, "a")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply for undo layout mismatch")
            expect(await core.undo() == .failed(.writeUnexpected), "undo with a wrong layout is not restored")
            expect(await core.undoAvailable, "undo layout mismatch keeps the record")
            expect(await core.undo() == .failed(.targetChanged(.valueChanged)),
                   "retry does not report the wrong layout as already restored")
        }
        do {
            let access = recordedSetup("a", [false])
            access.slackRecorded?["a\(ls)\(ls)b"] = ("a\nb", [false, false])
            let core = controller(access, "a\n\nb")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.writeUnexpected), "apply with a wrong layout is not applied")
            expect(await core.undoAvailable, "apply layout mismatch keeps the possible-write record")
            expect(await core.undo() == .restored, "undo still restores after Slack's own layout")
            expect(access.storedValue == "a" && access.layout == [false], "undo rebuilt the draft")
        }

        // 34. A pending window longer than the read-back timeout (review finding 2).
        for pendingReads in [40, 1000] {
            let access = recordedSetup("a", [false])
            access.slackPendingReads = pendingReads
            let core = controller(access, "a\nb")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.writeUnconfirmed(0)),
                   "apply still pending at the timeout is unconfirmed (\(pendingReads))")
            expect(await core.undo() == .restored, "undo of a still-pending write is not refused (\(pendingReads))")
            expect(access.storedValue == "a" && access.layout == [false], "pending undo restored (\(pendingReads))")
        }

        // 35. Undo refuses a layout the user changed after apply (review finding 3).
        do {
            let access = recordedSetup("a", [false])
            let core = controller(access, "a\nb")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply for user layout change")
            access.layout = [false, true, false]  // user adds a blank line; AXValue stays "a\nb"
            expect(await core.undo() == .failed(.targetChanged(.valueChanged)),
                   "undo refuses an added empty paragraph")
            expect(access.writes.count == 1, "refused undo performs no write")
        }

        // 36. Candidate separators and zero-width characters (review finding 4).
        expect(WriteBackPolicy.slackCandidate("a\u{2029}b\u{0085}c\rd\r\ne") == "a\nb\nc\nd\ne",
               "U+2029, U+0085, CR and CRLF become newlines")
        expect(WriteBackPolicy.slackCandidate("x\u{200B}y\u{200C}z\u{200D}w\u{FEFF}") == "xyzw",
               "zero-width characters are stripped from candidates")
        expect(WriteBackPolicy.slackEncoding(suggestion: "a\u{2029}b") == "a\(ls)b",
               "U+2029 is a paragraph break, not written verbatim")
        do {
            let access = recordedSetup("a", [false])
            let core = controller(access, "a\u{200B}\u{2029}\u{FEFF}b")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "candidate with U+2029 and zero-width applies")
            expect(access.writes.last?.1 == "a\(ls)b", "written candidate has no U+2029 or zero-width")
        }
        do {
            let access = slackSetup()
            let core = controller(access, "\u{200B}\u{FEFF}")
            _ = await core.requestPreview()
            expect(await core.apply() == .failed(.emptySuggestion), "zero-width-only candidate is empty")
            expect(access.writes.isEmpty, "zero-width-only candidate performs no write")
        }
        do {
            let access = slackSetup()
            access.storedValue = "hi\u{200B}"
            let core = controller(access, "hello")
            _ = await core.requestPreview()
            expect(await core.apply() == .applied, "setup apply over a zero-width original")
            expect(await core.undo() == .restored && access.writes.last?.1 == "hi\u{200B}",
                   "undo writes the user's original with its zero-width character")
        }

        if failures == 0 {
            print("WriteBackTests PASS")
        } else {
            print("WriteBackTests FAIL: \(failures) failure(s)")
            exit(1)
        }
    }
}

// MARK: - Fakes

/// The pre-Slack-only support matrix. Production supports only Slack (user decision
/// 10-27 22:49); the generic core tests still run selection and whole-value mode on these.
private let fixtureSupport: @Sendable (String?) -> WriteBackAppSupport = { bundleID in
    switch bundleID {
    case "com.apple.TextEdit", "com.apple.Notes": return .selection
    case "com.apple.Safari", "com.google.Chrome", "com.github.Electron": return .wholeValue
    default: return WriteBackPolicy.support(for: bundleID)
    }
}

private struct ImmediateClient: SuggestionProviding {
    let suggestion: String

    func optimize(text: String) async throws -> String {
        suggestion
    }
}

/// Suspends until the test responds, so generation/cancel behavior is
/// deterministic without timers.
private final class BlockingClient: SuggestionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func optimize(text: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                self.continuation = continuation
                let waiter = started
                started = nil
                return waiter
            }
            waiter?.resume()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyStarted: Bool = lock.withLock {
                if self.continuation != nil { return true }
                started = continuation
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func respond(_ value: String) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: value)
    }
}

private final class FakeToken {}

/// In-memory AX target. `valueReads` is consumed by every AXValue read, so the
/// test controls exactly when a pending setter effect becomes observable.
private final class FakeAccess: TextTargetAccess, @unchecked Sendable {
    var secureInput = false
    var frontmost: pid_t? = 100
    var bundles: [pid_t: String] = [100: "com.apple.TextEdit"]
    var element = TargetElement(token: FakeToken())
    var otherElement = TargetElement(token: FakeToken())
    var focused: TargetElement?
    var windowTitle: String? = "be-nice AX test target"
    var rich = false
    /// Slack composer paragraphs (true = empty). With `slackWrites`, setValue rebuilds
    /// them the way Slack does: a new paragraph at each U+2028, AXValue = text paragraphs.
    var layout: [Bool]?
    var slackWrites = false
    /// Reads after a Slack U+2028 write that still show the written text (real Slack: ~0.2 s).
    var slackPendingReads = 0
    /// Written string -> (AXValue, layout) as recorded in real Slack. When set, the fake
    /// uses only this table, so a test cannot pass on the model it is checking.
    var slackRecorded: [String: (String, [Bool])]?
    var roleValue: String? = "AXTextArea"
    var subroleValue: String?
    var storedValue = ""
    var storedRange = NSRange(location: 0, length: 0)
    var settable: Set<WriteAttribute> = [.value, .selectedText, .selectedTextRange]
    /// False simulates Electron-style async setters.
    var applyOnSet = true
    var applyOnRangeSet = true
    var setError: Int32 = 0
    var rangeSetError: Int32 = 0
    var valueReads: [String?] = []
    var calls: [String] = []
    var writes: [(WriteAttribute, String)] = []
    var rangeWrites: [NSRange] = []
    var now: TimeInterval = 0

    init() {
        focused = element
    }

    func isSecureInputEnabled() -> Bool {
        calls.append("secureInput")
        return secureInput
    }

    func frontmostPID() -> pid_t? {
        calls.append("frontmost")
        return frontmost
    }

    func bundleID(for pid: pid_t) -> String? {
        calls.append("bundleID")
        return bundles[pid]
    }

    func focusedElement(pid: pid_t) -> TargetElement? {
        calls.append("focusedElement")
        return focused
    }

    func hasRichContent(_ element: TargetElement) -> Bool { rich }

    func paragraphLayout(of element: TargetElement) -> [Bool]? { layout }

    func focusedWindowTitle(pid: pid_t) -> String? {
        calls.append("windowTitle")
        return windowTitle
    }

    func sameElement(_ a: TargetElement, _ b: TargetElement) -> Bool {
        a === b
    }

    func role(of element: TargetElement) -> String? {
        calls.append("role")
        return roleValue
    }

    func subrole(of element: TargetElement) -> String? {
        calls.append("subrole")
        return subroleValue
    }

    func value(of element: TargetElement) -> String? {
        calls.append("value")
        if valueReads.isEmpty == false {
            return valueReads.removeFirst()
        }
        return storedValue
    }

    func selectedRange(of element: TargetElement) -> NSRange? {
        calls.append("range")
        return storedRange
    }

    func isSettable(_ attribute: WriteAttribute, on element: TargetElement) -> Bool {
        calls.append("settable:\(attribute.rawValue)")
        return settable.contains(attribute)
    }

    func setValue(_ text: String, on element: TargetElement) -> Int32 {
        calls.append("write:value")
        writes.append((.value, text))
        if setError == 0 && applyOnSet {
            storedValue = text
            if slackWrites {
                let paragraphs = text.components(separatedBy: "\u{2028}")
                if let recorded = slackRecorded {
                    (storedValue, layout) = recorded[text] ?? ("UNRECORDED WRITE", nil)
                } else {
                    layout = paragraphs.map(\.isEmpty)
                    storedValue = WriteBackPolicy.slackValue(paragraphs: paragraphs)
                }
                valueReads = paragraphs.count > 1
                    ? Array(repeating: text, count: slackPendingReads) : []
            }
            storedRange = NSRange(location: (storedValue as NSString).length, length: 0)
        }
        return setError
    }

    func setSelectedText(_ text: String, on element: TargetElement) -> Int32 {
        calls.append("write:selectedText")
        writes.append((.selectedText, text))
        if setError == 0 && applyOnSet {
            storedValue = (storedValue as NSString)
                .replacingCharacters(in: storedRange, with: text)
            storedRange = NSRange(location: storedRange.location + (text as NSString).length,
                                  length: 0)
        }
        return setError
    }

    func setSelectedRange(_ range: NSRange, on element: TargetElement) -> Int32 {
        calls.append("write:range")
        rangeWrites.append(range)
        if rangeSetError == 0 {
            storedRange = applyOnRangeSet ? range : NSRange(location: 0, length: 0)
        }
        return rangeSetError
    }

    func uptime() -> TimeInterval {
        now
    }

    func sleep(_ seconds: TimeInterval) {
        now += seconds
    }
}
