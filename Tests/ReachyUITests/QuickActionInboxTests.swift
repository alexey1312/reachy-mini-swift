@testable import ReachyUI
import Testing

/// The inbox is one value with one job, and the job is easy to get subtly wrong:
/// SwiftUI notices a *change*, so a command that looks identical to the last one
/// has to arrive as a different value or it never runs.
@MainActor
@Suite("Home Screen quick actions")
struct QuickActionInboxTests {
    @Test("the same command twice in a row is two events")
    func distinguishesRepeatedTaps() {
        let inbox = QuickActionInbox()

        inbox.receive(type: "wake")
        let first = inbox.pending
        inbox.receive(type: "wake")

        #expect(first?.action == .wake)
        #expect(inbox.pending?.action == .wake)
        #expect(inbox.pending != first)
    }

    @Test("reading a command takes it")
    func clearsOnRead() {
        let inbox = QuickActionInbox()
        inbox.receive(type: "power-off")

        #expect(inbox.take() == .powerOff)
        #expect(inbox.pending == nil)
        #expect(inbox.take() == nil)
    }

    /// A cold launch taps before any robot is connected, so the command has to stay
    /// put while the lifecycle looks at it and decides it cannot run yet.
    @Test("looking at a command leaves it waiting")
    func peekLeavesItQueued() {
        let inbox = QuickActionInbox()
        inbox.receive(type: "sleep")

        #expect(inbox.peek() == .sleep)
        #expect(inbox.peek() == .sleep)
        #expect(inbox.take() == .sleep)
        #expect(inbox.pending == nil)
    }

    /// "Power off" from the Home Screen must not fire on a connection made long after
    /// the tap — that robot was chosen for some other reason.
    @Test("a command that waited too long is dropped, not run")
    func expires() {
        let start = ContinuousClock.now
        var now = start
        let inbox = QuickActionInbox(lifetime: .seconds(30), now: { now })
        inbox.receive(type: "power-off")

        now = start.advanced(by: .seconds(30))
        #expect(inbox.peek() == .powerOff)

        now = start.advanced(by: .seconds(31))
        #expect(inbox.peek() == nil)
        #expect(inbox.pending == nil)
        #expect(inbox.take() == nil)
    }

    /// A second tap is a new command with a fresh deadline, not the old one extended.
    @Test("a repeated tap starts its own clock")
    func repeatedTapRestartsTheClock() {
        let start = ContinuousClock.now
        var now = start
        let inbox = QuickActionInbox(lifetime: .seconds(30), now: { now })
        inbox.receive(type: "wake")

        now = start.advanced(by: .seconds(25))
        inbox.receive(type: "wake")
        now = start.advanced(by: .seconds(40))

        #expect(inbox.take() == .wake)
    }

    /// The boolean is what UIKit's `performActionFor` completion handler wants, and
    /// an identifier this app does not own must not leave a command queued.
    @Test("an unknown identifier is refused and queues nothing")
    func refusesAnUnknownIdentifier() {
        let inbox = QuickActionInbox()

        #expect(inbox.receive(type: "com.example.other") == false)
        #expect(inbox.pending == nil)
    }

    /// The raw values are the `UIApplicationShortcutItem` types installed on the
    /// Home Screen. Changing one silently orphans every icon already on a device.
    @Test("the identifiers are the ones the Home Screen holds")
    func pinsTheIdentifiers() {
        #expect(ReachyQuickAction.allCases.map(\.rawValue) == ["wake", "sleep", "power-off"])
    }
}
