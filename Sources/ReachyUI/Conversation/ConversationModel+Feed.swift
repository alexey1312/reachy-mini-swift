import Foundation
import ReachyKit

/// The half of ``ConversationModel`` that listens, and the rules about what may be
/// concluded from what arrives.
///
/// A file of its own for the reason `RunningAppModel+Conversation.swift` was: the model
/// carries the state and the seams, and this carries the policy.
extension ConversationModel {
    /// Follows the app's own notifications until the key changes.
    ///
    /// The stream is the whole feed — turns, transcript and levels merged in arrival
    /// order, which is what keeps "the assistant is speaking" and the line it spoke from
    /// being reordered against each other.
    func observe(app: RobotApp?, session: RobotSession) async {
        guard let app else { return }
        guard let stream = try? events(session, app) else {
            phase = .unavailable(.noTransport)
            return
        }
        for await event in stream {
            guard !Task.isCancelled else { return }
            receive(event)
        }
    }

    /// One frame from the app.
    func receive(_ event: ConversationEvent) {
        switch event {
        case let .turn(turn):
            self.turn = turn
            // A new turn makes the last sample meaningless — a meter frozen at the
            // volume of the previous speaker is worse than an empty one.
            level = nil
            settleLive()
        case let .transcript(line):
            append(line)
            settleLive()
        case let .level(sample):
            level = sample
        case .opened:
            settleLive()
        case .closed:
            noteFeedLost()
        }
    }

    /// A frame arrived, so the conversation is reachable — whatever the last failed call
    /// suggested. This is the only thing that promotes a phase upward, and it is
    /// evidence rather than elapsed time.
    func settleLive() {
        guard phase != .live else { return }
        // A configured backend is a separate question, and a frame does not answer it.
        // But a frame *is* the conversation working, so it outranks a stale reading.
        phase = .live
        preparingSince = nil
    }

    /// The feed stopped after having worked.
    ///
    /// Draws a gap rather than a verdict: a dropped socket is not evidence the app is
    /// gone, and the transport reconnects on its own. Only an arriving `not_running` —
    /// or a status read that answered — may say more than this.
    func noteFeedLost() {
        guard phase == .live else { return }
        phase = .interrupted
        turn = nil
        level = nil
        appendGapIfMissing()
    }

    /// One gap per interruption. A second `closed` with nothing in between describes the
    /// same hole, and two markers would claim two.
    func appendGapIfMissing() {
        guard hasTranscript else { return }
        if case .gap = entries.last?.kind {
            return
        }
        if case .ended = entries.last?.kind {
            return
        }
        add(TranscriptEntry(kind: .gap, text: String(localized: .reachy("The feed stopped here."))))
    }

    /// Appends, or replaces the trailing non-final row of the same role.
    ///
    /// Replacement is the defensive half: the app sends `final: true` from both of its
    /// emission sites today, so every line here is a whole utterance. It costs one
    /// comparison and covers a fork that starts streaming deltas, where appending would
    /// draw a staircase of growing prefixes instead of a sentence being written.
    func append(_ line: ConversationLine) {
        let entry = TranscriptEntry(line)
        if let last = entries.last, last.isSuperseded(by: line) {
            entries[entries.count - 1] = entry
            return
        }
        add(entry)
    }

    /// The client's own record of what it sent.
    ///
    /// A kind of its own rather than a `.spoken(.user)`, because nobody said it: the app
    /// injects the text as a user message and answers it, and the sent words never come
    /// back as a transcript line. Without this a send looks like it did nothing.
    func appendTyped(_ text: String) {
        add(TranscriptEntry(kind: .typed, text: text))
    }

    func add(_ entry: TranscriptEntry) {
        entries.append(entry)
        trim()
    }

    /// Drops the head past the cap, the shape `LogConsoleModel` uses.
    func trim() {
        guard entries.count > configuration.capacity else { return }
        entries.removeFirst(entries.count - configuration.capacity)
    }

    /// Nothing on the robot keeps a copy, which is why this asks first and why the
    /// confirmation names the count.
    func clear() {
        entries.removeAll()
    }
}

extension ConversationModel {
    /// A stable task identity for the one app whose own socket carries the conversation
    /// protocol. Nil tears the observer down while backgrounded and during process
    /// transitions.
    ///
    /// **It used to require a LAN address, and that is what #70 removed.** Daemon 1.10.0
    /// relays every non-`apps.*` frame to the running app's own `/rpc` and fans its
    /// notifications back, so the relay reaches the same conversation by a different
    /// road; `canControlConversation` is the question that answers, and it carries the
    /// version gate a bare `client is` cannot.
    ///
    /// The port is part of the identity — a poll that refreshes the app's metadata can
    /// name a port where the last one had only the fallback, and the observer has to
    /// redial rather than sit on a socket to nowhere. So is the transport, for the same
    /// reason: a session that moves between the LAN and the relay is no longer reaching
    /// the robot the way the open socket does.
    func streamKey(for status: RobotAppStatus?, session: RobotSession, active: Bool) -> String? {
        guard active,
              let status,
              status.state == .running,
              status.app.exposesConversationRPC,
              session.canControlConversation
        else { return nil }
        let port = status.app.customAppPort.map(String.init) ?? "default"
        return "\(status.app.id)@\(port)@\(session.isRemote ? "relay" : "lan")"
    }
}
