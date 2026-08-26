import Foundation
@testable import ReachyUI
import Testing

/// The call-request inbox carries `QuickActionInbox`'s obligations — two
/// identical requests are two events — plus two of its own: a request expires
/// rather than lurks (an unmute minutes after the tap is a privacy bug), and
/// routing never opens the microphone at a robot the user did not name.
@MainActor
@Suite("Call requests")
struct CallRequestInboxTests {
    @Test("the same request twice in a row is two events")
    func distinguishesRepeatedRequests() {
        let inbox = CallRequestInbox()

        inbox.receive(robotID: "reachy-1")
        let first = inbox.pending
        inbox.receive(robotID: "reachy-1")

        #expect(first?.request.robotID == "reachy-1")
        #expect(inbox.pending?.request.robotID == "reachy-1")
        #expect(inbox.pending != first)
    }

    @Test("dropping a request clears it")
    func dropClears() {
        let inbox = CallRequestInbox()
        inbox.receive(robotID: nil)

        inbox.drop()

        #expect(inbox.pending == nil)
    }

    @Test("a request within its window is not expired")
    func freshRequestIsLive() {
        let now = Date()
        let request = CallRequest(robotID: nil, receivedAt: now)

        #expect(request.isExpired(now: now.addingTimeInterval(CallRequest.timeToLive - 1)) == false)
    }

    /// The privacy bound: a redial that waited out a slow connection must not
    /// open the microphone minutes after the tap.
    @Test("a request past its window is expired")
    func staleRequestExpires() {
        let now = Date()
        let request = CallRequest(robotID: nil, receivedAt: now)

        #expect(request.isExpired(now: now.addingTimeInterval(CallRequest.timeToLive + 1)))
    }

    @Test("the named robot being the connected one proceeds")
    func matchingRobotProceeds() {
        let decision = CallRequestRouting.decide(requestRobotID: "reachy-1", connectedRobotID: "reachy-1")

        #expect(decision == .proceed)
    }

    /// The bare Siri phrase names nobody, which means "whichever robot this app
    /// is connected to" — the same reading every intent's optional robot takes.
    @Test("an unnamed robot proceeds against whatever is connected")
    func unnamedRobotProceeds() {
        let decision = CallRequestRouting.decide(requestRobotID: nil, connectedRobotID: "reachy-1")

        #expect(decision == .proceed)
    }

    /// The receive rule shared with Handoff: an inbound request never
    /// disconnects a live session — and it never unmutes at a robot the user
    /// did not name, so the answer is the Live tab and nothing more.
    @Test("a different connected robot gets the Live tab and no microphone")
    func mismatchedRobotStopsAtTheLiveTab() {
        let decision = CallRequestRouting.decide(requestRobotID: "reachy-2", connectedRobotID: "reachy-1")

        #expect(decision == .liveTabOnly)
    }

    @Test("nothing connected waits for the connection")
    func disconnectedWaits() {
        let decision = CallRequestRouting.decide(requestRobotID: "reachy-1", connectedRobotID: nil)

        #expect(decision == .waitForConnection)
    }
}
