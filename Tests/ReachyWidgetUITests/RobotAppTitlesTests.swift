import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// Why this join exists at all, and what it must not do.
///
/// An intent has one sentence and Siri reads it aloud, so the difference between
/// "Dance Party" and `dance_party` is the whole of the feature working.
@Suite("Robot app titles", .timeLimit(.minutes(1)))
struct RobotAppTitlesTests {
    private let robotID = "robot-a"
    private let dance = RobotAppSummary(id: "pollen/dance", name: "dance_party", title: "Dance Party")

    private func store() throws -> RobotAppsCacheStore {
        try RobotAppsCacheStore(
            defaults: #require(UserDefaults(suiteName: "RobotAppTitlesTests.\(UUID().uuidString)"))
        )
    }

    private func titles(_ store: RobotAppsCacheStore, robotID: String?) -> RobotAppTitles {
        RobotAppTitles(cache: store, robotID: { robotID })
    }

    /// The premise. `AppManager.start_app` files a running app as
    /// `AppInfo(name:source_kind:)` with an empty `extra`, so the daemon's own
    /// answer carries the Python entry point where a title should be — which is
    /// what makes reading the title off a status a bug rather than a shortcut.
    @Test("the daemon's own status has no title to read")
    func aRunningStatusCarriesNoTitle() {
        let status = StubAppsClient.status(name: "dance_party")

        #expect(status.app.title == "Dance Party")
    }

    @Test("an entry point the robot has installed resolves to its store title")
    func resolvesFromTheCache() throws {
        let store = try store()
        store.write([dance], robotID: robotID)

        #expect(titles(store, robotID: robotID).title(for: "dance_party") == "Dance Party")
    }

    /// A local app with no Hub card is still an app. Speaking the slug is worse
    /// than speaking nothing, and speaking somebody else's title is worse than both.
    @Test("an unknown entry point comes back untouched")
    func leavesAnUnknownNameAlone() throws {
        let store = try store()
        store.write([dance], robotID: robotID)

        #expect(titles(store, robotID: robotID).title(for: "face_tracking") == "face_tracking")
    }

    @Test("a list cached for another robot is not consulted")
    func ignoresAnotherRobotsList() throws {
        let store = try store()
        store.write([dance], robotID: "robot-b")

        #expect(titles(store, robotID: robotID).title(for: "dance_party") == "dance_party")
    }

    @Test("no robot to key the cache by is not a match")
    func needsAKnownRobot() throws {
        let store = try store()
        store.write([dance], robotID: robotID)

        #expect(titles(store, robotID: nil).title(for: "dance_party") == "dance_party")
    }
}
