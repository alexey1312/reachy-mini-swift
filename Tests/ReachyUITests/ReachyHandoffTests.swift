import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Handoff advertisement and delivery are the system's half and unverifiable here; these
/// assert the pure builder/parser pair, the same trade `SpotlightIndexTests` makes.
@Suite("ReachyHandoff")
struct ReachyHandoffTests {
    private let identity = RobotIdentity(hardwareID: "b68ff6bbe47f0608", name: "reachy_mini")

    private func published(tab: ReachyRouter.Tab, identity: RobotIdentity) -> NSUserActivity {
        let activity = NSUserActivity(activityType: ReachyHandoff.activityType)
        ReachyHandoff.publish(tab: tab, identity: identity, into: activity)
        return activity
    }

    @Test("every tab round-trips")
    func allTabsRoundTrip() {
        for tab in ReachyRouter.Tab.allCases {
            let payload = ReachyHandoff.payload(for: published(tab: tab, identity: identity))
            #expect(payload == ReachyHandoff.Payload(tab: tab, robotKey: "b68ff6bbe47f0608"))
        }
    }

    @Test("the robot travels as its deduplication key")
    func robotKeyIsDeduplicationKey() {
        let byHardware = ReachyHandoff.payload(for: published(tab: .moves, identity: identity))
        #expect(byHardware?.robotKey == "b68ff6bbe47f0608")

        let nameOnly = RobotIdentity(name: "reachy_mini")
        let byName = ReachyHandoff.payload(for: published(tab: .moves, identity: nameOnly))
        #expect(byName?.robotKey == "reachy_mini")
    }

    @Test("a foreign activity type is refused")
    func refusesAForeignActivity() {
        let activity = NSUserActivity(activityType: "com.example.other")
        ReachyHandoff.publish(tab: .moves, identity: identity, into: activity)
        #expect(ReachyHandoff.payload(for: activity) == nil)
    }

    @Test("a missing tab is refused")
    func refusesAMissingTab() {
        let activity = NSUserActivity(activityType: ReachyHandoff.activityType)
        activity.userInfo = [ReachyHandoff.robotKey: "b68ff6bbe47f0608"]
        #expect(ReachyHandoff.payload(for: activity) == nil)
    }

    @Test("an unknown tab spelling is refused")
    func refusesAnUnknownTab() {
        let activity = NSUserActivity(activityType: ReachyHandoff.activityType)
        activity.userInfo = [
            ReachyHandoff.tabKey: "cameras",
            ReachyHandoff.robotKey: "b68ff6bbe47f0608",
        ]
        #expect(ReachyHandoff.payload(for: activity) == nil)
    }

    @Test("the published activity is for Handoff and not for search")
    func eligibility() {
        let activity = published(tab: .robot, identity: identity)
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch)
    }

    @Test("the title is the robot's name, and absent without one")
    func title() {
        #expect(published(tab: .robot, identity: identity).title == "reachy_mini")

        let anonymous = RobotIdentity(hardwareID: "b68ff6bbe47f0608")
        #expect(published(tab: .robot, identity: anonymous).title == nil)
    }
}
