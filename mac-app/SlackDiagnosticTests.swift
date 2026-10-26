import Foundation

@main
struct SlackDiagnosticTests {
    @MainActor
    static func main() throws {
        let secret = "private-channel-message"
        let names = ["AXValue", "AXSelectedText", "AXSelectedTextRange", "AXTitle",
                     "AXDescription", "AXHelp", "AXURL", "AXDocument", "AXIdentifier"]
        let metadata = SlackDiagnostic.metadata(
            role: secret, subrole: secret,
            names: Array(repeating: names + [secret, "AXCustom-" + secret], count: 10_000).flatMap { $0 },
            settable: ["AXValue": true, "AXSelectedText": false,
                       "AXSelectedTextRange": true, "AXIdentifier": true, secret: true])
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        assert(!json.contains(secret))
        assert(metadata["role"] as? String == "unknown" && metadata["subrole"] == nil)
        assert(Set(metadata.keys) == ["attributeNames", "settable", "role"])
        let flags = metadata["settable"] as! [String: Bool]
        assert(flags == ["AXValue": true, "AXSelectedText": false, "AXSelectedTextRange": true])
        assert((metadata["attributeNames"] as! [String]) == names.sorted())
        for name in names { assert(metadata[name] == nil, "Sensitive values must never be report fields") }
        assert(data.count < 1_024, "Duplicate/custom attribute names must not grow output")
        let known = SlackDiagnostic.metadata(role: "AXTextArea", subrole: "AXUnknown",
                                             names: [], settable: [:])
        assert(known["role"] as? String == "AXTextArea")
        assert(known["subrole"] as? String == "AXUnknown")
        assert(SlackDiagnostic.maximumAncestors == 24)
        assert(SlackDiagnostic.maximumChildren == 64 && SlackDiagnostic.maximumChildDepth == 6)
        assert(SlackDiagnostic.childAllowance(count: 1_000, queued: 1, depth: 0) == 63)
        assert(SlackDiagnostic.childAllowance(count: 10, queued: 64, depth: 1) == 0)
        assert(SlackDiagnostic.childAllowance(count: 10, queued: 1, depth: 6) == 0)
        assert(SlackDiagnostic.childAllowance(count: -1, queued: 1, depth: 0) == 0)
        assert(SlackDiagnostic.childAllowance(count: 2, queued: 63, depth: 5) == 1)
        let string = "🔒" + secret
        assert(SlackDiagnostic.observation(string as CFString)["length"] as? Int == string.utf16.count)
        let generic = SlackDiagnostic.urlStructure("https://app.slack.com/client/T12345678/dms?secret=private-channel-message" as CFString)
        assert(generic["category"] as? String == "slack_client_generic_dms")
        let route = SlackDiagnostic.urlStructure("https://app.slack.com/client/T12345678/D12345678" as CFString)
        assert(route["conversationShaped"] as? Bool == true)
        assert(SlackDiagnostic.urlStructure(secret as CFString)["category"] as? String == "unknown")
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key("NSLink"): "https://private.example/" + secret,
            NSAttributedString.Key(secret): secret])
        let summary = SlackDiagnostic.attributedSummary(attributed)
        assert(summary["unknownAttributeKeys"] as? Bool == true)
        assert(summary["rangeCount"] as? Int == 1)
        assert(summary["attributeKeyCategories"] as? [String] == ["NSLink"])
        let truncated = SlackDiagnostic.attributedSummary(NSAttributedString(string: String(repeating: "x", count: SlackDiagnostic.maximumAttributedLength + 1)))
        assert(truncated["readStatus"] as? String == "length_limit")
        let redacted = try JSONSerialization.data(withJSONObject: [generic, route, summary, SlackDiagnostic.observation(string as CFString)])
        let output = String(decoding: redacted, as: UTF8.self)
        for forbidden in [secret, "T12345678", "D12345678", "private.example", "https://"] {
            assert(!output.contains(forbidden))
        }
        print("SlackDiagnosticTests passed (pure metadata only; no live AX or GUI)")
    }
}
