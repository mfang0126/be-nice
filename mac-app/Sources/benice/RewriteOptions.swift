import Foundation

/// A named way to rewrite. `instruction` goes to the model; `name` labels the card.
public struct RewriteStyle: Codable, Equatable, Sendable {
    public var name: String
    public var instruction: String

    public init(name: String, instruction: String) {
        self.name = name
        self.instruction = instruction
    }

    public static let presets: [RewriteStyle] = [
        RewriteStyle(name: "Direct", instruction: "Lead with the point, no hedging or filler"),
        RewriteStyle(name: "Friendly", instruction: "Warm and conversational, like talking to a colleague"),
        RewriteStyle(name: "Clear", instruction: "Plain words, short sentences, one idea each"),
        RewriteStyle(name: "Shorter", instruction: "Same message, half the words, only what is needed"),
        RewriteStyle(name: "Formal", instruction: "Professional tone for clients and leadership"),
        RewriteStyle(name: "Polished English", instruction: "Translate and tidy into English"),
        RewriteStyle(name: "Polite", instruction: "Courteous and respectful; keep requests as polite questions"),
    ]

    /// Preset wording from earlier builds; slots saved with it are upgraded to the current wording.
    static let retiredInstructions = [
        "Direct": "Lead with the point", "Friendly": "Relaxed, not stiff", "Clear": "One idea per sentence",
        "Shorter": "Same message, half the words", "Formal": "For clients and leadership",
    ]

    public static let defaultSlots = ["Polite", "Shorter", "Friendly"].compactMap { name in presets.first { $0.name == name } }
    /// The defaults before Polite existed; slots still holding exactly these are moved to the new defaults.
    static let previousDefaultNames = ["Direct", "Friendly", "Clear"]
    static let maxInstructionLength = 200
}

/// The three style slots shown as cards, in order; slot 1 is selected by default.
enum StyleSlots {
    static let key = "be-nice.styleSlots"

    static func load(_ defaults: UserDefaults = .standard) -> [RewriteStyle] {
        guard let data = defaults.data(forKey: key),
              let slots = try? JSONDecoder().decode([RewriteStyle].self, from: data),
              slots.count == 3, slots.allSatisfy(isValid) else { return RewriteStyle.defaultSlots }
        let upgraded = slots.map { slot in
            RewriteStyle.presets.first { $0.name == slot.name && RewriteStyle.retiredInstructions[slot.name] == slot.instruction }
                ?? slot
        }
        return upgraded.map(\.name) == RewriteStyle.previousDefaultNames ? RewriteStyle.defaultSlots : upgraded
    }

    static func save(_ slots: [RewriteStyle], _ defaults: UserDefaults = .standard) {
        guard slots.count == 3, slots.allSatisfy(isValid),
              let data = try? JSONEncoder().encode(slots) else { return }
        defaults.set(data, forKey: key)
    }

    static func isValid(_ style: RewriteStyle) -> Bool {
        let name = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = style.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = { (text: String) in
            text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        }
        return !name.isEmpty && name.count <= 40
            && !instruction.isEmpty && instruction.count <= RewriteStyle.maxInstructionLength
            && plain(name) && plain(instruction)
    }
}

public struct RewriteOption: Equatable, Sendable {
    public let style: RewriteStyle
    public let text: String

    public init(style: RewriteStyle, text: String) {
        self.style = style
        self.text = text
    }
}

/// Parses `{"options":[{"id":1,"text":"..."}]}` where `id` is the 1-based slot index into `styles`.
enum RewriteOptionsParser {
    enum ParseError: LocalizedError {
        case invalidJSON, invalidRoot, invalidCount, invalidEntry, invalidID, duplicateID, blankText

        var errorDescription: String? {
            switch self {
            case .invalidJSON: "Rewrite response must contain only a valid JSON object."
            case .invalidRoot: "Rewrite response must contain exactly an options array."
            case .invalidCount: "Rewrite response must contain between one and three options."
            case .invalidEntry: "Each rewrite option must contain exactly id and text."
            case .invalidID: "Rewrite option id must match one of the requested styles."
            case .duplicateID: "Each rewrite option must use a different style."
            case .blankText: "Rewrite option text must not be blank."
            }
        }
    }

    static func parse(_ response: String, styles: [RewriteStyle]) throws -> [RewriteOption] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(response.utf8))
        } catch {
            throw ParseError.invalidJSON
        }
        guard let root = value as? [String: Any], Set(root.keys) == ["options"],
              let entries = root["options"] as? [Any] else {
            throw ParseError.invalidRoot
        }
        guard (1...styles.count).contains(entries.count) else { throw ParseError.invalidCount }

        var ids = Set<Int>()
        var texts = Set<String>()
        var found: [(Int, String)] = []
        for entry in entries {
            guard let fields = entry as? [String: Any], Set(fields.keys) == ["id", "text"],
                  let number = fields["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let id = Int(exactly: number.doubleValue),
                  let text = fields["text"] as? String else {
                throw ParseError.invalidEntry
            }
            guard styles.indices.contains(id - 1) else { throw ParseError.invalidID }
            guard ids.insert(id).inserted else { throw ParseError.duplicateID }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ParseError.blankText }
            if texts.insert(trimmed).inserted { found.append((id, text)) }
        }
        // Cards follow slot order, whatever order the model answered in.
        return found.sorted { $0.0 < $1.0 }.map { RewriteOption(style: styles[$0.0 - 1], text: $0.1) }
    }
}
