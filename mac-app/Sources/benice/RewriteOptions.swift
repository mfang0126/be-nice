import Foundation

public enum RewriteStyle: String, Codable, Sendable {
    case direct, friendly, clear
}

public struct RewriteOption: Equatable, Sendable {
    public let style: RewriteStyle
    public let text: String

    public init(style: RewriteStyle, text: String) {
        self.style = style
        self.text = text
    }
}

enum RewriteOptionsParser {
    enum ParseError: LocalizedError {
        case invalidJSON, invalidRoot, invalidCount, invalidEntry, invalidStyle, duplicateStyle, blankText

        var errorDescription: String? {
            switch self {
            case .invalidJSON: "Rewrite response must contain only a valid JSON object."
            case .invalidRoot: "Rewrite response must contain exactly an options array."
            case .invalidCount: "Rewrite response must contain between one and three options."
            case .invalidEntry: "Each rewrite option must contain exactly style and text strings."
            case .invalidStyle: "Rewrite style must be direct, friendly, or clear."
            case .duplicateStyle: "Each rewrite option must use a different style."
            case .blankText: "Rewrite option text must not be blank."
            }
        }
    }

    static func parse(_ response: String) throws -> [RewriteOption] {
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
        guard (1...3).contains(entries.count) else { throw ParseError.invalidCount }

        var styles = Set<RewriteStyle>()
        var texts = Set<String>()
        var options: [RewriteOption] = []
        for entry in entries {
            guard let fields = entry as? [String: Any], Set(fields.keys) == ["style", "text"],
                  let rawStyle = fields["style"] as? String,
                  let text = fields["text"] as? String else {
                throw ParseError.invalidEntry
            }
            guard let style = RewriteStyle(rawValue: rawStyle) else { throw ParseError.invalidStyle }
            guard styles.insert(style).inserted else { throw ParseError.duplicateStyle }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ParseError.blankText }
            if texts.insert(trimmed).inserted {
                options.append(RewriteOption(style: style, text: text))
            }
        }
        return options
    }
}
