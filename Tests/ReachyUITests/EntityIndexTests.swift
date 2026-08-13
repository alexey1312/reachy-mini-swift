import Foundation
import ReachyKit
@testable import ReachyUI
import ReachyWidgetUI
import Testing

/// What Spotlight actually returns is a device check — no API reads an indexed
/// item back. What is assertable is the half that decides *whether* to write, and
/// that half has one way to be silently wrong: a stamp that never matches, which
/// re-indexes the robot's whole catalogue on every launch and shows up as nothing
/// but battery.
@Suite("Entity index")
struct EntityIndexTests {
    private func app(_ id: String) -> RobotAppEntity {
        RobotAppEntity(RobotAppSummary(id: id, name: id, title: id), isInstalled: true)
    }

    private func move(_ name: String) -> MoveEntity {
        MoveEntity(dataset: "pollen-robotics/reachy-mini-dances-library", move: name)
    }

    /// **The reason this is SHA-256 and not `hashValue`.** Swift seeds `Hasher` per
    /// process, so a stored `hashValue` compares unequal on the very next launch.
    /// A test in one process cannot see that — what it can pin is that the digest
    /// is a pure function of the content, which is the property `hashValue` lacks.
    @Test("the same catalogue stamps the same way")
    func stampsDeterministically() {
        let first = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a")], moves: [move("happy")])
        let second = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a")], moves: [move("happy")])

        #expect(first == second)
    }

    /// The daemon lists apps in whatever order it likes and the move index is a
    /// dictionary. Stamping the order rather than the contents would re-index on a
    /// reshuffle that changes nothing.
    @Test("order does not change the stamp")
    func ignoresOrder() {
        let forwards = ReachyEntityIndex.stamp(
            robotID: "hw-1",
            apps: [app("a"), app("b")],
            moves: [move("happy"), move("sad")]
        )
        let backwards = ReachyEntityIndex.stamp(
            robotID: "hw-1",
            apps: [app("b"), app("a")],
            moves: [move("sad"), move("happy")]
        )

        #expect(forwards == backwards)
    }

    @Test("installing something changes the stamp")
    func noticesANewApp() {
        let before = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a")], moves: [])
        let after = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a"), app("b")], moves: [])

        #expect(before != after)
    }

    @Test("removing something changes the stamp")
    func noticesARemovedApp() {
        let before = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a"), app("b")], moves: [])
        let after = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a")], moves: [])

        #expect(before != after)
    }

    /// The index describes one robot's apps. Connecting to a second one has to
    /// replace them rather than leave rows offering to start something that is
    /// installed somewhere else.
    @Test("another robot with the same catalogue stamps differently")
    func separatesRobots() {
        let first = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a")], moves: [])
        let second = ReachyEntityIndex.stamp(robotID: "hw-2", apps: [app("a")], moves: [])

        #expect(first != second)
    }

    /// An app id and a move id land in the same joined string, so a separator that
    /// can occur inside either would let two different catalogues collide. `\u{1}`
    /// cannot appear in a Space slug or a dataset name.
    @Test("an identifier cannot be split across the boundary")
    func resistsIdentifierCollisions() {
        let split = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("a"), app("b")], moves: [])
        let joined = ReachyEntityIndex.stamp(robotID: "hw-1", apps: [app("ab")], moves: [])

        #expect(split != joined)
    }
}
