import Foundation
@testable import HuggingFaceAuth
import Testing

/// A SwiftPM test binary is unsigned, and an unsigned process cannot always reach
/// a keychain — on a CI machine with no login keychain unlocked, every call comes
/// back `errSecMissingEntitlement`. Probing once decides whether these tests can
/// say anything at all, rather than failing for a reason that has nothing to do
/// with the code.
///
/// On macOS these tests reach the file-based keychain only. The test process has no
/// application identifier, so `KeychainItems` does not use the data protection
/// keychain here. `KeychainHFTokenStoreMoveTests` holds the move between the two.
private enum KeychainProbe {
    static let isUsable: Bool = {
        let store = KeychainHFTokenStore(service: "com.alexey1312.ReachyMini.probe")
        defer { try? store.clear() }
        do {
            try store.save(HFToken(accessToken: "probe"))
            return true
        } catch {
            return false
        }
    }()
}

@Suite("Keychain token store", .enabled(if: KeychainProbe.isUsable), .serialized)
struct KeychainHFTokenStoreTests {
    /// One service per test: `.serialized` orders tests inside this suite, but the
    /// keychain is shared with every other process on the machine.
    private func store(_ label: String = #function) -> KeychainHFTokenStore {
        KeychainHFTokenStore(service: "com.alexey1312.ReachyMini.tests.\(label)")
    }

    @Test("a token survives a round trip")
    func roundTripsAToken() throws {
        let store = store()
        defer { try? store.clear() }
        let token = HFToken(
            accessToken: "hf_abc",
            refreshToken: "r1",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            username: "alexey1312"
        )

        try store.save(token)

        #expect(try store.load() == token)
    }

    @Test("nothing stored reads as nothing, not as an error")
    func readsEmptyAsNil() throws {
        #expect(try store().load() == nil)
    }

    /// Signing in twice must replace the token, not fail on the second attempt —
    /// `SecItemAdd` answers `errSecDuplicateItem` for an item that already exists.
    @Test("saving twice replaces the first token")
    func overwritesAnExistingToken() throws {
        let store = store()
        defer { try? store.clear() }

        try store.save(HFToken(accessToken: "hf_first"))
        try store.save(HFToken(accessToken: "hf_second"))

        #expect(try store.load()?.accessToken == "hf_second")
    }

    @Test("clearing removes the token, and clearing again is not an error")
    func clearsIdempotently() throws {
        let store = store()
        try store.save(HFToken(accessToken: "hf_abc"))

        try store.clear()
        try store.clear()

        #expect(try store.load() == nil)
    }
}
