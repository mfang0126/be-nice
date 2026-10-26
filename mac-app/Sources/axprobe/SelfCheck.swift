import Foundation

/// Minimal runnable self-check for the pure write policy and JSON output.
/// No Accessibility permission required: `axprobe selftest`.
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                print("SELFTEST FAIL: \(message)")
            }
        }

        // Fixture shape: the written text must be fixed and derived from the fixture.
        expect(Fixture.text == "be-nice M0 fixture: hello world.", "fixture text is fixed")
        expect(Fixture.written == Fixture.text + Fixture.marker, "written = fixture + fixed marker")

        // Write gate: happy path.
        func gate(_ mutate: (inout GateBuilder) -> Void = { _ in }) -> WriteGate {
            var b = GateBuilder()
            mutate(&b)
            return b.build()
        }
        expect(writeDenial(gate()) == nil, "valid fixture target is allowed")
        expect(writeDenial(gate { $0.secureInput = true }) == .secureInput, "secure input blocks")
        expect(writeDenial(gate { $0.bundleID = nil }) == .unknownBundle, "missing bundle id blocks")
        expect(writeDenial(gate { $0.bundleID = "com.apple.Terminal" }) == .excludedApp, "Terminal blocks")
        expect(writeDenial(gate { $0.bundleID = "com.googlecode.iterm2" }) == .excludedApp, "iTerm blocks")
        expect(writeDenial(gate { $0.subrole = "AXSecureTextField" }) == .secureField, "secure field blocks")
        expect(writeDenial(gate { $0.role = "AXSecureTextField" }) == .secureField, "secure role blocks")
        expect(writeDenial(gate { $0.frontmost = false }) == .notFrontmost, "non-frontmost blocks")
        expect(writeDenial(gate { $0.focused = false }) == .focusChanged, "focus change blocks")
        expect(writeDenial(gate { $0.currentValue = Fixture.text + " " }) == .originalMismatch,
               "non-fixture original blocks")
        expect(writeDenial(gate { $0.currentValue = nil }) == .originalMismatch,
               "unreadable original blocks")
        expect(AppPolicy.excludedBundleIDs.contains("com.apple.Terminal"), "Terminal in exclusion list")

        // Bounded read-back (the same judgment used by probeWriteValue and
        // probeWriteSelection): Electron reports success then applies later.
        final class Clock {
            var now: TimeInterval = 0
            var sleeps: [TimeInterval] = []
            func sleep(_ seconds: TimeInterval) {
                sleeps.append(seconds)
                now += seconds
            }
        }
        func outcome(_ script: [String?], clock: Clock,
                     errorCode: Int32 = 0) -> WriteOutcome {
            var index = 0
            return classifyTextWrite(
                original: Fixture.text, expected: Fixture.written,
                errorCode: errorCode,
                read: {
                    defer { index += 1 }
                    return index < script.count ? script[index] : script[script.count - 1]
                },
                now: { clock.now },
                sleep: { clock.sleep($0) })
        }

        let immediate = Clock()
        expect(outcome([Fixture.written], clock: immediate) == .applied,
               "expected read-back is applied immediately")
        expect(immediate.sleeps.isEmpty, "expected read-back does not sleep")

        let late = Clock()
        expect(outcome([Fixture.text, Fixture.text, Fixture.written], clock: late) == .applied,
               "old value is polled until the write applies")
        expect(late.sleeps.count == 2, "late write polls between reads")

        let stuck = Clock()
        expect(outcome([Fixture.text], clock: stuck) == .unconfirmed(0),
               "success code + unchanged read-back is UNCONFIRMED, never FAKE_SUCCESS")
        expect(stuck.now >= axReadBackTimeout, "unchanged read-back polls the full timeout")
        expect(stuck.sleeps.allSatisfy { $0 <= axReadBackInterval + 0.0001 },
               "poll interval is at most 20 ms")

        let third = Clock()
        expect(outcome([Fixture.text, "third value"], clock: third)
                == .partial("value changed to unexpected content"),
               "third value fails immediately")
        expect(third.sleeps.count == 1, "third value is not polled further")

        let unreadable = Clock()
        expect(outcome([nil], clock: unreadable) == .partial("read-back unavailable"),
               "unreadable read-back fails immediately")
        expect(unreadable.sleeps.isEmpty, "unreadable read-back does not sleep")

        expect(outcome([Fixture.written], clock: Clock(), errorCode: -25204) == .applied,
               "observed applied text counts even when the API reports an error")
        expect(outcome([Fixture.text], clock: Clock(), errorCode: -25204) == .unconfirmed(-25204),
               "API error + unchanged read-back is UNCONFIRMED, not setError")

        // Undo is never executed by the probe: it must stay SKIPPED.
        let undo = AXProbe().probeUndo()
        expect(undo.result == .skipped, "undo without execution is SKIPPED")

        // JSON via JSONEncoder: escaping and round-trip.
        let report = TargetReport(
            app: "TextEdit", bundleID: "com.apple.TextEdit", pid: 4242,
            role: "AXTextArea", title: "a \"quoted\" title\nsecond line",
            mode: "read-only",
            capabilities: [
                CapabilityReport(name: "read-value", result: .ok, detail: "len=34"),
                CapabilityReport(name: "write-value", result: .fail,
                                 detail: "say \"hi\"\nnext line"),
            ]
        )
        let json = report.jsonString()
        if let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            expect(object["app"] as? String == "TextEdit", "JSON app")
            expect(object["pid"] as? Int == 4242, "JSON pid")
            expect(object["mode"] as? String == "read-only", "JSON mode")
            expect(object["title"] as? String == "a \"quoted\" title\nsecond line",
                   "JSON title escaping round-trips")
            let caps = object["capabilities"] as? [[String: Any]]
            expect(caps?.count == 2, "JSON capability count")
            expect(caps?[1]["result"] as? String == "FAIL", "JSON result raw value")
            expect(caps?[1]["detail"] as? String == "say \"hi\"\nnext line",
                   "JSON detail escaping round-trips")
        } else {
            expect(false, "JSON output parses")
        }

        if failures == 0 {
            print("SELFTEST PASS")
            return 0
        }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        return 1
    }

    private struct GateBuilder {
        var bundleID: String? = "com.apple.TextEdit"
        var role = "AXTextArea"
        var subrole: String? = nil
        var secureInput = false
        var frontmost = true
        var focused = true
        var currentValue: String? = Fixture.text
        var expectedValue = Fixture.text

        func build() -> WriteGate {
            WriteGate(bundleID: bundleID, role: role, subrole: subrole,
                      secureInputEnabled: secureInput, appIsFrontmost: frontmost,
                      elementIsFocused: focused, currentValue: currentValue,
                      expectedValue: expectedValue)
        }
    }
}
