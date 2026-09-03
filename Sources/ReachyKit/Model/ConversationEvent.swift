import Foundation
import ReachyJSON

/// One thing the conversation app said, unasked.
///
/// **One stream of an enum rather than a stream per notification kind**, and the
/// reason is that the merge is unavoidable either way. Over the relay the daemon
/// fans each method out separately, so three subscriptions would have to be merged
/// in a task group before anything could read them; over the LAN socket they all
/// arrive on one connection, so three streams would mean a fan-out table. The merge
/// exists in both arms, so it belongs *below* this type, written once, rather than
/// above it in every consumer.
///
/// The other half of the argument is ordering. These are one conversation, and the
/// order between them carries meaning: "the assistant is speaking" and the line it
/// spoke must not be interleavable by the transport. Separate streams have no order
/// between them at all. A consumer wanting one kind filters, which costs nothing and
/// cannot fall out of step — ``RobotSession/conversationTurns(for:)`` is that filter.
public enum ConversationEvent: Sendable, Equatable {
    /// `conversation.turn` — the app's own mapped state, emitted only on change.
    case turn(ConversationTurn)
    /// `conversation.transcript` — what was actually said.
    case transcript(ConversationLine)
    /// `conversation.level` — the audio meter, about 15 frames a second.
    case level(ConversationLevel)
    /// A transport seam, not a frame the app sent.
    ///
    /// Today's `turns()` reconnects silently, which is right for a caption — a
    /// caption that flickered on every blip would be worse than one that lags. It is
    /// wrong for a record: the robot keeps no transcript, so anything said while the
    /// socket was down is gone, and a reader who is not told simply reads two
    /// unrelated utterances as consecutive. These are what let a transcript draw the
    /// gap it cannot fill.
    case opened
    case closed
}

/// Who is talking. Shared by the transcript and the meter, which name the same roles.
public enum ConversationRole: Sendable, Equatable, Decodable {
    case user
    case assistant
    /// A role this build has not heard of. Carried rather than dropped, the way
    /// ``ConversationTurn/unknown(_:)`` is — a future `tool` role should appear in a
    /// transcript as itself, not vanish out of the middle of a conversation.
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "user": self = .user
        case "assistant": self = .assistant
        case let other: self = .unknown(other)
        }
    }
}

/// One utterance, as the app reported it.
///
/// **`isFinal` is `true` in every frame the app sends today**, and that is not an
/// assumption — `_emit_transcript` has exactly two call sites in the Space, the
/// completed user transcription and `response.output_audio_transcript.done`, and both
/// pass `True`. So one notification is one whole utterance and appending is correct.
/// The flag is still read, and a caller should still replace a trailing non-final
/// line of the same role, because it costs a branch and a fork or a later version may
/// start streaming deltas — but nothing here is *shaped* around a state that never
/// occurs.
///
/// No identity. The wire carries none, and minting one here would put a value in a
/// domain type that two decodes of the same frame disagree about. A screen that needs
/// row identity wraps this and mints its own.
public struct ConversationLine: Sendable, Equatable, Decodable {
    public let role: ConversationRole
    public let text: String
    public let isFinal: Bool

    public init(role: ConversationRole, text: String, isFinal: Bool = true) {
        self.role = role
        self.text = text
        self.isFinal = isFinal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ConversationRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        // Absent means final: the app's own parameter defaults to `True`, so a frame
        // that omits it is a whole utterance rather than a fragment of one.
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
        case isFinal = "final"
    }
}

/// One reading of the audio meter, per role.
///
/// The app scales RMS by six and clamps it to `0...1` before sending, so this is
/// already a drawable fraction rather than a physical measurement. It is clamped
/// again here, because a meter is a width and a value past one draws outside its
/// track.
///
/// **The non-finite case is handled in the initialiser and not in the decoder**, and
/// the difference is that only one of them can happen. `JSONCodec.daemon` leaves
/// Foundation's non-conforming float strategy at `.throw`, so `NaN` and `Infinity`
/// cannot cross the wire at all — a guard in `init(from:)` would be unreachable code
/// dressed as defence. What *is* reachable is this client constructing one: a
/// preview fixture, a test. `min`/`max` propagate `NaN` rather than clamping it, and
/// a `NaN` reaching a meter's `frame(width:)` is a layout crash, so it is pinned to
/// zero here. Only `NaN` — the infinities clamp correctly on their own, and an
/// infinite reading means "louder than the track", which is what the ceiling is for.
public struct ConversationLevel: Sendable, Equatable, Decodable {
    public let role: ConversationRole
    public let rms: Double

    public init(role: ConversationRole, rms: Double) {
        self.role = role
        self.rms = rms.isNaN ? 0 : min(max(rms, 0), 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: container.decode(ConversationRole.self, forKey: .role),
            rms: container.decode(Double.self, forKey: .rms)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case rms
    }
}

public extension ConversationEvent {
    /// The one reader both transports call, so the two arms cannot drift apart on
    /// what a frame means.
    ///
    /// Returns nil for anything this client does not consume, and each of those is a
    /// decision rather than an omission:
    ///
    /// - `conversation.activity` is the *raw* backend reason. The app's own web UI
    ///   subscribes to it and maps it to an orb state itself; `conversation.turn` is
    ///   that mapping done server-side, and the comment beside it in `console.py`
    ///   says it exists "for clients without that mapping (mobile)" — which is this
    ///   one. Consuming both would be reading the same fact twice, out of step.
    /// - `conversation.phase` is dead. `_emit_phase` is defined in `console.py` and
    ///   called from nowhere in the app, so a client that waits for one waits forever.
    /// - A reply carries an `id` and belongs to a caller, not to this stream.
    static func decoded(from data: Data) -> ConversationEvent? {
        guard let frame = try? JSONCodec.daemon.decode(Frame.self, from: data) else { return nil }
        switch frame.method {
        case "conversation.turn":
            return frame.params?.state.map(ConversationEvent.turn)
        case "conversation.transcript":
            return frame.params?.line.map(ConversationEvent.transcript)
        case "conversation.level":
            return frame.params?.level.map(ConversationEvent.level)
        default:
            return nil
        }
    }

    /// Just enough of a notification to route it. `params` is decoded three ways
    /// because one `method` chooses which of them is meaningful, and a shape that
    /// does not fit decodes to nil rather than throwing the whole frame away.
    private struct Frame: Decodable {
        struct Parameters: Decodable {
            let state: ConversationTurn?
            let line: ConversationLine?
            let level: ConversationLevel?

            init(from decoder: any Decoder) throws {
                state = try? decoder.container(keyedBy: CodingKeys.self)
                    .decodeIfPresent(ConversationTurn.self, forKey: .state)
                line = try? ConversationLine(from: decoder)
                level = try? ConversationLevel(from: decoder)
            }

            private enum CodingKeys: String, CodingKey {
                case state
            }
        }

        let method: String?
        let params: Parameters?
    }
}
