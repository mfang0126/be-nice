import AppKit

/// Zero-permission mode (docs/design/no-ax-mode.md). With Accessibility the pill sits on the
/// field and AX reads and writes. Without it: A, the Services menu replaces a selection in
/// place; B, the shortcut rewrites what the user copied and puts it on the clipboard.
enum AccessMode: Equatable {
    case accessibility
    case noAccessibility

    init(trusted: Bool) { self = trusted ? .accessibility : .noAccessibility }
}

struct HandoffError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let needsSetup = HandoffError(message: "Set up a model in Settings first.")
    static let noSelection = HandoffError(message: "Select your draft first.")
    static let noClipboardText = HandoffError(message: "Copy your draft first (⌘A ⌘C), then press the shortcut.")
    static let clipboardChanged = HandoffError(message: "The clipboard changed while rewriting; nothing was copied.")
    static let timedOut = HandoffError(message: "The rewrite took too long; nothing was replaced.")
    static let cancelled = HandoffError(message: "Cancelled; nothing was replaced.")
}

/// Every item and type on a pasteboard, so a clipboard rewrite can put the user's copy back.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { types[type] = item.data(forType: type) }
            return types
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }
}

/// Path B: rewrite what the user copied and put the result on the clipboard. The previous
/// contents are kept in memory only until the user restores them or the next run.
@MainActor
final class ClipboardRewriter {
    typealias Rewrite = @Sendable (String) async throws -> String

    private let pasteboard: NSPasteboard
    private let rewrite: Rewrite
    private var saved: PasteboardSnapshot?
    private var written: Int?  // changeCount right after our write

    init(pasteboard: NSPasteboard = .general, rewrite: @escaping Rewrite) {
        self.pasteboard = pasteboard
        self.rewrite = rewrite
    }

    func run() async throws {
        saved = nil
        written = nil
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HandoffError.noClipboardText }
        let before = PasteboardSnapshot(pasteboard)
        let start = pasteboard.changeCount
        let result = try await rewrite(text)
        // The user copied something else while waiting: never overwrite it.
        guard pasteboard.changeCount == start else { throw HandoffError.clipboardChanged }
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
        saved = before
        written = pasteboard.changeCount
    }

    var canRestore: Bool { saved != nil && written == pasteboard.changeCount }

    /// Puts the pre-rewrite clipboard back; refuses once anything else has been copied.
    @discardableResult
    func restore() -> Bool {
        defer { saved = nil; written = nil }
        guard let saved, written == pasteboard.changeCount else { return false }
        saved.restore(to: pasteboard)
        return true
    }
}

/// Lets the blocking Services handler read a result produced off the main thread.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?
    func set(_ result: Result<String, Error>) { lock.withLock { value = result } }
    var result: Result<String, Error>? { lock.withLock { value } }
}

/// Owns both no-Accessibility paths and their status pill, which sits by the mouse because
/// without AX the field's position is unknown.
@MainActor
final class NoAXController: NSObject {
    nonisolated static let serviceTimeout: TimeInterval = 55  // under NSTimeout (60 s) in Info.plist

    private let rewrite: ClipboardRewriter.Rewrite
    private let clipboard: ClipboardRewriter
    private let status = RewriteStatusController()
    private var task: Task<Void, Never>?
    private var serviceCancelled = false

    init(pasteboard: NSPasteboard = .general, rewrite: @escaping ClipboardRewriter.Rewrite) {
        self.rewrite = rewrite
        clipboard = ClipboardRewriter(pasteboard: pasteboard, rewrite: rewrite)
    }

    // MARK: A — Services

    /// NSServices entry `rewriteText` (Support/Info.plist). AppKit replaces the selection with
    /// whatever is on `pboard` when this returns without an error.
    @objc func rewriteText(_ pboard: NSPasteboard, userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if let message = handleService(pboard) { error.pointee = message as NSString }
    }

    /// Returns nil on success, otherwise the message shown and reported to AppKit.
    /// Services are synchronous: spin the run loop (pill stays live) until the rewrite ends.
    func handleService(_ pboard: NSPasteboard, timeout: TimeInterval = serviceTimeout) -> String? {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return finish(.failure(HandoffError.noSelection))
        }
        serviceCancelled = false
        status.show("Rewriting…", target: Self.mouseRect, undo: nil, cancel: { [weak self] in self?.serviceCancelled = true })
        let box = ResultBox()
        let rewrite = self.rewrite
        let work = Task.detached {
            do { box.set(.success(try await rewrite(text))) } catch { box.set(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while box.result == nil, !serviceCancelled, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let result = box.result else {
            work.cancel()
            return finish(.failure(serviceCancelled ? HandoffError.cancelled : HandoffError.timedOut))
        }
        if case .success(let rewritten) = result {
            pboard.clearContents()
            pboard.setString(rewritten, forType: .string)
        }
        return finish(result.map { _ in "Replaced — ⌘Z to undo" })
    }

    // MARK: B — clipboard shortcut

    func rewriteClipboard() {
        guard task == nil else { return }
        status.show("Rewriting…", target: Self.mouseRect, undo: nil, cancel: { [weak self] in self?.cancelClipboard() })
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<String, Error>
            do { try await clipboard.run(); outcome = .success("Copied — press ⌘V") } catch { outcome = .failure(error) }
            guard !Task.isCancelled else { return }
            task = nil
            _ = finish(outcome, undo: clipboard.canRestore ? { [weak self] in self?.restoreClipboard() } : nil)
        }
    }

    private func cancelClipboard() {
        task?.cancel()
        task = nil
        status.hide()
    }

    private func restoreClipboard() {
        let restored = clipboard.restore()
        status.show(restored ? "Restored" : "Clipboard changed; nothing restored", target: Self.mouseRect,
                    undo: nil, cancel: nil)
    }

    // MARK: Pill

    @discardableResult
    private func finish(_ outcome: Result<String, Error>, undo: (() -> Void)? = nil) -> String? {
        switch outcome {
        case .success(let message):
            status.show(message, target: Self.mouseRect, undo: undo, cancel: nil)
            return nil
        case .failure(let error):
            status.show(error.localizedDescription, target: Self.mouseRect, undo: nil, cancel: nil)
            return error.localizedDescription
        }
    }

    private static var mouseRect: CGRect { CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1)) }
}
