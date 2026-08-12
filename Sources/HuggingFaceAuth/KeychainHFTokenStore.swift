import Foundation
import ReachyJSON
import Security

/// Keeps this app's Hugging Face token in the Keychain.
///
/// The first Keychain code in the project, and where ADR 0001 said credentials
/// belong. Written against `Security` directly rather than a wrapper: the whole
/// surface is three calls, and a dependency that holds a credential is one more
/// thing to audit.
///
/// The item is `ThisDeviceOnly` — it does not travel to iCloud Keychain or into a
/// backup. A token restored onto another device would be one the user never
/// knowingly put there, and re-signing in costs a tap.
public struct KeychainHFTokenStore: HFTokenStoring {
    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    private let service: String
    private let account: String

    public init(
        service: String = "com.alexey1312.ReachyMini.huggingface",
        account: String = "oauth-token"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> HFToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            // A token this app can no longer parse is not an error worth
            // propagating — it reads as signed out, and the next sign-in
            // overwrites it.
            return try? JSONCodec.stored.decode(HFToken.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    public func save(_ token: HFToken) throws {
        let data = try JSONCodec.stored.encode(token)

        // Signing in again must replace what is there; `SecItemAdd` alone answers
        // `errSecDuplicateItem` the second time.
        let update = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else {
            throw Failure.keychain(update)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
