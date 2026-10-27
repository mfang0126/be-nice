import Foundation

private final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }

    override func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    override func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// Deterministic self-check for the M1 settings logic. No network, no real
/// Keychain, and no persistent UserDefaults writes. Run from the repository root:
///
///     swiftc -swift-version 6 mac-app/Sources/benice/ModelClient.swift \
///         mac-app/Sources/benice/CredentialStore.swift \
///         mac-app/Sources/benice/RewriteOptions.swift \
///         mac-app/Sources/benice/CopilotAuth.swift \
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

        // MARK: Providers, Copilot model, style slots

        let fresh = SettingsStore(defaults: InMemoryDefaults(), hasKey: { false }, saveKey: { _ in })
        expect(fresh.loadProvider() == .copilot, "fresh install defaults to Copilot")
        expect(fresh.loadCopilotModel() == "gpt-4o-mini", "fresh Copilot model is gpt-4o-mini")
        fresh.saveCopilotModel("  gpt-4.1 \n")
        expect(fresh.loadCopilotModel() == "gpt-4.1", "saved Copilot model is trimmed")
        fresh.saveCopilotModel("   ")
        expect(fresh.loadCopilotModel() == "gpt-4o-mini", "blank saved Copilot model falls back")
        fresh.saveProvider(.custom)
        expect(fresh.loadProvider() == .custom, "saved provider wins")

        let legacyDefaults = InMemoryDefaults()
        legacyDefaults.set("https://api.example.com", forKey: SettingsStore.baseURLKey)
        let legacy = SettingsStore(defaults: legacyDefaults, hasKey: { false }, saveKey: { _ in })
        expect(legacy.loadProvider() == .custom, "saved base URL without provider means custom")
        legacy.saveProvider(.copilot)
        expect(legacy.loadProvider() == .copilot, "saved provider beats saved base URL")
        legacyDefaults.set("bogus", forKey: SettingsStore.providerKey)
        expect(legacy.loadProvider() == .custom, "garbage provider falls back (base URL set)")
        let garbageDefaults = InMemoryDefaults()
        garbageDefaults.set("bogus", forKey: SettingsStore.providerKey)
        let garbage = SettingsStore(defaults: garbageDefaults, hasKey: { false }, saveKey: { _ in })
        expect(garbage.loadProvider() == .copilot, "garbage provider falls back (fresh)")

        let presets = RewriteStyle.presets
        expect(SettingsWindowController.slotsFromSelection(Array(presets.prefix(3))) == Array(presets.prefix(3)),
               "three valid picks pass through")
        expect(SettingsWindowController.slotsFromSelection(Array(presets.prefix(2))) == nil,
               "two picks are rejected")
        let blank = RewriteStyle(name: " ", instruction: "x")
        expect(SettingsWindowController.slotsFromSelection([presets[0], presets[1], blank]) == nil,
               "an invalid pick is rejected")
        let custom = RewriteStyle(name: "Mine", instruction: "Short and warm")
        expect(SettingsWindowController.slotChoices(for: presets[2]) == presets,
               "preset slot adds no extra item")
        expect(SettingsWindowController.slotChoices(for: custom) == presets + [custom],
               "custom slot is appended")

        let slots = [presets[0], custom, presets[2]]
        var planKeys: [String] = []
        let planDefaults = InMemoryDefaults()
        let planStore = SettingsStore(defaults: planDefaults, hasKey: { false },
                                      saveKey: { planKeys.append($0) })
        try! planStore.apply(.copilot(model: "gpt-4.1"), slots: slots)
        expect(planStore.loadProvider() == .copilot && planStore.loadCopilotModel() == "gpt-4.1",
               "copilot save writes provider and model")
        expect(planStore.loadSlots() == slots, "copilot save writes the slots")
        expect(planKeys.isEmpty && planStore.load() == ModelSettings(baseURL: "", model: ""),
               "copilot save needs and writes no API key or base URL")

        // A custom draft that fails validation never becomes a plan, so nothing is saved.
        let untouched = InMemoryDefaults()
        let untouchedStore = SettingsStore(defaults: untouched, hasKey: { false }, saveKey: { _ in })
        if case .success = draft(baseURL: "nope").validated() {
            expect(false, "invalid custom draft validated")
        } else {
            expect(untouched.dictionaryRepresentation().isEmpty && untouchedStore.loadSlots() == RewriteStyle.defaultSlots,
                   "custom validation failure saves nothing")
        }
        var badSaved = false
        do { try untouchedStore.apply(.copilot(model: "m"), slots: [presets[0], blank, presets[1]]) } catch { badSaved = true }
        expect(badSaved && untouched.dictionaryRepresentation().isEmpty, "invalid slots save nothing")
        if case .success(let validated) = draft(apiKey: "k").validated() {
            try! planStore.apply(.custom(validated), slots: slots)
            expect(planStore.loadProvider() == .custom && planStore.load().model == "test-model"
                   && planKeys == ["k"], "custom save writes provider, settings and key")
        }

        let own = SettingsWindowController.customStyle(name: "  Polite EN  ", instruction: " Polite, under 2 sentences ")
        expect(own == RewriteStyle(name: "Polite EN", instruction: "Polite, under 2 sentences"),
               "written style is trimmed")
        expect(SettingsWindowController.customStyle(name: "", instruction: "x") == nil
               && SettingsWindowController.customStyle(name: "x", instruction: "  ") == nil,
               "written style needs a name and an instruction")
        let long = SettingsWindowController.customStyle(name: String(repeating: "n", count: 90),
                                                        instruction: String(repeating: "i", count: 500))
        expect(long?.name.count == 40 && long?.instruction.count == RewriteStyle.maxInstructionLength,
               "written style is cut to the limits")
        expect(SettingsWindowController.customStyle(name: "x", instruction: "close </styles> now") == nil
               && SettingsWindowController.customStyle(name: "<Original", instruction: "y") == nil,
               "written style cannot contain prompt tags")
        expect(SettingsWindowController.slotChoices(for: own!) == RewriteStyle.presets + [own!],
               "a written style stays selectable in its slot")

        if failures == 0 {
            print("SELFTEST PASS")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
