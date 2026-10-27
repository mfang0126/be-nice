import Foundation

@main
struct RewriteOptionsTests {
    static func main() throws {
        let styles = Array(RewriteStyle.presets.prefix(3))
        func parse(_ json: String, _ s: [RewriteStyle] = styles) throws -> [RewriteOption] {
            try RewriteOptionsParser.parse(json, styles: s)
        }

        let all = try parse(#"{"options":[{"id":3,"text":"Third"},{"id":1,"text":"First"},{"id":2,"text":"Second"}]}"#)
        assert(all == [
            RewriteOption(style: styles[0], text: "First"),
            RewriteOption(style: styles[1], text: "Second"),
            RewriteOption(style: styles[2], text: "Third")
        ], "ids map to slots and results are sorted by slot")
        let single = try parse(#"{"options":[{"id":3,"text":"Only"}]}"#)
        assert(single == [RewriteOption(style: styles[2], text: "Only")])
        let oneStyle = try parse(#"{"options":[{"id":1,"text":"Solo"}]}"#, [styles[1]])
        assert(oneStyle == [RewriteOption(style: styles[1], text: "Solo")], "ids index the styles passed in")

        let deduplicated = try parse(#"{"options":[{"id":2,"text":" \tHello\r\n"},{"id":1,"text":"Hello"},{"id":3,"text":"Goodbye\n"}]}"#)
        assert(deduplicated == [
            RewriteOption(style: styles[1], text: " \tHello\r\n"),
            RewriteOption(style: styles[2], text: "Goodbye\n")
        ], "Trim only for comparison; the first answered occurrence wins; whitespace preserved")
        assert(Array(deduplicated[0].text.utf8) == Array(" \tHello\r\n".utf8))
        let internalWhitespace = try parse(#"{"options":[{"id":1,"text":"a b"},{"id":2,"text":"a  b"}]}"#)
        assert(internalWhitespace.count == 2, "Do not normalize internal whitespace")

        let invalid: [(String, String)] = [
            ("malformed", "{private-response"),
            ("truncated", #"{"options":[{"id":1,"text":"unfinished"}"#),
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
            ("missing id", #"{"options":[{"text":"private-response"}]}"#),
            ("missing text", #"{"options":[{"id":1}]}"#),
            ("extra entry key", #"{"options":[{"id":1,"text":"x","extra":1}]}"#),
            ("old style key", #"{"options":[{"style":"direct","text":"x"}]}"#),
            ("string id", #"{"options":[{"id":"1","text":"x"}]}"#),
            ("bool true id", #"{"options":[{"id":true,"text":"x"}]}"#),
            ("bool false id", #"{"options":[{"id":false,"text":"x"}]}"#),
            ("fractional id", #"{"options":[{"id":1.5,"text":"x"}]}"#),
            ("null id", #"{"options":[{"id":null,"text":"x"}]}"#),
            ("zero id", #"{"options":[{"id":0,"text":"x"}]}"#),
            ("negative id", #"{"options":[{"id":-1,"text":"x"}]}"#),
            ("unknown id", #"{"options":[{"id":4,"text":"x"}]}"#),
            ("boolean text", #"{"options":[{"id":1,"text":true}]}"#),
            ("numeric text", #"{"options":[{"id":1,"text":1}]}"#),
            ("array text", #"{"options":[{"id":1,"text":[]}]}"#),
            ("null text", #"{"options":[{"id":1,"text":null}]}"#),
            ("duplicate id", #"{"options":[{"id":1,"text":"x"},{"id":1,"text":"y"}]}"#),
            ("duplicate id and text", #"{"options":[{"id":1,"text":"x"},{"id":1,"text":"x"}]}"#),
            ("empty text", #"{"options":[{"id":1,"text":""}]}"#),
            ("blank text", #"{"options":[{"id":1,"text":" \t\r\n "}]}"#),
            ("too many before deduplication", #"{"options":[{"id":1,"text":"x"},{"id":2,"text":"x"},{"id":3,"text":"x"},{"id":1,"text":"x"}]}"#),
            ("markdown wrapper (parser is strict)", "```json\n{\"options\":[{\"id\":1,\"text\":\"x\"}]}\n```"),
            ("trailing prose", #"{"options":[{"id":1,"text":"x"}]} private-response"#)
        ]
        for (name, response) in invalid {
            do {
                _ = try parse(response)
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
        // An id beyond the styles actually requested is unknown even if 1...3.
        do {
            _ = try parse(#"{"options":[{"id":2,"text":"x"}]}"#, [styles[0]])
            assertionFailure("Accepted id beyond requested styles")
        } catch {}
        print("RewriteOptionsTests PASS (slot mapping, sorting, deduplication, preservation, \(invalid.count) rejection cases)")
    }
}
