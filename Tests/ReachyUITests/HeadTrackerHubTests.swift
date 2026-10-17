import Foundation
@testable import ReachyUI
import Testing

/// The hub's side of a `HeadTracker`: what it reads before a switch-on, when it
/// starts and stops the device, and the reference it hands out. The readings
/// themselves go through `receive`, which `HeadphoneTeleopTests` holds.
@MainActor
@Suite("Head tracker hub")
struct HeadTrackerHubTests {
    private final class FakeTracker: HeadTracker {
        var mapping = HeadphoneMotionMapping.headset
        var isAvailable = true
        var isDenied = false
        private(set) var starts = 0
        private(set) var stops = 0

        func start(into _: HeadphoneTeleop) {
            starts += 1
        }

        func stop() {
            stops += 1
        }
    }

    @Test("an available tracker offers the switch, and the hub takes its mapping")
    func availableOffersTheSwitch() {
        let hub = HeadphoneTeleop()
        let tracker = FakeTracker()

        hub.observe(tracker)

        #expect(hub.status == .off)
        #expect(hub.mapping == .headset)
    }

    @Test("a device that cannot track a head offers nothing")
    func unavailableStaysUnsupported() {
        let hub = HeadphoneTeleop()
        let tracker = FakeTracker()
        tracker.isAvailable = false

        hub.observe(tracker)
        hub.setOn(true)

        #expect(hub.status == .unsupported)
        #expect(tracker.starts == 0)
    }

    @Test("switching on starts the tracker and waits; switching off stops it")
    func switchingStartsAndStops() {
        let hub = HeadphoneTeleop()
        let tracker = FakeTracker()
        hub.observe(tracker)

        hub.setOn(true)
        #expect(hub.status == .waiting)
        #expect(tracker.starts == 1)

        hub.setOn(false)
        #expect(hub.status == .off)
        #expect(tracker.stops == 1)
    }

    @Test("a refusal read before the switch-on starts nothing")
    func deniedStartsNothing() {
        let hub = HeadphoneTeleop()
        let tracker = FakeTracker()
        tracker.isDenied = true
        hub.observe(tracker)

        hub.setOn(true)

        #expect(hub.status == .denied)
        #expect(tracker.starts == 0)
    }

    @Test("a refusal while running switches off and stops the tracker")
    func refusalWhileRunning() {
        let hub = HeadphoneTeleop()
        let tracker = FakeTracker()
        hub.observe(tracker)
        hub.setOn(true)

        hub.trackerWasRefused()

        #expect(hub.status == .denied)
        #expect(tracker.stops == 1)
    }

    /// The tracker asks before each reading; the answer is yes exactly once per request.
    @Test("a switch-on asks for one reference, and a recentre for another")
    func referenceIsHandedOutOnce() {
        let hub = HeadphoneTeleop()
        hub.observe(FakeTracker())
        hub.setOn(true)

        #expect(hub.takeReferenceRequest())
        #expect(!hub.takeReferenceRequest())

        hub.recentre()
        #expect(hub.takeReferenceRequest())
        #expect(!hub.takeReferenceRequest())
    }

    /// The two earbuds are mirror images, so a reference taken on one is wrong for the other.
    @Test("a change of earbud asks for a new reference, and the same earbud does not")
    func earbudChangeAsksForAReference() {
        let hub = HeadphoneTeleop()
        hub.observe(FakeTracker())
        hub.setOn(true)
        _ = hub.takeReferenceRequest()

        hub.noteSource(.left)
        #expect(hub.source == .left)
        #expect(hub.takeReferenceRequest())

        hub.noteSource(.left)
        #expect(!hub.takeReferenceRequest())

        hub.noteSource(.right)
        #expect(hub.takeReferenceRequest())
    }
}
