import Foundation

private final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }

    override func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// Deterministic self-check for the M1 settings logic. No network, no real
/// Keychain, and no persistent UserDefaults writes. Run from the repository root:
///
///     swiftc -swift-version 6 mac-app/Sources/benice/ModelClient.swift \
///         mac-app/Sources/benice/CredentialStore.swift \
///         mac-app/Sources/benice/SettingsWindow.swift \
///         mac-app/SettingsTests.swift -o /tmp/benice-settings-tests
///     /tmp/benice-settings-tests
@main
struct SettingsTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                print("SELFTEST FAIL: \(message)")
            }
        }
        func draft(baseURL: String = "https://api.example.com",
                   model: String = "test-model",
                   apiKey: String = "",
                   hasStoredAPIKey: Bool = false) -> SettingsDraft {
            SettingsDraft(baseURL: baseURL, model: model, apiKey: apiKey,
                          hasStoredAPIKey: hasStoredAPIKey)
        }
        func expectFailure(_ result: Result<ValidatedSettings, SettingsError>,
                           _ expected: SettingsError, _ message: String) {
            switch result {
            case .success:
                expect(false, message + " (unexpected success)")
            case .failure(let error):
                expect(error == expected, message + " (got \(error))")
            }
        }

        // MARK: Validation

        switch draft(apiKey: "  sk-explicit\n").validated() {
        case .success(let validated):
            expect(validated.settings == ModelSettings(baseURL: "https://api.example.com",
                                                       model: "test-model"),
                   "valid draft trims base URL and model")
            expect(validated.apiKeyToSave == "sk-explicit",
                   "explicit API key is trimmed and offered for saving")
        case .failure(let error):
            expect(false, "valid explicit-key draft rejected: \(error)")
        }

        switch draft(hasStoredAPIKey: true).validated() {
        case .success(let validated):
            expect(validated.apiKeyToSave == nil,
                   "blank input keeps the stored key instead of overwriting it")
        case .failure(let error):
            expect(false, "blank key with stored key rejected: \(error)")
        }

        switch draft(apiKey: "  \n", hasStoredAPIKey: true).validated() {
        case .success(let validated):
            expect(validated.apiKeyToSave == nil,
                   "whitespace-only key keeps the stored key")
        case .failure(let error):
            expect(false, "whitespace-only key with stored key rejected: \(error)")
        }

        expectFailure(draft(apiKey: "").validated(), .missingAPIKey,
                      "blank key with no stored key")
        expectFailure(draft(baseURL: "  ").validated(), .emptyBaseURL,
                      "whitespace-only base URL")
        expectFailure(draft(baseURL: "api.example.com").validated(), .invalidBaseURL,
                      "base URL without scheme")
        expectFailure(draft(baseURL: "http://api.example.com").validated(), .invalidBaseURL,
                      "non-loopback plaintext HTTP")
        expectFailure(draft(baseURL: "https://api.example.com?x=1").validated(),
                      .invalidBaseURL, "base URL with query")
        expectFailure(draft(baseURL: "https://user:pass@api.example.com").validated(),
                      .invalidBaseURL, "credentials in base URL")
        expectFailure(draft(baseURL: "https://user@api.example.com").validated(),
                      .invalidBaseURL, "username-only credentials in base URL")
        expectFailure(draft(baseURL: "https://api.example.com/v1/chat/completions").validated(),
                      .invalidBaseURL, "full endpoint instead of base URL")
        expectFailure(draft(model: " \n").validated(), .emptyModel, "whitespace-only model")

        switch draft(baseURL: "http://localhost:11434", model: " local ", apiKey: "k")
            .validated() {
        case .success(let validated):
            expect(validated.settings == ModelSettings(baseURL: "http://localhost:11434",
                                                       model: "local"),
                   "loopback HTTP and model trimming accepted")
        case .failure(let error):
            expect(false, "loopback HTTP rejected: \(error)")
        }

        // MARK: Persistence (in-memory defaults, fake Keychain)

        let defaults = InMemoryDefaults()
        var storedKey: String?
        var savedKeys: [String] = []
        let store = SettingsStore(
            defaults: defaults,
            hasKey: { storedKey != nil },
            saveKey: { key in
                savedKeys.append(key)
                storedKey = key
            })

        expect(store.load() == ModelSettings(baseURL: "", model: ""),
               "empty defaults load as empty settings")
        expect(try! !store.hasStoredAPIKey(), "no stored key is reported as absent")

        let first = ValidatedSettings(
            settings: ModelSettings(baseURL: "https://api.example.com", model: "m1"),
            apiKeyToSave: "sk-secret-1")
        try! store.save(first)
        expect(store.load() == first.settings, "saved base URL and model load back")
        expect(savedKeys == ["sk-secret-1"], "explicit key is written to the credential store")
        expect(try! store.hasStoredAPIKey(), "saved key is reported as stored")
        let persisted = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? String }
        expect(!persisted.contains { $0.contains("sk-secret-1") },
               "API key is never written to UserDefaults")

        let second = ValidatedSettings(
            settings: ModelSettings(baseURL: "https://api.example.com", model: "m2"),
            apiKeyToSave: nil)
        try! store.save(second)
        expect(savedKeys == ["sk-secret-1"],
               "blank API key input does not rewrite the credential store")
        expect(store.load().model == "m2", "model-only save updates defaults")

        // Keychain read errors propagate as errors, not as "no key stored".
        struct KeychainReadFailure: Error {}
        let unreadable = SettingsStore(
            defaults: defaults,
            hasKey: { throw KeychainReadFailure() },
            saveKey: { _ in })
        var readThrew = false
        do {
            _ = try unreadable.hasStoredAPIKey()
        } catch {
            readThrew = true
        }
        expect(readThrew, "Keychain read error is not collapsed into a missing key")

        // A failed Keychain write must not leave UserDefaults half-updated.
        struct KeychainWriteFailure: Error {}
        let failingSave = SettingsStore(
            defaults: defaults,
            hasKey: { storedKey != nil },
            saveKey: { _ in throw KeychainWriteFailure() })
        let beforeFailedSave = store.load()
        let failingWrite = ValidatedSettings(
            settings: ModelSettings(baseURL: "https://changed.example.com", model: "m3"),
            apiKeyToSave: "sk-secret-2")
        var saveThrew = false
        do {
            try failingSave.save(failingWrite)
        } catch {
            saveThrew = true
        }
        expect(saveThrew, "failed Keychain write surfaces an error")
        expect(store.load() == beforeFailedSave,
               "failed Keychain write leaves UserDefaults unchanged")
        expect(savedKeys == ["sk-secret-1"],
               "failed Keychain write does not touch the credential store")

        if failures == 0 {
            print("SELFTEST PASS")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
