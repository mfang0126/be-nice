"""Pure regression: compile the production apply/cancel methods against inert doubles.
Run: python3 -I mac-app/OptimizerControllerTests.py
No AppKit, windows, AX, clipboard, credentials, or network are used.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / "Sources/benice/OptimizerController.swift").read_text()


def method(name):
    start = max(source.find(f"    private func {name}("), source.find(f"    func {name}("))
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
    struct Target { let pid: Int32; let bundleID: String; let anchorRect = CGRect(x: 1, y: 2, width: 3, height: 4)
        nonisolated(unsafe) static var live = CGRect(x: 10, y: 20, width: 30, height: 40)
        var liveAnchorRect: CGRect { Self.live } }
}
enum Reason { case notFrontmost }
enum Failure { case targetChanged(Reason); var message: String { "failed" } }
enum ApplyOutcome { case applied; case failed(Failure) }
enum UndoOutcome { case restored; case failed(Failure) }
actor WriteBackController {
    var undoAvailable = true
    var writes = 0
    var cancellations = 0
    var succeed = false
    func setSucceed(_ value: Bool) { succeed = value }
    func apply(replacement: String) -> ApplyOutcome { writes += 1; return succeed ? .applied : .failed(.targetChanged(.notFrontmost)) }
    func undo() -> UndoOutcome { succeed ? .restored : .failed(.targetChanged(.notFrontmost)) }
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
@MainActor final class Status {
    var shown: [CGRect] = []
    var reanchored: [CGRect] = []
    func hide() {}
    func show(_ message: String, target: CGRect, undo: (() -> Void)?, cancel: (() -> Void)?) { shown.append(target) }
    func reanchor(_ target: CGRect) { reanchored.append(target) }
}
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
    var uncertainWrite = false
    var reanchor: Task<Void, Never>?
    var generation: UInt64 = 7
    var busy = false
    var restored = true
    func restoreFocus(_ target: TriggerController.Target) async -> Bool { restored }
'''
harness += method("apply") + "\n" + method("cancelPreview") + "\n" + method("showStatus") + "\n" + method("undoLast") + "\n}\n"
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
        // Result pills use the live composer rect, then re-anchor once, without blocking.
        let live = TriggerController.Target.live
        let stale = CGRect(x: 1, y: 2, width: 3, height: 4)
        for succeed in [true, false] {
            let controller = Controller()
            let core = WriteBackController()
            await core.setSucceed(succeed)
            let target = TriggerController.Target(pid: 42, bundleID: "fixture.app")
            controller.pending = core
            controller.pendingTarget = target
            controller.apply("replacement", token: 7)
            for _ in 0..<10000 { if !controller.busy { break }; await Task.yield() }
            precondition(controller.statusWindow.shown == [live], "apply result pill must use the live rect")
            precondition(controller.statusWindow.shown != [stale])
            TriggerController.Target.live = CGRect(x: 50, y: 60, width: 70, height: 80)
            try? await Task.sleep(for: .milliseconds(400))
            precondition(controller.statusWindow.reanchored == [TriggerController.Target.live], "pill must re-anchor once")
            TriggerController.Target.live = live
            controller.recovery = core
            controller.recoveryTarget = target
            controller.statusWindow.shown = []
            controller.undoLast()
            for _ in 0..<10000 { if !controller.busy { break }; await Task.yield() }
            await Task.yield()
            precondition(controller.statusWindow.shown == [live], "undo result pill must use the live rect")
        }
        // A new trigger or cancel drops a pending re-anchor.
        let controller = Controller()
        controller.showStatus("Restored", anchor: stale, refresh: { CGRect(x: 9, y: 9, width: 9, height: 9) })
        controller.cancelPreview()
        try? await Task.sleep(for: .milliseconds(300))
        precondition(controller.statusWindow.reanchored.isEmpty, "cancel must stop the re-anchor")
        // An unreadable (empty) refresh leaves the pill where it is.
        let steady = Controller()
        steady.showStatus("Restored", anchor: stale, refresh: { .zero })
        try? await Task.sleep(for: .milliseconds(300))
        precondition(steady.statusWindow.reanchored.isEmpty, "empty refresh must not move the pill")
        print("OptimizerControllerTests PASS (8 failed-apply/cancel scenarios, live-rect pills)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="benice-optimizer-tests-") as directory:
    swift = Path(directory) / "OptimizerControllerTests.swift"
    executable = Path(directory) / "tests"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
