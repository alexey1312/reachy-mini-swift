import Foundation
@testable import ReachyKit
import Testing

/// A dictionary-backed stand-in for `NSUbiquitousKeyValueStore`, with a write log so a test
/// can assert what was pushed — the echo test is the reason it exists.
private final class RecordingUbiquitousStore: UbiquitousStore {
    private var values: [String: Any]
    private(set) var setLog: [String] = []

    init(values: [String: Any] = [:]) {
        self.values = values
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        setLog.append(defaultName)
        values[defaultName] = value
    }

    @discardableResult
    func synchronize() -> Bool {
        true
    }

    func clearLog() {
        setLog.removeAll()
    }

    /// Delivers what a real store's external-change notification carries.
    func simulateExternalChange(of keys: [String]) {
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: self,
            userInfo: [
                NSUbiquitousKeyValueStoreChangedKeysKey: keys,
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
            ]
        )
    }
}

/// Observers registered on `.main` from the main thread deliver synchronously, so nothing
/// here waits (rule 7).
@Suite("CloudSettingsMirror")
@MainActor
struct CloudSettingsMirrorTests {
    private let key = "CloudSettingsMirrorTests.value"

    /// Its own suite name per test, for the reason `KnownRobotStoreTests` gives.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "CloudSettingsMirrorTests.\(UUID().uuidString)"))
    }

    @Test("start pushes a local value the cloud has never seen")
    func startPushesLocalValue() throws {
        let defaults = try makeDefaults()
        defaults.set("graphite", forKey: key)
        let cloud = RecordingUbiquitousStore()
        let mirror = CloudSettingsMirror(defaults: defaults, cloud: cloud, keys: [key])

        mirror.start()

        #expect(cloud.object(forKey: key) as? String == "graphite")
    }

    @Test("start pulls a differing cloud value over the local one")
    func startPullsCloudValue() throws {
        let defaults = try makeDefaults()
        defaults.set("local", forKey: key)
        let cloud = RecordingUbiquitousStore(values: [key: "cloud"])
        var applied = 0
        let mirror = CloudSettingsMirror(
            defaults: defaults,
            cloud: cloud,
            keys: [key],
            onDidApplyExternalChange: { applied += 1 }
        )

        mirror.start()

        #expect(defaults.string(forKey: key) == "cloud")
        #expect(applied == 1)
        #expect(cloud.setLog.isEmpty)
    }

    @Test("a local write after start reaches the cloud")
    func localWriteReachesCloud() throws {
        let defaults = try makeDefaults()
        let cloud = RecordingUbiquitousStore()
        let mirror = CloudSettingsMirror(defaults: defaults, cloud: cloud, keys: [key])
        mirror.start()

        defaults.set("coral", forKey: key)

        #expect(cloud.object(forKey: key) as? String == "coral")
        withExtendedLifetime(mirror) {}
    }

    @Test("an external change lands in defaults and fires the callback once")
    func externalChangeLands() throws {
        let defaults = try makeDefaults()
        let otherKey = "CloudSettingsMirrorTests.other"
        let cloud = RecordingUbiquitousStore()
        var applied = 0
        let mirror = CloudSettingsMirror(
            defaults: defaults,
            cloud: cloud,
            keys: [key, otherKey],
            onDidApplyExternalChange: { applied += 1 }
        )
        mirror.start()

        cloud.set("graphite", forKey: key)
        cloud.set("mint", forKey: otherKey)
        cloud.clearLog()
        cloud.simulateExternalChange(of: [key, otherKey])

        #expect(defaults.string(forKey: key) == "graphite")
        #expect(defaults.string(forKey: otherKey) == "mint")
        #expect(applied == 1)
        withExtendedLifetime(mirror) {}
    }

    @Test("a pull does not push back")
    func pullDoesNotEcho() throws {
        let defaults = try makeDefaults()
        let cloud = RecordingUbiquitousStore()
        let mirror = CloudSettingsMirror(defaults: defaults, cloud: cloud, keys: [key])
        mirror.start()

        cloud.set("graphite", forKey: key)
        cloud.clearLog()
        cloud.simulateExternalChange(of: [key])

        #expect(defaults.string(forKey: key) == "graphite")
        #expect(cloud.setLog.isEmpty)
        withExtendedLifetime(mirror) {}
    }

    @Test("a changed key outside the mirrored set is ignored")
    func foreignKeyIsIgnored() throws {
        let defaults = try makeDefaults()
        let cloud = RecordingUbiquitousStore()
        var applied = 0
        let mirror = CloudSettingsMirror(
            defaults: defaults,
            cloud: cloud,
            keys: [key],
            onDidApplyExternalChange: { applied += 1 }
        )
        mirror.start()

        cloud.set("stray", forKey: "CloudSettingsMirrorTests.foreign")
        cloud.simulateExternalChange(of: ["CloudSettingsMirrorTests.foreign"])

        #expect(defaults.object(forKey: "CloudSettingsMirrorTests.foreign") == nil)
        #expect(applied == 0)
        withExtendedLifetime(mirror) {}
    }

    @Test("a key the cloud removed is removed locally")
    func cloudRemovalRemovesLocally() throws {
        let defaults = try makeDefaults()
        defaults.set("graphite", forKey: key)
        let cloud = RecordingUbiquitousStore(values: [key: "graphite"])
        let mirror = CloudSettingsMirror(defaults: defaults, cloud: cloud, keys: [key])
        mirror.start()

        cloud.set(nil, forKey: key)
        cloud.simulateExternalChange(of: [key])

        #expect(defaults.object(forKey: key) == nil)
        withExtendedLifetime(mirror) {}
    }

    /// The robots blob crosses the mirror as opaque data: what device A remembered, device B
    /// decodes through the same frozen `JSONCodec.stored` — asserted through the real store
    /// API rather than by re-encoding.
    @Test("the known-robots blob round-trips between two suites")
    func robotsBlobRoundTrips() throws {
        let deviceA = try makeDefaults()
        let deviceB = try makeDefaults()
        let cloud = try makeDefaults()
        let robotsKey = KnownRobotStore.knownRobotsKey
        let mirrorA = CloudSettingsMirror(defaults: deviceA, cloud: cloud, keys: [robotsKey])
        mirrorA.start()

        KnownRobotStore(defaults: deviceA).remember(
            identity: RobotIdentity(hardwareID: "b68ff6bbe47f0608", name: "reachy_mini"),
            address: RobotAddress(host: "192.168.8.188"),
            at: Date(timeIntervalSince1970: 100)
        )
        let mirrorB = CloudSettingsMirror(defaults: deviceB, cloud: cloud, keys: [robotsKey])
        mirrorB.start()

        let arrived = KnownRobotStore(defaults: deviceB).all
        #expect(arrived.map(\.key) == ["b68ff6bbe47f0608"])
        #expect(arrived.first?.name == "reachy_mini")
        withExtendedLifetime(mirrorA) {}
    }
}
