import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// AX constants are imported as mutable globals; snapshot them once so later
// reads are concurrency-safe (same approach as AXProbe.swift).
private let axValueAttribute: String = kAXValueAttribute as String
private let axSelectedTextAttribute: String = kAXSelectedTextAttribute as String
private let axSelectedTextRangeAttribute: String = kAXSelectedTextRangeAttribute as String
private let axFocusedUIElementAttribute: String = kAXFocusedUIElementAttribute as String
private let axRoleAttribute: String = kAXRoleAttribute as String
private let axSubroleAttribute: String = kAXSubroleAttribute as String

// MARK: - Public types

public enum WriteAttribute: String, Sendable, Equatable {
    case value
    case selectedText
    case selectedTextRange
}

public enum WriteMode: String, Sendable, Equatable {
    /// Replace the captured UTF-16 selection with AXSelectedText.
    case selection
    /// Replace the whole AXValue.
    case wholeValue
}

public enum TargetMismatch: String, Sendable, Equatable {
    case notFrontmost
    case bundleChanged
    case focusChanged
    case valueChanged
    case selectionChanged
}

public enum WriteBackFailure: Error, Sendable, Equatable {
    case busy
    case nothingToApply
    case nothingToUndo
    case secureInput
    case excludedApp(String)
    case unsupportedApp(String)
    case unknownBundle
    case noFrontmostApp
    case noFocusedElement
    case secureField
    case notTextTarget(String)
    case valueUnavailable
    case selectionUnavailable
    case emptyText
    case notSettable(String)
    case targetChanged(TargetMismatch)
    case emptySuggestion
    /// The model returned the input unchanged; nothing is written.
    case noChange
    case requestFailed(String)
    /// The setter returned but the expected value was not observed. A write
    /// may still have occurred (async setter or late effect).
    case writeUnconfirmed(Int32)
    /// The read-back saw a third value or could not read it. A write may have
    /// occurred. Deliberately carries no captured document text.
    case writeUnexpected
    /// Slack draft contains emoji, mentions, links, lists, formatting, line breaks without a blank
    /// line, or other structure that a plain-text replace would drop or change; only copying is offered.
    case richContent

    /// User-facing, short. Never includes captured document text.
    public var message: String {
        switch self {
        case .busy: return "Another replace is still running. Wait a moment and try again."
        case .nothingToApply: return "There's no rewrite to apply."
        case .nothingToUndo: return "There's nothing to undo."
        case .secureInput: return "Can't read a password field."
        case .excludedApp, .unsupportedApp: return "Be Nice only works in Slack right now."
        case .unknownBundle: return "Be Nice only works in Slack right now."
        case .noFrontmostApp: return "Slack isn't in front. Switch back to Slack and try again."
        case .noFocusedElement: return "Click into the Slack message box and try again."
        case .secureField: return "Can't read a password field."
        case .richContent: return "This draft has emoji, mentions, links, lists, formatting or line breaks that a replace would change."
        case .notTextTarget: return "That isn't a text box. Click into the Slack message box and try again."
        case .valueUnavailable: return "Couldn't read the draft. Click into the message box and try again."
        case .selectionUnavailable: return "Couldn't read the selection. Click into the message box and try again."
        case .emptyText: return "The message box is empty. Write a draft first."
        case .notSettable: return "Slack won't let be-nice edit this box."
        case .targetChanged(let mismatch):
            switch mismatch {
            case .focusChanged: return "Slack focus moved. Click back into the message box and try again."
            case .notFrontmost: return "Slack isn't in front anymore. Switch back to Slack and try again."
            case .bundleChanged: return "The app changed. Switch back to Slack and try again."
            case .valueChanged: return "The draft changed. Rewrite it again."
            case .selectionChanged: return "The selection changed. Rewrite it again."
            }
        case .emptySuggestion: return "The rewrite came back empty. Try again."
        case .noChange: return "The rewrite is the same as your draft, so nothing was replaced."
        case .requestFailed(let detail): return "Rewrite failed: \(detail)"
        case .writeUnconfirmed:
            return "The replace may have gone through but wasn't confirmed. Check Slack before trying again."
        case .writeUnexpected:
            return "The replace may have gone through, but the box changed unexpectedly. Check Slack before trying again."
        }
    }
}

public struct SuggestionPreview: Sendable, Equatable {
    /// The exact text that was sent to the model: the selection text in
    /// selection mode, or the whole value in whole-value mode.
    public let original: String
    public let suggestion: String
    public let mode: WriteMode
}

/// Request identity handed over by the trigger. `requestPreview(target:)`
/// verifies PID, bundle ID and focused-element identity before reading text.
public struct WriteBackTarget: Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let element: TargetElement
    public let forceWholeValue: Bool

    public init(pid: pid_t, bundleID: String, element: TargetElement,
                forceWholeValue: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = element
        self.forceWholeValue = forceWholeValue
    }
}

public enum WriteBackState: Sendable, Equatable {
    case idle
    case reading
    case requesting
    case validating
    case writing
    case verified
    case failed(WriteBackFailure)
}

public enum PreviewOutcome: Sendable, Equatable {
    case ready(SuggestionPreview)
    case failed(WriteBackFailure)
    /// A response arrived after its request was superseded (generation mismatch).
    case stale
}

public enum ApplyOutcome: Sendable, Equatable {
    case applied
    case failed(WriteBackFailure)
}

public enum UndoOutcome: Sendable, Equatable {
    case restored
    case failed(WriteBackFailure)
}

public struct WriteBackConfig: Sendable, Equatable {
    public var readBackTimeout: TimeInterval
    public var readBackInterval: TimeInterval

    public init(readBackTimeout: TimeInterval = 0.5, readBackInterval: TimeInterval = 0.02) {
        self.readBackTimeout = readBackTimeout
        self.readBackInterval = readBackInterval
    }
}

/// Opaque element identity. The real adapter holds an AXUIElement; fakes hold
/// their own token. All use happens inside `WriteBackController`'s actor.
public final class TargetElement: @unchecked Sendable {
    let axElement: AXUIElement?
    let token: AnyObject?

    public init(_ element: AXUIElement) {
        self.axElement = element
        self.token = nil
    }

    init(token: AnyObject) {
        self.axElement = nil
        self.token = token
    }
}

// MARK: - Boundaries

/// Everything the state machine needs from the Accessibility layer. Splitting
/// this out keeps the transaction logic testable without live apps.
public protocol TextTargetAccess: Sendable {
    func isSecureInputEnabled() -> Bool
    func frontmostPID() -> pid_t?
    func bundleID(for pid: pid_t) -> String?
    func focusedElement(pid: pid_t) -> TargetElement?
    func focusedWindowTitle(pid: pid_t) -> String?
    func sameElement(_ a: TargetElement, _ b: TargetElement) -> Bool
    func role(of element: TargetElement) -> String?
    func subrole(of element: TargetElement) -> String?
    func value(of element: TargetElement) -> String?
    /// UTF-16 selection range.
    func selectedRange(of element: TargetElement) -> NSRange?
    func isSettable(_ attribute: WriteAttribute, on element: TargetElement) -> Bool
    func setValue(_ text: String, on element: TargetElement) -> Int32
    func setSelectedText(_ text: String, on element: TargetElement) -> Int32
    func setSelectedRange(_ range: NSRange, on element: TargetElement) -> Int32
    /// Sets AXFocused on this exact element (used to hand focus back to the captured Slack composer).
    func focus(_ element: TargetElement) -> Int32
    /// True when the editor holds non-text children (images such as emoji, links,
    /// mention pills) that AXValue does not represent.
    func hasRichContent(_ element: TargetElement) -> Bool
    func uptime() -> TimeInterval
    func sleep(_ seconds: TimeInterval)
}

extension TextTargetAccess {
    public func focus(_ element: TargetElement) -> Int32 { -25205 }  // kAXErrorCannotComplete
    public func hasRichContent(_ element: TargetElement) -> Bool { false }
}

public protocol SuggestionProviding: Sendable {
    func optimize(text: String) async throws -> String
}

extension ModelClient: SuggestionProviding {}

public enum WriteBackAppSupport: String, Sendable, Equatable {
    case selection
    case wholeValue
    case excluded
    case unsupported
}

/// Conservative projection of the M0 support matrix, kept in sync with
/// `TriggerPolicy`. Only bundles whose write path was actually verified are
/// allowed. VS Code/Insiders and terminal families are explicitly excluded.
public enum WriteBackPolicy {
    /// One node's child roles, as Slack's composer exposes them (S3 diagnosis 10-27):
    /// emoji are AXImage, links AXLink, lists AXList (subrole AXContentList), and a
    /// mention pill or other inline formatting splits a paragraph into several
    /// AXStaticText runs. Bold/italic/code runs are AXGroup with a "...StyleGroup"
    /// subrole (AXStrongStyleGroup, AXCodeStyleGroup), so a run at a paragraph's
    /// start or end, or a fully formatted paragraph, is caught by subrole.
    /// AXValue keeps none of that structure.
    public static func childrenAreRich(_ roles: [String], subroles: [String] = []) -> Bool {
        let richRoles: Set<String> = ["AXImage", "AXLink", "AXButton", "AXList"]
        return roles.contains { richRoles.contains($0) }
            || roles.filter { $0 == "AXStaticText" }.count > 1
            || subroles.contains { $0.hasSuffix("StyleGroup") }
    }

    /// The composer's own children, one per paragraph: whether `setValue(AXValue)`
    /// writes back the same layout. AXValue joins text paragraphs with a single "\n"
    /// and omits empty ones, and Slack turns each written "\n" into a new paragraph
    /// plus one empty paragraph (S3 10-27, 6.5 f2). So only "text (empty text)*" can
    /// be restored; Shift+Return lines (adjacent text paragraphs), double blank
    /// lines and leading/trailing empty lines cannot. An unread tree (no children)
    /// counts as restorable; any non-AXGroup or unreadable ("") child, or misaligned
    /// arrays, does not.
    public static func paragraphsRestorable(_ roles: [String], subroles: [String]) -> Bool {
        if roles.isEmpty { return true }
        guard roles.count == subroles.count, roles.allSatisfy({ $0 == "AXGroup" }) else { return false }
        let empty = subroles.map { $0 == "AXEmptyGroup" }
        return empty.count % 2 == 1 && empty.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 1) }
    }

    public static let selectionBundleIDs: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
    ]

    public static let wholeValueBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.github.Electron",
        slackBundleID,
    ]

    /// Slack desktop (MVP target). Its window title names the conversation
    /// ("<name> (DM) - <workspace> - Slack"), so it is pinned per transaction.
    public static let slackBundleID = "com.tinyspeck.slackmacgap"

    public static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    /// Editable-text roles from the M0 probe. AXWebArea is deliberately not a
    /// text target: the browser's editable control is the focused field/area.
    public static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXTextView",
    ]

    public static let electronFixtureBundleID = "com.github.Electron"
    public static let electronFixtureWindowTitle = "be-nice AX test target"

    public static func allowsWindow(bundleID: String, title: String?) -> Bool {
        bundleID != electronFixtureBundleID || title == electronFixtureWindowTitle
    }

    public static func support(for bundleID: String?) -> WriteBackAppSupport {
        guard let bundleID else { return .unsupported }
        if excludedBundleIDs.contains(bundleID) { return .excluded }
        if selectionBundleIDs.contains(bundleID) { return .selection }
        if wholeValueBundleIDs.contains(bundleID) { return .wholeValue }
        return .unsupported
    }
}

// MARK: - Controller

/// Preview-first transaction core:
///
///     idle -> reading -> requesting -> validating -> idle (preview shown)
///     idle -> validating -> writing -> verified | failed
///     verified/failed -> validating -> writing -> verified | failed (undo)
///
/// One request per target generation. `requestPreview` and later `apply` share
/// a generation token; any response whose token is no longer current is
/// discarded, and `cancel` also cancels the in-flight client task.
///
/// Apply and undo recheck the exact target immediately before the single text
/// write, then confirm it with a bounded read-back. Nothing is retried. The
/// clipboard is never touched. A possible-write undo record is installed
/// before the setter, so unconfirmed/unexpected outcomes can still be undone.
public actor WriteBackController {
    private struct CapturedTarget: Sendable {
        let pid: pid_t
        let bundleID: String
        let element: TargetElement
        let originalValue: String
        let selectionRange: NSRange?
        let selectedText: String?
        let mode: WriteMode
        /// Slack only: the focused window title at capture; apply/undo require it unchanged.
        var conversationTitle: String? = nil
    }

    private struct UndoRecord: Sendable {
        let target: CapturedTarget
        /// Full value apply intended, used as the stale value for undo.
        let appliedValue: String
        /// Where the suggestion now sits in `appliedValue`.
        let replacementRange: NSRange
    }

    private enum WriteCheck {
        case applied
        case unconfirmed
        case unexpected
    }

    private let access: any TextTargetAccess
    private let client: any SuggestionProviding
    private let config: WriteBackConfig

    public private(set) var state: WriteBackState = .idle
    public private(set) var preview: SuggestionPreview?

    private var pendingTarget: CapturedTarget?
    private var undoRecord: UndoRecord?
    private var requestTask: Task<String, Error>?
    private var generation: UInt64 = 0
    private var previewGeneration: UInt64 = 0

    public init(access: any TextTargetAccess,
                client: any SuggestionProviding,
                config: WriteBackConfig = WriteBackConfig()) {
        self.access = access
        self.client = client
        self.config = config
    }

    /// True when a product-managed undo is available and no operation is in
    /// flight. A possible-write record survives failed applies, so this can be
    /// true while `state` is `.failed`. Undo re-verifies the target, so a
    /// changed document is refused rather than overwritten.
    public var undoAvailable: Bool {
        guard undoRecord != nil else { return false }
        switch state {
        case .reading, .requesting, .validating, .writing: return false
        case .idle, .verified, .failed: return true
        }
    }

    // MARK: Preview

    public func requestPreview(target: WriteBackTarget? = nil) async -> PreviewOutcome {
        switch state {
        case .idle, .verified, .failed:
            break
        case .reading, .requesting, .validating, .writing:
            return .failed(.busy)
        }

        generation &+= 1
        let token = generation
        preview = nil
        pendingTarget = nil
        state = .reading

        let captureResult: Result<CapturedTarget, WriteBackFailure>
        if let target {
            captureResult = capture(expected: target)
        } else {
            captureResult = capture(expected: nil)
        }
        let target: CapturedTarget
        switch captureResult {
        case .success(let captured):
            target = captured
        case .failure(let failure):
            state = .failed(failure)
            return .failed(failure)
        }

        state = .requesting
        let input = target.mode == .selection
            ? (target.selectedText ?? "")
            : target.originalValue
        let client = self.client
        let task = Task { try await client.optimize(text: input) }
        requestTask = task
        let suggestion: String
        do {
            suggestion = try await task.value
        } catch {
            if token == generation { requestTask = nil }
            guard token == generation else { return .stale }
            let failure = WriteBackFailure.requestFailed(error.localizedDescription)
            state = .failed(failure)
            return .failed(failure)
        }
        if token == generation { requestTask = nil }

        // Actor reentrancy: cancel() or a newer request may have run while the
        // model call was suspended.
        guard token == generation, state == .requesting else { return .stale }

        state = .validating
        guard suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            let failure = WriteBackFailure.emptySuggestion
            state = .failed(failure)
            return .failed(failure)
        }
        guard suggestion != input else {
            let failure = WriteBackFailure.noChange
            state = .failed(failure)
            return .failed(failure)
        }
        // The preview is only offered while it still describes the live target.
        if let failure = recheck(target) {
            state = .failed(failure)
            return .failed(failure)
        }
        let ready = SuggestionPreview(original: input, suggestion: suggestion, mode: target.mode)
        preview = ready
        pendingTarget = target
        previewGeneration = token
        state = .idle
        return .ready(ready)
    }

    public func cancel() {
        requestTask?.cancel()
        requestTask = nil
        generation &+= 1
        preview = nil
        pendingTarget = nil
        // Cancellation stops in-flight work, not the user's recovery path.
        // A verified or possible write remains undoable until a later write
        // replaces the record or Undo restores it.
        switch state {
        case .reading, .requesting, .validating, .writing:
            state = .idle
        case .idle, .verified, .failed:
            break
        }
    }

    // MARK: Apply

    /// Capture before an activating editor takes focus. No model call or write.
    public func prepare(target: WriteBackTarget) -> PreviewOutcome {
        switch state {
        case .reading, .requesting, .validating, .writing: return .failed(.busy)
        case .idle, .verified, .failed: break
        }
        generation &+= 1
        preview = nil
        pendingTarget = nil
        switch capture(expected: target) {
        case .failure(let failure):
            state = .failed(failure)
            return .failed(failure)
        case .success(let captured):
            let input = captured.mode == .selection ? (captured.selectedText ?? "") : captured.originalValue
            let prepared = SuggestionPreview(original: input, suggestion: input, mode: captured.mode)
            pendingTarget = captured
            preview = prepared
            previewGeneration = generation
            state = .idle
            return .ready(prepared)
        }
    }

    public func validatePreparedTarget() -> WriteBackFailure? {
        guard state == .idle, let target = pendingTarget,
              previewGeneration == generation else { return .nothingToApply }
        return recheck(target)
    }

    public func apply(replacement: String? = nil) -> ApplyOutcome {
        guard state == .idle,
              let preview,
              let target = pendingTarget,
              previewGeneration == generation else {
            return .failed(.nothingToApply)
        }
        let suggestion = replacement ?? preview.suggestion
        guard !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(.emptySuggestion)
        }
        guard suggestion != preview.original else { return .failed(.noChange) }
        // Consume the preview up front: a failed apply must not leave a
        // displayed but unusable suggestion. The UI requires a new trigger.
        self.preview = nil
        pendingTarget = nil

        state = .validating
        if let failure = recheck(target) {
            state = .failed(failure)
            return .failed(failure)
        }

        let expected: String
        let attribute: WriteAttribute
        let replacementRange: NSRange
        switch target.mode {
        case .wholeValue:
            expected = suggestion
            attribute = .value
            replacementRange = NSRange(location: 0, length: (expected as NSString).length)
        case .selection:
            guard let range = target.selectionRange else {
                let failure = WriteBackFailure.selectionUnavailable
                state = .failed(failure)
                return .failed(failure)
            }
            expected = (target.originalValue as NSString)
                .replacingCharacters(in: range, with: suggestion)
            attribute = .selectedText
            replacementRange = NSRange(location: range.location,
                                       length: (suggestion as NSString).length)
        }
        if let failure = settableFailure(for: attribute, on: target.element) {
            state = .failed(failure)
            return .failed(failure)
        }
        if target.mode == .selection, let range = target.selectionRange {
            // The caret can move during the AX checks above. Re-select and
            // verify the captured range immediately before replacing text.
            let rangeError = access.setSelectedRange(range, on: target.element)
            guard rangeError == AXError.success.rawValue else {
                let failure = WriteBackFailure.notSettable(WriteAttribute.selectedTextRange.rawValue)
                state = .failed(failure)
                return .failed(failure)
            }
            guard access.selectedRange(of: target.element) == range else {
                state = .failed(.selectionUnavailable)
                return .failed(.selectionUnavailable)
            }
        }

        // Possible-write record: installed BEFORE the setter so an async or
        // late write can always be undone.
        undoRecord = UndoRecord(target: target,
                                appliedValue: expected,
                                replacementRange: replacementRange)

        state = .writing
        let setError: Int32
        switch attribute {
        case .value:
            setError = access.setValue(suggestion, on: target.element)
        case .selectedText:
            setError = access.setSelectedText(suggestion, on: target.element)
        case .selectedTextRange:
            setError = AXError.failure.rawValue
        }

        switch readBack(original: target.originalValue, expected: expected,
                        element: target.element) {
        case .applied:
            state = .verified
            refocusSlackComposer(target)  // leave the caret in Slack's composer
            return .applied
        case .unconfirmed:
            let failure = WriteBackFailure.writeUnconfirmed(setError)
            state = .failed(failure)
            return .failed(failure)
        case .unexpected:
            let failure = WriteBackFailure.writeUnexpected
            state = .failed(failure)
            return .failed(failure)
        }
    }

    // MARK: Undo

    /// Product write-back of the captured original. Never synthesizes Cmd-Z.
    ///
    /// - exact original value: already restored, clear the record, no write;
    /// - exact applied value: restore with one text write;
    /// - any third value: refuse and keep the record.
    public func undo() -> UndoOutcome {
        guard let record = undoRecord else { return .failed(.nothingToUndo) }
        switch state {
        case .verified, .failed, .idle:
            break
        case .reading, .requesting, .validating, .writing:
            return .failed(.busy)
        }

        state = .validating
        let current: String
        switch recheckForUndo(record) {
        case .success(let value):
            current = value
        case .failure(let failure):
            state = .failed(failure)
            return .failed(failure)
        }

        if current == record.target.originalValue {
            undoRecord = nil
            state = .verified
            return .restored
        }
        guard current == record.appliedValue else {
            // Third value: never overwrite it.
            let failure = WriteBackFailure.targetChanged(.valueChanged)
            state = .failed(failure)
            return .failed(failure)
        }

        let attribute: WriteAttribute =
            record.target.mode == .selection ? .selectedText : .value
        if let failure = settableFailure(for: attribute, on: record.target.element) {
            state = .failed(failure)
            return .failed(failure)
        }

        state = .writing
        let setError: Int32
        if record.target.mode == .selection {
            let rangeError = access.setSelectedRange(record.replacementRange,
                                                     on: record.target.element)
            guard rangeError == AXError.success.rawValue else {
                let failure = WriteBackFailure.notSettable(WriteAttribute.selectedTextRange.rawValue)
                state = .failed(failure)
                return .failed(failure)
            }
            // The setter must be observed before a text write replaces it.
            guard access.selectedRange(of: record.target.element) == record.replacementRange else {
                let failure = WriteBackFailure.selectionUnavailable
                state = .failed(failure)
                return .failed(failure)
            }
            setError = access.setSelectedText(record.target.selectedText ?? "",
                                              on: record.target.element)
        } else {
            setError = access.setValue(record.target.originalValue,
                                       on: record.target.element)
        }

        switch readBack(original: record.appliedValue,
                        expected: record.target.originalValue,
                        element: record.target.element) {
        case .applied:
            undoRecord = nil
            state = .verified
            refocusSlackComposer(record.target)  // leave the caret in Slack's composer
            return .restored
        case .unconfirmed:
            let failure = WriteBackFailure.writeUnconfirmed(setError)
            state = .failed(failure)
            return .failed(failure)
        case .unexpected:
            let failure = WriteBackFailure.writeUnexpected
            state = .failed(failure)
            return .failed(failure)
        }
    }

    // MARK: Capture and checks

    /// Policy checks happen before any sensitive text read: Secure Input,
    /// request identity (PID/bundle/focused element when supplied), excluded
    /// and unsupported bundles, secure fields, then only then document text.
    private func capture(expected: WriteBackTarget?) -> Result<CapturedTarget, WriteBackFailure> {
        if access.isSecureInputEnabled() { return .failure(.secureInput) }
        guard let pid = access.frontmostPID() else { return .failure(.noFrontmostApp) }
        if let expected, pid != expected.pid {
            return .failure(.targetChanged(.notFrontmost))
        }
        guard let bundleID = access.bundleID(for: pid) else { return .failure(.unknownBundle) }
        if let expected, bundleID != expected.bundleID {
            return .failure(.targetChanged(.bundleChanged))
        }
        let appSupport = WriteBackPolicy.support(for: bundleID)
        switch appSupport {
        case .excluded: return .failure(.excludedApp(bundleID))
        case .unsupported: return .failure(.unsupportedApp(bundleID))
        case .selection, .wholeValue: break
        }
        let windowTitle = bundleID == WriteBackPolicy.electronFixtureBundleID
            || bundleID == WriteBackPolicy.slackBundleID
            ? access.focusedWindowTitle(pid: pid) : nil
        guard WriteBackPolicy.allowsWindow(bundleID: bundleID, title: windowTitle) else {
            return .failure(.unsupportedApp(bundleID))
        }
        let conversationTitle = bundleID == WriteBackPolicy.slackBundleID ? windowTitle : nil
        if bundleID == WriteBackPolicy.slackBundleID, conversationTitle?.isEmpty != false {
            return .failure(.unsupportedApp(bundleID))
        }

        guard let element = access.focusedElement(pid: pid) else {
            return .failure(.noFocusedElement)
        }
        if let expected, access.sameElement(element, expected.element) == false {
            return .failure(.targetChanged(.focusChanged))
        }
        let role = access.role(of: element) ?? ""
        if role == "AXSecureTextField" || access.subrole(of: element) == "AXSecureTextField" {
            return .failure(.secureField)
        }
        guard WriteBackPolicy.textRoles.contains(role) else {
            return .failure(.notTextTarget(role))
        }

        // Only now read document text.
        guard let value = access.value(of: element) else { return .failure(.valueUnavailable) }
        guard value.isEmpty == false else { return .failure(.emptyText) }

        // Whole-value-only bundles and forced whole-value requests never need
        // AXSelectedTextRange (Safari contenteditable cannot provide it).
        if appSupport == .wholeValue || expected?.forceWholeValue == true {
            guard access.isSettable(.value, on: element) else {
                return .failure(.notSettable(WriteAttribute.value.rawValue))
            }
            return .success(CapturedTarget(pid: pid,
                                           bundleID: bundleID,
                                           element: element,
                                           originalValue: value,
                                           selectionRange: nil,
                                           selectedText: nil,
                                           mode: .wholeValue,
                                           conversationTitle: conversationTitle))
        }

        // Selection-capable apps keep auto selection-vs-whole behavior.
        guard let range = access.selectedRange(of: element) else {
            return .failure(.selectionUnavailable)
        }
        let length = (value as NSString).length
        guard range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else {
            return .failure(.selectionUnavailable)
        }
        if range.length == 0 {
            guard access.isSettable(.value, on: element) else {
                return .failure(.notSettable(WriteAttribute.value.rawValue))
            }
            return .success(CapturedTarget(pid: pid,
                                           bundleID: bundleID,
                                           element: element,
                                           originalValue: value,
                                           selectionRange: nil,
                                           selectedText: nil,
                                           mode: .wholeValue,
                                           conversationTitle: conversationTitle))
        }
        if let failure = settableFailure(for: .selectedText, on: element) {
            return .failure(failure)
        }
        let selectedText = (value as NSString).substring(with: range)
        return .success(CapturedTarget(pid: pid,
                                       bundleID: bundleID,
                                       element: element,
                                       originalValue: value,
                                       selectionRange: range,
                                       selectedText: selectedText,
                                       mode: .selection,
                                       conversationTitle: conversationTitle))
    }

    /// Slack (Electron) hands focus back to its web area, not the composer, after
    /// be-nice's window closes. Only after the same-app and same-conversation checks
    /// pass, re-focus the exact captured element; every later check still applies.
    private func refocusSlackComposer(_ target: CapturedTarget) {
        guard target.conversationTitle != nil,
              let focused = access.focusedElement(pid: target.pid),
              !access.sameElement(focused, target.element) else { return }
        _ = access.focus(target.element)
        access.sleep(0.15)
    }

    /// Recheck immediately before apply (and before offering a preview).
    private func recheck(_ target: CapturedTarget) -> WriteBackFailure? {
        if access.isSecureInputEnabled() { return .secureInput }
        guard access.frontmostPID() == target.pid else {
            return .targetChanged(.notFrontmost)
        }
        guard access.bundleID(for: target.pid) == target.bundleID else {
            return .targetChanged(.bundleChanged)
        }
        let windowTitle = target.bundleID == WriteBackPolicy.electronFixtureBundleID
            ? access.focusedWindowTitle(pid: target.pid) : nil
        guard WriteBackPolicy.allowsWindow(bundleID: target.bundleID, title: windowTitle) else {
            return .unsupportedApp(target.bundleID)
        }
        if let title = target.conversationTitle,
           access.focusedWindowTitle(pid: target.pid) != title {
            return .targetChanged(.focusChanged)
        }
        refocusSlackComposer(target)
        guard let focused = access.focusedElement(pid: target.pid),
              access.sameElement(focused, target.element) else {
            return .targetChanged(.focusChanged)
        }
        guard access.value(of: target.element) == target.originalValue else {
            return .targetChanged(.valueChanged)
        }
        if target.conversationTitle != nil, access.hasRichContent(target.element) {
            return .richContent
        }
        if target.mode == .selection {
            guard let range = target.selectionRange,
                  access.selectedRange(of: target.element) == range else {
                return .targetChanged(.selectionChanged)
            }
        }
        return nil
    }

    /// Undo re-checks identity and returns the exact current value. A moved
    /// caret is harmless: selection-mode undo re-selects its own range.
    private func recheckForUndo(_ record: UndoRecord) -> Result<String, WriteBackFailure> {
        if access.isSecureInputEnabled() { return .failure(.secureInput) }
        guard access.frontmostPID() == record.target.pid else {
            return .failure(.targetChanged(.notFrontmost))
        }
        guard access.bundleID(for: record.target.pid) == record.target.bundleID else {
            return .failure(.targetChanged(.bundleChanged))
        }
        let windowTitle = record.target.bundleID == WriteBackPolicy.electronFixtureBundleID
            ? access.focusedWindowTitle(pid: record.target.pid) : nil
        guard WriteBackPolicy.allowsWindow(bundleID: record.target.bundleID, title: windowTitle) else {
            return .failure(.unsupportedApp(record.target.bundleID))
        }
        if let title = record.target.conversationTitle,
           access.focusedWindowTitle(pid: record.target.pid) != title {
            return .failure(.targetChanged(.focusChanged))
        }
        refocusSlackComposer(record.target)
        guard let focused = access.focusedElement(pid: record.target.pid),
              access.sameElement(focused, record.target.element) else {
            return .failure(.targetChanged(.focusChanged))
        }
        guard let current = access.value(of: record.target.element) else {
            return .failure(.valueUnavailable)
        }
        return .success(current)
    }

    /// Selection writes also need a settable AXSelectedTextRange so undo can
    /// reselect the replaced text.
    private func settableFailure(for attribute: WriteAttribute,
                                 on element: TargetElement) -> WriteBackFailure? {
        guard access.isSettable(attribute, on: element) else {
            return .notSettable(attribute.rawValue)
        }
        if attribute == .selectedText,
           access.isSettable(.selectedTextRange, on: element) == false {
            return .notSettable(WriteAttribute.selectedTextRange.rawValue)
        }
        return nil
    }

    // MARK: Write and bounded read-back

    /// Exactly one bounded poll. `original` is the value expected while the
    /// setter is still pending; any third value or unreadable value stops
    /// immediately. No second write is ever issued.
    ///
    /// The deadline is checked between reads, so one AX read can still block up
    /// to the adapter's messaging timeout; that per-call timeout is the hard
    /// ceiling on this loop's total duration.
    private func readBack(original: String, expected: String,
                          element: TargetElement) -> WriteCheck {
        let deadline = access.uptime() + max(0, config.readBackTimeout)
        let interval = max(0.001, config.readBackInterval)
        while true {
            guard let current = access.value(of: element) else {
                return .unexpected
            }
            if current == expected { return .applied }
            if current != original { return .unexpected }
            let remaining = deadline - access.uptime()
            if remaining <= 0 { return .unconfirmed }
            access.sleep(min(interval, remaining))
        }
    }
}

// MARK: - Real Accessibility adapter

public struct SystemTextTargetAccess: TextTargetAccess {
    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 2.0) {
        self.messagingTimeout = messagingTimeout
    }

    public func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    public func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func focusedElement(pid: pid_t) -> TargetElement? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let raw = copyAttribute(app, axFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return TargetElement(element)
    }

    public func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let raw = copyAttribute(app, "AXFocusedWindow"),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(window, messagingTimeout)
        return copyAttribute(window, "AXTitle") as? String
    }

    public func sameElement(_ a: TargetElement, _ b: TargetElement) -> Bool {
        if let axA = a.axElement, let axB = b.axElement {
            return CFEqual(axA, axB)
        }
        return a.token === b.token
    }

    public func role(of element: TargetElement) -> String? {
        stringAttribute(element, axRoleAttribute)
    }

    public func subrole(of element: TargetElement) -> String? {
        stringAttribute(element, axSubroleAttribute)
    }

    public func value(of element: TargetElement) -> String? {
        stringAttribute(element, axValueAttribute)
    }

    public func selectedRange(of element: TargetElement) -> NSRange? {
        guard let raw = axElement(element),
              let value = copyAttribute(raw, axSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    public func isSettable(_ attribute: WriteAttribute, on element: TargetElement) -> Bool {
        guard let raw = axElement(element) else { return false }
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(raw, attributeName(attribute) as CFString,
                                                   &settable)
        return error == .success && settable.boolValue
    }

    public func setValue(_ text: String, on element: TargetElement) -> Int32 {
        setAttribute(element, axValueAttribute, text as CFTypeRef)
    }

    public func focus(_ element: TargetElement) -> Int32 {
        setAttribute(element, "AXFocused", kCFBooleanTrue)
    }

    /// Bounded walk (depth 4, 300 nodes) applying `WriteBackPolicy.childrenAreRich` to
    /// each node's children, and `paragraphsRestorable` to the composer's own children.
    /// Unknown or unreadable trees count as plain;
    /// the value/readback checks still guard the write itself.
    public func hasRichContent(_ element: TargetElement) -> Bool {
        guard let root = element.axElement else { return false }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            var raw: CFTypeRef?
            guard depth < 4,
                  AXUIElementCopyAttributeValue(node, "AXChildren" as CFString, &raw) == .success,
                  let children = raw as? [AXUIElement] else { continue }
            var roles: [String] = []
            var subroles: [String] = []
            for child in children {
                var role: CFTypeRef?
                roles.append(AXUIElementCopyAttributeValue(child, "AXRole" as CFString, &role) == .success
                    ? (role as? String ?? "") : "")
                var subrole: CFTypeRef?
                subroles.append(AXUIElementCopyAttributeValue(child, "AXSubrole" as CFString, &subrole) == .success
                    ? (subrole as? String ?? "") : "")
                queue.append((child, depth + 1))
            }
            if WriteBackPolicy.childrenAreRich(roles, subroles: subroles) { return true }
            if depth == 0, !WriteBackPolicy.paragraphsRestorable(roles, subroles: subroles) { return true }
        }
        return false
    }

    public func setSelectedText(_ text: String, on element: TargetElement) -> Int32 {
        setAttribute(element, axSelectedTextAttribute, text as CFTypeRef)
    }

    public func setSelectedRange(_ range: NSRange, on element: TargetElement) -> Int32 {
        var mutable = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &mutable) else {
            return AXError.failure.rawValue
        }
        return setAttribute(element, axSelectedTextRangeAttribute, value)
    }

    public func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Helpers

    private func axElement(_ element: TargetElement) -> AXUIElement? {
        element.axElement
    }

    private func attributeName(_ attribute: WriteAttribute) -> String {
        switch attribute {
        case .value: return axValueAttribute
        case .selectedText: return axSelectedTextAttribute
        case .selectedTextRange: return axSelectedTextRangeAttribute
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ element: TargetElement, _ name: String) -> String? {
        guard let raw = axElement(element) else { return nil }
        return copyAttribute(raw, name) as? String
    }

    private func setAttribute(_ element: TargetElement, _ name: String,
                              _ value: CFTypeRef) -> Int32 {
        guard let raw = axElement(element) else { return AXError.failure.rawValue }
        _ = AXUIElementSetMessagingTimeout(raw, messagingTimeout)
        return AXUIElementSetAttributeValue(raw, name as CFString, value).rawValue
    }
}
