import AppKit

/// be-nice menu-bar app.
///
/// M0 owns Accessibility onboarding; M1 adds OpenAI-compatible settings,
/// floating-dot/shortcut triggers, and preview-first apply/product undo.
/// No suggestion is ever applied before the user clicks Apply.
///
/// `--selftest` exercises the pure permission-state logic and exits without
/// creating an NSApplication (safe over SSH / while the desktop is locked).
@main
struct BeNiceMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(ShellSelfCheck.run())
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement is set in the app bundle Info.plist; this keeps the raw
        // SwiftPM executable menu-bar-only too (no Dock icon, no windows).
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate is weak; keep the delegate alive for the
        // entire event loop rather than ending its lexical lifetime at run().
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
