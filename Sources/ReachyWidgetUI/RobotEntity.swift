import AppIntents
import Foundation
import ReachyKit

/// One robot, as a spoken phrase or a shortcut names it.
///
/// **The entity carries an address and never acts on one.** `RobotIntentTarget`
/// looks the robot up again by `id` when the intent runs, because a shortcut is
/// persisted once and a robot moves between addresses (project rule 4, upstream
/// issue #269). The `host` here is for the picker's subtitle and nothing else —
/// two robots called "Reachy Mini" are told apart by where they answered, not by
/// their names.
public struct RobotEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reachy Mini")
    public static let defaultQuery = RobotEntityQuery()

    /// `KnownRobot.key`, which is `RobotIdentity.deduplicationKey` — the hardware
    /// id where the daemon reports one, the robot's name where it does not. It is
    /// the key every App Group store is already written against, so an entity and
    /// a snapshot name the same robot without a join.
    public let id: String
    /// The robot's own name, as the daemon reported it at the last handshake.
    /// `nil` for a robot that has never been named.
    public let name: String?
    /// Where it last answered, for the subtitle. Never used to connect.
    public let host: String?
    /// False for a robot the app has since forgotten. Such an entity is still
    /// returned rather than dropped — see `RobotEntityQuery.entities(for:)`.
    public let isKnown: Bool

    public init(_ robot: KnownRobot) {
        id = robot.key
        name = robot.name
        host = robot.address.displayString
        isKnown = true
    }

    /// An id with nothing behind it: a shortcut naming a robot the user has
    /// removed. The hardware id is not a name, but it is the only thing left, and
    /// showing it beats showing a blank row.
    init(forgotten id: String) {
        self.id = id
        name = nil
        host = nil
        isKnown = false
    }

    public var title: String {
        name ?? host ?? id
    }

    public var displayRepresentation: DisplayRepresentation {
        guard isKnown else {
            return DisplayRepresentation(title: "\(title)", subtitle: "Not connected any more")
        }
        guard let host else { return DisplayRepresentation(title: "\(title)") }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(host)")
    }
}

/// Which robots an intent may be addressed to: the ones this app has completed a
/// handshake with, most recently connected first.
///
/// **No network at all, unlike `RobotAppQuery`.** That one has to ask a robot what
/// it has installed; this one is answering out of the only record that exists —
/// `KnownRobots` in the App Group — and a robot is not less known for being
/// switched off. Reachability is the intent's problem, not the picker's, and
/// hiding an unreachable robot here would mean a shortcut that cannot be written
/// while the robot naps.
public struct RobotEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    private let robots: @Sendable () -> [KnownRobot]

    public init() {
        self.init(robots: { KnownRobots.all })
    }

    /// The seam the statics do not offer. `KnownRobots.all` reads one process-wide
    /// suite, and `swift test --parallel` runs suites concurrently against it.
    init(robots: @escaping @Sendable () -> [KnownRobot]) {
        self.robots = robots
    }

    /// Resolving a saved shortcut. **Never drops an identifier**, for the reason
    /// written over `RobotAppQuery.entities(for:)`: returning fewer entities is how
    /// the system learns a value is gone, and it rewrites the shortcut accordingly.
    /// A forgotten robot comes back marked, so the shortcut still says which robot
    /// it was written for.
    public func entities(for identifiers: [String]) async throws -> [RobotEntity] {
        let known = robots()
        return identifiers.map { id in
            known.first { $0.key == id }.map(RobotEntity.init) ?? RobotEntity(forgotten: id)
        }
    }

    /// Every robot, in the order `KnownRobotStore` keeps them: most recently
    /// connected first, which is also the one an intent naming none will use.
    public func allEntities() async throws -> [RobotEntity] {
        robots().map(RobotEntity.init)
    }

    public func suggestedEntities() async throws -> [RobotEntity] {
        try await allEntities()
    }

    /// What makes a spoken name resolve. Siri hands over the words it heard, so the
    /// match is on the name the daemon reported and on the address the robot
    /// answered at — a robot with no name is still reachable as "192.168.1.42".
    ///
    /// Case- and diacritic-insensitive containment rather than equality: "kitchen"
    /// has to find "Reachy in the kitchen", and a robot's name is free text
    /// somebody typed.
    public func entities(matching string: String) async throws -> [RobotEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try await allEntities() }
        return robots()
            .filter { robot in
                [robot.name, robot.address.displayString]
                    .compactMap(\.self)
                    .contains { $0.localizedStandardContains(needle) }
            }
            .map(RobotEntity.init)
    }
}
