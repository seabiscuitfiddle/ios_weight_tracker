import Foundation
import Security
import TallyCore

/// Stores the user's Anthropic API key in the iOS Keychain.
///
/// The Keychain rather than `UserDefaults` because this is a credential that can spend the
/// user's money. `UserDefaults` is a plist in the app container: readable from a filesystem
/// backup, and included in unencrypted device backups.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` adds two protections. *WhenUnlocked* means a
/// locked phone cannot yield the key even to code running in the background; *ThisDeviceOnly*
/// keeps it out of iCloud Keychain and encrypted backups, so restoring a backup onto another
/// device does not carry the key along. That matches the app's promise that nothing syncs on the
/// user's behalf — and it means the key must be re-entered after a device migration, which is
/// the right trade for a credential.
public struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    /// Keyed off the running bundle, so changing `BUNDLE_ID_PREFIX` doesn't silently orphan a
    /// previously stored key under a service name nothing looks up any more.
    public static func forCurrentBundle(
        bundle: Bundle = .main,
        suffix: String = "anthropic"
    ) -> KeychainAPIKeyStore {
        let base = bundle.bundleIdentifier ?? "tally"
        return KeychainAPIKeyStore(service: "\(base).\(suffix)")
    }

    public func apiKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8)
            else { throw KeychainError.unreadableItem }
            return key
        case errSecItemNotFound:
            // Not an error: this is the state before the user has set a key.
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Saves or replaces the key. Passing nil or blank text removes it.
    public func save(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmed, !trimmed.isEmpty else {
            try delete()
            return
        }

        let data = Data(trimmed.utf8)

        // Try updating first, since a plain add would fail with errSecDuplicateItem once a key
        // already exists — which is the common case when someone corrects a typo.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Deleting something that was never there is the caller's intended end state.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public var hasKey: Bool {
        (try? apiKey())?.isEmpty == false
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    case unreadableItem

    public var description: String {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status): \(message ?? "unknown")"
        case .unreadableItem:
            return "The stored API key could not be read as text."
        }
    }
}
