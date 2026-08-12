import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// Which robot a spoken phrase or a saved shortcut ends up addressing.
///
/// Unlike `RobotAppQuery` there is nothing to fetch here — the list is whatever
/// `KnownRobots` holds — so every test is about resolution rather than about
/// timing out gracefully.
@Suite("Robot entity query", .timeLimit(.minutes(1)))
struct RobotEntityQueryTests {
    private let kitchen = KnownRobot(
        key: "aa11bb22cc33dd44",
        name: "Reachy in the kitchen",
        address: RobotAddress(host: "192.168.1.42"),
        lastConnected: Date(timeIntervalSince1970: 1_800_000_000)
    )
    private let desk = KnownRobot(
        key: "ee55ff66aa77bb88",
        name: "Desk Reachy",
        address: RobotAddress(host: "reachy-mini.local"),
        lastConnected: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private func query(_ robots: [KnownRobot]) -> RobotEntityQuery {
        RobotEntityQuery(robots: { robots })
    }

    // MARK: - Resolving a saved shortcut

    @Test("identifiers resolve in the order they were asked for")
    func resolvesInOrder() async throws {
        let resolved = try await query([kitchen, desk]).entities(for: [desk.key, kitchen.key])

        #expect(resolved.map(\.id) == [desk.key, kitchen.key])
        #expect(resolved.map(\.isKnown).contains(false) == false)
        #expect(resolved.first?.title == "Desk Reachy")
    }

    /// The same rule `RobotAppQuery.entities(for:)` follows, and for the same
    /// reason: fewer entities than were asked for is how the system learns a value
    /// is gone, and it rewrites the shortcut on the strength of it.
    @Test("a forgotten robot still resolves, marked no longer known")
    func neverDropsAnIdentifier() async throws {
        let resolved = try await query([kitchen]).entities(for: [kitchen.key, "gone-robot"])

        #expect(resolved.map(\.id) == [kitchen.key, "gone-robot"])
        #expect(resolved.last?.isKnown == false)
        #expect(resolved.last?.title == "gone-robot")
    }

    @Test("with nothing known at all, every identifier still comes back")
    func resolvesWithNothingKnown() async throws {
        let resolved = try await query([]).entities(for: [kitchen.key])

        #expect(resolved.map(\.id) == [kitchen.key])
        #expect(resolved.first?.isKnown == false)
    }

    // MARK: - Filling the picker

    /// `KnownRobotStore.all` is sorted most recently connected first, and that
    /// order is load-bearing twice over: it is what the picker shows, and its first
    /// element is the robot an intent naming none acts on.
    @Test("the picker lists every robot, most recently connected first")
    func listsEveryRobot() async throws {
        let listed = try await query([kitchen, desk]).allEntities()

        #expect(listed.map(\.id) == [kitchen.key, desk.key])
        #expect(listed.first?.host == "192.168.1.42")
    }

    // MARK: - Matching a spoken name

    @Test("a spoken fragment matches the robot's name")
    func matchesPartOfAName() async throws {
        let matched = try await query([kitchen, desk]).entities(matching: "kitchen")

        #expect(matched.map(\.id) == [kitchen.key])
    }

    @Test("matching ignores case")
    func matchesRegardlessOfCase() async throws {
        let matched = try await query([kitchen, desk]).entities(matching: "DESK")

        #expect(matched.map(\.id) == [desk.key])
    }

    /// A robot the daemon never named is still reachable by where it answered,
    /// which is the only thing left to say about it.
    @Test("an unnamed robot matches on its address")
    func matchesOnTheAddress() async throws {
        let unnamed = KnownRobot(
            key: "cc99dd00ee11ff22",
            address: RobotAddress(host: "10.0.0.7"),
            lastConnected: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let matched = try await query([unnamed, desk]).entities(matching: "10.0.0.7")

        #expect(matched.map(\.id) == [unnamed.key])
    }

    @Test("no match is an empty list rather than everything")
    func refusesToGuess() async throws {
        let matched = try await query([kitchen, desk]).entities(matching: "garage")

        #expect(matched.isEmpty)
    }

    /// Siri can hand over nothing at all, and an empty needle would otherwise match
    /// every robot through `contains` — which is right here, but by accident. Say it
    /// on purpose instead.
    @Test("an empty phrase offers every robot")
    func offersEverythingForAnEmptyPhrase() async throws {
        let matched = try await query([kitchen, desk]).entities(matching: "   ")

        #expect(matched.map(\.id) == [kitchen.key, desk.key])
    }

    // MARK: - What the picker shows

    @Test("a known robot is shown with the address it answered at")
    func describesAKnownRobot() {
        let entity = RobotEntity(kitchen)

        #expect(entity.id == kitchen.key)
        #expect(entity.title == "Reachy in the kitchen")
        #expect(entity.host == "192.168.1.42")
    }

    /// The entity carries an address and must never be connected on it — the robot
    /// is looked up again when the intent runs. This pins the half that is visible:
    /// the id is the identity, not the address.
    @Test("the identity is the deduplication key, never the address")
    func identifiesByHardwareID() {
        let moved = KnownRobot(
            key: kitchen.key,
            name: kitchen.name,
            address: RobotAddress(host: "192.168.1.99"),
            lastConnected: kitchen.lastConnected
        )

        #expect(RobotEntity(moved).id == RobotEntity(kitchen).id)
        #expect(RobotEntity(moved).host != RobotEntity(kitchen).host)
    }
}
