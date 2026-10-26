import ApplicationServices
import CoreGraphics
import Foundation

/// Deterministic checks for TriggerController's pure policy/geometry. No
/// Accessibility permission, no NSApplication, no AX calls, no network:
///
///     swiftc -swift-version 6 mac-app/Sources/benice/TriggerController.swift \
///         mac-app/TriggerTests.swift -o /tmp/benice-trigger-tests
///     /tmp/benice-trigger-tests
@main
struct TriggerTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                print("SELFTEST FAIL: \(message)")
            }
        }
        func decision(_ bundleID: String?, _ role: String = "AXTextField",
                      subrole: String? = nil, ancestors: [String] = [],
                      windowTitle: String? = nil, secureInput: Bool = false) -> TriggerDecision {
            TriggerPolicy.decision(bundleID: bundleID, role: role, subrole: subrole,
                                   ancestorRoles: ancestors, windowTitle: windowTitle,
                                   secureInputEnabled: secureInput)
        }
        let inWeb = ["AXWindow", "AXWebArea"]

        // Support matrix, conservative per PLAN.md. Browser/Electron whole
        // value requires actual web content ancestry.
        expect(decision("com.apple.TextEdit", "AXTextArea") == .show(.selection),
               "TextEdit -> selection-capable mode")
        expect(decision("com.apple.Notes", "AXTextArea") == .show(.selection),
               "Notes text area -> selection-capable mode")
        expect(decision("com.apple.Notes", "AXTextView") == .show(.selection),
               "text view is a tested text role")
        expect(decision("com.apple.Safari", "AXTextField", ancestors: inWeb)
                == .show(.wholeValue),
               "Safari web field -> whole value")
        expect(decision("com.google.Chrome", "AXTextField", ancestors: inWeb)
                == .show(.wholeValue),
               "Chrome web field -> whole value")
        expect(decision("com.github.Electron", "AXTextArea", ancestors: inWeb,
                        windowTitle: "be-nice AX test target") == .show(.wholeValue),
               "dedicated Electron fixture web field -> whole value")
        expect(decision("com.github.Electron", "AXTextArea", ancestors: inWeb,
                        windowTitle: "A real Electron app") == .hide(.unsupportedApp),
               "default Electron bundle with another window is unsupported")
        expect(decision("com.github.Electron", "AXTextArea", ancestors: inWeb)
                == .hide(.unsupportedApp),
               "Electron fixture requires a verified window title")
        expect(decision("com.apple.Safari", "AXTextField") == .hide(.outsideWebContent),
               "Safari address bar without AXWebArea ancestor is hidden")
        expect(decision("com.github.Electron", "AXTextField") == .hide(.outsideWebContent),
               "native Electron field without web ancestry is hidden")
        expect(TriggerPolicy.hasWebAreaAncestor(inWeb), "web area ancestor detected")
        expect(!TriggerPolicy.hasWebAreaAncestor(["AXWindow", "AXToolbar"]),
               "toolbar ancestry is not web content")

        // Untested / excluded targets stay hidden.
        expect(decision("com.microsoft.VSCode", "AXTextArea") == .hide(.excludedApp),
               "VS Code excluded")
        expect(decision("com.apple.Terminal", "AXTextArea") == .hide(.excludedApp),
               "Terminal excluded")
        expect(decision("com.slack.Slack", "AXTextArea", ancestors: inWeb)
                == .hide(.unsupportedApp),
               "untested Slack is not claimed")
        expect(decision(nil, "AXTextArea") == .hide(.unknownBundle),
               "missing bundle id is not claimed")

        // Roles outside the tested set are non-text targets.
        expect(decision("com.apple.Safari", "AXWebArea") == .hide(.nonTextRole),
               "AXWebArea itself is not a trigger target")
        expect(decision("com.apple.Safari", "AXSearchField") == .hide(.nonTextRole),
               "search field is not in the tested role set")
        expect(decision("com.apple.Safari", "AXComboBox") == .hide(.nonTextRole),
               "combo box is not in the tested role set")
        expect(decision("com.apple.TextEdit", "AXButton") == .hide(.nonTextRole),
               "button is a non-text target")
        expect(decision("com.apple.Notes", "AXWindow") == .hide(.nonTextRole),
               "window is a non-text target")

        // Security gates.
        expect(decision("com.apple.TextEdit", "AXTextArea", secureInput: true)
                == .hide(.secureInput),
               "Secure Input hides even a supported app")
        expect(decision("com.apple.TextEdit", "AXSecureTextField") == .hide(.secureField),
               "secure text field role hides")
        expect(decision("com.apple.Safari", "AXTextField", subrole: "AXSecureTextField",
                        ancestors: inWeb) == .hide(.secureField),
               "secure subrole hides a password field")

        // Default shortcut: Ctrl+Option+Cmd+Space (Carbon key code 49).
        expect(TriggerController.HotKey.defaultShortcut.keyCode == 49,
               "default shortcut is Space")
        expect(TriggerController.HotKey.defaultShortcut.modifiers
                == 0x1000 | 0x0800 | 0x0100,
               "default shortcut is Ctrl+Option+Cmd")

        // AX top-left -> AppKit bottom-left conversion, primary screen only.
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let onPrimary = TriggerGeometry.appKitRect(
            fromAX: CGRect(x: 100, y: 100, width: 200, height: 50),
            primaryScreenFrame: primary)
        expect(onPrimary == CGRect(x: 100, y: 832, width: 200, height: 50),
               "primary-screen AX rect flips y (got \(onPrimary))")

        // A display above the primary one has negative AX y.
        let above = TriggerGeometry.appKitRect(
            fromAX: CGRect(x: 100, y: -120, width: 200, height: 60),
            primaryScreenFrame: primary)
        expect(above == CGRect(x: 100, y: 1042, width: 200, height: 60),
               "screen above primary keeps positive AppKit y (got \(above))")

        // A display left of the primary one has negative x in both spaces.
        let left = TriggerGeometry.appKitRect(
            fromAX: CGRect(x: -1800, y: 100, width: 200, height: 50),
            primaryScreenFrame: primary)
        expect(left == CGRect(x: -1800, y: 832, width: 200, height: 50),
               "negative-origin screen keeps x (got \(left))")

        let field = CGRect(x: 100, y: 832, width: 200, height: 50)

        // Rewrite entry sits just above the field's top-right corner, outside it.
        let button = TriggerGeometry.buttonFrame(field: field, within: primary)
        expect(button == CGRect(x: 212, y: 888, width: 88, height: 32),
               "Rewrite hugs the field's top-right corner (got \(String(describing: button)))")
        let negativeBounds = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let negativeField = CGRect(x: -800, y: -600, width: 400, height: 60)
        let negativeButton = TriggerGeometry.buttonFrame(field: negativeField, within: negativeBounds)
        expect(negativeButton == CGRect(x: -488, y: -534, width: 88, height: 32),
               "Rewrite handles negative x and y screen origins (got \(String(describing: negativeButton)))")
        let rightEdgeField = CGRect(x: 1000, y: 300, width: 512, height: 682)
        expect(TriggerGeometry.buttonFrame(field: rightEdgeField, within: primary)
                == CGRect(x: 1424, y: 262, width: 88, height: 32),
               "a field touching the top-right corner gets the button below it")
        let wideField = CGRect(x: 100, y: 0, width: 1412, height: 982)
        expect(TriggerGeometry.buttonFrame(field: wideField, within: primary)
                == CGRect(x: 6, y: 950, width: 88, height: 32),
               "a field filling top, right and bottom gets the button on its left")
        let rectangularClamp = TriggerGeometry.clamped(CGPoint(x: 100, y: 100),
            size: TriggerGeometry.buttonSize, within: negativeBounds)
        expect(rectangularClamp == CGPoint(x: -88, y: -32),
               "clamping accounts for the full rectangular button")
        expect(TriggerGeometry.buttonFrame(field: CGRect(x: 2000, y: 400, width: 300, height: 60),
                                           within: primary) == nil,
               "a field off this screen gets no button instead of one parked at the edge")
        let topField = CGRect(x: 1300, y: 450, width: 212, height: 532)
        expect(TriggerGeometry.buttonFrame(field: topField, within: primary)
                == CGRect(x: 1424, y: 412, width: 88, height: 32),
               "Rewrite moves below when there is no room above or right")
        expect(TriggerGeometry.buttonFrame(field: primary, within: primary) == nil,
               "Rewrite hides when no non-overlapping edge space exists")
        expect(TriggerGeometry.buttonFrame(field: .zero,
            within: CGRect(x: -50, y: -50, width: 50, height: 20)) == nil,
               "Rewrite hides when the visible area cannot fit the button")

        if failures == 0 {
            print("SELFTEST PASS")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
