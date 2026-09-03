import Foundation
import ReachyKit

/// What a ``ConversationTurn`` is called on screen.
///
/// A caption type rather than `String(describing:)` (project rule 9), and a shared one
/// rather than a copy per surface: the dock's strip and the conversation screen are both
/// on screen at once when the screen is open, and two mappings would be two chances for
/// them to claim the robot is in two states.
///
/// ``ConversationTurn/unknown(_:)`` carries the app's own word through untouched — a
/// future state should read as itself rather than as nothing (project rule 3).
enum ConversationTurnCaption {
    static func title(of turn: ConversationTurn) -> LocalizedStringResource {
        switch turn {
        case .listening: .reachy("Listening…")
        case .thinking: .reachy("Thinking…")
        case .speaking: .reachy("Speaking…")
        case .ready: .reachy("Ready")
        case let .unknown(state): "\(state)"
        }
    }

    /// What the state line says when the app has not reported a turn yet.
    ///
    /// Not "Ready", and the difference matters: the app emits a turn only on change and
    /// answers no read with one, so a client attaching mid-conversation legitimately
    /// knows nothing. Naming that is honest; guessing at a state would not be.
    static let unknown = LocalizedStringResource.reachy("Waiting for Reachy to say something")

    /// The microphone's state, said in words as well as drawn.
    ///
    /// The muted line names the consequence rather than the setting — what a reader
    /// wants to know is not that a flag is on but that the robot cannot hear the room.
    static func microphone(isMuted: Bool) -> LocalizedStringResource {
        isMuted ? .reachy("Mic off · Reachy can't hear the room") : .reachy("Reachy is listening to the room")
    }
}

/// The role captions above each utterance.
///
/// `You, typed` is its own caption rather than a decoration on `You`, because it is a
/// different claim: nobody said those words out loud, and the app injected them as a
/// prompt for the robot to answer.
enum TranscriptRoleCaption {
    static func title(of kind: TranscriptEntry.Kind) -> LocalizedStringResource? {
        switch kind {
        case let .spoken(role):
            switch role {
            case .user: .reachy("You")
            case .assistant: .reachy("Reachy")
            case let .unknown(other): "\(other)"
            }
        case .typed: .reachy("You, typed")
        case .gap, .ended: nil
        }
    }
}
