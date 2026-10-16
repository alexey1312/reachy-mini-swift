import Foundation
@testable import ReachyKeychain
import ReachyTestSupport
import Security
import Testing

/// The move out of the macOS file-based keychain, against two keychains in memory.
///
/// A real data protection keychain needs a signed app with an application
/// identifier, and a `swift test` process has none (`errSecMissingEntitlement`).
/// So these tests drive `KeychainItems` through its seam, and the real keychain is
/// a manual check on a signed build.
@Suite("Keychain items and the move out of the file-based keychain")
struct KeychainItemsTests {
    private struct Refused: Error, Equatable {
        let status: OSStatus
    }

    private let service = "com.alexey1312.ReachyMini.tests"
    private let account = "oauth-token"
    private let token = Data("hf_token".utf8)
    private let current = InMemoryKeychain()
    private let legacy = InMemoryKeychain()

    private var items: KeychainItems {
        KeychainItems(service: service, current: current, legacy: legacy, failure: { Refused(status: $0) })
    }

    @Test("an item an earlier build wrote moves across on the first read")
    func movesALegacyItem() throws {
        legacy.seed(token, service: service, account: account)

        #expect(try items.read(account: account) == token)

        #expect(current.data(service: service, account: account) == token)
        #expect(legacy.data(service: service, account: account) == nil)
    }

    /// The order is the guarantee: a delete before a failed write loses the token.
    @Test("a refused write keeps the old item and still returns it")
    func keepsTheLegacyItemWhenTheWriteFails() throws {
        legacy.seed(token, service: service, account: account)
        current.refuse(.write, with: errSecMissingEntitlement)

        #expect(try items.read(account: account) == token)

        #expect(legacy.data(service: service, account: account) == token)
        #expect(legacy.count(of: .delete) == 0)
    }

    @Test("a refused write is tried again on the next read, and then succeeds")
    func retriesAFailedMove() throws {
        legacy.seed(token, service: service, account: account)
        current.refuse(.write, with: errSecInteractionNotAllowed)
        _ = try items.read(account: account)

        current.refuse(.write, with: nil)
        #expect(try items.read(account: account) == token)

        #expect(current.data(service: service, account: account) == token)
        #expect(legacy.data(service: service, account: account) == nil)
    }

    @Test("a refused delete after the write leaves two copies, and the new one wins")
    func toleratesAFailedLegacyDelete() throws {
        legacy.seed(token, service: service, account: account)
        legacy.refuse(.delete, with: errSecAuthFailed)

        #expect(try items.read(account: account) == token)
        #expect(try items.read(account: account) == token)

        // The second read found the new copy and did not touch the old keychain.
        #expect(current.count(of: .write) == 1)
        #expect(legacy.count(of: .read) == 1)
    }

    @Test("an item already in the new keychain is read without touching the old one")
    func readsTheCurrentItemFirst() throws {
        current.seed(token, service: service, account: account)
        legacy.seed(Data("hf_stale".utf8), service: service, account: account)

        #expect(try items.read(account: account) == token)

        #expect(legacy.count(of: .read) == 0)
        #expect(current.count(of: .write) == 0)
    }

    @Test("no item in either keychain reads as nil and writes nothing")
    func readsNothingAsNil() throws {
        #expect(try items.read(account: account) == nil)

        #expect(current.count(of: .write) == 0)
        #expect(legacy.count(of: .delete) == 0)
    }

    @Test("a refused read of the old keychain is the caller's error, and nothing moves")
    func surfacesAFailedLegacyRead() {
        legacy.seed(token, service: service, account: account)
        legacy.refuse(.read, with: errSecInteractionNotAllowed)

        #expect(throws: Refused(status: errSecInteractionNotAllowed)) {
            try items.read(account: account)
        }
        #expect(current.count(of: .write) == 0)
        #expect(legacy.data(service: service, account: account) == token)
    }

    @Test("a write goes to the new keychain and removes the stale old copy")
    func writeRemovesTheLegacyCopy() throws {
        legacy.seed(Data("hf_stale".utf8), service: service, account: account)

        try items.write(token, account: account)

        #expect(current.data(service: service, account: account) == token)
        #expect(legacy.data(service: service, account: account) == nil)
    }

    @Test("a write still succeeds when the stale old copy cannot be deleted")
    func writeToleratesAFailedLegacyDelete() throws {
        legacy.seed(Data("hf_stale".utf8), service: service, account: account)
        legacy.refuse(.delete, with: errSecAuthFailed)

        try items.write(token, account: account)

        #expect(try items.read(account: account) == token)
    }

    /// Without the second delete, a sign-out comes back on the next read: the read
    /// finds the old item and moves it across again.
    @Test("a delete removes the item from both keychains, so a sign-out sticks")
    func deleteRemovesBothCopies() throws {
        current.seed(token, service: service, account: account)
        legacy.seed(Data("hf_stale".utf8), service: service, account: account)

        try items.delete(account: account)

        #expect(try items.read(account: account) == nil)
    }

    @Test("a refused delete of the old copy is the caller's error, and the new copy still goes")
    func deleteSurfacesAFailedLegacyDelete() {
        current.seed(token, service: service, account: account)
        legacy.seed(token, service: service, account: account)
        legacy.refuse(.delete, with: errSecAuthFailed)

        #expect(throws: Refused(status: errSecAuthFailed)) {
            try items.delete(account: account)
        }
        #expect(current.data(service: service, account: account) == nil)
    }

    /// The callers sign out with `try?`. A delete that stopped at the first failure
    /// would leave the old copy, and the next read would move it back.
    @Test("a refused delete of the new copy still removes the old one")
    func deleteRemovesTheLegacyCopyWhenTheCurrentDeleteFails() {
        current.seed(token, service: service, account: account)
        legacy.seed(token, service: service, account: account)
        current.refuse(.delete, with: errSecInteractionNotAllowed)

        #expect(throws: Refused(status: errSecInteractionNotAllowed)) {
            try items.delete(account: account)
        }
        #expect(legacy.data(service: service, account: account) == nil)
    }

    @Test("a refused call in the new keychain arrives as the caller's error")
    func mapsTheStatus() {
        current.refuse(.write, with: errSecMissingEntitlement)

        #expect(throws: Refused(status: errSecMissingEntitlement)) {
            try items.write(token, account: account)
        }
    }

    @Test("items are kept apart by account")
    func keepsAccountsApart() throws {
        legacy.seed(token, service: service, account: "reachy-mini")
        legacy.seed(Data("other".utf8), service: service, account: "reachy-mini-2")

        #expect(try items.read(account: "reachy-mini") == token)

        #expect(legacy.data(service: service, account: "reachy-mini-2") == Data("other".utf8))
    }

    @Test("with no old keychain, nothing is moved")
    func passesThroughWithoutALegacyKeychain() throws {
        let items = KeychainItems(service: service, current: current, legacy: nil, failure: { Refused(status: $0) })

        try items.write(token, account: account)
        #expect(try items.read(account: account) == token)
        try items.delete(account: account)
        #expect(try items.read(account: account) == nil)
    }

    #if os(macOS)
        /// The production path in this process. A `swift test` binary has no application
        /// identifier, so it must stay on the file-based keychain: the data protection
        /// keychain would refuse every call with `errSecMissingEntitlement`.
        @Test("a process with no application identifier keeps the file-based keychain")
        func unsignedProcessHasNoApplicationIdentifier() {
            #expect(SigningEntitlements.applicationIdentifier == nil)
        }
    #endif
}
