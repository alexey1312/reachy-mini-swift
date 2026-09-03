import Foundation
import ReachyKit

/// One row of the transcript.
///
/// A wrapper around ``ConversationLine`` rather than that type itself, for two
/// reasons. The wire carries no identity, so a `List` needs one minted here — and
/// minting it in the domain type would put a value in it that two decodes of the same
/// frame disagree about. And the transcript holds rows the robot never sent: what this
/// client typed, and the seams where the record has a hole in it.
struct TranscriptEntry: Identifiable, Equatable {
    /// What kind of row this is, which decides both how it reads and whether it can
    /// be replaced by a later frame.
    enum Kind: Equatable {
        /// Something said out loud, and transcribed by the app.
        case spoken(ConversationRole)
        /// Something this client sent with `conversation.say`.
        ///
        /// **Its own kind rather than a `.spoken(.user)`, because it is not speech.**
        /// The app injects the text as a user message and asks the model to answer it;
        /// nobody said it, it is never transcribed, and it would otherwise be the one
        /// row in the transcript that claims to be a recording and is not.
        case typed
        /// The feed stopped and started again. What was said in between is lost — the
        /// robot keeps no history — so this is the only honest thing to draw there.
        case gap
        /// The conversation ended here, and why.
        case ended(Ending)
    }

    enum Ending: Equatable {
        case appStopped
        case feedLost
    }

    let id = UUID()
    let kind: Kind
    let text: String
    /// Whether the app has finished this utterance. Always true on the wire today; a
    /// non-final row is replaceable by the next one of the same role.
    let isFinal: Bool

    init(kind: Kind, text: String, isFinal: Bool = true) {
        self.kind = kind
        self.text = text
        self.isFinal = isFinal
    }

    init(_ line: ConversationLine) {
        self.init(kind: .spoken(line.role), text: line.text, isFinal: line.isFinal)
    }

    /// Whether a newly arrived line should replace this row rather than follow it.
    ///
    /// Only a non-final row of the same role, which is a state nothing produces today
    /// — the app's two emission sites both send `final: true`. It costs one comparison
    /// and covers a fork that starts streaming deltas, where appending instead would
    /// draw a staircase of growing prefixes.
    func isSuperseded(by line: ConversationLine) -> Bool {
        guard case let .spoken(role) = kind else { return false }
        return !isFinal && role == line.role
    }

    /// Rows a person said or the robot said, which is what a summary or an export is
    /// about — the seams and endings are this client's own commentary.
    var isUtterance: Bool {
        switch kind {
        case .spoken, .typed: true
        case .gap, .ended: false
        }
    }
}

extension TranscriptEntry {
    /// How a row is prefixed when the transcript leaves this app — copied, shared, or
    /// handed to something that summarises it.
    ///
    /// Deliberately **not** localised. This is a record leaving the app, and a
    /// transcript whose speaker labels change with the phone's language is one that
    /// cannot be diffed, searched or pasted beside another. The on-screen captions are
    /// localised; these are data.
    static func exportPrefix(for kind: Kind) -> String {
        switch kind {
        case let .spoken(role):
            switch role {
            case .user: "You: "
            case .assistant: "Reachy: "
            case let .unknown(other): "\(other): "
            }
        case .typed: "You (typed): "
        case .gap, .ended: ""
        }
    }
}
