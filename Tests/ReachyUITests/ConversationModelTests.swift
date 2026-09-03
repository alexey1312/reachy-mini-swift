import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// What no reference image can hold: what the model concludes from what arrived, and —
/// more importantly — what it refuses to conclude from what did not.
@MainActor
@Suite("Conversation model")
struct ConversationModelTests {
    private static let app = RobotApp.preview(
        name: "reachy_mini_conversation_app",
        installed: true,
        customAppURL: "http://0.0.0.0:7860/"
    )

    private func session() -> RobotSession {
        .preview(runningApp: RobotAppStatus(app: Self.app, state: .running))
    }

    private func model(
        status: @escaping ConversationModel.ReadStatus = { _, _ in ConversationBackendStatus(canProceed: true) },
        microphone: @escaping ConversationModel.ReadMicrophone = { _, _ in false },
        setMicrophone: @escaping ConversationModel.SetMicrophone = { _, _, muted in muted },
        interrupt: @escaping ConversationModel.Interrupt = { _, _ in },
        say: @escaping ConversationModel.Say = { _, _, _ in },
        configuration: ConversationModel.Configuration = ConversationModel.Configuration()
    ) -> ConversationModel {
        ConversationModel(
            configuration: configuration,
            events: { _, _ in AsyncStream { $0.finish() } },
            readStatus: status,
            readMicrophone: microphone,
            setMicrophone: setMicrophone,
            interruptConversation: interrupt,
            say: say
        )
    }

    // MARK: The turn

    /// Never faked. The app emits a turn only on change and answers no read with one, so
    /// a screen showing "Ready" on open would be inventing it.
    @Test("the turn is unknown until the conversation moves")
    func leavesTheTurnUnknown() async {
        let model = model()

        await model.prime(app: Self.app, session: session())

        #expect(model.turn == nil)
        #expect(model.phase == .live)
    }

    /// A meter frozen at the previous speaker's volume is worse than an empty one.
    @Test("a turn change clears the level")
    func clearsTheLevelOnATurn() {
        let model = model()
        model.receive(.level(ConversationLevel(role: .user, rms: 0.8)))
        #expect(model.level != nil)

        model.receive(.turn(.thinking))

        #expect(model.level == nil)
    }

    // MARK: Verdicts

    /// **The rule this whole model turns on.** A timeout is a Wi-Fi blip until something
    /// says otherwise, and the transport reconnects on its own — so it may report, and it
    /// may not conclude.
    @Test("a timeout reports without concluding the app is gone")
    func doesNotConcludeFromATimeout() async {
        let model = model(interrupt: { _, _ in throw ConversationFailure.timedOut })
        model.receive(.opened)
        #expect(model.phase == .live)

        await model.interrupt(app: Self.app, session: session())

        #expect(model.phase == .live)
        #expect(model.lastError != nil)
    }

    /// An arriving `not_running` is the app itself saying it is gone. That one may.
    @Test("an arriving not-running concludes the app stopped")
    func concludesFromNotRunning() async {
        let model = model(interrupt: { _, _ in
            throw ConversationFailure.rejected(code: -32000, reason: .notRunning, message: "no app is running")
        })
        model.receive(.opened)

        await model.interrupt(app: Self.app, session: session())

        #expect(model.phase == .unavailable(.appStopped))
    }

    /// There is nothing a reader could do about a build that has no such method, so the
    /// controls go rather than a message arriving.
    @Test("an unknown method retires the controls and reports nothing")
    func retiresControlsOnUnknownMethod() async {
        let model = model(interrupt: { _, _ in throw ConversationFailure.methodNotFound })
        #expect(model.offersControls)

        await model.interrupt(app: Self.app, session: session())

        #expect(!model.offersControls)
        #expect(model.lastError == nil)
    }

    // MARK: The microphone

    /// The robot's answer is drawn, not the request — an app that refused, or another
    /// client that muted it a moment ago, must not leave this claiming a state the robot
    /// is not in.
    @Test("the flag the app answers with is the one that is kept")
    func rendersTheAnswer() async {
        let model = model(setMicrophone: { _, _, _ in true })

        await model.setMicrophoneMuted(false, app: Self.app, session: session())

        #expect(model.isMicrophoneMuted)
    }

    /// **The branch no reference image can see.** A press that failed must still be
    /// followed by a release: the two failures are not symmetric, and a microphone left
    /// open is the one outcome this control cannot produce.
    @Test("a release is sent even when the press failed")
    func alwaysSendsTheRelease() async {
        let sent = Sent()
        let model = model(setMicrophone: { _, _, muted in
            sent.record(muted)
            if !muted {
                throw ConversationFailure.timedOut
            }
            return muted
        })
        let session = session()

        await model.setMicrophoneMuted(false, app: Self.app, session: session)
        await model.endHold(app: Self.app, session: session)

        #expect(sent.values == [false, true])
        #expect(model.isMicrophoneMuted)
    }

    /// The dock and this screen both stay up over an unreachable robot on purpose, so
    /// their controls have to refuse rather than reach for a socket that cannot open —
    /// and refusing is not a failure to report, because nothing was attempted.
    @Test("an unreachable robot is not asked, and nothing is reported")
    func refusesWhileUnreachable() async {
        let sent = Sent()
        let model = model(setMicrophone: { _, _, muted in
            sent.record(muted)
            return muted
        })
        let unreachable = RobotSession.preview(
            phase: .unreachable(.preview),
            runningApp: RobotAppStatus(app: Self.app, state: .running)
        )

        await model.setMicrophoneMuted(true, app: Self.app, session: unreachable)

        #expect(sent.values.isEmpty)
        #expect(model.lastError == nil)
        #expect(!model.isMicrophoneMuted)
    }

    // MARK: Sending

    /// The sent words never come back as a transcript line — only audio transcription
    /// produces those — so without this a send looks like it did nothing. And it must not
    /// be a spoken row: nobody said it.
    @Test("a sent message is recorded as typed, never as speech")
    func recordsSendsAsTyped() async {
        let model = model()
        model.draft = "happy birthday"

        await model.send(app: Self.app, session: session())

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.kind == .typed)
        #expect(model.draft.isEmpty)
    }

    /// Clearing the field on a failure turns a retry into a retype.
    @Test("a refused send keeps the draft and records nothing")
    func keepsTheDraftOnFailure() async {
        let model = model(say: { _, _, _ in throw ConversationFailure.timedOut })
        model.draft = "happy birthday"

        await model.send(app: Self.app, session: session())

        #expect(model.draft == "happy birthday")
        #expect(model.entries.isEmpty)
        #expect(model.lastError != nil)
    }

    @Test("whitespace alone never reaches the wire")
    func refusesEmptySends() async {
        let sent = Sent()
        let model = model(say: { _, _, _ in sent.record(true) })
        model.draft = "   \n "

        await model.send(app: Self.app, session: session())

        #expect(sent.values.isEmpty)
        #expect(!model.canSend)
    }

    // MARK: Priming

    /// The backend takes up to ninety seconds to come up and answers `loop_unavailable`
    /// throughout. A first failure is a state to narrate, not a refusal.
    @Test("a still-starting backend keeps the screen waiting")
    func waitsOutTheStartup() async {
        let attempts = Sent()
        var configuration = ConversationModel.Configuration()
        configuration.retryInterval = .milliseconds(1)
        let model = model(
            status: { _, _ in
                attempts.record(true)
                guard attempts.values.count > 2 else {
                    throw ConversationFailure.rejected(
                        code: -32000, reason: .loopUnavailable, message: "still starting"
                    )
                }
                return ConversationBackendStatus(canProceed: true)
            },
            configuration: configuration
        )

        await model.prime(app: Self.app, session: session())

        #expect(attempts.values.count == 3)
        #expect(model.phase == .live)
    }

    /// The budget is injected so this crosses it without waiting ninety seconds out
    /// (project rule 7) — but past it the answer changes, and that is the assertion.
    @Test("a backend that never comes up stops being called starting")
    func givesUpPastTheBudget() async {
        var configuration = ConversationModel.Configuration()
        configuration.retryInterval = .milliseconds(1)
        configuration.startupBudget = 0
        let model = model(
            status: { _, _ in
                throw ConversationFailure.rejected(code: -32000, reason: .loopUnavailable, message: "still starting")
            },
            configuration: configuration
        )

        await model.prime(app: Self.app, session: session())

        #expect(model.phase == .unavailable(.appUnavailable))
    }

    /// The fix for this one is on the robot — the app's own settings page — rather than
    /// anywhere in this app, which is why it is a phase of its own.
    @Test("an app with no voice backend says so rather than looking empty")
    func reportsAnUnconfiguredBackend() async {
        let model = model(status: { _, _ in ConversationBackendStatus(canProceed: false) })

        await model.prime(app: Self.app, session: session())

        #expect(model.phase == .backendUnconfigured)
    }
}

/// Records what a seam was handed, across the suspension points a `@MainActor` test
/// still has.
private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var values: [Bool] {
        lock.withLock { recorded }
    }

    func record(_ value: Bool) {
        lock.withLock { recorded.append(value) }
    }
}
