import Foundation

/// Deterministic self-check for CopilotAuth. No network, no real gh, no real token.
/// See `copilot-auth` in mac-app/scripts/run-tests.sh for the swiftc line.
@main
struct CopilotAuthTests {
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }
        typealias A = CopilotAuth
        func expectAuth(_ expected: A.AuthError, _ message: String, _ body: () throws -> String) {
            do { _ = try body(); expect(false, message + " (no error)") }
            catch { expect((error as? A.AuthError) == expected, message + " (got \(error))") }
        }

        // Candidates.
        expect(A.ghCandidates(path: "/a:/b:/a", home: "/h") == [
            "/a/gh", "/b/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/h/.local/bin/gh"],
               "candidates: PATH order, then fixed spots, deduped")
        expect(A.ghCandidates(path: "/usr/local/bin:/x", home: "/h") == [
            "/usr/local/bin/gh", "/x/gh", "/opt/homebrew/bin/gh", "/h/.local/bin/gh"],
               "candidates: fixed spot already on PATH is not repeated")
        for empty: String? in [nil, ""] {
            expect(A.ghCandidates(path: empty, home: "/h") == [
                "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/h/.local/bin/gh"],
                   "candidates: empty PATH gives only fixed spots")
        }

        // Environment scrubbing.
        let env = A.ghEnvironment(from: ["GITHUB_TOKEN": "x", "GH_TOKEN": "y", "PATH": "/p", "HOME": "/h"])
        expect(env["GITHUB_TOKEN"] == nil && env["GH_TOKEN"] == nil, "env: token vars removed")
        expect(env["GH_PROMPT_DISABLED"] == "1" && env["GH_NO_UPDATE_NOTIFIER"] == "1", "env: prompts disabled")
        expect(env["PATH"] == "/p" && env["HOME"] == "/h", "env: PATH and HOME kept")

        // usableModels.
        let json = """
        {"data":[
         {"id":"a","name":"Alpha","capabilities":{"type":"chat"},"policy":{"state":"enabled"}},
         {"id":"b","name":"Off","capabilities":{"type":"chat"},"policy":{"state":"disabled"}},
         {"id":"c","name":"Embed","capabilities":{"type":"embeddings"}},
         {"id":"d","name":"Responses","capabilities":{"type":"chat"},"supported_endpoints":["/responses"]},
         {"id":"e","capabilities":{"type":"chat"}},
         {"id":"f","name":"Both","capabilities":{"type":"chat"},"supported_endpoints":["/responses","/chat/completions"]},
         {"id":"g","name":"Empty list","capabilities":{"type":"chat"},"supported_endpoints":[]},
         {"id":"a","name":"Dup","capabilities":{"type":"chat"}},
         {"id":"","name":"No id","capabilities":{"type":"chat"}}
        ]}
        """
        let models = try! A.usableModels(from: Data(json.utf8))
        expect(models == [
            A.Model(id: "a", name: "Alpha"), A.Model(id: "e", name: "e"),
            A.Model(id: "f", name: "Both"), A.Model(id: "g", name: "Empty list")],
               "usableModels filters, keeps absent policy, dedupes, name falls back (got \(models))")
        for bad in ["not json", "{}", #"{"data":"x"}"#] {
            do {
                _ = try A.usableModels(from: Data(bad.utf8))
                expect(false, "bad JSON must throw: \(bad)")
            } catch {
                expect((error as? A.AuthError) == .models("unexpected response"), "bad JSON error for \(bad): \(error)")
            }
        }

        // defaultModel.
        let m1 = A.Model(id: "x", name: "x"), m2 = A.Model(id: "gpt-4o-mini", name: "mini")
        expect(A.defaultModel(in: [m1, m2]) == m2, "default prefers gpt-4o-mini")
        expect(A.defaultModel(in: [m1]) == m1, "default falls back to first")
        expect(A.defaultModel(in: []) == nil, "default of none is nil")

        // config(model:).
        let config = A.config(model: "m")
        expect(config.exactEndpoint == URL(string: "https://api.githubcopilot.com/chat/completions"),
               "config uses exact chat endpoint")
        expect(config.extraHeaders == ["Copilot-Integration-Id": "vscode-chat", "Editor-Version": "vscode/1.104.0"],
               "config carries both headers")

        expect(A.validToken("ghp_abcdefghijklmnopqrstuvwxyz0123\nextra") == "ghp_abcdefghijklmnopqrstuvwxyz0123", "validToken: first line only")
        expect(A.validToken("warning: not logged in") == nil && A.validToken("{\"a\":1}") == nil && A.validToken("short") == nil, "validToken: rejects non-tokens")
        expect(!A.ghCandidates(path: "relative/bin:/usr/bin", home: "/h").contains("relative/bin/gh"), "ghCandidates: relative PATH entries dropped")
        // token() with fake runner.
        let calls = Counter()
        A.isExecutable = { $0 == "/opt/homebrew/bin/gh" }
        A.runGh = { _, _ in calls.bump(); return "  ghp_testtoken0123456789abcd\n" }
        A.resetTokenCache()
        expect((try? A.token()) == "ghp_testtoken0123456789abcd", "token: success, trimmed")
        expect((try? A.token()) == "ghp_testtoken0123456789abcd" && calls.value == 1, "token: cache hit does not re-run")
        _ = try? A.token(refresh: true)
        expect(calls.value == 2, "token: refresh re-runs")
        A.resetTokenCache()
        A.runGh = { _, _ in "\n" }
        expectAuth(.notLoggedIn, "token: empty output") { try A.token() }
        A.runGh = { _, _ in nil }
        expectAuth(.notLoggedIn, "token: failed run") { try A.token() }
        A.isExecutable = { _ in false }
        expectAuth(.ghNotFound, "token: no candidates") { try A.token() }
        let missing = A.AuthError.ghNotFound.localizedDescription
        expect(missing.contains("cli.github.com") && missing.contains("brew install gh") && missing.contains("gh auth login"),
               "missing gh says how to install it, then log in: \(missing)")
        expect(!A.AuthError.notLoggedIn.localizedDescription.contains("install"), "installed but logged out only asks for a login")
        A.isExecutable = { $0 == "/opt/homebrew/bin/gh" || $0 == "/usr/local/bin/gh" }
        A.runGh = { path, _ in path == "/usr/local/bin/gh" ? "ghp_second0123456789abcdefg" : nil }
        expect((try? A.token()) == "ghp_second0123456789abcdefg", "token: failed candidate falls through to the next")
        A.resetTokenCache()

        // listModels via URLProtocol stub.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelsStub.self]
        let session = URLSession(configuration: configuration)
        ModelsStub.state.set(status: 200, body: json)
        let listed = try! await A.listModels(token: "ghp_testtoken0123456789abcd", session: session)
        expect(listed.map(\.id) == ["a", "e", "f", "g"], "listModels parses a 200")
        let seen = ModelsStub.state.lastRequest
        expect(seen?.url == A.modelsEndpoint && seen?.httpMethod == "GET", "listModels GETs the models endpoint")
        expect(seen?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_testtoken0123456789abcd", "listModels sends Bearer")
        expect(seen?.value(forHTTPHeaderField: "Copilot-Integration-Id") == "vscode-chat"
                && seen?.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.104.0", "listModels sends headers")
        for (status, expected) in [(401, A.AuthError.notLoggedIn), (500, .models("HTTP 500"))] {
            ModelsStub.state.set(status: status, body: "{}")
            do {
                _ = try await A.listModels(token: "ghp_testtoken0123456789abcd", session: session)
                expect(false, "listModels \(status) must throw")
            } catch {
                expect((error as? A.AuthError) == expected, "listModels \(status) error (got \(error))")
            }
        }
        session.invalidateAndCancel()

        if failures == 0 { print("SELFTEST PASS"); exit(0) }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        exit(1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class ModelsStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var last: URLRequest?
    func set(status: Int, body: String) { lock.withLock { self.status = status; self.body = Data(body.utf8) } }
    func record(_ request: URLRequest) { lock.withLock { last = request } }
    var lastRequest: URLRequest? { lock.withLock { last } }
    var response: (Int, Data) { lock.withLock { (status, body) } }
}

private final class ModelsStub: URLProtocol {
    static let state = ModelsStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        let (status, body) = Self.state.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
