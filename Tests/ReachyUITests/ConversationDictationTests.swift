import Foundation
import ReachyKit
import ReachyMedia
@testable import ReachyUI
import Testing

/// Talking to Reachy from this device: the order of the robot calls a take makes, and
/// what it must never do — record after a prompt, touch the robot on a refusal, leave
/// the robot's microphone muted, or lose a release that arrived early.
///
/// Everything is logged into one list, the device's calls and the robot's together,
/// because the order across the two is the claim.
@MainActor
@Suite("Conversation dictation", .timeLimit(.minutes(1)))
struct ConversationDictationTests {
    private static let app = RobotApp.preview(
        name: "reachy_mini_conversation_app",
        installed: true,
        customAppURL: "http://0.0.0.0:7860/"
    )

    private func session() -> RobotSession {
        .preview(runningApp: RobotAppStatus(app: Self.app, state: .running))
    }

    private func model(
        _ stub: DictationStub,
        configuration: ConversationModel.Configuration = ConversationModel.Configuration()
    ) -> ConversationModel {
        let model = ConversationModel(
            configuration: configuration,
            events: { _, _ in AsyncStream { $0.finish() } },
            readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
            readMicrophone: { _, _ in false },
            setMicrophone: { _, _, muted in try await stub.setMicrophone(muted) },
            interruptConversation: { _, _ in try await stub.interrupt() },
            say: { _, _, text in try await stub.say(text) },
            dictation: stub.seam
        )
        model.receive(.opened)
        return model
    }

    // MARK: The order

    @Test("a hold over a speaking robot interrupts it, mutes it, sends the words and unmutes it")
    func holdOverASpeakingRobot() async {
        let stub = DictationStub()
        let model = model(stub)
        model.receive(.turn(.speaking))

        await model.talk(.pressed, app: Self.app, session: session())?.value
        #expect(model.dictation == .recording(heard: "", isLatched: false))
        #expect(model.isMicrophoneMuted)

        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start", "interrupt", "mic(true)", "finish", "say(hello)", "mic(false)"])
        #expect(model.entries.last?.kind == .dictated)
        #expect(model.entries.last?.text == "hello")
        #expect(model.dictation == .idle)
        #expect(model.isMicrophoneMuted == false)
    }

    @Test("a quiet robot is not interrupted")
    func quietRobotIsNotInterrupted() async {
        let stub = DictationStub()
        let model = model(stub)
        model.receive(.turn(.listening))

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start", "mic(true)", "finish", "say(hello)", "mic(false)"])
    }

    /// Nothing was muted by the take, so nothing is owed back — unmuting would open a
    /// microphone somebody had closed on purpose.
    @Test("an already muted robot is neither muted nor unmuted")
    func alreadyMutedIsLeftAlone() async {
        let stub = DictationStub()
        let model = model(stub)
        model.isMicrophoneMuted = true

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start", "finish", "say(hello)"])
        #expect(model.isMicrophoneMuted)
    }

    @Test("silence sends nothing, says so, and still gives the microphone back")
    func silenceSendsNothing() async {
        let stub = DictationStub()
        stub.outcome = .nothing
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start", "mic(true)", "finish", "mic(false)"])
        #expect(model.dictationNotice == .nothingHeard)
        #expect(model.hasTranscript == false)
    }

    @Test("a recognizer failure sends nothing and is reported in its own slot")
    func recognitionFailure() async {
        let stub = DictationStub()
        stub.outcome = .failed
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(stub.log.contains("say(hello)") == false)
        #expect(model.dictationRefusal == .transcriptionFailed)
    }

    // MARK: Permission and refusal

    /// The alert took the touch, so the release may never come — a take started under
    /// it would record until the time limit.
    @Test("a press that had to ask records nothing and touches nothing")
    func promptingPressRecordsNothing() async {
        let stub = DictationStub()
        stub.authorization = .askedJustNow
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize"])
        #expect(model.dictationNotice == .allowedNow)
        #expect(model.dictation == .idle)
    }

    @Test("a blocked permission touches neither the robot nor the microphone, and names its pane")
    func blockedPermission() async {
        let stub = DictationStub()
        stub.authorization = .speechBlocked(.denied)
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize"])
        #expect(model.dictationRefusal == .speech(.denied))
        #expect(model.dictationRefusal?.pane == .speechRecognition)

        stub.authorization = .ready
        await model.talk(.pressed, app: Self.app, session: session())?.value
        #expect(model.dictationRefusal == nil)
    }

    @Test("a call in progress refuses before any robot call")
    func callInProgressRefuses() async {
        let stub = DictationStub()
        stub.refusal = .callInProgress
        let model = model(stub)
        model.receive(.turn(.speaking))

        await model.talk(.pressed, app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start"])
        #expect(model.dictationRefusal == .callInProgress)
        #expect(model.dictationRefusal?.pane == nil)
        #expect(model.dictation == .idle)
    }

    /// A retry rather than a retalk.
    @Test("a failed send keeps the words in the composer and still unmutes")
    func failedSendKeepsTheWords() async {
        let stub = DictationStub()
        stub.sayFailure = ConversationFailure.timedOut
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value

        #expect(model.draft == "hello")
        #expect(model.hasTranscript == false)
        #expect(model.lastError != nil)
        #expect(stub.log.last == "mic(false)")
    }

    // MARK: Timing

    @Test("a release that arrives while permission is still being asked is applied, not dropped")
    func earlyReleaseIsApplied() async {
        let stub = DictationStub()
        stub.holdsAuthorize = true
        let model = model(stub)

        let press = model.talk(.pressed, app: Self.app, session: session())
        await until { stub.authorizeGate != nil }
        #expect(model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session()) == nil)
        stub.authorizeGate?.resume()
        await press?.value
        await until { model.dictation == .idle }

        #expect(stub.log.contains("finish"))
        #expect(stub.log.last == "mic(false)")
    }

    /// An unmute sent while the mute is still in flight would land first and leave the
    /// robot deaf.
    @Test("the unmute waits for a mute still in flight")
    func unmuteWaitsForTheMute() async {
        let stub = DictationStub()
        stub.holdsMute = true
        let model = model(stub)

        let press = model.talk(.pressed, app: Self.app, session: session())
        await until { stub.muteGate != nil }
        let end = model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())
        await until { stub.log.contains("finish") }
        #expect(stub.log.contains("say(hello)") == false)

        stub.muteGate?.resume()
        await press?.value
        await end?.value

        #expect(stub.log == [
            "authorize", "start", "mic(true)", "finish", "mic(true) landed", "say(hello)", "mic(false)",
        ])
    }

    /// A tap is how a Mac click works, and a hold is not the only way to talk.
    @Test("a short press latches, and the next tap sends")
    func tapLatchesThenSends() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        #expect(model.talk(.released(heldFor: .milliseconds(80)), app: Self.app, session: session()) == nil)
        #expect(model.dictation == .recording(heard: "", isLatched: true))

        #expect(model.talk(.pressed, app: Self.app, session: session()) == nil)
        await model.talk(.released(heldFor: .milliseconds(80)), app: Self.app, session: session())?.value

        #expect(stub.log.contains("say(hello)"))
        #expect(model.dictation == .idle)
    }

    @Test("the accessible toggle starts a take and the second one sends it")
    func toggleTwiceSends() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.toggled, app: Self.app, session: session())?.value
        #expect(model.dictation == .recording(heard: "", isLatched: true))
        await model.talk(.toggled, app: Self.app, session: session())?.value

        #expect(stub.log.contains("say(hello)"))
    }

    @Test("the time limit ends the take and sends what it heard")
    func timeLimitSends() async {
        let stub = DictationStub()
        var configuration = ConversationModel.Configuration()
        configuration.takeLimit = .zero
        let model = model(stub, configuration: configuration)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await until { model.dictation == .idle }

        #expect(stub.log.contains("say(hello)"))
    }

    // MARK: Ending without sending

    @Test("discarding sends nothing and gives the microphone back")
    func discardRestores() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.discarded, app: Self.app, session: session())?.value

        #expect(stub.log == ["authorize", "start", "mic(true)", "cancel", "mic(false)"])
        #expect(model.dictation == .idle)
    }

    @Test("a take cancelled while permission is asked never records and never reaches the robot")
    func cancelWhilePreparing() async {
        let stub = DictationStub()
        stub.holdsAuthorize = true
        let model = model(stub)

        let press = model.talk(.pressed, app: Self.app, session: session())
        await until { stub.authorizeGate != nil }
        #expect(model.cancelTake() == nil)
        stub.authorizeGate?.resume()
        await press?.value

        #expect(stub.log == ["authorize", "cancel"])
    }

    @Test("a preempted take goes idle, says so, and gives the microphone back")
    func preemptionRestores() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        stub.events?(.preempted)
        await until { stub.log.last == "mic(false)" }

        #expect(model.dictation == .idle)
        #expect(model.dictationNotice == .preempted)
        #expect(stub.log.contains("say(hello)") == false)
    }

    @Test("what the device hears so far is on screen while it records")
    func partialWordsAreShown() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        stub.events?(.heard("what's on"))
        stub.events?(.level(0.4))

        #expect(model.dictation == .recording(heard: "what's on", isLatched: false))
        #expect(model.dictationLevel == ConversationLevel(role: .user, rms: 0.4))
    }

    // MARK: Guards

    @Test("the other controls wait for a take to end")
    func otherControlsWait() async {
        let stub = DictationStub()
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.interrupt(app: Self.app, session: session())
        await model.setMicrophoneMuted(false, app: Self.app, session: session())

        #expect(stub.log == ["authorize", "start", "mic(true)"])
    }

    @Test("nothing starts while the conversation is not live")
    func notLive() {
        let stub = DictationStub()
        let model = model(stub)
        model.phase = .preparing

        #expect(model.talk(.pressed, app: Self.app, session: session()) == nil)
        #expect(stub.log.isEmpty)
    }

    /// `say` is one of the methods an older build lacks; the controls go, and so does
    /// the take.
    @Test("a -32601 on the send retires the controls and ends the take")
    func methodNotFoundOnSend() async {
        let stub = DictationStub()
        stub.sayFailure = ConversationFailure.methodNotFound
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value
        await model.talk(.released(heldFor: .seconds(2)), app: Self.app, session: session())?.value
        await until { stub.log.last == "mic(false)" }

        #expect(model.offersControls == false)
        #expect(model.dictation == .idle)
    }

    @Test("an arriving not-running on the mute concludes the app stopped and ends the take")
    func notRunningOnMute() async {
        let stub = DictationStub()
        stub.muteFailure = ConversationFailure.rejected(code: -32000, reason: .notRunning, message: "no app")
        let model = model(stub)

        await model.talk(.pressed, app: Self.app, session: session())?.value

        #expect(model.phase == .unavailable(.appStopped))
        #expect(model.dictation == .idle)
        #expect(stub.log.contains("cancel"))
    }

    // MARK: -

    /// Waits for a condition rather than a duration (project rule 7). The suite's time
    /// limit is what bounds a condition that never comes true.
    private func until(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
