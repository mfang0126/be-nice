import AppKit
import ApplicationServices

enum SlackDiagnostic {
    // Keep AX IPC off the main actor and cross back only with serialized metadata.
    static func response(requestID: String) throws -> Data {
        var report = snapshot()
        report["requestID"] = requestID
        report["updatedAt"] = Date().timeIntervalSince1970
        return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }

    private static let bundleID = "com.tinyspeck.slackmacgap"
    static let maximumAncestors = 24
    static let maximumChildren = 64
    static let maximumChildDepth = 6
    static let maximumAttributedLength = 16_384
    // Fixed vocabulary prevents custom AX strings from becoming a content channel.
    private static let roles: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea",
        "AXTextArea", "AXTextField", "AXComboBox", "AXButton", "AXToolbar",
        "AXImage", "AXLink", "AXSplitGroup", "AXTabGroup", "AXStaticText", "AXUnknown"
    ]
    private static let subroles: Set<String> = [
        "AXStandardWindow", "AXDialog", "AXSystemDialog", "AXSearchField",
        "AXSecureTextField", "AXUnknown"
    ]
    private static let attributeNames: Set<String> = [
        "AXRole", "AXSubrole", "AXParent", "AXChildren", "AXFocused", "AXEnabled",
        "AXPosition", "AXSize", "AXWindow", "AXTopLevelUIElement", "AXValue",
        "AXSelectedText", "AXSelectedTextRange", "AXNumberOfCharacters",
        "AXVisibleCharacterRange", "AXInsertionPointLineNumber", "AXTitle",
        "AXDescription", "AXHelp", "AXURL", "AXDocument", "AXIdentifier",
        "AXDOMIdentifier", "AXDOMClassList"
    ]
    private static let writableAttributes = ["AXValue", "AXSelectedText", "AXSelectedTextRange"]

    // Only names and flags enter the report; arbitrary keys and string values are discarded.
    static func metadata(role: String?, subrole: String?, names: [String],
                         settable: [String: Bool]) -> [String: Any] {
        var result: [String: Any] = [
            "attributeNames": Array(Set(names).intersection(attributeNames)).sorted(),
            "settable": settable.filter { writableAttributes.contains($0.key) }
        ]
        result["role"] = role.flatMap { roles.contains($0) ? $0 : nil } ?? "unknown"
        if let subrole, subroles.contains(subrole) { result["subrole"] = subrole }
        return result
    }

    static func observation(_ value: CFTypeRef?) -> [String: Any] {
        guard let value else { return ["cfType": "none"] }
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() {
            return ["cfType": "string", "length": (value as! String).utf16.count]
        }
        if type == CFURLGetTypeID() { return ["cfType": "url"] }
        if type == CFArrayGetTypeID() { return ["cfType": "array", "length": CFArrayGetCount((value as! CFArray))] }
        if type == CFAttributedStringGetTypeID() {
            return ["cfType": "attributedString", "length": CFAttributedStringGetLength((value as! CFAttributedString))]
        }
        if type == AXUIElementGetTypeID() { return ["cfType": "element"] }
        if type == AXValueGetTypeID() { return ["cfType": "axValue"] }
        if type == CFBooleanGetTypeID() { return ["cfType": "boolean"] }
        if type == CFNumberGetTypeID() { return ["cfType": "number"] }
        return ["cfType": "unknown"]
    }

    static func urlStructure(_ value: CFTypeRef?) -> [String: Any] {
        let text: String?
        if let value, CFGetTypeID(value) == CFURLGetTypeID() { text = (value as! URL).absoluteString }
        else { text = value as? String }
        guard let text, let url = URLComponents(string: text), let host = url.host else {
            return ["category": "unknown", "workspaceShaped": false, "conversationShaped": false]
        }
        let parts = url.path.split(separator: "/").map(String.init)
        func shaped(_ part: String, prefixes: String) -> Bool {
            guard part.count >= 9, part.count <= 32, let first = part.first, prefixes.contains(first) else { return false }
            return part.dropFirst().allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        }
        let client = host.lowercased() == "app.slack.com" && parts.first == "client"
        let workspace = client && parts.dropFirst().contains { shaped($0, prefixes: "T") }
        let conversation = client && parts.dropFirst().contains { shaped($0, prefixes: "CDG") }
        let category = !client ? "other" : conversation ? "slack_client_conversation_shaped" : parts.contains("dms") ? "slack_client_generic_dms" : "slack_client_other"
        return ["category": category, "workspaceShaped": workspace, "conversationShaped": conversation]
    }

    static func childAllowance(count: Int, queued: Int, depth: Int) -> Int {
        guard count > 0, depth >= 0, depth < maximumChildDepth else { return 0 }
        return min(count, max(0, maximumChildren - max(0, queued)))
    }

    static func attributedSummary(_ text: NSAttributedString) -> [String: Any] {
        guard text.length <= maximumAttributedLength else { return ["readStatus": "length_limit"] }
        let allowed: Set<String> = ["AXFont", "AXForegroundColor", "AXBackgroundColor", "AXUnderline", "AXStrikethrough", "AXLink", "AXAttachment", "NSFont", "NSColor", "NSBackgroundColor", "NSUnderline", "NSStrikethrough", "NSLink", "NSAttachment", "NSParagraphStyle"]
        var keys = Set<String>()
        var ranges = 0
        var unknown = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            ranges += 1
            for key in attributes.keys {
                if allowed.contains(key.rawValue) { keys.insert(key.rawValue) } else { unknown = true }
            }
        }
        return ["readStatus": "ok", "length": text.length, "rangeCount": ranges,
                "attributeKeyCategories": keys.sorted(), "unknownAttributeKeys": unknown,
                "formatPresent": !keys.isEmpty || unknown]
    }

    static func snapshot() -> [String: Any] {
        var report: [String: Any] = ["status": "blocked", "contextIdentityVerified": false,
                                     "ancestorCount": 0, "truncated": false]
        func blocked(_ reason: String) -> [String: Any] {
            report["reason"] = reason
            return report
        }
        guard AXIsProcessTrusted() else { return blocked("accessibility_not_trusted") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return blocked("slack_not_running") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleID,
              apps.contains(where: { $0.processIdentifier == app.processIdentifier }) else {
            return blocked("slack_not_foreground")
        }
        let pid = app.processIdentifier
        report["pid"] = Int(pid)
        if let url = app.bundleURL,
           let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.count <= 64,
           version.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.-").contains($0) }) {
            report["version"] = version
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let application = AXUIElementCreateApplication(pid)
        var failure: String?
        func ready(_ element: AXUIElement) -> Bool {
            guard failure == nil else { return false }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
                failure = "slack_lost_foreground"; return false
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { failure = "timeout"; return false }
            guard AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining))) == .success else {
                failure = "messaging_timeout_unavailable"; return false
            }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
                failure = "element_owner_mismatch"; return false
            }
            return true
        }
        var lastReadStatus = "not_read"
        func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard ready(element) else { lastReadStatus = "blocked"; return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            lastReadStatus = error == .success ? "ok" : error == .attributeUnsupported ? "unsupported" : error == .noValue ? "no_value" : "error"
            if error == .cannotComplete { failure = "ax_cannot_complete" }
            else if error != .success && error != .attributeUnsupported && error != .noValue {
                failure = "attribute_read_failed"
            }
            return error == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard var current = element(copy(application, "AXFocusedUIElement")) else {
            return blocked(failure ?? "focused_element_unavailable")
        }
        let focused = current
        func inspect(_ target: AXUIElement) -> [String: Any] {
            let role = copy(target, "AXRole") as? String
            let subrole = copy(target, "AXSubrole") as? String
            var names: CFArray?
            var parameters: CFArray?
            var namesStatus = "blocked"
            var parametersStatus = "blocked"
            if ready(target) {
                namesStatus = AXUIElementCopyAttributeNames(target, &names) == .success ? "ok" : "error"
            }
            if ready(target) {
                parametersStatus = AXUIElementCopyParameterizedAttributeNames(target, &parameters) == .success ? "ok" : "error"
            }
            let advertised = names as? [String] ?? []
            let parameterNames = parameters as? [String] ?? []
            var flags: [String: Bool] = [:]
            var settableStatus: [String: String] = [:]
            for attribute in writableAttributes {
                settableStatus[attribute] = "blocked"
                guard ready(target) else { break }
                var flag: DarwinBoolean = false
                let error = AXUIElementIsAttributeSettable(target, attribute as CFString, &flag)
                settableStatus[attribute] = error == .success ? "ok" : "error"
                if error == .success {
                    flags[attribute] = flag.boolValue
                }
            }
            var node = metadata(role: role, subrole: subrole, names: advertised, settable: flags)
            node["settableStatus"] = settableStatus
            node["attributeNamesStatus"] = namesStatus
            node["parameterizedNamesStatus"] = parametersStatus
            node["parameterizedAttributeNames"] = Array(Set(parameterNames).intersection(["AXAttributedStringForRange"])).sorted()
            var observations: [String: Any] = [:]
            for name in ["AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXURL", "AXDocument", "AXValue"] {
                var item: [String: Any] = ["supported": advertised.contains(name), "readStatus": namesStatus == "ok" ? "unsupported" : "unknown", "cfType": "none"]
                if advertised.contains(name) {
                    let value = copy(target, name)
                    item.merge(observation(value)) { _, new in new }
                    item["readStatus"] = lastReadStatus
                    if name == "AXURL" || name == "AXDocument", value != nil { item["urlStructure"] = urlStructure(value) }
                }
                observations[name] = item
            }
            node["attributes"] = observations
            return node
        }
        var nodes: [[String: Any]] = []
        var termination = "ancestor_limit"
        for depth in 0...maximumAncestors {
            guard ready(current) else { termination = "blocked"; break }
            nodes.append(inspect(current))
            if depth == maximumAncestors { break }
            let parentValue = copy(current, "AXParent")
            guard let parent = element(parentValue) else {
                termination = lastReadStatus == "no_value" || lastReadStatus == "unsupported" ? "root" : "parent_unavailable"
                break
            }
            current = parent
        }
        report["nodes"] = nodes
        report["ancestorCount"] = max(0, nodes.count - 1)
        report["ancestorTermination"] = termination
        report["truncated"] = termination != "root"

        var children: [[String: Any]] = []
        var childTermination = "complete"
        // Only descend from the focused composer: never inspect an ancestor's children.
        if nodes.first?["role"] as? String == "AXTextArea" {
            var queue: [(AXUIElement, Int)] = [(focused, 0)]
            var index = 0
            while index < queue.count {
                guard ready(queue[index].0) else { childTermination = "blocked"; break }
                let (target, depth) = queue[index]
                index += 1
                let role = copy(target, "AXRole") as? String
                let value = copy(target, "AXValue")
                let valueStatus = lastReadStatus
                let url = copy(target, "AXURL")
                let urlStatus = lastReadStatus
                // Count first, then fetch only the bounded prefix; do not copy a potentially huge child array.
                var count: CFIndex = 0
                guard ready(target) else { childTermination = "blocked"; break }
                let countError = AXUIElementGetAttributeValueCount(target, "AXChildren" as CFString, &count)
                var node = metadata(role: role, subrole: nil, names: [], settable: [:])
                node["depth"] = depth
                node["value"] = observation(value).merging(["readStatus": valueStatus]) { _, new in new }
                node["urlPresent"] = url != nil
                node["urlReadStatus"] = urlStatus
                node["childCountStatus"] = countError == .success ? "ok" : "error"
                if countError == .success { node["childCount"] = count }
                children.append(node)
                guard countError == .success else { childTermination = "children_unavailable"; continue }
                guard count > 0 else { continue }
                guard depth < maximumChildDepth else { childTermination = "depth_limit"; continue }
                let remaining = maximumChildren - queue.count
                guard remaining > 0 else { childTermination = "node_limit"; continue }
                let requested = childAllowance(count: count, queued: queue.count, depth: depth)
                if requested < count { childTermination = "node_limit" }
                var values: CFArray?
                guard ready(target) else { childTermination = "blocked"; break }
                let error = AXUIElementCopyAttributeValues(target, "AXChildren" as CFString, 0, requested, &values)
                guard error == .success, let array = values as? [AnyObject], array.count == requested else {
                    childTermination = "children_unavailable"; continue
                }
                for value in array {
                    if let child = element(value) { queue.append((child, depth + 1)) }
                    else { childTermination = "invalid_child" }
                }
            }
        } else { childTermination = "not_composer" }
        report["composerChildren"] = ["nodes": children, "termination": childTermination,
                                      "complete": childTermination == "complete", "nodeLimit": maximumChildren, "depthLimit": maximumChildDepth]

        var attributed: [String: Any] = ["readStatus": "not_available", "supported": false]
        if let first = nodes.first, let names = first["parameterizedAttributeNames"] as? [String], names.contains("AXAttributedStringForRange"),
           first["role"] as? String == "AXTextArea" {
            attributed["supported"] = true
            let value = copy(focused, "AXValue")
            if let text = value as? String, text.utf16.count <= maximumAttributedLength {
                var range = CFRange(location: 0, length: text.utf16.count)
                if let parameter = AXValueCreate(.cfRange, &range), ready(focused) {
                    var result: CFTypeRef?
                    let error = AXUIElementCopyParameterizedAttributeValue(focused, "AXAttributedStringForRange" as CFString, parameter, &result)
                    attributed.merge(observation(result)) { _, new in new }
                    attributed["readStatus"] = error == .success ? "unexpected_type" : "error"
                    if error == .success, let result, CFGetTypeID(result) == CFAttributedStringGetTypeID() {
                        let string = result as! NSAttributedString
                        attributed.merge(attributedSummary(string)) { _, new in new }
                        if string.length != range.length { attributed["readStatus"] = "range_mismatch" }
                    }
                } else { attributed["readStatus"] = "blocked" }
            } else { attributed["readStatus"] = lastReadStatus == "ok" ? "length_or_type_limit" : lastReadStatus }
        }
        report["attributedText"] = attributed
        if failure == nil { _ = ready(focused) }
        if let failure { report["truncated"] = true; return blocked(failure) }
        report["status"] = "ok"
        return report
    }
}
