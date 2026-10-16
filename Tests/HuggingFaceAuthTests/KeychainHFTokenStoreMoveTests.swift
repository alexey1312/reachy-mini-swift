import Foundation
@testable import HuggingFaceAuth
import ReachyJSON
import ReachyKeychain
import ReachyTestSupport
import Security
import Testing

/// The token through the whole store, with two keychains in memory behind it.
/// `KeychainItemsTests` holds the move itself; this holds what the user sees.
@Suite("Keychain token store across the move to the data protection keychain")
struct KeychainHFTokenStoreMoveTests {
    private let service = "com.alexey1312.ReachyMini.huggingface"
    private let current = InMemoryKeychain()
    private let legacy = InMemoryKeychain()

    private var store: KeychainHFTokenStore {
        KeychainHFTokenStore(
            items: KeychainItems(
                service: service,
                current: current,
                legacy: legacy,
                failure: KeychainHFTokenStore.Failure.keychain
            )
        )
    }

    private let token = HFToken(
        accessToken: "hf_abc",
        refreshToken: "r1",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        username: "alexey1312"
    )

    @Test("a token an earlier build saved is still there after the update")
    func staysSignedIn() throws {
        try legacy.seed(JSONCodec.stored.encode(token), service: service, account: "oauth-token")

        #expect(try store.load() == token)
        #expect(try store.load() == token)
        #expect(legacy.data(service: service, account: "oauth-token") == nil)
    }

    @Test("a token stays readable when the data protection keychain refuses it")
    func staysSignedInWithoutTheEntitlement() throws {
        try legacy.seed(JSONCodec.stored.encode(token), service: service, account: "oauth-token")
        current.refuse(.write, with: errSecMissingEntitlement)

        #expect(try store.load() == token)
    }

    @Test("signing out removes the old copy too, so the token does not come back")
    func signOutSticks() throws {
        try legacy.seed(JSONCodec.stored.encode(token), service: service, account: "oauth-token")
        try current.seed(JSONCodec.stored.encode(token), service: service, account: "oauth-token")

        try store.clear()

        #expect(try store.load() == nil)
    }

    @Test("a refused call arrives as the store's own error")
    func mapsTheFailure() {
        current.refuse(.write, with: errSecMissingEntitlement)

        #expect(throws: KeychainHFTokenStore.Failure.keychain(errSecMissingEntitlement)) {
            try store.save(token)
        }
    }
}
