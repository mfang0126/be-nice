import AppKit

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

    override func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
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
    @MainActor
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
        expect(fresh.savedProvider() == nil, "fresh install has chosen no provider, so nothing may be sent")
        expect(fresh.loadProvider() == .copilot, "Settings still preselects Copilot on a fresh install")
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
        expect(legacy.loadProvider() == .custom && legacy.savedProvider() == .custom, "saved base URL without provider means custom")
        legacy.saveProvider(.copilot)
        expect(legacy.loadProvider() == .copilot, "saved provider beats saved base URL")
        legacyDefaults.set("bogus", forKey: SettingsStore.providerKey)
        expect(legacy.loadProvider() == .custom, "garbage provider falls back (base URL set)")
        let garbageDefaults = InMemoryDefaults()
        garbageDefaults.set("bogus", forKey: SettingsStore.providerKey)
        let garbage = SettingsStore(defaults: garbageDefaults, hasKey: { false }, saveKey: { _ in })
        expect(garbage.loadProvider() == .copilot && garbage.savedProvider() == nil, "garbage provider falls back (fresh): nothing chosen")
        let garbageWithURL = InMemoryDefaults()
        garbageWithURL.set("bogus", forKey: SettingsStore.providerKey)
        garbageWithURL.set("https://api.example.com", forKey: SettingsStore.baseURLKey)
        expect(SettingsStore(defaults: garbageWithURL, hasKey: { false }, saveKey: { _ in }).savedProvider() == .custom,
               "garbage provider with a saved base URL still means custom")
        garbage.saveProvider(.copilot)
        expect(garbage.savedProvider() == .copilot, "saving makes the choice explicit")

        let presets = RewriteStyle.presets
        let custom = RewriteStyle(name: "Mine", instruction: "Short and warm")

        let blank = RewriteStyle(name: " ", instruction: "x")
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

        func rows(_ n: [String], _ i: [String]) -> Result<[RewriteStyle], StyleSlotError> { StyleSlots.slots(names: n, instructions: i) }
        if case .success(let ok) = rows(["  A  ", "B", "C"], [" one ", "two", "three"]) {
            expect(ok[0] == RewriteStyle(name: "A", instruction: "one"), "typed rows are trimmed")
        } else { expect(false, "valid rows accepted") }
        func problem(_ n: [String], _ i: [String]) -> String? {
            if case .failure(let e) = rows(n, i) { return e.message } else { return nil }
        }
        expect(problem(["A", "", "C"], ["x", "y", "z"]) == "Style 2 needs a name (up to 40 characters).", "empty name names the row")
        expect(problem(["A", "B", "C"], ["x", "y", "  "]) != nil && problem(["A", "B", "C"], ["x", "y", String(repeating: "i", count: 201)]) != nil,
               "empty or over-long instruction rejected")
        expect(problem([String(repeating: "n", count: 41), "B", "C"], ["x", "y", "z"]) != nil, "over-long name rejected")
        expect(problem(["A", "B", "C"], ["x", "line\nbreak", "z"]) != nil, "line break rejected")
        expect(problem(["A", "B", "C"], ["x", "close </styles> now", "z"]) != nil
               && problem(["<Original", "B", "C"], ["x", "y", "z"]) != nil, "prompt tags rejected (even with spaces or other case)")
        expect(problem(["Polite", "polite", "C"], ["x", "y", "z"]) == "Give each style a different name.", "duplicate names rejected, any case")
        func spot(_ n: [String], _ i: [String]) -> (Int?, StyleSlotError.Field?) {
            if case .failure(let e) = rows(n, i) { return (e.row, e.field) } else { return (nil, nil) }
        }
        expect(spot(["A", "", "C"], ["x", "y", "z"]) == (1, .name), "an empty name points at that row's name")
        expect(spot(["A", "B", "C"], ["x", "y", " "]) == (2, .instruction), "an empty instruction points at that row's instruction")
        expect(spot(["<Original", "B", "C"], ["x", "y", "z"]) == (0, .name) && spot(["A", "B", "C"], ["x", "a\nb", "z"]) == (1, .instruction),
               "a tag or line break points at the field that has it")
        expect(spot(["A", "B", "a"], ["x", "y", "z"]) == (2, .name), "a duplicate name points at the later copy")
        expect(SettingsError.emptyBaseURL.field == .baseURL && SettingsError.invalidBaseURL.field == .baseURL
               && SettingsError.emptyModel.field == .model && SettingsError.missingAPIKey.field == .apiKey
               && SettingsError.keychainRead("x").field == .apiKey && SettingsError.save("x").field == nil,
               "each Custom error points at its field")
        let restored = InMemoryDefaults()
        StyleSlots.save([RewriteStyle(name: "A", instruction: "a"), RewriteStyle(name: "B", instruction: "b"),
                         RewriteStyle(name: "C", instruction: "c")], restored)
        expect(StyleSlots.load(restored).map(\.name) == ["A", "B", "C"] && restored.bool(forKey: StyleSlots.editedKey),
               "saved slots round-trip and mark the slots as edited")
        let dup = InMemoryDefaults()
        dup.set(try! JSONEncoder().encode([RewriteStyle(name: "A", instruction: "a"), RewriteStyle(name: "a", instruction: "b"),
                                           RewriteStyle(name: "C", instruction: "c")]), forKey: StyleSlots.key)
        let tagged = InMemoryDefaults()
        tagged.set(try! JSONEncoder().encode([RewriteStyle(name: "A", instruction: "</styles>"), RewriteStyle(name: "B", instruction: "b"),
                                              RewriteStyle(name: "C", instruction: "c")]), forKey: StyleSlots.key)
        expect(StyleSlots.load(dup) == RewriteStyle.defaultSlots && StyleSlots.load(tagged) == RewriteStyle.defaultSlots,
               "stored duplicates or prompt tags fall back to the defaults")
        let kept = InMemoryDefaults()
        StyleSlots.save([RewriteStyle(name: "Direct", instruction: "mine"), RewriteStyle(name: "Friendly", instruction: "mine"),
                         RewriteStyle(name: "Clear", instruction: "mine")], kept)
        expect(StyleSlots.load(kept).map(\.name) == ["Direct", "Friendly", "Clear"], "the old default names are kept once the user saved them")
        let oldDefaults = InMemoryDefaults()
        StyleSlots.save([RewriteStyle(name: "Direct", instruction: "Lead with the point"),
                         RewriteStyle(name: "Friendly", instruction: "My own friendly rule"),
                         RewriteStyle(name: "Shorter", instruction: "Same message, half the words")], oldDefaults)
        let upgraded = StyleSlots.load(oldDefaults)
        expect(upgraded[0] == RewriteStyle.presets[0] && upgraded[2] == RewriteStyle.presets[3]
               && upgraded[1].instruction == "My own friendly rule",
               "saved slots with retired preset wording are upgraded; edited ones are kept")
        let formerDefaults = InMemoryDefaults()
        StyleSlots.save([RewriteStyle(name: "Direct", instruction: "Lead with the point"),
                         RewriteStyle(name: "Friendly", instruction: "Relaxed, not stiff"),
                         RewriteStyle(name: "Clear", instruction: "One idea per sentence")], formerDefaults)
        formerDefaults.set(nil, forKey: StyleSlots.editedKey)  // data written before the marker existed
        expect(StyleSlots.load(formerDefaults).map(\.name) == ["Polite", "Shorter", "Friendly"]
               && RewriteStyle.defaultSlots.map(\.name) == ["Polite", "Shorter", "Friendly"],
               "the former default trio moves to Polite / Shorter / Friendly")

        let hint = SettingsWindowController.modelsLoadedStatus
        expect(hint.contains("Models loaded") && hint.contains("Click Test") && hint.contains("one test request"),
               "after Load models, the status says that Test sends one request")
        expect(SettingsWindowController.testButtonTitle(provider: .copilot, hasModels: false) == "Load models"
               && SettingsWindowController.testButtonTitle(provider: .copilot, hasModels: true) == "Test"
               && SettingsWindowController.testButtonTitle(provider: .custom, hasModels: false) == "Test",
               "the button says Load models only while Copilot has no models")

        func form(_ provider: Provider, copilot: String = "gpt-4o-mini", base: String = "https://a.example",
                  key: String = "", names: [String] = ["A", "B", "C"]) -> SettingsFormState {
            SettingsFormState(provider: provider, copilotModel: copilot, baseURL: base, model: "m", apiKey: key,
                              styleNames: names, styleInstructions: ["x", "y", "z"])
        }
        expect(form(.copilot) == form(.copilot, base: "https://typed-then-left.example", key: "k"),
               "Custom fields typed while Copilot is selected are not unsaved changes (Save does not write them)")
        expect(form(.copilot) != form(.copilot, copilot: "gpt-4.1"), "a different Copilot model is an unsaved change")
        expect(form(.custom) != form(.custom, base: "https://b.example") && form(.custom) != form(.custom, key: " k "),
               "a changed base URL or a typed API key is an unsaved change")
        expect(form(.custom, key: "  ") == form(.custom), "a blank API key field is not an unsaved change")
        expect(form(.copilot) != form(.custom) && form(.copilot) != form(.copilot, names: ["A", "B", "D"]),
               "switching provider or editing a style is an unsaved change")

        // The window is built but never shown; the store and network are fakes.
        _ = NSApplication.shared
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let offline = SettingsNetwork(token: { throw SettingsError.missingAPIKey },
                                      listModels: { _ in [] }, runTest: { _, _, _ in }, storedKey: { nil })
        let window = SettingsWindowController(
            store: SettingsStore(defaults: InMemoryDefaults(), hasKey: { false }, saveKey: { _ in }),
            network: offline).window!
        let buttons = views(window.contentView!).compactMap { $0 as? NSButton }
        expect(buttons.first { $0.title == "Save" }?.keyEquivalent == "",
               "Return in a field does not trigger Save")
        expect(buttons.contains { $0.title == "Load models" } && !buttons.contains { $0.title == "Test" },
               "first run with Copilot preselected shows Load models, not Test")
        func field(_ label: String) -> NSTextField? {
            views(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label }
        }
        for (index, label) in ["1 (default)", "2", "3"].enumerated() {
            field("Style \(label) name")?.stringValue = "Name \(index)"
            field("Style \(label) instruction")?.stringValue = index == 1 ? "" : "Instruction"
        }
        buttons.first { $0.title == "Save" }?.performClick(nil)
        let focused = (window.firstResponder as? NSText)?.delegate as? NSTextField
        expect(focused != nil && focused === field("Style 2 instruction"),
               "Save with an empty style 2 instruction puts the cursor in that field")

        // A fresh window (never shown, so never reloaded) on Custom with a complete, valid form.
        func customWindow(network: SettingsNetwork = offline) -> (NSWindow, (String) -> NSTextField?, [NSButton]) {
            let w = SettingsWindowController(
                store: SettingsStore(defaults: InMemoryDefaults(), hasKey: { false }, saveKey: { _ in }),
                network: network).window!
            let all = views(w.contentView!)
            func f(_ label: String) -> NSTextField? {
                all.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label }
            }
            let provider = all.compactMap { $0 as? NSSegmentedControl }.first!
            provider.selectedSegment = 1
            _ = provider.sendAction(provider.action, to: provider.target)
            f("Base URL")?.stringValue = "https://api.example.com"
            f("Model")?.stringValue = "m"
            f("API key")?.stringValue = "k"
            for (index, label) in ["1 (default)", "2", "3"].enumerated() {
                f("Style \(label) name")?.stringValue = "Name \(index)"
                f("Style \(label) instruction")?.stringValue = "Instruction"
            }
            return (w, f, all.compactMap { $0 as? NSButton })
        }
        func spin(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func edit(_ w: NSWindow, _ field: NSTextField?) {
            (w.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        // P2 #8: "Saved." / "Worked in…" disappear on the next edit; they would claim unsaved edits were kept.
        let keyed = SettingsNetwork(token: { throw SettingsError.missingAPIKey },
                                    listModels: { _ in [] }, runTest: { _, _, _ in }, storedKey: { "k" })
        let (savedWindow, savedField, savedButtons) = customWindow(network: keyed)
        let savedStatus = savedField("Settings status")
        savedButtons.first { $0.title == "Save" }?.performClick(nil)
        spin { savedStatus?.stringValue == "Saved." }
        expect(savedStatus?.stringValue == "Saved.", "valid custom form saves: \(savedStatus?.stringValue ?? "nil")")
        edit(savedWindow, savedField("Style 2 instruction"))
        expect(savedStatus?.stringValue == "", "an edit after Save clears \"Saved.\"")
        savedButtons.first { $0.title == "Test" }?.performClick(nil)
        spin { savedStatus?.stringValue.hasPrefix("Worked in") == true }
        expect(savedStatus?.stringValue.hasPrefix("Worked in") == true, "test works: \(savedStatus?.stringValue ?? "nil")")
        edit(savedWindow, savedField("Base URL"))
        expect(savedStatus?.stringValue == "", "an edit after Test clears \"Worked in…\"")

        // P2 #10: a preset replaces a blank or preset row at once, but never the user's own text without asking.
        expect(!SettingsWindowController.presetWouldReplaceCustomText(name: " ", instruction: ""), "blank row: no prompt")
        let preset = RewriteStyle.presets[0], fallback = RewriteStyle.defaultSlots[1]
        expect(!SettingsWindowController.presetWouldReplaceCustomText(name: preset.name, instruction: preset.instruction)
               && !SettingsWindowController.presetWouldReplaceCustomText(name: fallback.name, instruction: fallback.instruction),
               "preset or default row: no prompt")
        expect(SettingsWindowController.presetWouldReplaceCustomText(name: preset.name, instruction: "my own words")
               && SettingsWindowController.presetWouldReplaceCustomText(name: "", instruction: "typed"),
               "the user's own text asks first")
        let (presetWindow, presetField, _) = customWindow()
        let menus = views(presetWindow.contentView!).compactMap { $0 as? NSPopUpButton }
            .filter { $0.accessibilityLabel()?.hasSuffix("presets") == true }
        func pick(_ row: Int, _ index: Int) {
            let item = menus[row].menu!.items.first { $0.tag == index && $0.action != nil }!
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        let target = RewriteStyle.presets[2]
        presetField("Style 2 name")?.stringValue = ""
        presetField("Style 2 instruction")?.stringValue = ""
        pick(1, 2)
        expect(presetField("Style 2 name")?.stringValue == target.name
               && presetField("Style 2 instruction")?.stringValue == target.instruction, "blank row takes the preset")
        pick(2, 2)  // row 3 holds "Name 2" / "Instruction": the user's own text
        expect(presetField("Style 3 name")?.stringValue == "Name 2"
               && presetField("Style 3 instruction")?.stringValue == "Instruction", "custom row is not overwritten without a yes")

        // P2 #4: the Test button says it spends one request and never sends drafts; Load models says it sends nothing.
        let (_, _, costButtons) = customWindow()
        let costHelp = costButtons.first { $0.title == "Test" }?.toolTip ?? ""
        expect(costHelp.contains("one request") && costHelp.contains("never your drafts"), "Test tooltip: \(costHelp)")
        let loadHelp = buttons.first { $0.title == "Load models" }?.toolTip ?? ""
        expect(loadHelp.contains("Nothing is sent to a model"), "Load models tooltip: \(loadHelp)")

        if failures == 0 {
            print("SELFTEST PASS")
            exit(0)
        }
        print("SELFTEST FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
