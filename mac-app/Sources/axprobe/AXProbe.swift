import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

// The AX C string constants (`kAXValueAttribute`, `kAXRoleAttribute`, …) are
// imported as mutable globals. We snapshot each into a plain `let` of type
// String once; String is Sendable, so later reads are concurrency-safe.
// Likewise `kAXTrustedCheckOptionPrompt` is avoided in favour of its documented
// literal key.
private let axTrustedPromptKey: String = "AXTrustedCheckOptionPrompt"
private let axValueAttr: String = kAXValueAttribute as String
private let axRoleAttr: String = kAXRoleAttribute as String
private let axSubroleAttr: String = kAXSubroleAttribute as String
private let axTitleAttr: String = kAXTitleAttribute as String
private let axDescriptionAttr: String = kAXDescriptionAttribute as String
private let axSelectedTextAttr: String = kAXSelectedTextAttribute as String
private let axSelectedTextRangeAttr: String = kAXSelectedTextRangeAttribute as String
private let axFocusedUIElementAttr: String = kAXFocusedUIElementAttribute as String

func axValueKey() -> String { axValueAttr }
func axRoleKey() -> String { axRoleAttr }
func axSubroleKey() -> String { axSubroleAttr }
func axTitleKey() -> String { axTitleAttr }
func axDescriptionKey() -> String { axDescriptionAttr }
func axSelectedTextKey() -> String { axSelectedTextAttr }
func axSelectedTextRangeKey() -> String { axSelectedTextRangeAttr }
func axFocusedUIElementKey() -> String { axFocusedUIElementAttr }
func axTrustedPrompt() -> String { axTrustedPromptKey }

/// The one and only text this probe is ever allowed to write into.
/// The user must put exactly this text into the target field. Any other
/// original text blocks all writes (PLAN.md: data safety > capability).
enum Fixture {
    static let text = "be-nice M0 fixture: hello world."
    static let marker = " [be-nice-probe]"
    static let written = text + marker
}

enum ProbeResult: String, Encodable, Equatable {
    case ok = "OK"
    case fail = "FAIL"
    case unsupported = "UNSUPPORTED"
    case skipped = "SKIPPED"
    case blocked = "BLOCKED"            // secure input / password / exclusion / unsafe target
}

struct CapabilityReport: Encodable, Equatable {
    let name: String
    let result: ProbeResult
    let detail: String
}

struct TargetReport: Encodable, Equatable {
    let app: String
    let bundleID: String?
    let pid: Int32
    let role: String
    let title: String
    let mode: String          // "read-only" or "write"
    let capabilities: [CapabilityReport]
}

extension TargetReport {
    /// JSON via JSONEncoder (never hand-built strings: titles/details can contain
    /// quotes, newlines and backslashes).
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"json-encode-failed\"}"
        }
        return text
    }
}

// MARK: - Pure write policy (self-checked)

/// Why a write (or any target access) is not allowed. Pure input → decision,
/// no AX calls, so the self-check can exercise every branch without
/// Accessibility permission.
enum WriteDenial: String, Equatable {
    case secureInput = "BLOCKED_SECURE_INPUT"
    case excludedApp = "BLOCKED_EXCLUDED_APP"
    case unknownBundle = "BLOCKED_UNKNOWN_BUNDLE"
    case secureField = "BLOCKED_SECURE_FIELD"
    case notFrontmost = "BLOCKED_NOT_FRONTMOST"
    case focusChanged = "BLOCKED_FOCUS_CHANGED"
    case originalMismatch = "BLOCKED_ORIGINAL_MISMATCH"

    var detail: String {
        switch self {
        case .secureInput: return "Secure Input is enabled system-wide"
        case .excludedApp: return "app is on the Terminal exclusion list"
        case .unknownBundle: return "app has no bundle identifier; cannot verify exclusion"
        case .secureField: return "target is a secure/password text field"
        case .notFrontmost: return "target app is not frontmost"
        case .focusChanged: return "focused element is not the captured element"
        case .originalMismatch: return "current text is not exactly the fixed fixture"
        }
    }
}

struct WriteGate: Equatable {
    let bundleID: String?
    let role: String
    let subrole: String?
    let secureInputEnabled: Bool
    let appIsFrontmost: Bool
    let elementIsFocused: Bool
    let currentValue: String?
    let expectedValue: String
}

enum AppPolicy {
    /// Terminal-family apps are excluded from writeback in M0 (PLAN.md).
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    /// Roles that can hold editable text. Anything else (AXApplication,
    /// AXWindow, buttons, …) is reported BLOCKED as a non-text target instead
    /// of a misleading UNSUPPORTED text capability.
    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXTextView", "AXComboBox",
        "AXSearchField", "AXWebArea",
    ]

    /// App-level policy, evaluated BEFORE any AX target discovery/read.
    /// Terminal is reported BLOCKED even when it has no focused element.
    static func denial(bundleID: String?, allowWrite: Bool) -> WriteDenial? {
        if AXProbe.isSecureInputEnabled { return .secureInput }
        guard let bundleID else { return allowWrite ? .unknownBundle : nil }
        if excludedBundleIDs.contains(bundleID) { return .excludedApp }
        return nil
    }
}

func writeDenial(_ gate: WriteGate) -> WriteDenial? {
    if gate.secureInputEnabled { return .secureInput }
    guard let bundleID = gate.bundleID else { return .unknownBundle }
    if AppPolicy.excludedBundleIDs.contains(bundleID) { return .excludedApp }
    if gate.role == "AXSecureTextField" || gate.subrole == "AXSecureTextField" {
        return .secureField
    }
    if !gate.appIsFrontmost { return .notFrontmost }
    if !gate.elementIsFocused { return .focusChanged }
    if gate.currentValue != gate.expectedValue { return .originalMismatch }
    return nil
}

// MARK: - Bounded read-back (self-checked)

/// Bounded, read-only polling for AX setters that report success before the
/// value is observable (Electron applies AXValue/AXSelectedText asynchronously).
let axReadBackTimeout: TimeInterval = 0.5
let axReadBackInterval: TimeInterval = 0.02
let readBackMs = Int(axReadBackTimeout * 1000)

enum ReadBack<T> {
    case settled(T)      // expected value observed
    case timedOut        // still the old value at the deadline
    case unexpected(T?)  // third value (or unreadable): stop immediately
}

/// Poll `read` until it reports the expected value. Keep waiting only while it
/// still reports the old value; anything else stops immediately. This function
/// never writes, so a late setter effect cannot be retried or raced.
func waitForRead<T>(
    timeout: TimeInterval = axReadBackTimeout,
    interval: TimeInterval = axReadBackInterval,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    read: () -> T?,
    isExpected: (T) -> Bool,
    isStale: (T) -> Bool
) -> ReadBack<T> {
    let deadline = now() + max(0, timeout)
    while true {
        if let value = read() {
            if isExpected(value) { return .settled(value) }
            if !isStale(value) { return .unexpected(value) }
        } else {
            return .unexpected(nil)
        }
        // ponytail: the deadline is checked between reads; one AX read can
        // block up to the messaging timeout. Per-call AX timeout remains the
        // hard bound.
        let remaining = deadline - now()
        if remaining <= 0 { return .timedOut }
        sleep(min(interval, remaining))
    }
}

enum WriteOutcome: Equatable {
    case applied
    case unconfirmed(Int32)     // setter returned; read-back still old at deadline
    case partial(String)        // third value, or read-back unavailable
}

/// Classify a text write by a bounded read-back, never by the return code
/// alone. A value that stays old until the deadline is UNCONFIRMED, not a
/// permanent FAKE_SUCCESS, because the setter may still apply later.
func classifyTextWrite(original: String, expected: String, errorCode: Int32,
                       read: () -> String?,
                       now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                       sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) -> WriteOutcome {
    switch waitForRead(now: now, sleep: sleep, read: read,
                       isExpected: { $0 == expected },
                       isStale: { $0 == original }) {
    case .settled: return .applied
    case .timedOut: return .unconfirmed(errorCode)
    case .unexpected(let after):
        return .partial(after == nil ? "read-back unavailable" : "value changed to unexpected content")
    }
}

// MARK: - Probe

final class AXProbe {
    /// Restore is only attempted while the target still contains exactly what
    /// the probe wrote. Anything else is left untouched and reported.
    enum RestoreStatus: Equatable {
        case notNeeded
        case notAttempted
        case verified
        case refusedCurrentChanged
        case refusedUnsafeTarget
        case failed
        case unconfirmed

        var detail: String {
            switch self {
            case .notNeeded: return "already original"
            case .notAttempted: return "NOT ATTEMPTED (value restore or range read-back not confirmed)"
            case .verified: return "verified"
            case .refusedCurrentChanged: return "REFUSED (target changed; left as-is)"
            case .refusedUnsafeTarget: return "REFUSED (not frontmost/focused or Secure Input; left as-is)"
            case .failed: return "FAILED"
            case .unconfirmed: return "UNCONFIRMED (restore not observed after \(readBackMs) ms; left as-is)"
            }
        }

        var healthy: Bool { self == .notNeeded || self == .verified }
    }

    private let timeout: Float
    private(set) var lastReadError: AXError = .success

    init(timeout: CFTimeInterval = 2.0) {
        self.timeout = Float(timeout)
    }

    // MARK: Trust

    static func isTrusted(prompt: Bool) -> Bool {
        let key = axTrustedPrompt()
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// System-wide Secure Input (password prompts, lock screens, terminals).
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: Element helpers

    private func applyTimeout(_ el: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(el, timeout)
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        applyTimeout(el)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        lastReadError = err
        return err == .success ? value : nil
    }

    private func settable(_ el: AXUIElement, _ name: String) -> Bool {
        applyTimeout(el)
        var b = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(el, name as CFString, &b)
        return err == .success && b.boolValue
    }

    private func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        applyTimeout(el)
        return AXUIElementSetAttributeValue(el, name as CFString, value)
    }

    func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private func readRange(_ el: AXUIElement) -> CFRange? {
        guard let raw = attr(el, axSelectedTextRangeKey()),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func setRange(_ el: AXUIElement, _ range: CFRange) -> AXError {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return .failure }
        return set(el, axSelectedTextRangeKey(), value)
    }

    private func rangeEquals(_ a: CFRange?, _ b: CFRange) -> Bool {
        guard let a else { return false }
        return a.location == b.location && a.length == b.length
    }

    private func settleRange(_ el: AXUIElement, expected: CFRange,
                             stale: CFRange) -> ReadBack<CFRange> {
        waitForRead(read: { readRange(el) },
                    isExpected: { rangeEquals($0, expected) },
                    isStale: { rangeEquals($0, stale) })
    }

    // MARK: Target discovery

    func frontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        applyTimeout(app)
        guard let focused = attr(app, axFocusedUIElementKey()),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        applyTimeout(element)
        return element
    }

    func describe(_ el: AXUIElement) -> (role: String, subrole: String?, title: String?) {
        let role = stringAttr(el, axRoleKey()) ?? "?"
        let subrole = stringAttr(el, axSubroleKey())
        var title = stringAttr(el, axTitleKey())
        if title == nil { title = stringAttr(el, axDescriptionKey()) }
        return (role, subrole, title)
    }

    // MARK: Write preflight (re-reads PID/focus/value immediately before every write)

    private func preflight(_ el: AXUIElement, pid: pid_t, bundleID: String?,
                           expectedValue: String, name: String) -> CapabilityReport? {
        let d = describe(el)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let focused = focusedElement(pid: pid)
        let gate = WriteGate(
            bundleID: bundleID,
            role: d.role,
            subrole: d.subrole,
            secureInputEnabled: Self.isSecureInputEnabled,
            appIsFrontmost: frontmost?.processIdentifier == pid,
            elementIsFocused: focused.map { CFEqual($0, el) } ?? false,
            currentValue: stringAttr(el, axValueKey()),
            expectedValue: expectedValue
        )
        guard let denial = writeDenial(gate) else { return nil }
        return CapabilityReport(name: name, result: .blocked,
                                detail: "\(denial.rawValue): \(denial.detail)")
    }

    /// Can we still safely put the original text back? Checks Secure Input,
    /// frontmost PID and element identity via CFEqual.
    private func targetStillSafe(_ el: AXUIElement, pid: pid_t) -> Bool {
        if Self.isSecureInputEnabled { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let focused = focusedElement(pid: pid) else { return false }
        return CFEqual(focused, el)
    }

    // MARK: Read probes

    func probeReadSelection(_ el: AXUIElement) -> CapabilityReport {
        if let sel = stringAttr(el, axSelectedTextKey()) {
            return CapabilityReport(name: "read-selection", result: .ok,
                                    detail: "len=\(sel.count)")
        }
        return CapabilityReport(name: "read-selection",
                                result: lastReadError == .attributeUnsupported ? .unsupported : .fail,
                                detail: "AXSelectedText unavailable; AXError=\(lastReadError.rawValue)")
    }

    func probeReadValue(_ el: AXUIElement) -> CapabilityReport {
        if let v = stringAttr(el, axValueKey()) {
            return CapabilityReport(name: "read-value", result: .ok,
                                    detail: "len=\(v.count)")
        }
        return CapabilityReport(name: "read-value",
                                result: lastReadError == .attributeUnsupported ? .unsupported : .fail,
                                detail: "AXValue unavailable; AXError=\(lastReadError.rawValue)")
    }

    // MARK: Restore helpers (value/range are restored only while still probe-owned)

    private func restoreValueIfProbeValue(_ el: AXUIElement, pid: pid_t,
                                          original: String) -> RestoreStatus {
        let current = stringAttr(el, axValueKey())
        if current == original { return .notNeeded }
        guard current == Fixture.written else { return .refusedCurrentChanged }
        guard targetStillSafe(el, pid: pid) else { return .refusedUnsafeTarget }
        _ = set(el, axValueKey(), original as CFTypeRef)
        switch waitForRead(read: { stringAttr(el, axValueKey()) },
                           isExpected: { $0 == original },
                           isStale: { $0 == Fixture.written }) {
        case .settled: return .verified
        case .timedOut: return .unconfirmed
        case .unexpected: return .failed
        }
    }

    private func restoreRangeIfCurrent(_ el: AXUIElement, pid: pid_t,
                                       expected: CFRange, original: CFRange) -> RestoreStatus {
        guard let current = readRange(el) else { return .refusedCurrentChanged }
        if rangeEquals(current, original) { return .notNeeded }
        guard rangeEquals(current, expected) else { return .refusedCurrentChanged }
        guard targetStillSafe(el, pid: pid) else { return .refusedUnsafeTarget }
        _ = setRange(el, original)
        switch settleRange(el, expected: original, stale: expected) {
        case .settled: return .verified
        case .timedOut: return .unconfirmed
        case .unexpected: return .failed
        }
    }

    // MARK: Mutation probes (only called with explicit --allow-write)

    /// Set AXSelectedTextRange, verify it moved, then restore + verify the
    /// original selection (only while the selection is still probe-owned).
    func probePosition(_ el: AXUIElement, pid: pid_t, bundleID: String?) -> CapabilityReport {
        guard let value = stringAttr(el, axValueKey()) else {
            return CapabilityReport(name: "position", result: .unsupported, detail: "no AXValue")
        }
        guard let originalRange = readRange(el) else {
            return CapabilityReport(name: "position", result: .unsupported,
                                    detail: "no AXSelectedTextRange")
        }
        guard settable(el, axSelectedTextRangeKey()) else {
            return CapabilityReport(name: "position", result: .unsupported,
                                    detail: "AXSelectedTextRange not settable")
        }
        if let blocked = preflight(el, pid: pid, bundleID: bundleID,
                                   expectedValue: Fixture.text, name: "position") {
            return blocked
        }
        let target = CFRange(location: 0, length: min(3, value.utf16.count))
        let err = setRange(el, target)
        switch settleRange(el, expected: target, stale: originalRange) {
        case .timedOut:
            return CapabilityReport(name: "position", result: .fail,
                                    detail: "UNCONFIRMED: set range err=\(err.rawValue); selection still original after \(readBackMs) ms; left as-is (late range change possible)")
        case .unexpected(let after):
            return CapabilityReport(name: "position", result: .fail,
                                    detail: "set range err=\(err.rawValue) read-back=\(after.map { "\($0.location),\($0.length)" } ?? "nil"); left as-is, no restore attempted")
        case .settled:
            let restore = restoreRangeIfCurrent(el, pid: pid, expected: target, original: originalRange)
            if err != .success {
                return CapabilityReport(name: "position", result: .fail,
                                        detail: "set range err=\(err.rawValue) but read-back reached target; selection restore \(restore.detail)")
            }
            if restore.healthy {
                return CapabilityReport(name: "position", result: .ok,
                                        detail: "range=\(target.location),\(target.length) verified; original selection restore \(restore.detail)")
            }
            return CapabilityReport(name: "position", result: .fail,
                                    detail: "range verified but original selection restore \(restore.detail)")
        }
    }

    /// Whole-value write with fixed replacement, bounded read-back, and
    /// verified restore of value and selection. A partial/unknown change is
    /// FAIL and left untouched; a read-back still old at the deadline is
    /// FAIL/UNCONFIRMED (a late write may still apply), never a permanent
    /// FAKE_SUCCESS.
    func probeWriteValue(_ el: AXUIElement, pid: pid_t, bundleID: String?) -> CapabilityReport {
        let name = "write-value"
        guard let original = stringAttr(el, axValueKey()) else {
            return CapabilityReport(name: name, result: .unsupported, detail: "no AXValue")
        }
        guard let originalRange = readRange(el) else {
            return CapabilityReport(name: name, result: .unsupported,
                                    detail: "no AXSelectedTextRange; refusing write")
        }
        guard settable(el, axValueKey()) else {
            return CapabilityReport(name: name, result: .unsupported, detail: "AXValue not settable")
        }
        if let blocked = preflight(el, pid: pid, bundleID: bundleID,
                                   expectedValue: Fixture.text, name: name) {
            return blocked
        }
        let err = set(el, axValueKey(), Fixture.written as CFTypeRef)
        switch classifyTextWrite(original: original, expected: Fixture.written,
                                 errorCode: err.rawValue,
                                 read: { stringAttr(el, axValueKey()) }) {
        case .applied:
            let valueRestore = restoreValueIfProbeValue(el, pid: pid, original: original)
            // AXValue restoration can reset the selection; capture its post-state.
            let rangeAfterRestore = readRange(el)
            let rangeRestore: RestoreStatus
            if valueRestore.healthy, stringAttr(el, axValueKey()) == original,
               let rangeAfterRestore {
                rangeRestore = restoreRangeIfCurrent(el, pid: pid,
                    expected: rangeAfterRestore, original: originalRange)
            } else {
                rangeRestore = .notAttempted
            }
            if valueRestore.healthy && rangeRestore.healthy {
                return CapabilityReport(name: name, result: .ok,
                                        detail: "wrote + verified; value restore \(valueRestore.detail), selection restore \(rangeRestore.detail)")
            }
            return CapabilityReport(name: name, result: .fail,
                                    detail: "wrote + verified but restore not clean (value \(valueRestore.detail), selection \(rangeRestore.detail))")
        case .unconfirmed(let code):
            return CapabilityReport(name: name, result: .fail,
                                    detail: "UNCONFIRMED: set returned \(code == 0 ? "success" : "error \(code)"); value still original after \(readBackMs) ms; left as-is (late write possible)")
        case .partial(let why):
            return CapabilityReport(name: name, result: .fail,
                                    detail: "\(why) (err=\(err.rawValue)); left as-is, no restore attempted")
        }
    }

    /// Selection-level write: select-all, re-preflight, replace AXSelectedText,
    /// verify, restore value and original selection (only while probe-owned).
    func probeWriteSelection(_ el: AXUIElement, pid: pid_t, bundleID: String?) -> CapabilityReport {
        let name = "write-selection"
        guard let original = stringAttr(el, axValueKey()) else {
            return CapabilityReport(name: name, result: .unsupported, detail: "no AXValue")
        }
        guard original.utf16.count > 0 else {
            return CapabilityReport(name: name, result: .skipped, detail: "empty text")
        }
        guard settable(el, axSelectedTextKey()) else {
            return CapabilityReport(name: name, result: .unsupported,
                                    detail: "AXSelectedText not settable")
        }
        guard let originalRange = readRange(el) else {
            return CapabilityReport(name: name, result: .unsupported,
                                    detail: "no AXSelectedTextRange")
        }
        if let blocked = preflight(el, pid: pid, bundleID: bundleID,
                                   expectedValue: Fixture.text, name: name) {
            return blocked
        }
        let fullRange = CFRange(location: 0, length: original.utf16.count)
        let rangeErr = setRange(el, fullRange)
        switch settleRange(el, expected: fullRange, stale: originalRange) {
        case .timedOut:
            return CapabilityReport(name: name, result: .fail,
                                    detail: "select-all UNCONFIRMED: err=\(rangeErr.rawValue); selection still original after \(readBackMs) ms; left as-is (late range change possible)")
        case .unexpected(let afterRange):
            return CapabilityReport(name: name, result: .fail,
                                    detail: "select-all failed (err=\(rangeErr.rawValue) read-back=\(afterRange.map { "\($0.location),\($0.length)" } ?? "nil")); left as-is, no restore attempted")
        case .settled:
            if rangeErr != .success {
                let restore = restoreRangeIfCurrent(el, pid: pid, expected: fullRange, original: originalRange)
                return CapabilityReport(name: name, result: .fail,
                                        detail: "select-all set err=\(rangeErr.rawValue) but read-back reached full range; selection restore \(restore.detail)")
            }
        }

        // Re-check the target and the range immediately before the text write.
        if let blocked = preflight(el, pid: pid, bundleID: bundleID,
                                   expectedValue: Fixture.text, name: name) {
            let restore = restoreRangeIfCurrent(el, pid: pid, expected: fullRange,
                                                original: originalRange)
            return CapabilityReport(name: name, result: .blocked,
                                    detail: "\(blocked.detail); selection restore \(restore.detail)")
        }
        if !rangeEquals(readRange(el), fullRange) {
            let afterRange = readRange(el)
            let restore: RestoreStatus = rangeEquals(afterRange, originalRange)
                ? .notNeeded : .refusedCurrentChanged
            return CapabilityReport(name: name, result: .fail,
                                    detail: "selection changed after select-all; selection restore \(restore.detail)")
        }

        let err = set(el, axSelectedTextKey(), Fixture.written as CFTypeRef)
        switch classifyTextWrite(original: original, expected: Fixture.written,
                                 errorCode: err.rawValue,
                                 read: { stringAttr(el, axValueKey()) }) {
        case .applied:
            let rangeBeforeRestore = readRange(el)
            let valueRestore = restoreValueIfProbeValue(el, pid: pid, original: original)
            let rangeRestore = restoreRangeIfCurrent(
                el, pid: pid,
                expected: rangeBeforeRestore ?? fullRange,
                original: originalRange)
            if valueRestore.healthy && rangeRestore.healthy {
                return CapabilityReport(name: name, result: .ok,
                                        detail: "replaced + verified; value restore \(valueRestore.detail), selection restore \(rangeRestore.detail)")
            }
            return CapabilityReport(name: name, result: .fail,
                                    detail: "replace verified but restore not clean (value \(valueRestore.detail), selection \(rangeRestore.detail))")
        case .unconfirmed(let code):
            return CapabilityReport(name: name, result: .fail,
                                    detail: "UNCONFIRMED: set returned \(code == 0 ? "success" : "error \(code)"); value still original after \(readBackMs) ms; left as-is (late write possible; selection left at probe range)")
        case .partial(let why):
            return CapabilityReport(name: name, result: .fail,
                                    detail: "\(why) (err=\(err.rawValue)); left as-is, no restore attempted")
        }
    }

    // MARK: Non-mutating probes

    /// Undo is NOT executed by the probe (synthesizing Cmd-Z would steal focus).
    /// It must stay SKIPPED until a human actually presses Cmd-Z.
    func probeUndo() -> CapabilityReport {
        return CapabilityReport(name: "undo", result: .skipped,
                                detail: "not executed; press Cmd-Z manually and verify restore")
    }

    /// Focus retention: frontmost PID + element identity via CFEqual.
    func probeFocus(_ el: AXUIElement, pid: pid_t) -> CapabilityReport {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return CapabilityReport(name: "focus", result: .fail, detail: "no frontmost app")
        }
        let frontmost = front.processIdentifier == pid
        guard let focused = focusedElement(pid: pid) else {
            return CapabilityReport(name: "focus", result: .fail,
                                    detail: "frontmost=\(frontmost) but no focused element")
        }
        let same = CFEqual(el, focused)
        let d = describe(focused)
        if frontmost && same {
            return CapabilityReport(name: "focus", result: .ok,
                                    detail: "frontmost + element identity match (\(d.role))")
        }
        return CapabilityReport(name: "focus", result: .fail,
                                detail: "frontmost=\(frontmost) identity=\(same) focused=\(d.role) \(d.title ?? "-")")
    }

    /// Clipboard protection: compare changeCount captured before the run.
    func probeClipboard(before: Int) -> CapabilityReport {
        let after = NSPasteboard.general.changeCount
        return CapabilityReport(name: "clipboard",
                                result: after == before ? .ok : .fail,
                                detail: "changeCount before=\(before) after=\(after)")
    }

    // MARK: Full target run

    /// Report emitted without touching a target (policy block, or discovery
    /// found a non-text element). No target read/write happens here.
    func blockedReport(app: String, bundleID: String?, pid: pid_t,
                       role: String = "?", title: String = "",
                       reason: String, allowWrite: Bool,
                       element: AXUIElement? = nil) -> TargetReport {
        let names = ["read-selection", "read-value", "position", "write-value", "write-selection"]
        var caps = names.map {
            CapabilityReport(name: $0, result: .blocked, detail: reason)
        }
        caps.append(probeUndo())
        if let element {
            caps.append(probeFocus(element, pid: pid))
        } else {
            caps.append(CapabilityReport(name: "focus", result: .skipped,
                                         detail: "target not discovered (blocked before AX read)"))
        }
        caps.append(CapabilityReport(name: "clipboard", result: .skipped,
                                     detail: "not accessed by probe"))
        return TargetReport(app: app, bundleID: bundleID, pid: pid, role: role,
                            title: title, mode: allowWrite ? "write" : "read-only",
                            capabilities: caps)
    }

    func run(on el: AXUIElement, pid: pid_t, app: String, bundleID: String?,
             allowWrite: Bool, valueOnly: Bool = false) -> TargetReport {
        applyTimeout(el)
        let d = describe(el)

        // Policy checks BEFORE any read of the target (secure input, Terminal,
        // unknown bundle in write mode). A password field is blocked before its
        // AXValue/AXSelectedText is ever read.
        if let denial = AppPolicy.denial(bundleID: bundleID, allowWrite: allowWrite) {
            return blockedReport(app: app, bundleID: bundleID, pid: pid,
                                 reason: "\(denial.rawValue): \(denial.detail)",
                                 allowWrite: allowWrite)
        }
        if d.role == "AXSecureTextField" || d.subrole == "AXSecureTextField" {
            return blockedReport(app: app, bundleID: bundleID, pid: pid,
                                 role: d.role, title: d.title ?? "",
                                 reason: "\(WriteDenial.secureField.rawValue): \(WriteDenial.secureField.detail)",
                                 allowWrite: allowWrite)
        }

        // A focused element that is not a text control (AXApplication/AXWindow
        // is what some apps return when nothing editable has focus) must not
        // masquerade as an UNSUPPORTED text capability.
        if !AppPolicy.textRoles.contains(d.role) {
            return blockedReport(app: app, bundleID: bundleID, pid: pid,
                                 role: d.role, title: d.title ?? "",
                                 reason: "non-text target role=\(d.role)",
                                 allowWrite: allowWrite, element: el)
        }

        let clipboardBefore = NSPasteboard.general.changeCount
        var caps: [CapabilityReport] = []

        // Read-only capabilities always run (they never mutate the target).
        caps.append(probeReadSelection(el))
        caps.append(probeReadValue(el))

        if !allowWrite {
            for name in ["position", "write-value", "write-selection"] {
                caps.append(CapabilityReport(name: name, result: .skipped,
                                             detail: "read-only mode (use --allow-write)"))
            }
        } else if valueOnly {
            caps.append(CapabilityReport(name: "position", result: .skipped, detail: "value-only test"))
            caps.append(probeWriteValue(el, pid: pid, bundleID: bundleID))
            caps.append(CapabilityReport(name: "write-selection", result: .skipped, detail: "value-only test"))
        } else {
            var stopped = false
            func stoppedReport(_ name: String) -> CapabilityReport {
                CapabilityReport(name: name, result: .skipped,
                                 detail: "stopped after previous write/restore FAIL")
            }

            let position = probePosition(el, pid: pid, bundleID: bundleID)
            caps.append(position)
            if position.result == .fail { stopped = true }

            let value: CapabilityReport
            if stopped {
                value = stoppedReport("write-value")
            } else {
                value = probeWriteValue(el, pid: pid, bundleID: bundleID)
            }
            caps.append(value)
            if value.result == .fail { stopped = true }

            let selection: CapabilityReport
            if stopped {
                selection = stoppedReport("write-selection")
            } else {
                selection = probeWriteSelection(el, pid: pid, bundleID: bundleID)
            }
            caps.append(selection)
        }

        caps.append(probeUndo())
        caps.append(probeFocus(el, pid: pid))
        caps.append(probeClipboard(before: clipboardBefore))

        return TargetReport(app: app, bundleID: bundleID, pid: pid,
                            role: d.role, title: d.title ?? "",
                            mode: allowWrite ? "write" : "read-only",
                            capabilities: caps)
    }
}
