@testable import ReachyMedia
import Testing

/// The whole of the call framing's decision table (issue #78). The reducer is
/// the only part of the LiveCommunicationKit integration a test can hold — the
/// framework itself needs a device — so every rule worth having lives here:
/// one start per call, mute never ends, and **every** path out of a call closes
/// the microphone.
@Suite("Call lifecycle")
struct CallLifecycleTests {
    @Test("an unmute with no call starts one")
    func unmuteStartsACall() {
        var lifecycle = CallLifecycle()

        #expect(lifecycle.handle(.unmuteTapped) == [.requestMicPermissionThenStart])
        #expect(lifecycle.state == .starting)
    }

    @Test("a second unmute while starting performs nothing")
    func doubleTapStartsOnce() {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)

        #expect(lifecycle.handle(.unmuteTapped) == [])
        #expect(lifecycle.state == .starting)
    }

    @Test("the system handing the start back activates the call")
    func performedStartActivates() {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)

        let effects = lifecycle.handle(.performedStart)

        #expect(effects == [
            .takeAudioOwnership, .fulfillPendingAction, .applyMic(true),
            .reportStartedConnecting, .reportConnected, .donate,
        ])
        #expect(lifecycle.state == .active)
    }

    @Test("a start arriving with no call in flight is refused")
    func unexpectedStartIsRefused() {
        var lifecycle = CallLifecycle()

        #expect(lifecycle.handle(.performedStart) == [.failPendingAction])
        #expect(lifecycle.state == .idle)
    }

    @Test("a refused microphone abandons the start quietly")
    func permissionDeniedAbandons() {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)

        #expect(lifecycle.handle(.micPermissionDenied) == [])
        #expect(lifecycle.state == .idle)
    }

    @Test("a failed perform abandons the start quietly")
    func startFailureAbandons() {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)

        #expect(lifecycle.handle(.startFailed) == [])
        #expect(lifecycle.state == .idle)
    }

    @Test("in-call mute routes through the system and does not end the call")
    func muteRoutesThroughTheSystem() {
        var lifecycle = CallLifecycle.active()

        #expect(lifecycle.handle(.muteTapped) == [.performMuteAction(isMuted: true)])
        #expect(lifecycle.state == .active)
        #expect(lifecycle.handle(.unmuteTapped) == [.performMuteAction(isMuted: false)])
        #expect(lifecycle.state == .active)
    }

    @Test("the system's mute action lands on the track, muted or not")
    func performedMuteAppliesToTheTrack() {
        var lifecycle = CallLifecycle.active()

        #expect(lifecycle.handle(.performedMute(isMuted: true)) == [.applyMic(false), .fulfillPendingAction])
        #expect(lifecycle.state == .active)
        #expect(lifecycle.handle(.performedMute(isMuted: false)) == [.applyMic(true), .fulfillPendingAction])
    }

    @Test("a mute action with no call is refused")
    func unexpectedMuteIsRefused() {
        var lifecycle = CallLifecycle()

        #expect(lifecycle.handle(.performedMute(isMuted: true)) == [.failPendingAction])
    }

    /// Fulfilling the end *is* the report for a system-initiated hang-up —
    /// reporting it again would double-end the conversation.
    @Test("the End button mutes, fulfills, and reports nothing")
    func performedEndMutesWithoutReporting() {
        var lifecycle = CallLifecycle.active()

        #expect(lifecycle.handle(.performedEnd) == [.applyMic(false), .fulfillPendingAction])
        #expect(lifecycle.state == .idle)
    }

    @Test("the system may end a call it is still validating")
    func endWhileStartingIsHonoured() {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)

        #expect(lifecycle.handle(.performedEnd) == [.applyMic(false), .fulfillPendingAction])
        #expect(lifecycle.state == .idle)
    }

    @Test("a session dying under the call mutes and reports the ending")
    func ineligibleSessionEndsAndReports() {
        var lifecycle = CallLifecycle.active()

        let effects = lifecycle.handle(.sessionBecameIneligible(.failed))

        #expect(effects == [.applyMic(false), .reportEnded(.failed)])
        #expect(lifecycle.state == .idle)
    }

    @Test("a robot going away reads as the far side ending, not a failure")
    func sleepReadsAsRemoteEnded() {
        var lifecycle = CallLifecycle.active()

        #expect(lifecycle.handle(.sessionBecameIneligible(.remoteEnded)) == [
            .applyMic(false), .reportEnded(.remoteEnded),
        ])
    }

    @Test("ineligibility with no call performs nothing")
    func ineligibleWhileIdleIsQuiet() {
        var lifecycle = CallLifecycle()

        #expect(lifecycle.handle(.sessionBecameIneligible(.failed)) == [])
    }

    /// The reset already tore everything down system-side; only the microphone
    /// is left to close.
    @Test("a manager reset mutes and reports nothing")
    func managerResetMutes() {
        var lifecycle = CallLifecycle.active()

        #expect(lifecycle.handle(.managerReset) == [.applyMic(false)])
        #expect(lifecycle.state == .idle)
    }

    @Test("a mute request with no call still mutes")
    func idleMuteStillMutes() {
        var lifecycle = CallLifecycle()

        #expect(lifecycle.handle(.muteTapped) == [.applyMic(false)])
        #expect(lifecycle.state == .idle)
    }

    /// The invariant stated in the type's header, checked as one sweep: there
    /// is no way out of `.active` whose effects leave the microphone open.
    @Test(
        "every path out of an active call closes the microphone",
        arguments: [
            CallLifecycle.Event.performedEnd,
            .sessionBecameIneligible(.failed),
            .sessionBecameIneligible(.remoteEnded),
            .managerReset,
        ]
    )
    func everyEndingMutes(_ event: CallLifecycle.Event) {
        var lifecycle = CallLifecycle.active()

        let effects = lifecycle.handle(event)

        #expect(lifecycle.state == .idle)
        #expect(effects.contains(.applyMic(false)))
    }
}

private extension CallLifecycle {
    /// A lifecycle walked into `.active` through its own front door, so the
    /// fixture can never drift from the real path.
    static func active() -> CallLifecycle {
        var lifecycle = CallLifecycle()
        _ = lifecycle.handle(.unmuteTapped)
        _ = lifecycle.handle(.performedStart)
        return lifecycle
    }
}
