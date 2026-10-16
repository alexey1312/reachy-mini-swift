import Foundation
import ReachyKeychain
@testable import ReachySSH
import ReachyTestSupport
import Security
import Testing

/// The two SSH stores across the move to the data protection keychain, with two
/// keychains in memory behind them. A lost pinned key shows the user a "new robot
/// identity" warning for a robot whose key never changed.
@Suite("Keychain SSH stores across the move to the data protection keychain")
struct KeychainSSHStoresTests {
    private let current = InMemoryKeychain()
    private let legacy = InMemoryKeychain()
    private let robot = "reachy-mini"

    private func items(_ service: String) -> KeychainItems {
        KeychainItems(service: service, current: current, legacy: legacy, failure: ReachySSHError.keychain)
    }

    @Test("a host key an earlier build pinned is still pinned after the update")
    func keepsThePinnedHostKey() throws {
        let service = "com.alexey1312.ReachyMini.ssh.hostkey"
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKxSnnReKXYSkOtrc1X2t3KlT7aQiTAgRxF4A+fDZCz"
        legacy.seed(Data(key.utf8), service: service, account: robot)
        let store = KeychainHostKeyStore(items: items(service))

        #expect(try store.pinnedKey(forRobot: robot) == key)
        #expect(current.data(service: service, account: robot) == Data(key.utf8))
        #expect(legacy.data(service: service, account: robot) == nil)
    }

    @Test("a password an earlier build saved is still saved after the update")
    func keepsTheSavedPassword() throws {
        let service = "com.alexey1312.ReachyMini.ssh.login"
        let earlier = KeychainSSHCredentialStore(
            items: KeychainItems(service: service, current: legacy, legacy: nil, failure: ReachySSHError.keychain)
        )
        try earlier.save(SSHCredentials(host: "", username: "pollen", password: "secret"), forRobot: robot)
        let store = KeychainSSHCredentialStore(items: items(service))

        let credentials = try #require(try store.credentials(forRobot: robot))

        #expect(credentials.username == "pollen")
        #expect(credentials.password == "secret")
        #expect(legacy.data(service: service, account: robot) == nil)
    }

    @Test("forgetting a robot's key removes the old copy too")
    func forgettingSticks() throws {
        let service = "com.alexey1312.ReachyMini.ssh.hostkey"
        legacy.seed(Data("ssh-ed25519 AAAA".utf8), service: service, account: robot)
        let store = KeychainHostKeyStore(items: items(service))

        try store.forget(robot: robot)

        #expect(try store.pinnedKey(forRobot: robot) == nil)
    }

    @Test("a refused call arrives as the SSH layer's own error")
    func mapsTheFailure() {
        current.refuse(.write, with: errSecMissingEntitlement)
        let store = KeychainHostKeyStore(items: items("com.alexey1312.ReachyMini.ssh.hostkey"))

        #expect(throws: ReachySSHError.keychain(errSecMissingEntitlement)) {
            try store.pin("ssh-ed25519 AAAA", forRobot: robot)
        }
    }
}
