import Foundation

/// GitHub Copilot access through the user's own `gh` login. Be Nice never logs in, stores
/// or shows the token: it asks `gh auth token` each app run and uses it as the Bearer.
/// The Copilot chat API is undocumented by GitHub (PLAN 「模型接入」); drafts go to GitHub.
enum CopilotAuth {
    static let chatEndpoint = URL(string: "https://api.githubcopilot.com/chat/completions")!
    static let modelsEndpoint = URL(string: "https://api.githubcopilot.com/models")!
    static let preferredModel = "gpt-4o-mini"
    static let headers = ["Copilot-Integration-Id": "vscode-chat", "Editor-Version": "vscode/1.104.0"]

    struct Model: Equatable, Sendable {
        let id: String
        let name: String
    }

    enum AuthError: Error, Equatable, LocalizedError {
        case ghNotFound
        case notLoggedIn
        case models(String)

        var errorDescription: String? {
            switch self {
            case .ghNotFound:
                return "GitHub CLI (gh) isn't installed. Get it from cli.github.com or run `brew install gh`, "
                    + "then run `gh auth login` in Terminal and try again."
            case .notLoggedIn:
                return "GitHub login not found. Run `gh auth login` in Terminal first, then try again."
            case .models(let message):
                return "Couldn't load Copilot models: \(message)"
            }
        }
    }

    /// Where `gh` may live: PATH first, then Homebrew and ~/.local/bin (a menu-bar app has a
    /// minimal PATH). Order is preserved and duplicates removed. Pure: no filesystem checks.
    static func ghCandidates(path: String?, home: String) -> [String] {
        let dirs = (path ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/gh" }
        var seen = Set<String>()
        return (dirs + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home + "/.local/bin/gh"])
            .filter { seen.insert($0).inserted }
    }

    /// Environment for `gh auth token`: no GITHUB_TOKEN / GH_TOKEN short-circuit, no prompts.
    static func ghEnvironment(from base: [String: String]) -> [String: String] {
        var env = base
        env["GITHUB_TOKEN"] = nil
        env["GH_TOKEN"] = nil
        env["GH_HOST"] = nil  // always the github.com login, never an enterprise host
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        return env
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable {
            struct Capabilities: Decodable { let type: String? }
            struct Policy: Decodable { let state: String? }
            let id: String?
            let name: String?
            let capabilities: Capabilities?
            let policy: Policy?
            let supported_endpoints: [String]?
        }
        let data: [Entry]
    }

    /// Chat models the account can use: type chat, policy not disabled, and either no declared
    /// endpoints or `/chat/completions` among them. Input is the decoded `/models` JSON.
    static func usableModels(from json: Data) throws -> [Model] {
        guard let response = try? JSONDecoder().decode(ModelsResponse.self, from: json) else {
            throw AuthError.models("unexpected response")
        }
        var seen = Set<String>()
        var models: [Model] = []
        for entry in response.data {
            guard let id = entry.id, !id.isEmpty,
                  entry.capabilities?.type == "chat",
                  entry.policy?.state != "disabled" else { continue }
            if let endpoints = entry.supported_endpoints, !endpoints.isEmpty,
               !endpoints.contains("/chat/completions") { continue }
            guard seen.insert(id).inserted else { continue }
            models.append(Model(id: id, name: entry.name ?? id))
        }
        return models
    }

    /// `preferredModel` when listed, else the first model, else nil.
    static func defaultModel(in models: [Model]) -> Model? {
        models.first { $0.id == preferredModel } ?? models.first
    }

    static func config(model: String) -> ModelConfig {
        ModelConfig(baseURL: URL(string: "https://api.githubcopilot.com")!, model: model,
                    exactEndpoint: chatEndpoint, extraHeaders: headers)
    }

    // Test seams: tests replace these so the real gh and filesystem are never touched.
    /// Runs `gh auth token` at the path; returns stdout, or nil on non-zero exit / timeout.
    nonisolated(unsafe) static var runGh: @Sendable (_ path: String, _ environment: [String: String]) -> String? = runRealGh
    nonisolated(unsafe) static var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedToken: String?

    static func resetTokenCache() { cacheLock.withLock { cachedToken = nil } }

    /// The user's token from `gh auth token`, cached for the app run; `refresh` re-reads it
    /// (after a 401). Blocking: call from a detached task, never the main actor.
    static func token(refresh: Bool = false) throws -> String {
        if refresh { cacheLock.withLock { cachedToken = nil } }  // a failed re-read must not keep an expired token
        else if let cached = cacheLock.withLock({ cachedToken }) { return cached }
        let candidates = ghCandidates(path: ProcessInfo.processInfo.environment["PATH"],
                                      home: NSHomeDirectory()).filter(isExecutable)
        guard !candidates.isEmpty else { throw AuthError.ghNotFound }
        let env = ghEnvironment(from: ProcessInfo.processInfo.environment)
        for path in candidates {
            guard let out = runGh(path, env) else { continue }
            guard let token = validToken(out) else { continue }
            cacheLock.withLock { cachedToken = token }
            return token
        }
        throw AuthError.notLoggedIn
    }

    /// First line of `gh` output if it looks like a GitHub token; anything else (warnings, JSON) is rejected.
    static func validToken(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.range(of: #"^[A-Za-z0-9_.-]{20,255}$"#, options: .regularExpression) == nil ? nil : line
    }

    private static func runRealGh(path: String, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// GET /models with the token. Blocking-safe: uses URLSession async.
    static func listModels(token: String, session: URLSession = ModelClient.safeSession) async throws -> [Model] {
        var request = URLRequest(url: modelsEndpoint, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AuthError.models(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.models("unexpected response") }
        if http.statusCode == 401 { resetTokenCache(); throw AuthError.notLoggedIn }
        guard (200..<300).contains(http.statusCode) else { throw AuthError.models("HTTP \(http.statusCode)") }
        return try usableModels(from: data)
    }
}
