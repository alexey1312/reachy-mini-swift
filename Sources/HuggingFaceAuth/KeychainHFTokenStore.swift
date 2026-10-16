import Foundation
import ReachyJSON
import ReachyKeychain

/// Keeps this app's Hugging Face token in the Keychain.
///
/// The first Keychain code in the project, and where ADR 0001 said credentials
/// belong. The `SecItem` calls, the macOS data protection keychain and the move out
/// of the file-based keychain are in `ReachyKeychain`, which `ReachySSH` uses too.
///
/// The item is `ThisDeviceOnly` — it does not travel to iCloud Keychain or into a
/// backup. A token restored onto another device would be one the user never
/// knowingly put there, and re-signing in costs a tap.
public struct KeychainHFTokenStore: HFTokenStoring {
    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    private let items: KeychainItems
    private let account: String

    public init(
        service: String = "com.alexey1312.ReachyMini.huggingface",
        account: String = "oauth-token"
    ) {
        self.init(items: KeychainItems(service: service, failure: Failure.keychain), account: account)
    }

    /// The seam for tests, which hand in a `KeychainItems` with no Keychain behind it.
    package init(items: KeychainItems, account: String = "oauth-token") {
        self.items = items
        self.account = account
    }

    public func load() throws -> HFToken? {
        guard let data = try items.read(account: account) else { return nil }
        // A token this app can no longer parse is not an error worth
        // propagating — it reads as signed out, and the next sign-in
        // overwrites it.
        return try? JSONCodec.stored.decode(HFToken.self, from: data)
    }

    public func save(_ token: HFToken) throws {
        try items.write(JSONCodec.stored.encode(token), account: account)
    }

    public func clear() throws {
        try items.delete(account: account)
    }
}
