import Foundation

/// One editable style shared by all rewrites. Raw samples are deliberately not
/// part of this value, so profile persistence never persists source samples.
public struct StyleProfile: Equatable, Sendable {
    public var guide: String

    public init(guide: String = "") { self.guide = guide }

    public var isEmpty: Bool {
        guide.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Persists the style preference only. Samples and held-out evaluation text
/// stay in transient UI/test flows and have no persistence keys here.
struct StyleStore: @unchecked Sendable {
    private static let guideKey = "be-nice.style.guide"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> StyleProfile {
        StyleProfile(guide: defaults.string(forKey: Self.guideKey) ?? "")
    }

    func save(_ profile: StyleProfile) {
        defaults.set(profile.guide.trimmingCharacters(in: .whitespacesAndNewlines),
                   forKey: Self.guideKey)
    }
}
