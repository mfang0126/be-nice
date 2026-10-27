"""Pure regression: compile the production apply/cancel methods against inert doubles.
Run: python3 -I mac-app/OptimizerControllerTests.py
No AppKit, windows, AX, clipboard, credentials, or network are used.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / "Sources/benice/OptimizerController.swift").read_text()


def method(name):
    start = source.index(f"    private func {name}(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func", 1)


harness = r'''
import Foundation
import CoreGraphics
struct TriggerController {
    struct Target { let pid: Int32; let bundleID: String; let anchorRect: CGRect = .zero }
}
enum Reason { case notFrontmost }
enum Failure { case targetChanged(Reason); var message: String { "failed" } }
enum ApplyOutcome { case applied; case failed(Failure) }
actor WriteBackController {
    var undoAvailable = true
    var writes = 0
    var cancellations = 0
    func apply(replacement: String) -> ApplyOutcome { writes += 1; return .failed(.targetChanged(.notFrontmost)) }
    func cancel() { cancellations += 1 }
}
@MainActor final class NSRunningApplication {
    static var activations: [Int32] = []
    static var bundles: [Int32: String] = [42: "fixture.app"]
    let processIdentifier: Int32
    var bundleIdentifier: String? { Self.bundles[processIdentifier] }
    init?(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
    func activate(options: [Int]) { Self.activations.append(processIdentifier) }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)
}
@MainActor final class Preview {
    var copyOnly = false
    func suspendForApply() {}
    func setBusy(_ busy: Bool) {}
    func resumeCopyOnly(reason: String) { copyOnly = true }
    func dismiss() {}
}
@MainActor final class Status { func hide() {} }
@MainActor final class Controller {
    let previewWindow = Preview()
    let statusWindow = Status()
    var pending: WriteBackController?
    var recovery: WriteBackController?
    var pendingTarget: TriggerController.Target?
    var recoveryTarget: TriggerController.Target?
    var request: Task<Void, Never>?
    var regenerate: Task<Void, Never>?
    var shown: (original: String, options: [String])?
    var generation: UInt64 = 7
    var busy = false
    var restored = true
    func restoreFocus(_ target: TriggerController.Target) async -> Bool { restored }
    func showStatus(_ message: String, anchor: CGRect) {}
'''
harness += method("apply") + "\n" + method("cancelPreview") + "\n}\n"
harness += r'''
@main struct Tests {
    @MainActor static func main() async {
        for restored in [true, false] {
            for frontmost in [ProcessInfo.processInfo.processIdentifier, 99] {
                for bundleMatches in [true, false] {
                    NSRunningApplication.activations = []
                    NSRunningApplication.bundles[42] = "fixture.app"
                    let controller = Controller()
                    let core = WriteBackController()
                    controller.restored = restored
                    controller.pending = core
                    controller.pendingTarget = .init(pid: 42, bundleID: "fixture.app")
                    controller.apply("replacement", token: 7)
                    for _ in 0..<10000 {
                        if !controller.busy { break }
                        await Task.yield()
                    }
                    precondition(!controller.busy, "apply must complete")
                    precondition(controller.previewWindow.copyOnly)
                    precondition(controller.pending == nil, "failed apply must remove write capability")
                    precondition(controller.pendingTarget?.pid == 42)
                    precondition(controller.pendingTarget?.bundleID == "fixture.app")
                    precondition(controller.recovery === core && controller.recoveryTarget?.pid == 42)
                    let writes = await core.writes
                    controller.apply("retry", token: 7)
                    await Task.yield()
                    let retriedWrites = await core.writes
                    precondition(retriedWrites == writes, "copy-only cannot retry replacement")
                    NSWorkspace.shared.frontmostApplication = NSRunningApplication(processIdentifier: frontmost)
                    if !bundleMatches { NSRunningApplication.bundles[42] = "other.app" }
                    controller.cancelPreview(returnToTarget: true)
                    let expected: [Int32] = frontmost == ProcessInfo.processInfo.processIdentifier && bundleMatches ? [42] : []
                    precondition(NSRunningApplication.activations == expected, "cancel must respect focus and app identity")
                    precondition(controller.pendingTarget == nil && controller.pending == nil)
                    precondition(controller.generation == 8 && controller.request == nil)
                    precondition(controller.recovery === core, "cancel must preserve recovery")
                    controller.cancelPreview(returnToTarget: true)
                    precondition(NSRunningApplication.activations == expected, "return target consumed once")
                }
            }
        }
        print("OptimizerControllerTests PASS (8 failed-apply/cancel scenarios)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="benice-optimizer-tests-") as directory:
    swift = Path(directory) / "OptimizerControllerTests.swift"
    executable = Path(directory) / "tests"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
