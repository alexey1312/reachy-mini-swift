import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The dock's two conversation controls: mute the robot's microphone, and stop it
/// mid-sentence.
@MainActor
@Suite("Running app conversation controls", .timeLimit(.minutes(1)))
struct RunningAppConversationTests {
    private static let app = RobotApp.previewConversation

    /// Records what the model asked the app to do.
    final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var muted: [Bool] = []
        private(set) var interrupts = 0
        var failure: (any Error)?

        func mute(_ value: Bool) throws {
            if let failure {
                throw failure
            }
            lock.withLock { muted.append(value) }
        }

        func interrupt() throws {
            if let failure {
                throw failure
            }
            lock.withLock { interrupts += 1 }
        }
    }

    private func model(_ commands: Commands) -> RunningAppModel {
        RunningAppModel(
            conversationTurns: { _, _ in AsyncStream { $0.finish() } },
            setConversationMuted: { _, _, muted in try commands.mute(muted) },
            interruptConversation: { _, _ in try commands.interrupt() }
        )
    }

    private func session() -> RobotSession {
        .preview(runningApp: RobotAppStatus(app: Self.app, state: .running))
    }

    @Test("muting sends the state the dock is switching to")
    func mutes() async {
        let commands = Commands()
        let model = model(commands)

        await model.setMicrophoneMuted(true, on: session(), app: Self.app)

        #expect(commands.muted == [true])
        #expect(model.isMicrophoneMuted)
    }

    /// The app owns the microphone, so the dock cannot read the state back — it can
    /// only remember what it last asked for. Toggling has to reverse that memory or
    /// the button becomes a one-way switch.
    @Test("muting twice unmutes")
    func unmutes() async {
        let commands = Commands()
        let model = model(commands)
        let session = session()

        await model.setMicrophoneMuted(true, on: session, app: Self.app)
        await model.setMicrophoneMuted(false, on: session, app: Self.app)

        #expect(commands.muted == [true, false])
        #expect(!model.isMicrophoneMuted)
    }

    @Test("interrupting reaches the app")
    func interrupts() async {
        let commands = Commands()
        let model = model(commands)

        await model.interrupt(on: session(), app: Self.app)

        #expect(commands.interrupts == 1)
    }

    /// A refused mute must not leave the button showing the state it failed to
    /// reach — that is the one thing worse than not having the button.
    @Test("a refused mute keeps the state it actually had")
    func keepsStateOnFailure() async {
        let commands = Commands()
        commands.failure = ConversationRPCClient.Failure.timedOut
        let model = model(commands)

        await model.setMicrophoneMuted(true, on: session(), app: Self.app)

        #expect(!model.isMicrophoneMuted)
        #expect(model.lastError != nil)
    }

    /// A build of the app without these methods is not a failure to report — there
    /// is nothing the reader could do. The controls go instead.
    @Test("an app that does not know the method hides the controls rather than erroring")
    func hidesOnUnknownMethod() async {
        let commands = Commands()
        commands.failure = ConversationRPCClient.Failure.methodNotFound
        let model = model(commands)
        #expect(model.offersConversationControls)

        await model.interrupt(on: session(), app: Self.app)

        #expect(!model.offersConversationControls)
        #expect(model.lastError == nil)
    }

    /// Muting is a request about the *robot's* input, so a disconnected robot has
    /// nothing to mute — and the dock stays up while unreachable by design.
    @Test("an unreachable robot is not asked")
    func refusesWhileUnreachable() async {
        let commands = Commands()
        let model = model(commands)
        let unreachable = RobotSession.preview(
            phase: .unreachable(.preview),
            runningApp: RobotAppStatus(app: Self.app, state: .running)
        )

        await model.setMicrophoneMuted(true, on: unreachable, app: Self.app)

        #expect(commands.muted.isEmpty)
    }
}
