// Run: swift mac-app/partial-selection-check.swift [TextEdit|Notes|Code]
// Disposable fixture only. Leaves the verified replacement for native undo.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

let targetName = CommandLine.arguments.count == 1 ? "TextEdit" : CommandLine.arguments[1]
guard CommandLine.arguments.count <= 2, ["TextEdit", "Notes", "Code"].contains(targetName) else {
    print("usage: partial-selection-check.swift [TextEdit|Notes|Code]"); exit(2)
}
let targetBundle = targetName == "TextEdit" ? "com.apple.TextEdit"
    : targetName == "Notes" ? "com.apple.Notes" : "com.microsoft.VSCode"

let original = "be-nice M0 fixture: hello world."
let expected = "be-nice M0 fixture: HELLO world."
func require(_ condition: Bool, _ message: String) {
    guard condition else { print("STOP: \(message)"); exit(1) }
}
require(AXIsProcessTrusted(), "Accessibility permission missing")
require(!IsSecureEventInputEnabled(), "Secure Input enabled")
guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == targetBundle else {
    print("STOP: \(targetName) must be frontmost"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)
func attribute(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(el, key as CFString, &value)
    require(error == .success, "\(key) AXError=\(error.rawValue)")
    return value
}
guard let raw = attribute(root, "AXFocusedUIElement"),
      CFGetTypeID(raw) == AXUIElementGetTypeID() else { exit(1) }
let field = raw as! AXUIElement
AXUIElementSetMessagingTimeout(field, 2)
guard let windowRaw = attribute(field, "AXWindow"),
      CFGetTypeID(windowRaw) == AXUIElementGetTypeID() else { exit(1) }
let window = windowRaw as! AXUIElement
AXUIElementSetMessagingTimeout(window, 2)
if targetName == "TextEdit" {
    // This driver is only for the freshly created, unsaved test document.
    require(attribute(window, "AXTitle") as? String == "Untitled 2", "not the dedicated test window")
    var document: CFTypeRef?
    let documentError = AXUIElementCopyAttributeValue(window, "AXDocument" as CFString, &document)
    require(documentError == .noValue || documentError == .attributeUnsupported ||
            (documentError == .success && (document == nil || (document as? String) == "")),
            "saved or unknown document; refusing write")
} else if targetName == "Notes" {
    // AX exposes the shared Notes window, not a disposable-note identity.
    // The operator must separately establish that the current note is dedicated.
    let title = attribute(window, "AXTitle") as? String
    require(title?.hasPrefix("All iCloud") == true, "not the Notes fixture window")
} else {
    require(attribute(window, "AXTitle") as? String == "be-nice-m0-vscode-fixture.txt",
            "not the dedicated VS Code fixture window")
    let document = attribute(window, "AXDocument") as? String
    let allowedDocuments = [
        "/tmp/be-nice-m0-vscode-fixture.txt",
        "file:///tmp/be-nice-m0-vscode-fixture.txt",
        "/private/tmp/be-nice-m0-vscode-fixture.txt",
        "file:///private/tmp/be-nice-m0-vscode-fixture.txt",
    ]
    require(document.map(allowedDocuments.contains) == true,
            "not the dedicated /tmp VS Code fixture")
}
require(attribute(field, "AXRole") as? String == "AXTextArea", "not a text area")
require(attribute(field, "AXValue") as? String == original, "fixture mismatch")
func range() -> CFRange {
    guard let value = attribute(field, "AXSelectedTextRange"),
          CFGetTypeID(value) == AXValueGetTypeID() else { exit(1) }
    var result = CFRange()
    require(AXValueGetValue(value as! AXValue, .cfRange, &result), "range decoding")
    return result
}
func gate(_ text: String) {
    require(!IsSecureEventInputEnabled(), "Secure Input enabled")
    require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "frontmost changed")
    guard let focused = attribute(root, "AXFocusedUIElement") else { exit(1) }
    require(CFEqual(focused, field), "focus changed")
    require(attribute(field, "AXValue") as? String == text, "text changed")
}
let clipboardBefore = NSPasteboard.general.changeCount
var selection = CFRange(location: 20, length: 5)
let selectedRange = AXValueCreate(.cfRange, &selection)!
gate(original)
let rangeError = AXUIElementSetAttributeValue(field, "AXSelectedTextRange" as CFString, selectedRange)
require(rangeError == .success, "range set AXError=\(rangeError.rawValue)")
let actualRange = { () -> CFRange in
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    var latest = CFRange()
    repeat {
        latest = range()
        if latest.location == 20 && latest.length == 5 { break }
        Thread.sleep(forTimeInterval: 0.02)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return latest
}()
print("range readback: location=\(actualRange.location) length=\(actualRange.length)")
require(actualRange.location == 20 && actualRange.length == 5, "range readback mismatch")
require(attribute(field, "AXSelectedText") as? String == "hello", "selected text mismatch")
print("selection PASS: range=20,5 text=hello")
gate(original)
let beforeWrite = range()
require(beforeWrite.location == 20 && beforeWrite.length == 5, "selection changed")
let writeError = AXUIElementSetAttributeValue(field, "AXSelectedText" as CFString, "HELLO" as CFString)
print("AXSelectedText set AXError=\(writeError.rawValue)")
let deadline = ProcessInfo.processInfo.systemUptime + 0.5
var after = attribute(field, "AXValue") as? String
while after != expected && after == original && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.02)
    after = attribute(field, "AXValue") as? String
}
let clipboardAfter = NSPasteboard.general.changeCount
require(after == expected,
        "replacement mismatch; current=\(after ?? "unreadable"); clipboard changed=\(clipboardAfter != clipboardBefore); no retry")
require(writeError == .success,
        "setter returned AXError=\(writeError.rawValue); current=\(after ?? "unreadable"); clipboard changed=\(clipboardAfter != clipboardBefore)")
gate(expected)
require(clipboardAfter == clipboardBefore, "clipboard changed; HELLO remains, inspect test document")
print("replacement PASS: exact full value, unchanged prefix/suffix; focus PASS; clipboard unchanged")
print("Left HELLO in fixture for one native Cmd-Z; verify exact original afterward.")
