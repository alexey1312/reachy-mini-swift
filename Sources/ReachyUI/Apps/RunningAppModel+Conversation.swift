import Foundation
import ReachyKit

/// Everything the dock knows about the one app that speaks JSON-RPC: the turn it is
/// in, and the two controls worth reaching for from a phone.
///
/// A file of its own because `RunningAppModel.swift` is at SwiftLint's length limit,
/// the same split `RobotSession+<Feature>.swift` makes.
extension RunningAppModel {
    /// A stable task identity for the one app whose own socket carries the official
    /// semantic conversation protocol. Returning nil tears the observer down while
    /// backgrounded, during process transitions, and over daemon 1.9's relay path
    /// (which has no address to dial).
    ///
    /// The port is part of the identity: a poll that refreshes the app's metadata
    /// can name a port where the last one only had the fallback, and the observer
    /// has to redial rather than sit on a socket to nowhere.
    func conversationStreamKey(
        for status: RobotAppStatus?,
        session: RobotSession,
        active: Bool
    ) -> String? {
        guard active,
              let status,
              status.state == .running,
              status.app.exposesConversationRPC,
              session.address != nil
        else { return nil }
        return "\(status.app.id)@\(status.app.customAppPort.map(String.init) ?? "default")"
    }

    /// Follows Conversation App 1.0's `conversation.turn` notifications. This is
    /// presentation enrichment only: an absent or old `/rpc` surface quietly
    /// leaves the daemon's ordinary "Running" caption in place.
    ///
    /// So does a live one until the conversation next moves. `turn` is push-only
    /// and emitted on change, and `conversation.status` answers with backend config
    /// rather than a state, so there is nothing to seed the first frame from.
    func observeConversation(status: RobotAppStatus?, session: RobotSession) async {
        conversationTurn = nil
        guard let status, status.state == .running, status.app.exposesConversationRPC,
              let turns = try? conversationTurns(session, status.app)
        else { return }

        for await turn in turns {
            guard !Task.isCancelled else { return }
            conversationTurn = turn
        }
    }

    /// Mutes or unmutes the robot's own microphone.
    ///
    /// The flag is written only once the app has accepted the command: a button
    /// showing a state the robot never reached is worse than one that did nothing.
    func setMicrophoneMuted(_ muted: Bool, on session: RobotSession, app: RobotApp) async {
        await command(on: session) {
            try await setConversationMuted(session, app, muted)
            isMicrophoneMuted = muted
        }
    }

    /// Stops the robot mid-sentence.
    func interrupt(on session: RobotSession, app: RobotApp) async {
        await command(on: session) {
            try await interruptConversation(session, app)
        }
    }

    /// Runs one conversation command, and decides what its failure means.
    ///
    /// `-32601` is not reported: an app build without the method cannot grow one
    /// mid-session, so there is nothing a reader could act on — the controls go
    /// instead. Everything else lands in `lastError`, which the dock's one caption
    /// line renders and the poll retires.
    ///
    /// Deliberately not `run(_:_:)`: that one re-reads the app's transition state
    /// afterwards, and neither of these changes it.
    /// The dock stays up over an unreachable robot on purpose (`isReachable`), so
    /// its controls have to refuse rather than reach for a socket that cannot open.
    private func command(on session: RobotSession, _ work: () async throws -> Void) async {
        guard isReachable(session) else { return }
        do {
            try await work()
        } catch ConversationRPCClient.Failure.methodNotFound {
            offersConversationControls = false
        } catch {
            recordFailure(error)
        }
    }
}
