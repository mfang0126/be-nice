"""Pure regression using the production diagnostic task with controlled completions.
Run: python3 -I mac-app/DiagnosticPublicationTests.py
No AppKit, AX, GUI, clipboard, credentials, or network are used.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / "Sources/benice/MenuBarShell.swift").read_text()
start = source.index("                    diagnosticGeneration &+= 1")
task = source.index("                    Task {", start)
opening = source.index("{", task)
depth, end = 1, opening + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
production = source[start:end].replace("Task {", "return Task {", 1)
property_line = next(line for line in source.splitlines() if "private var diagnosticGeneration =" in line)

harness = r'''
import Foundation

final class Gate: @unchecked Sendable {
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
}
enum SlackDiagnostic {
    static let a = Gate()
    static let b = Gate()
    static func response(requestID: String) throws -> Data {
        let gate = requestID == "A" ? a : b
        gate.started.continuation.yield(())
        gate.release.wait()
        return try JSONSerialization.data(withJSONObject: ["requestID": requestID])
    }
}
@MainActor final class Publisher {
'''
harness += property_line + r'''
    var refreshGeneration = 0
    func start(id: String, directory: URL) -> Task<Void, Never> {
'''
harness += production + "\n    }\n}\n"
harness += r'''
@main struct Tests {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let publisher = Publisher()
        var aStarted = SlackDiagnostic.a.started.stream.makeAsyncIterator()
        var bStarted = SlackDiagnostic.b.started.stream.makeAsyncIterator()
        let a = publisher.start(id: "A", directory: directory)
        await aStarted.next()
        let b = publisher.start(id: "B", directory: directory)
        await bStarted.next()
        // Permission polling must not invalidate an accepted diagnostic.
        publisher.refreshGeneration += 1
        SlackDiagnostic.b.release.signal()
        await b.value
        let result = directory.appendingPathComponent("slack-result.json")
        let bytes = try Data(contentsOf: result)
        let report = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
        precondition(report["requestID"] == "B", "newest response retains request correlation")
        SlackDiagnostic.a.release.signal()
        await a.value
        let finalBytes = try Data(contentsOf: result)
        precondition(finalBytes == bytes, "late A must not overwrite completed B")
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("DiagnosticPublicationTests PASS (B completes before A; permission refresh independent; response mode 0600)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="benice-diagnostic-tests-") as directory:
    swift = Path(directory) / "DiagnosticPublicationTests.swift"
    executable = Path(directory) / "tests"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable), directory], check=True, timeout=30)
