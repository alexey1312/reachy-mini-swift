import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Which session and which app get a conversation observer at all, and when the observer
/// has to be torn down and redialled. Moved here from `RunningAppModelTests` with the
/// state it reads.
@MainActor
@Suite("Conversation stream identity")
struct ConversationStreamKeyTests {
    /// The one app whose own socket carries the protocol.
    static let app = RobotApp.preview(
        name: "reachy_mini_conversation_app",
        installed: true,
        customAppURL: "http://0.0.0.0:7860/"
    )

    /// Any other app: running, and speaking nothing this client understands.
    static func status(_ state: RobotAppStatus.State) -> RobotAppStatus {
        RobotAppStatus(app: .preview(name: "dance_app", installed: true), state: state)
    }

    static func session(_ state: RobotAppStatus.State) -> RobotSession {
        .preview(runningApp: RobotAppStatus(app: app, state: state))
    }

    private func model() -> ConversationModel {
        ConversationModel(
            events: { _, _ in AsyncStream { $0.finish() } },
            readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
            readMicrophone: { _, _ in false },
            setMicrophone: { _, _, muted in muted },
            interruptConversation: { _, _ in },
            say: { _, _, _ in }
        )
    }

    @Test("only a running official conversation app gets a turn stream")
    func choosesConversationStream() {
        let model = model()
        let connected = Self.session(.running)
        let conversation = RobotAppStatus(app: Self.app, state: .running)

        #expect(model.streamKey(for: conversation, session: connected, active: true) != nil)
        #expect(model.streamKey(for: Self.status(.running), session: connected, active: true) == nil)
        #expect(model.streamKey(
            for: RobotAppStatus(app: Self.app, state: .starting),
            session: connected,
            active: true
        ) == nil)
        #expect(model.streamKey(for: conversation, session: connected, active: false) == nil)
    }

    /// **What #70 changed.** This used to require a LAN address, because daemon 1.9.0
    /// had no relay for these frames. Daemon 1.10.0 routes every non-`apps.*` frame to
    /// the running app's own `/rpc` and fans its notifications back, so a relayed
    /// session reaches the same conversation by a different road.
    ///
    /// The key still differs between the two, because a session that moves from one to
    /// the other has to redial rather than sit on a socket it is no longer reaching the
    /// robot through — the same argument the port already makes.
    @Test("a relayed session gets the conversation too, on a key of its own")
    func streamsOverTheRelay() {
        let model = model()
        let conversation = RobotAppStatus(app: Self.app, state: .running)

        let overRelay = model.streamKey(
            for: conversation,
            session: .preview(link: .remote),
            active: true
        )
        let overLAN = model.streamKey(for: conversation, session: Self.session(.running), active: true)

        #expect(overRelay != nil)
        #expect(overLAN != nil)
        #expect(overRelay != overLAN)
    }

    /// `.task(id:)` restarts on a changed id and on nothing else, so a port the
    /// daemon only learned on the second poll has to change the key.
    @Test("a newly reported port redials rather than reusing the socket")
    func portIsPartOfTheStreamIdentity() {
        let model = model()
        let connected = Self.session(.running)
        let unknownPort = RobotAppStatus(
            app: .preview(name: "reachy_mini_conversation_app", installed: true),
            state: .running
        )
        let key = { (status: RobotAppStatus) in
            model.streamKey(for: status, session: connected, active: true)
        }

        #expect(key(RobotAppStatus(app: Self.app, state: .running)) != key(unknownPort))
        #expect(key(unknownPort) != nil)
    }

    /// The observer reads the merged feed, so what reaches the model is asserted on the
    /// model rather than on a stream double — `ConversationModelTests` covers what each
    /// event kind does. What belongs here is that the observer is opened **for the app**,
    /// not merely for the session: the port lives on the app, and dialling the daemon's
    /// own 8000 would reach the REST API instead.
    @Test("the observer is opened for the running app, not just the session")
    func opensTheStreamForTheRunningApp() async {
        final class Observed: @unchecked Sendable {
            var app: RobotApp?
        }
        let observed = Observed()
        let model = ConversationModel(
            events: { _, app in
                observed.app = app
                return AsyncStream { $0.finish() }
            },
            readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
            readMicrophone: { _, _ in false },
            setMicrophone: { _, _, muted in muted },
            interruptConversation: { _, _ in },
            say: { _, _, _ in }
        )

        await model.observe(app: Self.app, session: Self.session(.running))

        #expect(observed.app?.customAppPort == 7860)
    }

    /// A transport that cannot carry the app's control surface is a state to draw, not a
    /// failure to report: nothing was attempted and nothing arrived.
    @Test("a transport that cannot carry it says so rather than reporting")
    func namesAnAbsentTransport() async {
        let model = ConversationModel(
            events: { _, _ in throw ReachyKitError.conversationUnavailable },
            readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
            readMicrophone: { _, _ in false },
            setMicrophone: { _, _, muted in muted },
            interruptConversation: { _, _ in },
            say: { _, _, _ in }
        )

        await model.observe(app: Self.app, session: Self.session(.running))

        #expect(model.phase == .unavailable(.noTransport))
        #expect(model.lastError == nil)
    }
}
