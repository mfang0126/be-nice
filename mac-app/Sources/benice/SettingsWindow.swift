import AppKit

// MARK: - Settings model (pure logic, covered by SettingsTests)

/// Non-secret model configuration persisted in `UserDefaults`.
struct ModelSettings: Equatable {
    var baseURL: String
    var model: String
}

enum Provider: String, Equatable, Sendable {
    case copilot, custom
}

enum SettingsError: Error, Equatable, LocalizedError {
    case emptyBaseURL
    case invalidBaseURL
    case emptyModel
    case missingAPIKey
    case keychainRead(String)
    case save(String)

    var errorDescription: String? {
        switch self {
        case .emptyBaseURL:
            return "Enter a base URL, for example https://api.example.com."
        case .invalidBaseURL:
            return "Base URL must be an https URL (http is allowed only for localhost), "
                + "without query, fragment, or credentials."
        case .emptyModel:
            return "Enter a model name."
        case .missingAPIKey:
            return "Enter an API key."
        case .keychainRead(let message):
            return "Could not read the Keychain: \(message)"
        case .save(let message):
            return "Could not save settings: \(message)"
        }
    }
}

struct ValidatedSettings: Equatable {
    var settings: ModelSettings
    /// `nil` means "keep the key already stored in the Keychain".
    var apiKeyToSave: String?
}

/// Raw form state. Validation reuses `ModelClient.endpoint(for:)` so the
/// settings window and the request path agree on what a valid base URL is.
struct SettingsDraft: Equatable {
    var baseURL: String
    var model: String
    var apiKey: String
    var hasStoredAPIKey: Bool

    func validated() -> Result<ValidatedSettings, SettingsError> {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .failure(.emptyBaseURL) }
        guard let url = URL(string: base), ModelClient.endpoint(for: url) != nil else {
            return .failure(.invalidBaseURL)
        }

        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyModel) }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || hasStoredAPIKey else { return .failure(.missingAPIKey) }

        return .success(ValidatedSettings(
            settings: ModelSettings(baseURL: base, model: name),
            apiKeyToSave: key.isEmpty ? nil : key))
    }
}

/// Persists base URL/model in `UserDefaults` and the API key in `CredentialStore`.
/// The Keychain accessors are injectable so tests never touch the login keychain.
///
/// `@unchecked Sendable`: the injected closures must be thread-safe. Instances
/// are immutable after construction, and the UI deliberately calls the Keychain
/// accessors from a detached task because they can block or show a system prompt.
struct SettingsStore: @unchecked Sendable {
    static let baseURLKey = "be-nice.model.baseURL"
    static let modelKey = "be-nice.model.id"

    static let providerKey = "be-nice.provider"
    static let copilotModelKey = "be-nice.copilot.model"

    private let defaults: UserDefaults
    private let hasKey: () throws -> Bool
    private let saveKey: (String) throws -> Void

    init(defaults: UserDefaults = .standard,
         hasKey: @escaping () throws -> Bool = { try CredentialStore.hasAPIKey() },
         saveKey: @escaping (String) throws -> Void = { try CredentialStore.saveAPIKey($0) }) {
        self.defaults = defaults
        self.hasKey = hasKey
        self.saveKey = saveKey
    }

    /// Synchronous and non-secret; safe on the main actor.
    func load() -> ModelSettings {
        ModelSettings(
            baseURL: defaults.string(forKey: Self.baseURLKey) ?? "",
            model: defaults.string(forKey: Self.modelKey) ?? "")
    }

    /// The saved choice; else `.custom` for installs that already saved a base URL (they were
    /// configured before providers existed), else `.copilot`.
    func loadProvider() -> Provider {
        if let raw = defaults.string(forKey: Self.providerKey), let saved = Provider(rawValue: raw) {
            return saved
        }
        return load().baseURL.isEmpty ? .copilot : .custom
    }

    func saveProvider(_ provider: Provider) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
    }

    func loadCopilotModel() -> String {
        let saved = defaults.string(forKey: Self.copilotModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved! : CopilotAuth.preferredModel
    }

    func saveCopilotModel(_ id: String) {
        defaults.set(id, forKey: Self.copilotModelKey)
    }

    /// Presence check only; the secret value never reaches the UI or logs.
    func hasStoredAPIKey() throws -> Bool {
        try hasKey()
    }

    /// Writes the key first so a rejected/prompt-cancelled Keychain write
    /// leaves the UserDefaults configuration untouched.
    func save(_ validated: ValidatedSettings) throws {
        if let key = validated.apiKeyToSave {
            do {
                try saveKey(key)
            } catch {
                throw SettingsError.save(error.localizedDescription)
            }
        }
        defaults.set(validated.settings.baseURL, forKey: Self.baseURLKey)
        defaults.set(validated.settings.model, forKey: Self.modelKey)
    }
}

// MARK: - Save plan (pure persistence, covered by SettingsTests)

/// What Save writes for the chosen provider. A custom plan carries an already
/// validated draft, so a validation failure never reaches the store.
enum SettingsSavePlan: Equatable, Sendable {
    case copilot(model: String)
    case custom(ValidatedSettings)
}

extension SettingsStore {
    func loadSlots() -> [RewriteStyle] {
        StyleSlots.load(defaults)
    }

    /// Custom first: a rejected Keychain write throws before anything else is written.
    func apply(_ plan: SettingsSavePlan, slots: [RewriteStyle]) throws {
        guard slots.count == 3, slots.allSatisfy(StyleSlots.isValid), StyleSlots.hasDistinctNames(slots) else {
            throw SettingsError.save("Each of the three styles needs a name, an instruction and a different name.")
        }
        switch plan {
        case .copilot(let model):
            saveProvider(.copilot)
            saveCopilotModel(model)
        case .custom(let validated):
            try save(validated)
            saveProvider(.custom)
        }
        StyleSlots.save(slots, defaults)
    }
}

/// Everything the window needs from the network or `gh`; tests inject fakes.
/// The closures run on detached tasks and must be thread-safe.
struct SettingsNetwork: Sendable {
    var token: @Sendable () throws -> String
    var listModels: @Sendable (String) async throws -> [CopilotAuth.Model]
    /// One real rewrite with the given config and bearer/API key.
    var runTest: @Sendable (ModelConfig, String, [RewriteStyle]) async throws -> Void
    var storedKey: @Sendable () throws -> String?

    static let testDraft = "hi, the numbers in the report look off, can you fix them by tomorrow?"

    static let live = SettingsNetwork(
        token: { try CopilotAuth.token() },
        listModels: { try await CopilotAuth.listModels(token: $0) },
        runTest: { config, key, styles in
            _ = try await ModelClient(config: config, apiKey: key)
                .rewriteOptions(text: SettingsNetwork.testDraft, styles: styles)
        },
        storedKey: { try CredentialStore.loadAPIKey() })
}

/// Detached-task results. Plain `String` messages keep the payload Sendable.
private enum KeyPresenceResult: Sendable {
    case present(Bool)
    case failed(String)
}

private enum SaveResult: Sendable {
    case saved
    case failed(String)
}

private enum ModelsResult: Sendable {
    case models([CopilotAuth.Model])
    case failed(String)
}

private enum TestInput: Sendable {
    case copilot(model: String)
    case custom(ModelConfig, apiKey: String?)
}

private enum TestResult: Sendable {
    case worked(seconds: Double)
    case failed(String)
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let contentWidth: CGFloat = 560

    private let store: SettingsStore
    private let network: SettingsNetwork

    private let providerControl = NSSegmentedControl(
        labels: ["GitHub Copilot", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let copilotStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let copilotModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var copilotPane: NSView = {
        let grid = NSGridView(views: [[fieldLabel("Model"), copilotModelPopup]])
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        let pane = NSStackView(views: [copilotStatusLabel, grid])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 8
        return pane
    }()

    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private lazy var customPane: NSView = {
        let grid = NSGridView(views: [
            [fieldLabel("Base URL"), baseURLField],
            [fieldLabel("Model"), modelField],
            [fieldLabel("API key"), apiKeyField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for field in [baseURLField, modelField, apiKeyField] {
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        return grid
    }()

    private let styleNameFields = (0..<3).map { _ in NSTextField() }
    private let styleInstructionFields = (0..<3).map { _ in NSTextField() }
    /// Pull-down per row: picking a preset fills that row's two fields, nothing more.
    private let presetMenus = (0..<3).map { _ in NSPopUpButton(frame: .zero, pullsDown: true) }
    private let restoreButton = NSButton(title: "Restore defaults", target: nil, action: nil)

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private lazy var saveButton: NSButton = {
        let button = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        return button
    }()

    private lazy var testButton: NSButton = {
        let button = NSButton(title: "Test", target: self, action: #selector(testSettings))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var closeButton: NSButton = {
        let button = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\u{1b}"
        return button
    }()

    private var hasStoredKey = false
    private var isCheckingKeychain = false
    /// While true the form is locked: fields, Close, and the window close
    /// button are disabled, and reload/reopen cannot supersede the save.
    private var isSaving = false
    /// Test/Save are disabled and the provider/fields locked while a test runs.
    private var isTesting = false
    /// Kept until a successful reload/save so a Keychain read failure is never
    /// silently downgraded to "no key stored".
    private var keychainReadError: String?
    /// Drops stale async results (Keychain presence, save, and test completions).
    private var stateGeneration = 0
    /// Test results have their own counter so a test never discards a pending Keychain check.
    private var testGeneration = 0
    /// Drops stale Copilot model-list results; separate so a Keychain check cannot discard them.
    private var copilotGeneration = 0

    init(store: SettingsStore = SettingsStore(), network: SettingsNetwork = .live) {
        self.store = store
        self.network = network
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "Be Nice Settings"
        // The controller owns the window; closing it must not release it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent(in: window)
        applyProvider(store.loadProvider(), refresh: false)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not load from a nib")
    }

    /// Shows and focuses the window. Reopening an already-visible window keeps
    /// unsaved edits; only a fresh open reloads persisted values.
    /// The app stays in `.accessory` mode, so no Dock icon appears.
    func present() {
        // An in-flight save owns the form; a reload must not supersede it.
        if !isSaving, window?.isVisible != true {
            reload()
            showWindow(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Escape and the red close button must both be inert while saving.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isSaving
    }

    // MARK: Pure helpers

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        for field in [baseURLField, modelField, apiKeyField] {
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        baseURLField.placeholderString = "https://api.example.com"
        baseURLField.setAccessibilityLabel("Base URL")
        modelField.placeholderString = "model name"
        modelField.setAccessibilityLabel("Model")
        apiKeyField.setAccessibilityLabel("API key")

        providerControl.segmentStyle = .rounded
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        providerControl.setAccessibilityLabel("Provider")

        copilotStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copilotStatusLabel.textColor = .secondaryLabelColor
        copilotStatusLabel.preferredMaxLayoutWidth = Self.contentWidth
        copilotModelPopup.setAccessibilityLabel("Copilot model")
        copilotModelPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let stylesHeader = NSTextField(labelWithString: "Your three styles")
        stylesHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let slotNames = ["1 (default)", "2", "3"]
        let presetItems = RewriteStyle.presets
        for row in 0..<3 {
            let name = styleNameFields[row], instruction = styleInstructionFields[row], presets = presetMenus[row]
            name.placeholderString = "Name"
            name.setAccessibilityLabel("Style \(slotNames[row]) name")
            name.widthAnchor.constraint(equalToConstant: 120).isActive = true
            instruction.placeholderString = "How to write, e.g. Warm, under 2 sentences"
            instruction.setAccessibilityLabel("Style \(slotNames[row]) instruction")
            instruction.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            presets.setAccessibilityLabel("Style \(slotNames[row]) presets")
            presets.addItem(withTitle: "Presets")
            for (index, preset) in presetItems.enumerated() {
                let item = NSMenuItem(title: preset.name, action: #selector(presetPicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.representedObject = row
                presets.menu?.addItem(item)
            }
            presets.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        let stylesGrid = NSGridView(views: (0..<3).map { row in
            [fieldLabel(slotNames[row]), styleNameFields[row], styleInstructionFields[row], presetMenus[row]]
        })
        stylesGrid.rowSpacing = 6
        stylesGrid.columnSpacing = 8
        stylesGrid.column(at: 0).xPlacement = .leading
        stylesGrid.column(at: 0).width = 80
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefaults)
        restoreButton.bezelStyle = .rounded
        restoreButton.setAccessibilityLabel("Restore defaults")

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth
        statusLabel.setAccessibilityLabel("Settings status")

        let buttons = NSStackView(views: [closeButton, testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)
        let pushRight = NSView()
        buttons.insertArrangedSubview(pushRight, at: 0)  // Close, Test and Save sit at the right, Save last

        let stack = NSStackView(views: [
            providerControl, copilotPane, customPane, stylesHeader, stylesGrid, restoreButton, statusLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(8, after: stylesHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content

        // Hidden panes are skipped by the key loop. Return (default button) is Save.
        apiKeyField.delegate = self
        window.initialFirstResponder = providerControl
        let order: [NSView] = [providerControl, copilotModelPopup, baseURLField, modelField, apiKeyField]
            + (0..<3).flatMap { [styleNameFields[$0], styleInstructionFields[$0], presetMenus[$0]] }
            + [restoreButton, closeButton, testButton, saveButton]
        for (view, next) in zip(order, order.dropFirst() + [order[0]]) { view.nextKeyView = next }
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    /// Resizes to the content's fitting height, keeping the title bar where it is.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.contentWidth + 40, height: content.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    // MARK: Provider

    private var selectedProvider: Provider {
        providerControl.selectedSegment == 1 ? .custom : .copilot
    }

    private func applyProvider(_ provider: Provider, refresh: Bool) {
        providerControl.selectedSegment = provider == .custom ? 1 : 0
        copilotPane.isHidden = provider != .copilot
        customPane.isHidden = provider != .custom
        updateButtonState()
        fitWindow()
        if refresh, provider == .copilot { refreshCopilot() }
    }

    @objc private func providerChanged() {
        show("", isError: false)
        applyProvider(selectedProvider, refresh: true)
    }

    private var selectedCopilotModelID: String? {
        copilotModelPopup.selectedItem?.representedObject as? String
    }

    /// Token and model list come off the main actor (`gh` is a subprocess).
    private func refreshCopilot() {
        copilotGeneration &+= 1
        let generation = copilotGeneration
        let wanted = selectedCopilotModelID ?? store.loadCopilotModel()
        copilotModelPopup.menu?.removeAllItems()
        copilotModelPopup.isEnabled = false
        setCopilotStatus("Checking GitHub login…", isError: false)

        Task {
            let result = await Task.detached { [network] () -> ModelsResult in
                do {
                    return .models(try await network.listModels(try network.token()))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            guard generation == self.copilotGeneration else { return }
            switch result {
            case .failed(let message):
                self.setCopilotStatus(message, isError: true)
            case .models(let models):
                let initial = models.first { $0.id == wanted } ?? CopilotAuth.defaultModel(in: models)
                guard let initial else {
                    self.setCopilotStatus("No models available", isError: true)
                    break
                }
                for model in models {
                    let item = NSMenuItem(title: model.name, action: nil, keyEquivalent: "")
                    item.representedObject = model.id
                    self.copilotModelPopup.menu?.addItem(item)
                }
                if let index = models.firstIndex(of: initial) {
                    self.copilotModelPopup.selectItem(at: index)
                }
                self.copilotModelPopup.isEnabled = !self.isBusy
                self.setCopilotStatus("Using your GitHub login.", isError: false)
            }
        }
    }

    private func setCopilotStatus(_ message: String, isError: Bool) {
        copilotStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        copilotStatusLabel.stringValue = message
        fitWindow()
    }

    // MARK: Style slots

    private func loadSlots() {
        fill(store.loadSlots())
    }

    private func fill(_ slots: [RewriteStyle]) {
        for (row, style) in slots.enumerated() {
            styleNameFields[row].stringValue = style.name
            styleInstructionFields[row].stringValue = style.instruction
        }
    }

    @objc private func presetPicked(_ item: NSMenuItem) {
        guard let row = item.representedObject as? Int, RewriteStyle.presets.indices.contains(item.tag),
              (0..<3).contains(row) else { return }
        let preset = RewriteStyle.presets[item.tag]
        styleNameFields[row].stringValue = preset.name
        styleInstructionFields[row].stringValue = preset.instruction
    }

    @objc private func restoreDefaults() {
        fill(RewriteStyle.defaultSlots)
        show("Defaults restored. Save to keep them.", isError: false)
    }

    // MARK: Load / save

    private func reload() {
        let settings = store.load()
        baseURLField.stringValue = settings.baseURL
        modelField.stringValue = settings.model
        // The stored secret is never read into the field or shown.
        apiKeyField.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        loadSlots()

        hasStoredKey = false
        keychainReadError = nil
        // A superseded test must not leave the form locked.
        isTesting = false
        setBusyUI(false)
        copilotModelPopup.menu?.removeAllItems()
        applyProvider(store.loadProvider(), refresh: true)
        beginPresenceCheck()
    }

    /// Runs the presence query off the main actor. A nonblank API-key entry
    /// does not depend on this result, so Save stays enabled in that case.
    private func beginPresenceCheck() {
        stateGeneration &+= 1
        let generation = stateGeneration
        isCheckingKeychain = true
        updateAPIKeyPlaceholder()
        updateButtonState()

        Task {
            let result = await Task.detached { [store] () -> KeyPresenceResult in
                do {
                    return .present(try store.hasStoredAPIKey())
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            guard generation == self.stateGeneration else { return }
            self.isCheckingKeychain = false
            switch result {
            case .present(let present):
                self.hasStoredKey = present
                self.keychainReadError = nil
            case .failed(let message):
                self.hasStoredKey = false
                self.keychainReadError = message
                self.show(SettingsError.keychainRead(message).localizedDescription,
                          isError: true)
            }
            self.updateAPIKeyPlaceholder()
            self.updateButtonState()
        }
    }

    private var apiKeyInputIsBlank: Bool {
        apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool { isSaving || isTesting }

    private func updateButtonState() {
        // A blank custom key depends on the stored-presence result, so wait for it.
        let waitingForKeychain = selectedProvider == .custom && isCheckingKeychain && apiKeyInputIsBlank
        let enabled = !isBusy && !waitingForKeychain
        saveButton.isEnabled = enabled
        testButton.isEnabled = enabled
    }

    private func setBusyUI(_ busy: Bool) {
        providerControl.isEnabled = !busy
        baseURLField.isEnabled = !busy
        modelField.isEnabled = !busy
        apiKeyField.isEnabled = !busy
        for row in 0..<3 {
            styleNameFields[row].isEnabled = !busy
            styleInstructionFields[row].isEnabled = !busy
            presetMenus[row].isEnabled = !busy
        }
        restoreButton.isEnabled = !busy
        copilotModelPopup.isEnabled = !busy && copilotModelPopup.numberOfItems > 0
        updateButtonState()
    }

    private func setSavingUI(_ saving: Bool) {
        setBusyUI(saving || isTesting)
        closeButton.isEnabled = !saving
        window?.standardWindowButton(.closeButton)?.isEnabled = !saving
    }

    private func updateAPIKeyPlaceholder() {
        if isCheckingKeychain {
            apiKeyField.placeholderString = "Checking Keychain…"
        } else if keychainReadError != nil {
            apiKeyField.placeholderString = "Keychain unavailable; enter API key"
        } else if hasStoredKey {
            apiKeyField.placeholderString = "Stored in Keychain; leave blank to keep"
        } else {
            apiKeyField.placeholderString = "Required"
        }
    }

    /// The Custom pane as a validated draft, with the same rules for Save and Test.
    private func validatedCustomDraft() -> Result<ValidatedSettings, SettingsError> {
        let draft = SettingsDraft(
            baseURL: baseURLField.stringValue,
            model: modelField.stringValue,
            apiKey: apiKeyField.stringValue,
            hasStoredAPIKey: hasStoredKey)
        // A failed presence read is not "no key": keep the real error.
        if apiKeyInputIsBlank, let readError = keychainReadError {
            return .failure(.keychainRead(readError))
        }
        return draft.validated()
    }

    /// The plan for the current provider, or nil after showing why not.
    private func currentPlan() -> SettingsSavePlan? {
        switch selectedProvider {
        case .copilot:
            guard let model = selectedCopilotModelID else {
                show("Pick a Copilot model first. Click Test to reload the list.", isError: true)
                return nil
            }
            return .copilot(model: model)
        case .custom:
            switch validatedCustomDraft() {
            case .failure(let error):
                show(error.localizedDescription, isError: true)
                return nil
            case .success(let validated):
                return .custom(validated)
            }
        }
    }

    private func currentSlots() -> [RewriteStyle]? {
        switch StyleSlots.slots(names: styleNameFields.map(\.stringValue),
                                instructions: styleInstructionFields.map(\.stringValue)) {
        case .success(let slots): return slots
        case .failure(let problem):
            show(problem.message, isError: true)
            return nil
        }
    }

    @objc private func saveSettings() {
        guard !isBusy, let slots = currentSlots(), let plan = currentPlan() else { return }

        // Invalidate any in-flight presence result: the save outcome is
        // authoritative for whether a key now exists.
        stateGeneration &+= 1
        let generation = stateGeneration
        isSaving = true
        isCheckingKeychain = false
        setSavingUI(true)
        show("Saving…", isError: false)

        Task {
            let result = await Task.detached { [store] () -> SaveResult in
                do {
                    try store.apply(plan, slots: slots)
                    return .saved
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            // Reload/reopen are blocked while saving, so this only guards
            // against future supersession paths.
            guard generation == self.stateGeneration else { return }
            self.isSaving = false
            self.setSavingUI(false)
            switch result {
            case .saved:
                if case .custom(let validated) = plan {
                    // Fields were disabled during the save, so replacing their
                    // text with the normalized values cannot clobber user edits.
                    self.baseURLField.stringValue = validated.settings.baseURL
                    self.modelField.stringValue = validated.settings.model
                    if validated.apiKeyToSave != nil {
                        self.hasStoredKey = true
                        self.keychainReadError = nil
                        self.apiKeyField.stringValue = ""
                    }
                    self.updateAPIKeyPlaceholder()
                }
                self.show("Saved.", isError: false)
            case .failed(let message):
                self.show(message, isError: true)
            }
        }
    }

    /// One real rewrite with the unsaved settings; nothing is persisted.
    @objc private func testSettings() {
        guard !isBusy, let slots = currentSlots(), let plan = currentPlan() else { return }

        let input: TestInput
        switch plan {
        case .copilot(let model):
            input = .copilot(model: model)
        case .custom(let validated):
            guard let url = URL(string: validated.settings.baseURL) else {
                show(SettingsError.invalidBaseURL.localizedDescription, isError: true)
                return
            }
            input = .custom(ModelConfig(baseURL: url, model: validated.settings.model),
                            apiKey: validated.apiKeyToSave)
        }

        testGeneration &+= 1
        let generation = testGeneration
        isTesting = true
        setBusyUI(true)
        show("Testing…", isError: false)

        Task {
            let started = Date()
            let result = await Task.detached { [network] () -> TestResult in
                do {
                    switch input {
                    case .copilot(let model):
                        try await network.runTest(CopilotAuth.config(model: model),
                                                  try network.token(), slots)
                    case .custom(let config, let apiKey):
                        guard let key = try apiKey ?? network.storedKey() else {
                            throw SettingsError.missingAPIKey
                        }
                        try await network.runTest(config, key, slots)
                    }
                    return .worked(seconds: Date().timeIntervalSince(started))
                } catch {
                    if case ModelClientError.http(status: 401, _) = error { CopilotAuth.resetTokenCache() }
                    return .failed(error.localizedDescription)
                }
            }.value
            guard generation == self.testGeneration else { return }
            self.isTesting = false
            self.setBusyUI(false)
            switch result {
            case .worked(let seconds):
                self.show(String(format: "Worked in %.1f s.", seconds), isError: false)
            case .failed(let message):
                self.show(message, isError: true)
            }
            if case .copilot = input { self.refreshCopilot() }
        }
    }

    private func show(_ message: String, isError: Bool) {
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.stringValue = message
        fitWindow()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// A nonblank key makes Save independent of the presence check.
    func controlTextDidChange(_ obj: Notification) {
        updateButtonState()
    }
}
