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
    /// keeps offering the address of a robot the user just removed.
    public func forget(_ key: String) {
        let robots = all
        let removed = robots.first { $0.key == key }
        write(robots.filter { $0.key != key })
        if let removed, lastAddress == removed.address {
            lastAddress = nil
        }
    }

    private func write(_ robots: [KnownRobot]) {
        guard let data = try? JSONCodec.stored.encode(robots) else { return }
        defaults.set(data, forKey: Self.knownRobotsKey)
    }
}
