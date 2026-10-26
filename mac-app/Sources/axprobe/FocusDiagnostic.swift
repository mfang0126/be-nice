import AppKit
import ApplicationServices
import Foundation

/// Read-only metadata: never reads field contents or changes focus.
enum FocusDiagnostic {
    static func run(app: NSRunningApplication, timeout: Float) {
        let front = NSWorkspace.shared.frontmostApplication
        print("trusted=\(AXProbe.isTrusted(prompt: false)) secureInput=\(AXProbe.isSecureInputEnabled)")
        print("targetPID=\(app.processIdentifier) frontmostPID=\(front?.processIdentifier ?? -1) frontmostBundle=\(front?.bundleIdentifier ?? "unknown")")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // Diagnostic hint only: lock-state dictionary keys are not a write gate.
        print("screenLocked=\(session?["CGSSessionScreenIsLocked"] as? Int ?? -1)")
        guard AXProbe.isTrusted(prompt: false) else {
            print("BLOCKED: Accessibility permission missing")
            return
        }
        guard AppPolicy.denial(bundleID: app.bundleIdentifier, allowWrite: false) == nil else {
            print("BLOCKED: app policy or Secure Input")
            return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let system = AXUIElementCreateSystemWide()
        for (label, root) in [("application", application), ("system", system)] {
            AXUIElementSetMessagingTimeout(root, timeout)
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(root, "AXFocusedUIElement" as CFString, &raw)
            print("\(label).focused AXError=\(error.rawValue)")
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, timeout)
            var pid: pid_t = -1
            AXUIElementGetPid(element, &pid)
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role)
            print("\(label).focused pid=\(pid) role=\(role as? String ?? "unknown") roleError=\(roleError.rawValue)")
        }
    }
}
