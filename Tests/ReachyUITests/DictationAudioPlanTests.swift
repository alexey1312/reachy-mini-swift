@testable import ReachyMedia
import Testing

/// Who gives way to whom when a take on this device wants the microphone. The session
/// itself only exists on a device, so every rule worth holding lives in the reducer —
/// the same split `CallLifecycleTests` makes for the call framing.
@Suite("Dictation audio plan")
struct DictationAudioPlanTests {
    @Test("a call refuses a take and leaves the plan idle")
    func callRefuses() {
        var plan = DictationAudioPlan()

        #expect(plan.willStart(owner: .call) == [.refuseCallInProgress])
        #expect(plan.isActive == false)
    }

    /// The robot's voice would otherwise play out of this device's speaker and into the
    /// take — and two audio units recording one microphone is nothing to rely on.
    @Test("over a camera session, WebRTC's audio stands down and comes back")
    func cameraSessionStandsDown() {
        var plan = DictationAudioPlan()

        #expect(plan.willStart(owner: .app) == [.cancelTransition, .disableWebRTCAudio])
        #expect(plan.owesRelease == false)
        #expect(plan.didEnd(owner: .app) == [.enableWebRTCAudio])
        #expect(plan.isActive == false)
    }

    @Test("with nothing running, the take activates the session and owes the release")
    func nobodyOwesRelease() {
        var plan = DictationAudioPlan()

        #expect(plan.willStart(owner: .nobody) == [.cancelTransition, .configureAndActivate])
        #expect(plan.owesRelease)
        #expect(plan.didEnd(owner: .nobody) == [.release])
        #expect(plan.owesRelease == false)
    }

    @Test("ending twice does nothing the second time")
    func didEndIsIdempotent() {
        var plan = DictationAudioPlan()
        _ = plan.willStart(owner: .nobody)
        _ = plan.didEnd(owner: .nobody)

        #expect(plan.didEnd(owner: .nobody).isEmpty)
    }

    @Test("a second start while one runs is a no-op")
    func secondStartIsIgnored() {
        var plan = DictationAudioPlan()
        _ = plan.willStart(owner: .app)

        #expect(plan.willStart(owner: .app).isEmpty)
    }

    /// The camera now owns the session, so the take owes no release — and WebRTC's unit
    /// waits, because the engine still holds the microphone.
    @Test("a camera starting mid-take takes the session but not the audio unit")
    func cameraStartsMidTake() {
        var plan = DictationAudioPlan()
        _ = plan.willStart(owner: .nobody)

        #expect(plan.cameraStarted() == false)
        #expect(plan.owesRelease == false)
        #expect(plan.didEnd(owner: .app) == [.enableWebRTCAudio])
    }

    @Test("a camera starting with no take may turn its audio on at once")
    func cameraStartsWithoutATake() {
        var plan = DictationAudioPlan()
        // Outside the macro: `#expect` captures a bare call on an immutable copy.
        let mayEnable = plan.cameraStarted()

        #expect(mayEnable)
    }

    /// Releasing under a running engine would deactivate the session it records
    /// through, so the take owes the release instead.
    @Test("a camera stopping mid-take defers its release to the take")
    func cameraStopsMidTake() {
        var plan = DictationAudioPlan()
        _ = plan.willStart(owner: .app)

        #expect(plan.cameraStopped() == false)
        #expect(plan.didEnd(owner: .nobody) == [.release])
    }

    @Test("a camera stopping with no take releases as it always did")
    func cameraStopsWithoutATake() {
        var plan = DictationAudioPlan()
        let mayRelease = plan.cameraStopped()

        #expect(mayRelease)
    }

    /// The take ends first, so the engine has let go before the system interrupts the
    /// session for the call — and nothing is restored, because the call owns it now.
    @Test("a call starting mid-take preempts it and touches nothing else")
    func callPreemptsATake() {
        var plan = DictationAudioPlan()
        _ = plan.willStart(owner: .app)

        #expect(plan.callWillStart() == [.preempt])
        #expect(plan.isActive == false)
        #expect(plan.didEnd(owner: .call).isEmpty)
    }

    @Test("a call starting with no take changes nothing")
    func callWithoutATake() {
        var plan = DictationAudioPlan()

        #expect(plan.callWillStart().isEmpty)
    }

    @Test("an interruption preempts first, then restores what the take borrowed")
    func interruptionPreemptsThenRestores() {
        var overCamera = DictationAudioPlan()
        _ = overCamera.willStart(owner: .app)
        #expect(overCamera.interrupted(owner: .app) == [.preempt, .enableWebRTCAudio])

        var alone = DictationAudioPlan()
        _ = alone.willStart(owner: .nobody)
        #expect(alone.interrupted(owner: .nobody) == [.preempt, .release])
    }
}
