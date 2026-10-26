import Foundation

@main
struct RewriteOptionsTests {
    static func main() throws {
        let all = try RewriteOptionsParser.parse(#"{"options":[{"style":"direct","text":"First"},{"style":"friendly","text":"Second"},{"style":"clear","text":"Third"}]}"#)
        assert(all == [
            RewriteOption(style: .direct, text: "First"),
            RewriteOption(style: .friendly, text: "Second"),
            RewriteOption(style: .clear, text: "Third")
        ], "All styles and original order must be preserved")
        let single = try RewriteOptionsParser.parse(#"{"options":[{"style":"clear","text":"Only"}]}"#)
        assert(single == [RewriteOption(style: .clear, text: "Only")])

        let deduplicated = try RewriteOptionsParser.parse(#"{"options":[{"style":"friendly","text":" \tHello\r\n"},{"style":"direct","text":"Hello"},{"style":"clear","text":"Goodbye\n"}]}"#)
        assert(deduplicated == [
            RewriteOption(style: .friendly, text: " \tHello\r\n"),
            RewriteOption(style: .clear, text: "Goodbye\n")
        ], "Trim only for comparison; preserve first occurrence and actual whitespace")
        assert(Array(deduplicated[0].text.utf8) == Array(" \tHello\r\n".utf8))
        let internalWhitespace = try RewriteOptionsParser.parse(#"{"options":[{"style":"direct","text":"a b"},{"style":"clear","text":"a  b"}]}"#)
        assert(internalWhitespace.count == 2, "Do not normalize internal whitespace")

        let invalid: [(String, String)] = [
            ("malformed", "{private-response"),
            ("truncated", #"{"options":[{"style":"direct","text":"unfinished"}"#),
            ("array root", "[]"),
            ("null root", "null"),
            ("string root", #""private-response""#),
            ("number root", "42"),
            ("missing options", "{}"),
            ("extra root key", #"{"options":[],"private-response":true}"#),
            ("wrong options type", #"{"options":{}}"#),
            ("null options", #"{"options":null}"#),
            ("empty options", #"{"options":[]}"#),
            ("nonobject entry", #"{"options":["private-response"]}"#),
            ("null entry", #"{"options":[null]}"#),
            ("missing style", #"{"options":[{"text":"private-response"}]}"#),
            ("missing text", #"{"options":[{"style":"direct"}]}"#),
            ("extra entry key", #"{"options":[{"style":"direct","text":"x","extra":1}]}"#),
            ("numeric style", #"{"options":[{"style":1,"text":"x"}]}"#),
            ("boolean text", #"{"options":[{"style":"direct","text":true}]}"#),
            ("numeric text", #"{"options":[{"style":"direct","text":1}]}"#),
            ("array text", #"{"options":[{"style":"direct","text":[]}]}"#),
            ("null text", #"{"options":[{"style":"direct","text":null}]}"#),
            ("unknown style", #"{"options":[{"style":"private-response","text":"x"}]}"#),
            ("duplicate style", #"{"options":[{"style":"direct","text":"x"},{"style":"direct","text":"y"}]}"#),
            ("duplicate style and text", #"{"options":[{"style":"direct","text":"x"},{"style":"direct","text":"x"}]}"#),
            ("empty text", #"{"options":[{"style":"direct","text":""}]}"#),
            ("blank text", #"{"options":[{"style":"direct","text":" \t\r\n "}]}"#),
            ("too many before deduplication", #"{"options":[{"style":"direct","text":"x"},{"style":"friendly","text":"x"},{"style":"clear","text":"x"},{"style":"direct","text":"x"}]}"#),
            ("markdown wrapper", "```json\n{\"options\":[{\"style\":\"direct\",\"text\":\"x\"}]}\n```"),
            ("trailing prose", #"{"options":[{"style":"direct","text":"x"}]} private-response"#)
        ]
        for (name, response) in invalid {
            do {
                _ = try RewriteOptionsParser.parse(response)
                assertionFailure("Accepted invalid response: \(name)")
            } catch {
                guard let localized = error as? LocalizedError,
                      let message = localized.errorDescription else {
                    assertionFailure("Missing helpful error: \(name)")
                    continue
                }
                assert(!message.isEmpty && !message.contains("private-response"), "Errors must not expose response content")
            }
        }
        print("RewriteOptionsTests PASS (valid styles, deduplication, preservation, \(invalid.count) rejection cases)")
    }
}
