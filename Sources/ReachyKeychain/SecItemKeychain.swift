import Foundation
import Security

/// The real Keychain, through `Security` directly.
///
/// No wrapper library: the whole surface is four calls, and a dependency that holds
/// a credential is one more thing to audit. Every item is `ThisDeviceOnly`, so it
/// does not go to iCloud Keychain or into a backup. A credential restored onto
/// another device is one that the user never put there.
enum SecItemKeychain: KeychainBackend {
    /// The keychain that `SecItem` uses when no attribute picks one. On iOS that is
    /// the data protection keychain. On macOS it is the file-based login keychain,
    /// where `kSecAttrAccessible` does not apply as it does on iOS.
    case platformDefault
    /// macOS only: the data protection keychain, in one access group. The group is
    /// the app's application identifier, which no other app or extension has.
    case dataProtection(accessGroup: String)

    func read(service: String, account: String) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainFailure(status)
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        // A second save must replace the item. `SecItemAdd` alone answers
        // `errSecDuplicateItem` for an item that is there already.
        let query = base(service: service, account: account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else { throw KeychainFailure(update) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure(status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status)
        }
    }

    private func base(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if case let .dataProtection(accessGroup) = self {
            query[kSecUseDataProtectionKeychain as String] = true
            // On every call, not only on the add. Without it, a query matches all the
            // app's groups, and the App Group is one that the widget shares.
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

#if os(macOS)
    /// What the running process was signed with.
    enum SigningEntitlements {
        /// The team prefix and the bundle ID, for example `TEAMID.com.alexey1312.ReachyMini`.
        ///
        /// Xcode adds this entitlement when a provisioning profile signs the app, which is
        /// true of the App Store, Developer ID and development builds. It is the app's
        /// own keychain access group. The widget extension has a different one, so it
        /// cannot read items in this group. Nil for an unsigned build and for `swift test`.
        static let applicationIdentifier: String? = {
            guard let task = SecTaskCreateFromSelf(nil) else { return nil }
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
            guard let identifier = value as? String, !identifier.isEmpty else { return nil }
            return identifier
        }()
    }
#endif
