import Foundation

private final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

@main
struct StyleProfileTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("SELFTEST FAIL: \(message)") }
        }

        expect(StyleProfile().isEmpty, "blank profile is empty")
        expect(StyleProfile(guide: " \n").isEmpty, "whitespace-only guide is empty")
        expect(!StyleProfile(guide: "Warm and concise").isEmpty, "nonblank profile is not empty")

        let defaults = InMemoryDefaults()
        let store = StyleStore(defaults: defaults)
        expect(store.load() == StyleProfile(), "missing preference uses the generic path")
        store.save(StyleProfile(guide: "  Warm and concise\n"))
        expect(store.load().guide == "Warm and concise", "one shared guide persists trimmed")
        expect(defaults.dictionaryRepresentation().count == 1,
               "only one guide is persisted; no samples or selection keys exist")

        if failures == 0 { print("StyleProfileTests PASS"); exit(0) }
        print("StyleProfileTests FAILED (\(failures) assertion(s))")
        exit(1)
    }
}
