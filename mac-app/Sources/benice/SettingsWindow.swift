import AppKit

// MARK: - Settings model (pure logic, covered by SettingsTests)

/// Non-secret model configuration persisted in `UserDefaults`.
struct ModelSettings: Equatable {
    var baseURL: String
    var model: String
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

/// Detached-task results. Plain `String` messages keep the payload Sendable.
private enum KeyPresenceResult: Sendable {
    case present(Bool)
    case failed(String)
}

private enum SaveResult: Sendable {
    case saved
    case failed(String)
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private lazy var saveButton: NSButton = {
        let button = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
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
    /// Kept until a successful reload/save so a Keychain read failure is never
    /// silently downgraded to "no key stored".
    private var keychainReadError: String?
    /// Drops stale async Keychain results (reload/save completions).
    private var stateGeneration = 0

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "be-nice Settings"
        // The controller owns the window; closing it must not release it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent(in: window)
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

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 400
        statusLabel.setAccessibilityLabel("Settings status")

        let buttons = NSStackView(views: [closeButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content

        // Tab order matches the visual row (Close then Save) and the default
        // (Return) button is Save.
        apiKeyField.delegate = self
        window.initialFirstResponder = baseURLField
        baseURLField.nextKeyView = modelField
        modelField.nextKeyView = apiKeyField
        apiKeyField.nextKeyView = closeButton
        closeButton.nextKeyView = saveButton
        saveButton.nextKeyView = baseURLField
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
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

        hasStoredKey = false
        keychainReadError = nil
        beginPresenceCheck()
    }

    /// Runs the presence query off the main actor. A nonblank API-key entry
    /// does not depend on this result, so Save stays enabled in that case.
    private func beginPresenceCheck() {
        stateGeneration &+= 1
        let generation = stateGeneration
        isCheckingKeychain = true
        updateAPIKeyPlaceholder()
        updateSaveButtonState()

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
            self.updateSaveButtonState()
        }
    }

    private var apiKeyInputIsBlank: Bool {
        apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSaveButtonState() {
        // A blank key depends on the stored-presence result, so wait for it.
        saveButton.isEnabled = !isSaving && !(isCheckingKeychain && apiKeyInputIsBlank)
    }

    private func setSavingUI(_ saving: Bool) {
        baseURLField.isEnabled = !saving
        modelField.isEnabled = !saving
        apiKeyField.isEnabled = !saving
        closeButton.isEnabled = !saving
        window?.standardWindowButton(.closeButton)?.isEnabled = !saving
        updateSaveButtonState()
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

    @objc private func saveSettings() {
        guard !isSaving else { return }

        let draft = SettingsDraft(
            baseURL: baseURLField.stringValue,
            model: modelField.stringValue,
            apiKey: apiKeyField.stringValue,
            hasStoredAPIKey: hasStoredKey)

        // A failed presence read is not "no key": keep the real error.
        if draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let readError = keychainReadError {
            show(SettingsError.keychainRead(readError).localizedDescription, isError: true)
            return
        }

        switch draft.validated() {
        case .failure(let error):
            show(error.localizedDescription, isError: true)
        case .success(let validated):
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
                        try store.save(validated)
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
                    self.show("Saved.", isError: false)
                case .failed(let message):
                    self.show(message, isError: true)
                }
            }
        }
    }

    private func show(_ message: String, isError: Bool) {
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.stringValue = message
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// A nonblank key makes Save independent of the presence check.
    func controlTextDidChange(_ obj: Notification) {
        updateSaveButtonState()
    }
}
