import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Trigger policy (pure, self-checked)

enum TriggerMode: String, Equatable, Sendable {
    /// The app was verified for both selected-text and whole-value writes; the
    /// write-back core chooses selected text when a selection exists and the
    /// whole value otherwise.
    case selection
    /// Whole-value only. The core must replace the entire value even when a
    /// selection exists (Electron/Safari/Chrome selected-text writes were not
    /// confirmed in M0).
    case wholeValue
}

enum TriggerHideReason: String, Equatable, Sendable {
    case secureInput
    case unknownBundle
    case excludedApp
    case unsupportedApp
    case secureField
    case nonTextRole
    case outsideWebContent
    case noGeometry
}

enum TriggerDecision: Equatable, Sendable {
    case show(TriggerMode)
    case hide(TriggerHideReason)
}

enum AppSupport: Equatable, Sendable {
    case selection
    case wholeValue
    case excluded
    case unsupported
    case unknown
}

/// Slack only (user decision 10-27 22:49): no other app gets the entry. Selection
/// mode stays in the code but no app reaches it.
enum TriggerPolicy {
    static let selectionBundleIDs: Set<String> = []

    static let wholeValueBundleIDs: Set<String> = [
        slackBundleID,
    ]

    static let slackBundleID = "com.tinyspeck.slackmacgap"

    /// Terminal-family bundles (same list as the M0 probe) plus VS Code, whose
    /// setters returned success without a confirmed effect in M0.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    /// Roles that were actually exercised as text targets. AXWebArea, combo
    /// boxes and search fields are deliberately absent.
    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXTextView",
    ]

    static let webAreaRole = "AXWebArea"
    /// AXParent walk cap. Slack composers (S3 diagnosis 10-27): channel AXWebArea
    /// is the 16th parent, thread reply the 18th.
    static let maxAncestorDepth = 24
    static let electronFixtureBundleID = "com.github.Electron"
    static let electronFixtureWindowTitle = "be-nice AX test target"

    static func appSupport(bundleID: String?) -> AppSupport {
        guard let bundleID else { return .unknown }
        if excludedBundleIDs.contains(bundleID) { return .excluded }
        if selectionBundleIDs.contains(bundleID) { return .selection }
        if wholeValueBundleIDs.contains(bundleID) { return .wholeValue }
        return .unsupported
    }

    /// Browser/Electron fields must sit inside web content. This is what keeps
    /// address bars and native browser fields from showing the dot.
    static func hasWebAreaAncestor(_ ancestorRoles: [String]) -> Bool {
        ancestorRoles.contains(webAreaRole)
    }

    /// Single policy entry point. `ancestorRoles` is the bounded AXParent walk
    /// (parents only, nearest first); it is required for `.wholeValue` apps.
    static func decision(bundleID: String?, role: String, subrole: String?,
                         ancestorRoles: [String] = [], windowTitle: String? = nil,
                         secureInputEnabled: Bool) -> TriggerDecision {
        if secureInputEnabled { return .hide(.secureInput) }
        let mode: TriggerMode
        switch appSupport(bundleID: bundleID) {
        case .excluded: return .hide(.excludedApp)
        case .unsupported: return .hide(.unsupportedApp)
        case .unknown: return .hide(.unknownBundle)
        case .selection: mode = .selection
        case .wholeValue: mode = .wholeValue
        }
        // Checked before the role allow-list: some apps expose a password
        // field as AXTextField with subrole AXSecureTextField.
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .hide(.secureField)
        }
        guard textRoles.contains(role) else { return .hide(.nonTextRole) }
        if mode == .wholeValue && !hasWebAreaAncestor(ancestorRoles) {
            return .hide(.outsideWebContent)
        }
        if bundleID == electronFixtureBundleID && windowTitle != electronFixtureWindowTitle {
            return .hide(.unsupportedApp)
        }
        return .show(mode)
    }
}

// MARK: - Geometry (pure, self-checked)

enum TriggerGeometry {
    static let buttonSize = CGSize(width: 88, height: 32)

    /// Keep the entry just outside the focused input's top-right corner, never on it
    /// (AppKit coordinates, y up). Falls back to right of, below, then left of the field.
    static func buttonFrame(field: CGRect, within bounds: CGRect,
                            size: CGSize = buttonSize) -> CGRect? {
        guard bounds.width >= size.width, bounds.height >= size.height else {
            return nil
        }
        let w = size.width, h = size.height, gap: CGFloat = 6
        let candidates = [
            CGPoint(x: field.maxX - w, y: field.maxY + gap),          // above, right-aligned
            CGPoint(x: field.maxX + gap, y: field.maxY - h),          // right, top-aligned
            CGPoint(x: field.maxX - w, y: field.minY - h - gap),      // below, right-aligned
            CGPoint(x: field.minX - w - gap, y: field.maxY - h),      // left, top-aligned
        ]
        for origin in candidates {
            let frame = CGRect(origin: clamped(origin, size: size, within: bounds),
                               size: size)
            // Clamping must not slide it away from the field (e.g. a mostly off-screen field).
            let touchesField = frame.intersects(field.insetBy(dx: -(gap + 1), dy: -(gap + 1)))
            if !frame.intersects(field) && touchesField { return frame }
        }
        return nil
    }

    /// Status pill: same row as the entry button but left-aligned with the field, so
    /// both stay visible and clickable. Too narrow for both: take the button's spot
    /// (the pill panel sits one level above the button and covers it).
    static func pillFrame(field: CGRect, within bounds: CGRect, size: CGSize) -> CGRect? {
        let gap: CGFloat = 6
        let left = CGRect(x: field.minX, y: field.maxY + gap, width: size.width, height: size.height)
        if let button = buttonFrame(field: field, within: bounds),
           button.minY == field.maxY + gap,                      // button is in the row above
           bounds.contains(left), left.maxX + gap <= button.minX {
            return left
        }
        return buttonFrame(field: field, within: bounds, size: size)
    }

    /// AX global coordinates have their origin at the top-left of the primary
    /// (menu bar) screen and grow downward. AppKit global coordinates have the
    /// origin at the bottom-left of that same screen and grow upward. Screens
    /// left of, right of, or above the primary one keep working: AX x is the
    /// same, and only the primary screen's height is used for the flip.
    static func appKitRect(fromAX ax: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(x: ax.minX,
               y: primaryScreenFrame.maxY - ax.maxY,
               width: ax.width,
               height: ax.height)
    }

    /// Keeps the entry inside one screen even when the field is partly off-screen
    /// or on a display with a negative origin.
    static func clamped(_ origin: CGPoint, size: CGSize, within bounds: CGRect) -> CGPoint {
        CGPoint(x: max(bounds.minX, min(origin.x, bounds.maxX - size.width)),
                y: max(bounds.minY, min(origin.y, bounds.maxY - size.height)))
    }
}

// MARK: - Off-MainActor AX snapshot

/// AX reads for the trigger run outside MainActor. Each element gets a short
/// messaging timeout and the whole snapshot gets a wall-clock deadline.
///
/// `ponytail:` the deadline is checked between calls; one blocked AX call can
/// overshoot it by up to `callTimeout`. The snapshot is therefore bounded, not
/// strictly nonblocking, and the main thread never performs these reads.
private enum TriggerAX {
    struct Snapshot: @unchecked Sendable {
        let pid: pid_t
        let bundleID: String
        let role: String
        let mode: TriggerMode
        let axRect: CGRect
        let element: AXUIElement
    }

    static let callTimeout: Float = 0.15
    static let snapshotDeadline: TimeInterval = 0.6

    static func capture(pid: pid_t, bundleID: String) -> Snapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + snapshotDeadline

        guard let element = focusedElement(pid: pid, deadline: deadline) else { return nil }
        guard let role = stringAttribute(element, "AXRole", deadline: deadline) else {
            return nil
        }
        let subrole = stringAttribute(element, "AXSubrole", deadline: deadline)
        let support = TriggerPolicy.appSupport(bundleID: bundleID)
        let ancestors = support == .wholeValue
            ? ancestorRoles(of: element, deadline: deadline) : []
        let windowTitle = bundleID == TriggerPolicy.electronFixtureBundleID
            ? focusedWindowTitle(pid: pid, deadline: deadline) : nil
        guard case .show(let mode) = TriggerPolicy.decision(
            bundleID: bundleID, role: role, subrole: subrole,
            ancestorRoles: ancestors, windowTitle: windowTitle, secureInputEnabled: false) else { return nil }
        // Slack: anchor to the composer box (the nearest ancestor that also holds the
        // formatting and send toolbars) so the button never covers Slack's controls.
        guard let rect = anchorRect(of: element, bundleID: bundleID, deadline: deadline) else { return nil }

        return Snapshot(pid: pid, bundleID: bundleID, role: role, mode: mode,
                        axRect: rect, element: element)
    }

    /// The rect the entry and status pill hang from: the field, or in Slack its composer box.
    static func anchorRect(of element: AXUIElement, bundleID: String, deadline: TimeInterval) -> CGRect? {
        guard let fieldRect = geometry(of: element, deadline: deadline) else { return nil }
        var rect = fieldRect
        if bundleID == TriggerPolicy.slackBundleID,
           let box = composerBox(of: element, deadline: deadline),
           let boxRect = geometry(of: box, deadline: deadline),
           boxRect.contains(fieldRect), boxRect.height <= 400 {  // never a page-sized container
            rect = boxRect
        }
        return rect
    }

    /// Nearest ancestor (up to 4 levels) that directly contains an AXToolbar: in
    /// Slack that box holds the formatting bar, the text area and the send bar.
    private static func composerBox(of element: AXUIElement,
                                    deadline: TimeInterval) -> AXUIElement? {
        var current = element
        for _ in 0..<4 {
            guard let raw = copyAttribute(current, "AXParent", deadline: deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let parent = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(parent, callTimeout)
            if let children = copyAttribute(parent, "AXChildren", deadline: deadline) as? [AXUIElement],
               children.contains(where: { stringAttribute($0, "AXRole", deadline: deadline) == "AXToolbar" }) {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// The AXParent walk stops at the first AXWebArea, the depth cap, the
    /// deadline, or a read failure. It never reaches the application root.
    private static func ancestorRoles(of element: AXUIElement,
                                      deadline: TimeInterval) -> [String] {
        var roles: [String] = []
        var current = element
        for _ in 0..<TriggerPolicy.maxAncestorDepth {
            guard let raw = copyAttribute(current, "AXParent", deadline: deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let parent = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(parent, callTimeout)
            guard let role = stringAttribute(parent, "AXRole", deadline: deadline) else {
                break
            }
            roles.append(role)
            if role == TriggerPolicy.webAreaRole { break }
            current = parent
        }
        return roles
    }

    private static func focusedElement(pid: pid_t,
                                       deadline: TimeInterval) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, callTimeout)
        guard let raw = copyAttribute(application, "AXFocusedUIElement",
                                      deadline: deadline),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, callTimeout)
        return element
    }

    private static func focusedWindowTitle(pid: pid_t,
                                           deadline: TimeInterval) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, callTimeout)
        guard let raw = copyAttribute(application, "AXFocusedWindow", deadline: deadline),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, callTimeout)
        return stringAttribute(window, "AXTitle", deadline: deadline)
    }

    private static func geometry(of element: AXUIElement,
                                 deadline: TimeInterval) -> CGRect? {
        guard let rawPosition = copyAttribute(element, "AXPosition", deadline: deadline),
              let rawSize = copyAttribute(element, "AXSize", deadline: deadline),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String,
                                      deadline: TimeInterval) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, callTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String,
                                        deadline: TimeInterval) -> String? {
        copyAttribute(element, name, deadline: deadline) as? String
    }
}

// MARK: - Panel + dot

private let axFocusedElementChanged = "AXFocusedUIElementChanged"

/// `canBecomeKey`/`canBecomeMain` false plus `becomesKeyOnlyIfNeeded` keeps
/// clicks on the dot from taking keyboard focus away from the target app.
/// Collection behavior/level are best-effort; full-screen visibility is not
/// verified (PLAN.md M1).
private final class TriggerDotPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TriggerDotView: NSButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Slack aubergine pill so the entry reads as part of Slack's composer area.
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x4A / 255, green: 0x15 / 255, blue: 0x4B / 255, alpha: 1).cgColor
        layer?.cornerRadius = frameRect.height / 2
        attributedTitle = NSAttributedString(string: "✎ Rewrite", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        setButtonType(.momentaryChange)
        focusRingType = .none
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func clicked() {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Controller

/// Owns the floating dot, the PID-scoped AXObserver, and the global shortcut.
///
/// The controller never calls the model and never writes text. It reports the
/// current focused target through `handler`; the write-back core is responsible
/// for revalidating PID/element/original text before any write.
///
/// All state is MainActor-isolated. AX snapshot reads run off MainActor; panel
/// work, observer installation, and the final target check run on MainActor.
/// Create and drive it from the app delegate. `stop()` is the cleanup path and
/// must be called on termination: it removes the NSWorkspace observers, the
/// PID-scoped AXObserver, the refresh timer, and the Carbon hotkey.
@MainActor
final class TriggerController {
    enum HotKeyStatus: Equatable, Sendable {
        case notStarted
        case registered
        case failed(OSStatus)

        var isRegistered: Bool {
            if case .registered = self { return true }
            return false
        }
    }

    struct HotKey: Equatable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// ⌃⌥⌘Space. Values are Carbon key code / modifier flags so the MVP
        /// default is fixed but a caller can pass another binding.
        /// Ctrl+Option+Cmd avoids the Ctrl+Option+Space input-source conflict.
        static let defaultShortcut = HotKey(
            keyCode: 49, modifiers: 0x1000 | 0x0800 | 0x0100)
        static let defaultShortcutDescription = "⌃⌥⌘Space"
    }

    struct Target {
        let pid: pid_t
        let bundleID: String
        let role: String
        let mode: TriggerMode
        /// AppKit screen coordinates used to present the suggestion below the field.
        let anchorRect: CGRect
        /// Revalidate before writing: focus may have moved between this
        /// callback and the actual write-back.
        let element: AXUIElement

        /// Where the composer is now. It grows and shrinks with the draft, so `anchorRect`
        /// (read when the entry was clicked) goes stale after a replace or undo. `.zero`
        /// when it cannot be read: the status pill then sits in the screen corner.
        var liveAnchorRect: CGRect {
            guard let primary = NSScreen.screens.first else { return .zero }
            AXUIElementSetMessagingTimeout(element, TriggerAX.callTimeout)
            let deadline = ProcessInfo.processInfo.systemUptime + TriggerAX.snapshotDeadline
            guard let ax = TriggerAX.anchorRect(of: element, bundleID: bundleID, deadline: deadline) else { return .zero }
            return TriggerGeometry.appKitRect(fromAX: ax, primaryScreenFrame: primary.frame)
        }
    }

    typealias Handler = @MainActor (Target) -> Void

    private static let refreshInterval: TimeInterval = 0.5
    private static let triggerDebounce: TimeInterval = 0.35

    private let handler: Handler
    private let hotKey: HotKey
    private let panel: TriggerDotPanel

    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedPID: pid_t?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isRunning = false
    private var refreshTimer: Timer?
    private var lastTriggerTime: TimeInterval = -.infinity

    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var pendingTargetCompletion: ((Target?) -> Void)?

    private(set) var currentTarget: Target?
    /// The shell can surface `.failed` instead of leaving a silent no-op.
    private(set) var hotKeyStatus: HotKeyStatus = .notStarted
    var hotKeyAvailable: Bool { hotKeyStatus.isRegistered }
    var onShortcutWithoutAccessibility: (() -> Void)?

    init(handler: @escaping Handler, hotKey: HotKey = .defaultShortcut) {
        self.handler = handler
        self.hotKey = hotKey
        let dot = TriggerDotView(frame: NSRect(origin: .zero, size: TriggerGeometry.buttonSize))
        dot.setAccessibilityElement(true)
        dot.setAccessibilityRole(.button)
        dot.setAccessibilityLabel("Rewrite")
        let panel = TriggerDotPanel(size: TriggerGeometry.buttonSize)
        panel.contentView = dot
        self.panel = panel
        dot.onClick = { [weak self] in self?.fireFromDot() }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(frontmostApplicationChanged),
                           name: NSWorkspace.didActivateApplicationNotification,
                           object: nil)
        center.addObserver(self, selector: #selector(activeSpaceChanged),
                           name: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil)
        installHotKey()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        uninstallHotKey()
        tearDownObserver()
        stopRefreshTimer()
        pendingTargetCompletion = nil
        hide()
    }

    /// Recompute target/visibility. Safe to call when the permission state
    /// changes; it is also the observer/workspace callback path.
    func refresh() {
        requestRefresh(completion: nil)
    }

    // MARK: Refresh pipeline

    /// Dot and shortcut both ask for a fresh snapshot and fire only its result.
    private func requestTarget(completion: @escaping (Target?) -> Void) {
        requestRefresh(completion: completion)
    }

    private func requestRefresh(completion: ((Target?) -> Void)?) {
        refreshGeneration &+= 1
        if let completion { pendingTargetCompletion = completion }
        guard isRunning else {
            hide()
            finishPending(nil)
            return
        }
        startRefreshIfNeeded()
    }

    private func startRefreshIfNeeded() {
        guard !refreshInFlight else { return }
        guard isRunning else {
            hide()
            finishPending(nil)
            return
        }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            tearDownObserver()
            hide()
            finishPending(nil)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            tearDownObserver()
            hide()
            finishPending(nil)
            return
        }
        switch TriggerPolicy.appSupport(bundleID: bundleID) {
        case .selection, .wholeValue:
            break
        case .excluded, .unsupported, .unknown:
            tearDownObserver()
            hide()
            finishPending(nil)
            return
        }

        ensureObserver(pid: app.processIdentifier)
        refreshInFlight = true
        let generation = refreshGeneration
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = TriggerAX.capture(pid: pid, bundleID: bundleID)
            await MainActor.run {
                self?.finishRefresh(snapshot, generation: generation)
            }
        }
    }

    private func finishRefresh(_ snapshot: TriggerAX.Snapshot?, generation: Int) {
        refreshInFlight = false
        guard isRunning else {
            hide()
            finishPending(nil)
            return
        }
        // A newer request arrived while this snapshot was running. Drop this
        // result and take a fresh one so callers never see stale state.
        guard generation == refreshGeneration else {
            startRefreshIfNeeded()
            return
        }
        apply(snapshot)
        finishPending(currentTarget)
    }

    private func apply(_ snapshot: TriggerAX.Snapshot?) {
        guard let snapshot,
              isRunning,
              AXIsProcessTrusted(),
              !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              let primary = NSScreen.screens.first else {
            hide()
            return
        }

        let appKitField = TriggerGeometry.appKitRect(fromAX: snapshot.axRect,
                                                     primaryScreenFrame: primary.frame)
        let targetScreen = screen(containing: appKitField) ?? primary
        currentTarget = Target(pid: snapshot.pid, bundleID: snapshot.bundleID,
                               role: snapshot.role, mode: snapshot.mode,
                               anchorRect: appKitField, element: snapshot.element)
        if let frame = TriggerGeometry.buttonFrame(field: appKitField,
                                                    within: targetScreen.visibleFrame) {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        } else {
            // Keep the shortcut target and refresh timer when no clear edge space exists.
            panel.orderOut(nil)
        }
        startRefreshTimer()
    }

    private func finishPending(_ target: Target?) {
        guard let completion = pendingTargetCompletion else { return }
        pendingTargetCompletion = nil
        completion(target)
    }

    // MARK: Trigger paths

    /// Dot click and shortcut both take a fresh snapshot. The cached target is
    /// never trusted: frontmost PID/bundle, focused element, role, ancestry and
    /// Secure Input are all re-read immediately before firing.
    private func fireFromDot() {
        requestTrigger()
    }

    fileprivate func fireFromShortcut() {
        // Without Accessibility the same shortcut runs the clipboard path (docs/design/no-ax-mode.md).
        if !AXIsProcessTrusted() {
            if isRunning, acceptTriggerTime() { onShortcutWithoutAccessibility?() }
            return
        }
        requestTrigger()
    }

    private func requestTrigger() {
        guard isRunning, acceptTriggerTime() else { return }
        requestTarget { [weak self] target in
            guard let self, self.isRunning, let target,
                  AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
            else { return }
            self.handler(target)
        }
    }

    /// Small debounce: Carbon auto-repeat and double clicks must not queue
    /// duplicate optimization requests.
    private func acceptTriggerTime() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTime >= Self.triggerDebounce else { return false }
        lastTriggerTime = now
        return true
    }

    // MARK: Visibility + bounded refresh timer

    private func hide() {
        currentTarget = nil
        panel.orderOut(nil)
        stopRefreshTimer()
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        // Bounded fallback for window move/resize/destroy and for an observer
        // that failed to register: refresh only while the dot is visible.
        let timer = Timer(timeInterval: Self.refreshInterval, target: self,
                          selector: #selector(refreshTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func refreshTick() {
        guard currentTarget != nil else {
            stopRefreshTimer()
            return
        }
        // Do not cancel a slow in-flight snapshot every tick; focus/space
        // notifications still supersede it when the target actually changes.
        guard !refreshInFlight else { return }
        refresh()
    }

    @objc private func frontmostApplicationChanged() {
        refresh()
    }

    @objc private func activeSpaceChanged() {
        refresh()
    }

    // MARK: AX focus tracking

    private func ensureObserver(pid: pid_t) {
        guard observedPID != pid || observer == nil else { return }
        tearDownObserver()
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, beniceAXObserverCallback, &newObserver) == .success,
              let newObserver else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, TriggerAX.callTimeout)
        let added = AXObserverAddNotification(
            newObserver, application, axFocusedElementChanged as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        // If registration fails the dot still gets a bounded refresh timer
        // while visible; it is never left stale forever.
        guard added == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        observedApplication = application
        observedPID = pid
    }

    private func tearDownObserver() {
        if let observer {
            if let observedApplication {
                AXObserverRemoveNotification(observer, observedApplication,
                                             axFocusedElementChanged as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedApplication = nil
        observedPID = nil
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first
    }

    // MARK: Carbon hotkey

    private func installHotKey() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerUPP: EventHandlerUPP = beniceHotKeyHandler
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), handlerUPP, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
        guard installed == noErr else {
            hotKeyHandlerRef = nil
            hotKeyStatus = .failed(installed)
            return
        }
        var ref: EventHotKeyRef?
        // 'BNCE' signature, fixed id: one shortcut per process.
        let hotKeyID = EventHotKeyID(signature: 0x424E4345, id: 1)
        let registered = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else {
            if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
            hotKeyHandlerRef = nil
            hotKeyStatus = .failed(registered)
            return
        }
        hotKeyRef = ref
        hotKeyStatus = .registered
    }

    private func uninstallHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
        hotKeyHandlerRef = nil
        hotKeyStatus = .notStarted
    }
}

// MARK: - C callbacks

private func beniceAXObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                      _ notification: CFString,
                                      _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let controller = Unmanaged<TriggerController>.fromOpaque(refcon).takeUnretainedValue()
    // The observer source lives in the main run loop, but hop through the
    // MainActor explicitly rather than assuming the callback's executor.
    Task { @MainActor in controller.refresh() }
}

private func beniceHotKeyHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<TriggerController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in controller.fireFromShortcut() }
    return noErr
}
