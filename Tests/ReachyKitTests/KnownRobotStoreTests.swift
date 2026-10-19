import Foundation
@testable import ReachyKit
import Testing

@Suite("KnownRobotStore")
struct KnownRobotStoreTests {
    /// Its own suite name per test: `swift test --parallel` runs suites concurrently and
    /// `UserDefaults.standard` is one table shared by all of them.
    private func makeStore() throws -> KnownRobotStore {
        let defaults = try #require(UserDefaults(suiteName: "KnownRobotStoreTests.\(UUID().uuidString)"))
        return KnownRobotStore(defaults: defaults)
    }

    @Test("remembers a robot by identity")
    func remembers() throws {
        let store = try makeStore()
        store.remember(
            identity: RobotIdentity(hardwareID: "b68ff6bbe47f0608", name: "reachy_mini"),
            address: RobotAddress(host: "192.168.8.188"),
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(store.all.count == 1)
        #expect(store.all.first?.key == "b68ff6bbe47f0608")
        #expect(store.all.first?.name == "reachy_mini")
        #expect(store.all.first?.address.host == "192.168.8.188")
    }

    @Test("the same robot at a new address updates in place")
    func updatesInPlace() throws {
        let store = try makeStore()
        let identity = RobotIdentity(hardwareID: "b68ff6bbe47f0608", name: "reachy_mini")
        store.remember(
            identity: identity,
            address: RobotAddress(host: "192.168.8.188"),
            at: Date(timeIntervalSince1970: 100)
        )
        store.remember(
            identity: identity,
            address: RobotAddress(host: "10.0.0.9"),
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(store.all.count == 1)
        #expect(store.all.first?.address.host == "10.0.0.9")
    }

    @Test("a daemon reporting no hardware id falls back to the robot name")
    func fallsBackToName() throws {
        let store = try makeStore()
        store.remember(
            identity: RobotIdentity(name: "reachy_mini"),
            address: RobotAddress(host: "127.0.0.1"),
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(store.all.first?.key == "reachy_mini")
    }

    @Test("lists the most recently connected robot first")
    func ordersByRecency() throws {
        let store = try makeStore()
        store.remember(
            identity: RobotIdentity(hardwareID: "aaa"),
            address: RobotAddress(host: "10.0.0.1"),
            at: Date(timeIntervalSince1970: 100)
        )
        store.remember(
            identity: RobotIdentity(hardwareID: "bbb"),
            address: RobotAddress(host: "10.0.0.2"),
            at: Date(timeIntervalSince1970: 300)
        )
        store.remember(
            identity: RobotIdentity(hardwareID: "ccc"),
            address: RobotAddress(host: "10.0.0.3"),
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(store.all.map(\.key) == ["bbb", "ccc", "aaa"])
    }

    @Test("forgetting a robot drops it and clears a last address pointing at it")
    func forgets() throws {
        let store = try makeStore()
        let address = RobotAddress(host: "192.168.8.188")
        store.remember(
            identity: RobotIdentity(hardwareID: "aaa"),
            address: address,
            at: Date(timeIntervalSince1970: 100)
        )
        store.lastAddress = address

        store.forget("aaa")

        #expect(store.all.isEmpty)
        #expect(store.lastAddress == nil)
    }

    @Test("forgetting one robot leaves another robot's last address alone")
    func forgetsWithoutClearingUnrelatedAddress() throws {
        let store = try makeStore()
        store.remember(
            identity: RobotIdentity(hardwareID: "aaa"),
            address: RobotAddress(host: "10.0.0.1"),
            at: Date(timeIntervalSince1970: 100)
        )
        store.lastAddress = RobotAddress(host: "10.0.0.2")

        store.forget("aaa")

        #expect(store.lastAddress?.host == "10.0.0.2")
    }

    @Test("forgetting the robot the sweep holds to releases the hold, and only that robot")
    func forgettingReleasesTheHold() throws {
        let store = try makeStore()
        store.remember(identity: RobotIdentity(hardwareID: "aaa"), address: RobotAddress(host: "10.0.0.1"))
        store.remember(identity: RobotIdentity(hardwareID: "bbb"), address: RobotAddress(host: "10.0.0.2"))
        store.lastHardwareID = "aaa"

        store.forget("bbb")
        #expect(store.lastHardwareID == "aaa")

        store.forget("aaa")
        #expect(store.lastHardwareID == nil)
    }
}
