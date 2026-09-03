import Foundation
@testable import ReachyKit
import Testing

/// The frame reader both transports share. Everything here is a real frame the
/// conversation app sends, or a frame it deliberately sends and this client
/// deliberately ignores.
@Suite("Conversation events")
struct ConversationEventTests {
    private func event(_ frame: String) -> ConversationEvent? {
        ConversationEvent.decoded(from: Data(frame.utf8))
    }

    @Test("a turn notification decodes to its state")
    func decodesTurn() {
        #expect(
            event(#"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"speaking"}}"#)
                == .turn(.speaking)
        )
    }

    /// The app emits `{"state":"listening","reason":"interrupted"}` when somebody
    /// interrupts, and the extra field must not cost the frame (project rule 3).
    @Test("an unknown field beside the state does not break the frame")
    func toleratesUnknownFields() {
        #expect(
            event(
                #"{"jsonrpc":"2.0","method":"conversation.turn","#
                    + #""params":{"state":"listening","reason":"interrupted"}}"#
            ) == .turn(.listening)
        )
    }

    @Test("a transcript notification decodes to a whole utterance")
    func decodesTranscript() {
        #expect(
            event(
                #"{"jsonrpc":"2.0","method":"conversation.transcript","#
                    + #""params":{"role":"assistant","text":"Happy birthday.","final":true}}"#
            ) == .transcript(ConversationLine(role: .assistant, text: "Happy birthday.", isFinal: true))
        )
    }

    /// The app's own `_emit_transcript` defaults `final` to `True` and no call site
    /// passes anything else, so a frame that omits it is a whole utterance — not a
    /// fragment a reader should hold open waiting for its end.
    @Test("a transcript with no final flag is a whole utterance")
    func defaultsFinalToTrue() {
        guard case let .transcript(line)? = event(
            #"{"jsonrpc":"2.0","method":"conversation.transcript","params":{"role":"user","text":"Hello"}}"#
        ) else {
            Issue.record("expected a transcript event")
            return
        }
        #expect(line.isFinal)
    }

    /// The defensive path. Nothing sends this today; the flag is read so that a fork
    /// which starts streaming deltas is drawn as a line being written rather than as
    /// a burst of separate utterances.
    @Test("a non-final transcript is carried as non-final")
    func carriesNonFinal() {
        guard case let .transcript(line)? = event(
            #"{"jsonrpc":"2.0","method":"conversation.transcript","#
                + #""params":{"role":"user","text":"Hel","final":false}}"#
        ) else {
            Issue.record("expected a transcript event")
            return
        }
        #expect(!line.isFinal)
    }

    /// A future role reaches the transcript as itself. Dropping it would take an
    /// utterance out of the middle of a conversation with nothing said.
    @Test("an unknown role is carried rather than dropped")
    func carriesUnknownRole() {
        #expect(
            event(
                #"{"jsonrpc":"2.0","method":"conversation.transcript","#
                    + #""params":{"role":"tool","text":"ran a tool","final":true}}"#
            ) == .transcript(ConversationLine(role: .unknown("tool"), text: "ran a tool"))
        )
    }

    @Test("a level notification decodes to a drawable fraction")
    func decodesLevel() {
        #expect(
            event(#"{"jsonrpc":"2.0","method":"conversation.level","params":{"role":"user","rms":0.42}}"#)
                == .level(ConversationLevel(role: .user, rms: 0.42))
        )
    }

    /// The app clamps before sending, so this is belt and braces — but a meter is a
    /// width, and a value past one draws outside its track.
    @Test("a level past one is clamped")
    func clampsLevel() {
        #expect(
            event(#"{"jsonrpc":"2.0","method":"conversation.level","params":{"role":"user","rms":2.5}}"#)
                == .level(ConversationLevel(role: .user, rms: 1))
        )
    }

    /// An unreadable reading is no reading. The frame goes rather than reaching a
    /// meter as a zero somebody would read as silence.
    @Test("a level with no number in it drops the frame")
    func dropsUnreadableLevel() {
        #expect(event(#"{"jsonrpc":"2.0","method":"conversation.level","params":{"role":"user","rms":null}}"#) == nil)
    }

    /// `NaN` cannot arrive over the wire — `JSONCodec.daemon` leaves the
    /// non-conforming float strategy at `.throw` — so this pins the path that *can*
    /// happen: this client building one. `min`/`max` propagate `NaN` rather than
    /// clamping it, and a `NaN` reaching a meter's width is a layout crash.
    @Test("a non-finite level built in code is pinned to zero")
    func pinsNonFiniteLevel() {
        #expect(ConversationLevel(role: .user, rms: .nan).rms == 0)
        #expect(ConversationLevel(role: .user, rms: .infinity).rms == 1)
        #expect(ConversationLevel(role: .user, rms: -1).rms == 0)
    }

    /// `conversation.activity` is the raw backend reason the app's own web UI maps to
    /// an orb state itself. `conversation.turn` is that mapping done server-side, and
    /// its comment says it exists for clients like this one — so reading both would be
    /// reading one fact twice, out of step.
    @Test("the raw activity feed is ignored in favour of the mapped turn")
    func ignoresActivity() {
        #expect(
            event(
                #"{"jsonrpc":"2.0","method":"conversation.activity","#
                    + #""params":{"reason":"assistant_audio_delta"}}"#
            ) == nil
        )
    }

    /// `_emit_phase` is defined in the app and called from nowhere in it. A client
    /// that waited on this would wait forever.
    @Test("the dead phase notification is ignored")
    func ignoresPhase() {
        #expect(
            event(#"{"jsonrpc":"2.0","method":"conversation.phase","params":{"phase":"ready","reason":null}}"#)
                == nil
        )
    }

    /// A reply belongs to the caller that sent the request, not to this stream —
    /// which is what keeps a multiplexed socket's answers out of a transcript.
    @Test("a reply is not mistaken for a notification")
    func ignoresReplies() {
        #expect(event(#"{"jsonrpc":"2.0","id":7,"result":{"muted":true}}"#) == nil)
        #expect(event(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}"#) == nil)
    }

    @Test("a frame that is not JSON at all is ignored")
    func ignoresGarbage() {
        #expect(event("not json") == nil)
    }
}

/// The failure vocabulary both transports throw.
@Suite("Conversation failures")
struct ConversationFailureTests {
    /// The mapping that matters most, and it lives in one initialiser precisely so
    /// the LAN arm and the relay arm cannot disagree about it.
    @Test("-32601 is method-not-found on either path")
    func mapsMethodNotFound() {
        #expect(ConversationFailure(code: -32601, message: "Method not found", reason: nil) == .methodNotFound)
        #expect(
            ConversationFailure(relay: .rpc(code: -32601, message: "Method not found", reason: nil))
                == .methodNotFound
        )
    }

    /// The relay answers this when no app is running at all — a different screen from
    /// an app that is running and refusing.
    @Test("the relay's not-running is carried with its code")
    func mapsNotRunning() {
        let failure = ConversationFailure(
            relay: .rpc(code: -32000, message: "no app is running", reason: "not_running")
        )
        #expect(failure == .rejected(code: -32000, reason: .notRunning, message: "no app is running"))
        #expect(failure.reason == .notRunning)
    }

    @Test("the relay's app-unavailable is carried")
    func mapsAppUnavailable() {
        let failure = ConversationFailure(
            relay: .rpc(code: -32603, message: "app unavailable", reason: "app_unavailable")
        )
        #expect(failure.reason == .appUnavailable)
    }

    /// Not a failure yet: the backend takes up to ninety seconds to come up, and the
    /// app's own client retries this rather than reporting it.
    @Test("still-starting is a reason of its own")
    func mapsLoopUnavailable() {
        #expect(
            ConversationFailure(code: -32000, message: "still starting", reason: "loop_unavailable").reason
                == .loopUnavailable
        )
    }

    /// The set grows on the robot's side, so an unrecognised code reaches the screen
    /// as the robot's own word rather than as nothing.
    @Test("an unrecognised reason is carried as itself")
    func carriesUnknownReason() {
        #expect(
            ConversationFailure(code: -32000, message: "no", reason: "brand_new").reason == .unknown("brand_new")
        )
    }

    /// `.robot` has no code and never had one — the `{type, command}` protocol does
    /// not carry them. A zero here would be a number to branch on that no robot sent.
    @Test("a codeless relay failure carries no code")
    func keepsCodeOptional() {
        #expect(
            ConversationFailure(relay: .robot("the robot said no"))
                == .rejected(code: nil, reason: nil, message: "the robot said no")
        )
    }

    /// To a caller these are the same fact: the app cannot be reached.
    @Test("a closed channel is unreachable, not a timeout")
    func mapsClosed() {
        #expect(ConversationFailure(relay: .closed) == .unreachable)
        #expect(ConversationFailure(relay: .timedOut) == .timedOut)
    }
}
