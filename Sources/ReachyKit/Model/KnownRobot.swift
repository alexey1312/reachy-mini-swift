import Foundation
import ReachyJSON

/// A robot this app has completed a handshake with.
///
/// Keyed by `RobotIdentity.deduplicationKey`, never by address: the same robot answers at
/// several addresses and moves between them (rule 4, upstream issue #269).
public struct KnownRobot: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public var name: String?
    public var address: RobotAddress
    public var lastConnected: Date

    public var id: String {
        key
    }

    public init(key: String, name: String? = nil, address: RobotAddress, lastConnected: Date) {
        self.key = key
        self.name = name
        self.address = address
        self.lastConnected = lastConnected
    }
}

/// Storage for known robots, bound to one `UserDefaults`.
///
/// The injectable defaults exist for the tests: `--parallel` runs suites concurrently and
/// `.standard` is a single table they would otherwise fight over. Production goes through
/// `KnownRobots`, which wraps `.standard`.
public struct KnownRobotStore {
    /// Public because the app target names it when it starts the iCloud mirror.
    public static let knownRobotsKey = "ReachyKit.knownRobots"
    static let lastAddressKey = "ReachyKit.lastAddress"
    static let lastHardwareIDKey = "ReachyKit.lastHardwareID"
    static let provisionedKey = "ReachyKit.pendingProvisionedHardwareID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Most recently connected first.
    public var all: [KnownRobot] {
        guard let data = defaults.data(forKey: Self.knownRobotsKey),
              let robots = try? JSONCodec.stored.decode([KnownRobot].self, from: data)
        else { return [] }
        return robots.sorted { $0.lastConnected > $1.lastConnected }
    }

    public var lastAddress: RobotAddress? {
        get {
            guard let data = defaults.data(forKey: Self.lastAddressKey) else { return nil }
            return try? JSONCodec.stored.decode(RobotAddress.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONCodec.stored.encode(newValue) else {
                defaults.removeObject(forKey: Self.lastAddressKey)
                return
            }
            defaults.set(data, forKey: Self.lastAddressKey)
        }
    }

    /// The hardware id of the robot this device connected to last over the LAN, written
    /// beside `lastAddress`. An automatic attempt takes no other robot while it is set.
    ///
    /// Its own key, not part of `all`: that list is mirrored through iCloud, so its most
    /// recent entry can be a robot another device used. `nil` when that robot reported no
    /// hardware id, which pins nothing — a robot that cannot be told apart cannot be held to.
    public var lastHardwareID: String? {
        get { defaults.string(forKey: Self.lastHardwareIDKey) }
        nonmutating set { set(newValue, forKey: Self.lastHardwareIDKey) }
    }

    /// A robot just given a Wi-Fi password over Bluetooth, waiting to be recognised once
    /// it appears on the network. `KnownRobots.pendingProvisionedHardwareID` has the reason
    /// it is a hardware id.
    public var pendingProvisionedHardwareID: String? {
        get { defaults.string(forKey: Self.provisionedKey) }
        nonmutating set { set(newValue, forKey: Self.provisionedKey) }
    }

    /// Upserts by identity, so a robot that reappears at another address updates its record
    /// rather than adding a second one.
    public func remember(identity: RobotIdentity, address: RobotAddress, at date: Date = Date()) {
        var robots = all
        let key = identity.deduplicationKey
        let robot = KnownRobot(key: key, name: identity.name, address: address, lastConnected: date)
        robots.removeAll { $0.key == key }
        robots.append(robot)
        write(robots)
    }

    /// Also clears `lastAddress` when it pointed at this robot — otherwise the manual field
    /// keeps offering the address of a robot the user just removed. `lastHardwareID` goes
    /// the same way, so forgetting the robot the sweep is held to frees the sweep.
    public func forget(_ key: String) {
        let robots = all
        let removed = robots.first { $0.key == key }
        write(robots.filter { $0.key != key })
        if let removed, lastAddress == removed.address {
            lastAddress = nil
        }
        if lastHardwareID == key {
            lastHardwareID = nil
        }
    }

    private func write(_ robots: [KnownRobot]) {
        guard let data = try? JSONCodec.stored.encode(robots) else { return }
        defaults.set(data, forKey: Self.knownRobotsKey)
    }

    private func set(_ value: String?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(value, forKey: key)
    }
}
