// Run after focusing one disposable Chromium fixture:
// swift mac-app/electron-native-undo-check.swift [Electron|Chrome] input|textarea|contenteditable [--write-only|--verify-original]
// Default app: Electron. Default mode: write once, send Cmd-Z, verify by AX readback.
// Split modes allow an external input driver to send exactly one Cmd-Z between them.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

let fixture = "be-nice M0 fixture: hello world."
var arguments = Array(CommandLine.arguments.dropFirst())
let appName = arguments.first == "Chrome" || arguments.first == "Electron"
    ? arguments.removeFirst() : "Electron"
let bundleID = appName == "Chrome" ? "com.google.Chrome" : "com.github.Electron"
let controls = [
    "input": (role: "AXTextField", original: fixture + " [input]"),
    "textarea": (role: "AXTextArea", original: fixture + " [textarea]"),
    "contenteditable": (role: "AXTextArea", original: fixture + " [contenteditable]"),
]
guard arguments.count >= 1 && arguments.count <= 2, let control = controls[arguments[0]] else {
    print("usage: electron-native-undo-check.swift [Electron|Chrome] input|textarea|contenteditable [--write-only|--verify-original]")
    exit(2)
}
let label = arguments[0]
let expectedRole = control.role
let original = control.original
let replacement = original + " [be-nice-undo]"
let mode = arguments.count == 2 ? arguments[1] : ""
guard mode.isEmpty || mode == "--write-only" || mode == "--verify-original" else {
    print("unknown mode: \(mode)"); exit(2)
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { print("STOP: \(message)"); exit(1) }
}
func waitForValue(_ field: AXUIElement, expected: String, stale: String) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(field, "AXValue" as CFString, &raw)
        require(error == .success, "AXValue read AXError=\(error.rawValue)")
        guard let value = raw as? String else { print("STOP: non-string AXValue"); exit(1) }
        if value == expected { return true }
        require(value == stale, "unexpected third value; inspect fixture, no retry")
        Thread.sleep(forTimeInterval: 0.02)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}

require(AXIsProcessTrusted(), "Accessibility permission missing")
require(!IsSecureEventInputEnabled(), "Secure Input enabled")
guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == bundleID else {
    print("STOP: \(appName) must be frontmost"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
    require(error == .success, "\(key) AXError=\(error.rawValue)")
    return value
}
guard let rawField = attribute(root, "AXFocusedUIElement"),
      CFGetTypeID(rawField) == AXUIElementGetTypeID() else { exit(1) }
let field = rawField as! AXUIElement
AXUIElementSetMessagingTimeout(field, 2)
guard let rawWindow = attribute(field, "AXWindow"),
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { exit(1) }
let window = rawWindow as! AXUIElement
let windowTitle = attribute(window, "AXTitle") as? String
require(appName == "Chrome" ? windowTitle?.hasPrefix("be-nice AX test target") == true
        : windowTitle == "be-nice AX test target", "not the disposable test window")
require(attribute(field, "AXRole") as? String == expectedRole, "unexpected focused role for \(label)")
if mode == "--verify-original" {
    require(waitForValue(field, expected: original, stale: replacement),
            "undo UNCONFIRMED; current=\(attribute(field, "AXValue") as? String ?? "unreadable")")
    print("undo PASS: \(label) restored exact original after external Cmd-Z; focused role and unique fixture verified")
    exit(0)
}
require(attribute(field, "AXValue") as? String == original, "fixture mismatch")
func gate(_ expected: String) {
    require(!IsSecureEventInputEnabled(), "Secure Input enabled")
    require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "frontmost changed")
    guard let focused = attribute(root, "AXFocusedUIElement") else { exit(1) }
    require(CFEqual(focused, field), "focus changed")
    require(attribute(field, "AXValue") as? String == expected, "value changed before operation")
}
let clipboardBefore = NSPasteboard.general.changeCount
gate(original)
let writeError = AXUIElementSetAttributeValue(field, "AXValue" as CFString, replacement as CFString)
print("app=\(appName) target=\(label) pid=\(app.processIdentifier) AXValue set AXError=\(writeError.rawValue)")
require(writeError == .success, "write failed")
require(waitForValue(field, expected: replacement, stale: original), "write UNCONFIRMED; inspect fixture, no undo sent")
gate(replacement)
if mode == "--write-only" {
    print("READY: \(label) replacement verified; clipboardCount=\(clipboardBefore); send one external Cmd-Z, then --verify-original")
    exit(0)
}

let source = CGEventSource(stateID: .hidSystemState)
guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: false) else {
    print("STOP: could not create Cmd-Z; replacement remains"); exit(1)
}
keyDown.flags = .maskCommand
keyUp.flags = .maskCommand
keyDown.postToPid(app.processIdentifier)
keyUp.postToPid(app.processIdentifier)
print("Sent one native Cmd-Z; waiting for independent AXValue readback")
require(waitForValue(field, expected: original, stale: replacement),
        "undo UNCONFIRMED; replacement remains or result arrived late; inspect fixture, no retry")
gate(original)
require(NSPasteboard.general.changeCount == clipboardBefore, "clipboard changed; inspect fixture")
print("undo PASS: \(label) restored exact original; focus PASS; clipboard unchanged")
