import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// `EntityURLRepresentation` takes a string literal and no interpolated values, so
/// an entity's URL is a hand-written second copy of what `ReachyDeepLink` builds.
/// Nothing in the compiler holds those two together; this does.
@Suite("Entity URLs")
struct EntityURLTests {
    private func app(id: String) -> RobotAppEntity {
        RobotAppEntity(RobotAppSummary(id: id, name: "conversation", title: "Conversation"), isInstalled: true)
    }

    @Test("an app's URL is the deep link the app already parses")
    func matchesTheDeepLink() async {
        let entity = app(id: "pollen-robotics/reachy_mini_conversation")

        let url = await entity.urlRepresentation

        #expect(url == ReachyDeepLink.apps.url(identifier: entity.id))
    }

    /// The round trip is the point: a template that drifted from `ReachyDeepLink`
    /// would still produce *a* URL, and the failure would be a tap that opens the
    /// app and does nothing.
    @Test("an app's URL parses back to the app it names")
    func roundTripsThroughTheDeepLink() async throws {
        let entity = app(id: "pollen-robotics/reachy_mini_conversation")

        let url = try #require(await entity.urlRepresentation)
        let target = try #require(ReachyDeepLink.Target(url: url))

        #expect(target.destination == .apps)
        #expect(target.identifier == entity.id)
    }
}
