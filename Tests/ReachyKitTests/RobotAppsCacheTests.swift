import Foundation
@testable import ReachyKit
import Testing

/// The widget's menu of apps. It cannot ask the robot what is installed, so this
/// is the list a picker offers and the list a tile is drawn from — and unlike a
/// reading of the robot's state, an old one is still usable.
@Suite("Robot apps cache")
struct RobotAppsCacheTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let robotID = "robot-a"

    private func store() throws -> RobotAppsCacheStore {
        try RobotAppsCacheStore(
            defaults: #require(UserDefaults(suiteName: "RobotAppsCacheTests.\(UUID().uuidString)"))
        )
    }

    @Test("a summary keeps the two identities and the artwork")
    func summarisesAnApp() {
        let app = RobotApp.preview(
            name: "reachy_mini_dance",
            title: "Dance Party",
            emoji: "💃",
            gradient: ("pink", "indigo"),
            installed: true
        )

        let summary = RobotAppSummary(app)

        #expect(summary.id == app.id)
        #expect(summary.name == "reachy_mini_dance")
        #expect(summary.title == "Dance Party")
        #expect(summary.emoji == "💃")
        #expect(summary.gradient == RobotApp.Gradient(from: "pink", to: "indigo"))
    }

    /// An installed app whose metadata the daemon could not find has only its
    /// entry point name. It is still an app and still launchable.
    @Test("an app with no card falls back to its name")
    func summarisesAnAppWithNoCard() {
        let app = RobotApp.preview(
            name: "face_tracking",
            title: nil,
            emoji: nil,
            author: nil,
            likes: nil,
            gradient: nil,
            installed: true
        )

        let summary = RobotAppSummary(app)

        #expect(summary.title == "Face Tracking")
        #expect(summary.emoji == nil)
        #expect(summary.gradient == nil)
    }

    @Test("a written list comes back")
    func roundTrips() throws {
        let store = try store()
        let written = RobotApp.previewInstalled.map(RobotAppSummary.init)

        store.write(written, robotID: robotID, at: now)

        #expect(store.current(for: robotID)?.installed == written)
        #expect(store.current(for: robotID)?.takenAt == now)
    }

    @Test("an empty store knows nothing")
    func startsEmpty() throws {
        #expect(try store().current(for: robotID) == nil)
    }

    @Test("a later write replaces the list")
    func replacesTheList() throws {
        let store = try store()
        store.write(RobotApp.previewInstalled.map(RobotAppSummary.init), robotID: robotID, at: now)

        let one = [RobotAppSummary(id: "a", name: "a", title: "A")]
        store.write(one, robotID: robotID, at: now.addingTimeInterval(60))

        #expect(store.current(for: robotID)?.installed == one)
    }

    @Test("an id is looked up, and an unknown one is not invented")
    func looksUpAnID() throws {
        let store = try store()
        let installed = RobotApp.previewInstalled.map(RobotAppSummary.init)
        store.write(installed, robotID: robotID, at: now)
        let cache = try #require(store.current(for: robotID))

        #expect(cache.summary(id: installed[0].id) == installed[0])
        #expect(cache.summary(id: "never-installed") == nil)
    }

    @Test("a list past the freshness window is stale")
    func reportsStale() {
        let cache = RobotAppsCache(robotID: robotID, installed: [], takenAt: now)

        #expect(cache.isStale(at: now.addingTimeInterval(RobotAppsCache.freshness)) == false)
        #expect(cache.isStale(at: now.addingTimeInterval(RobotAppsCache.freshness + 1)))
    }

    /// A clock that went backwards is not a list from the future gone old.
    @Test("a list dated in the future is not stale")
    func toleratesAClockGoingBackwards() {
        let cache = RobotAppsCache(robotID: robotID, installed: [], takenAt: now)

        #expect(cache.isStale(at: now.addingTimeInterval(-3600)) == false)
    }

    /// Half an hour is the snapshot's window, not this one — a stale reading is a
    /// lie, a stale menu is merely old.
    @Test("the menu outlives a reading by a long way")
    func outlivesASnapshot() {
        #expect(RobotAppsCache.freshness > RobotSnapshotStore.freshness)
    }

    @Test("a menu is visible only to the robot that produced it")
    func bindsTheMenuToRobotIdentity() throws {
        let store = try store()
        store.write(RobotApp.previewInstalled.map(RobotAppSummary.init), robotID: robotID, at: now)

        #expect(store.current(for: robotID) != nil)
        #expect(store.current(for: "robot-b") == nil)
    }
}
