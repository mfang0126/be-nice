import Foundation
import Security

/// Single API key stored as a generic-password Keychain item.
public enum CredentialStore {
    public enum StoreError: Error, Equatable, LocalizedError {
        case emptyKey
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .emptyKey:
                return "API key is empty."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                    ?? "unknown Keychain error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    /// Per-launch cache: macOS may ask the user to authorize each Keychain read,
    /// so read once per app run. Save/delete keep it in sync.
    nonisolated(unsafe) private static var cachedKey: String?
    private static let cacheLock = NSLock()

    #if DEBUG
    static let devKeyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/be-nice/dev-api-key")
    #endif

    private static let service = "be-nice.model-api-key"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores (or replaces) the API key. Surrounding whitespace is removed.
    public static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyKey }
        let data = Data(trimmed.utf8)

        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        cacheLock.withLock { cachedKey = trimmed }
    }

    /// Reports whether a key is stored without returning the secret data.
    /// Attributes-only queries avoid loading the key into memory.
    public static func hasAPIKey() throws -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return item != nil
    }

    /// Returns the stored key, or `nil` when none is stored.
    public static func loadAPIKey() throws -> String? {
        if let cached = cacheLock.withLock({ cachedKey }) { return cached }
        #if DEBUG
        // Development builds are re-signed on every build, which makes macOS ask for the
        // Keychain password again each time. Dev builds read a 0600 file written by
        // scripts/configure-dev-model.sh instead; release builds never compile this.
        if let devKey = try? String(contentsOf: devKeyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !devKey.isEmpty {
            cacheLock.withLock { cachedKey = devKey }
            return devKey
        }
        #endif
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        cacheLock.withLock { cachedKey = trimmed }
        return trimmed
    }

    /// Removes the stored key. Does nothing when none is stored.
    public static func deleteAPIKey() throws {
        cacheLock.withLock { cachedKey = nil }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
