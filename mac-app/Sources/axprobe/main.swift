import AppKit
import Foundation

/// be-nice AX probe CLI (M0).
///
/// Usage:
///   axprobe check                                  # permission status
///   axprobe trust                                  # prompt for Accessibility permission
///   axprobe fixture                                # print the fixed writable fixture text
///   axprobe target [--app <name>] [--json] [--timeout <sec>]
///   axprobe target --allow-write ...               # required for any mutation
///   axprobe selftest                               # pure policy + JSON checks, no AX permission
///
/// Does not call any LLM. Writes are OFF by default; with --allow-write they are
/// only permitted when the target text is exactly the fixture text. Every write
/// and restore is read back and verified before being reported as OK.
/// Undo is never executed automatically and is always reported SKIPPED.

@main
struct Main {
    struct Options {
        var app: String?
        var json = false
        var timeout: CFTimeInterval = 2.0
        var allowWrite = false
        var valueOnly = false
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            printUsage(); exit(2)
        }

        switch cmd {
        case "check":
            let trusted = AXProbe.isTrusted(prompt: false)
            print(trusted ? "AX_TRUSTED=true" : "AX_TRUSTED=false")
            exit(trusted ? 0 : 1)

        case "trust":
            _ = AXProbe.isTrusted(prompt: true)
            print("Prompt shown. Re-run `axprobe check` after granting.")
            exit(0)

        case "fixture":
            print(Fixture.text)
            exit(0)

        case "selftest":
            exit(SelfCheck.run())

        case "diagnose-focus":
            guard let opts = parseOptions(Array(args.dropFirst())),
                  !opts.allowWrite, !opts.json, !opts.valueOnly,
                  let name = opts.app, let app = findApp(named: name) else {
                print("usage: axprobe diagnose-focus --app <name> [--timeout <sec>]")
                exit(2)
            }
            FocusDiagnostic.run(app: app, timeout: Float(opts.timeout))

        case "target":
            runTarget(Array(args.dropFirst()))

        case "--help", "-h", "help":
            printUsage(); exit(0)

        default:
            printUsage(); exit(2)
        }
    }

    static func printUsage() {
        print("""
        usage: axprobe <check|trust|fixture|target|diagnose-focus|selftest> [options]
          diagnose-focus --app <name> [--timeout <sec>]  (read-only metadata)
          target [--app <name>] [--json] [--timeout <sec>] [--allow-write] [--value-only]

        Writes are off by default. --allow-write only works when the target
        field contains exactly this fixture text (and nothing else):
          \(Fixture.text)
        Replacement written during the probe:
          \(Fixture.written)
        """)
    }

    // MARK: - target

    static func runTarget(_ args: [String]) {
        guard let opts = parseOptions(args) else {
            printUsage(); exit(2)
        }
        guard AXProbe.isTrusted(prompt: false) else {
            print("AX_TRUSTED=false — run `axprobe trust` first."); exit(1)
        }
        let target: NSRunningApplication
        if let name = opts.app {
            guard let found = findApp(named: name) else {
                print("App not found: \(name)"); exit(1)
            }
            target = found
        } else {
            guard let front = NSWorkspace.shared.frontmostApplication else {
                print("No frontmost app"); exit(1)
            }
            target = front
        }
        let appName = target.localizedName ?? opts.app ?? "?"
        let probe = AXProbe(timeout: opts.timeout)

        // App-level policy BEFORE target discovery: Terminal/Secure Input must
        // be BLOCKED even when the app has no focused element, and no AX read
        // of the target may happen.
        if let denial = AppPolicy.denial(bundleID: target.bundleIdentifier,
                                         allowWrite: opts.allowWrite) {
            let report = probe.blockedReport(
                app: appName, bundleID: target.bundleIdentifier,
                pid: target.processIdentifier,
                reason: "\(denial.rawValue): \(denial.detail)",
                allowWrite: opts.allowWrite)
            print(opts.json ? report.jsonString() : renderText(report))
            exit(0)
        }

        guard let el = probe.focusedElement(pid: target.processIdentifier) else {
            let report = probe.blockedReport(
                app: appName, bundleID: target.bundleIdentifier,
                pid: target.processIdentifier,
                reason: "AXFocusedUIElement unavailable; AXError=\(probe.lastReadError.rawValue)",
                allowWrite: opts.allowWrite)
            print(opts.json ? report.jsonString() : renderText(report))
            exit(0)
        }
        let report = probe.run(on: el, pid: target.processIdentifier,
                               app: appName,
                               bundleID: target.bundleIdentifier,
                               allowWrite: opts.allowWrite, valueOnly: opts.valueOnly)
        print(opts.json ? report.jsonString() : renderText(report))
        exit(report.capabilities.contains { $0.result == .fail } ? 4 : 0)
    }

    // MARK: - helpers

    static func parseOptions(_ args: [String]) -> Options? {
        var opts = Options()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--app":
                guard i + 1 < args.count else { return nil }
                opts.app = args[i + 1]
                i += 2
            case "--timeout":
                guard i + 1 < args.count,
                      let seconds = Double(args[i + 1]), seconds > 0, seconds <= 600 else { return nil }
                opts.timeout = seconds
                i += 2
            case "--json":
                opts.json = true
                i += 1
            case "--value-only":
                opts.valueOnly = true
                i += 1
            case "--allow-write":
                opts.allowWrite = true
                i += 1
            default:
                return nil
            }
        }
        return opts
    }

    static func findApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { $0.localizedName == name }) { return exact }
        if let bundle = apps.first(where: { $0.bundleIdentifier == name }) { return bundle }
        let matches = apps.filter { ($0.localizedName ?? "").lowercased() == name.lowercased() }
        return matches.count == 1 ? matches[0] : nil
    }

    static func renderText(_ r: TargetReport) -> String {
        var out = "=== \(r.app) (pid \(r.pid)) role=\(r.role) mode=\(r.mode)"
        out += " bundle=\(r.bundleID ?? "-") title=\(r.title.debugDescription) ===\n"
        for c in r.capabilities {
            out += String(format: "  %-16@ %-14@ %@\n",
                          c.name as NSString, c.result.rawValue as NSString, c.detail as NSString)
        }
        return out
    }
}
