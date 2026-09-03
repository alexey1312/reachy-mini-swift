import ReachyDesign
import ReachyKit
import SwiftUI

/// What the running app is doing, in the one wording the dock and the expanded
/// sheet both use.
///
/// It lives in its own type rather than as a `private var` on the dock because two
/// surfaces render it: a user who reads "Stopping…" on the strip and "Running" in
/// the sheet has been told the robot is in two states at once.
///
/// A caption rather than a view of its own: the dock passes it to `AppRowLabel`,
/// which takes a `ReachyStatusLabel` and would have no use for a wrapper around
/// one. The shape of the label belongs to `ReachyDesign`; what belongs here is the
/// mapping from the daemon's process states onto a tone and a phrase.
///
/// The daemon's vocabulary is deliberately thin — five process states and nothing
/// about what the app is *doing*. A semantic state ("listening", "thinking") comes
/// from the app's own port and arrives separately from the daemon process state.
enum RunningAppCaption {
    /// Whether this caption is the only place the crash can be read.
    ///
    /// Not a matter of taste, and not a default worth having: the dock is one row
    /// with a single caption line under the app's name, so a crash there has to
    /// say that it happened and where the output is. It used to substitute the
    /// output itself, which put the first two lines of a stderr tail — a
    /// `Process exited with code 1` and half a traceback — in a strip nobody can
    /// read them in. The sheet prints the same output in full two rows below its
    /// state, and a caption repeating it there renders those two lines under a
    /// heading that promised a state.
    enum Failure {
        /// Say it crashed, and that the page has the output.
        case inline
        /// Keep the state phrase; the surface shows the output somewhere of its own.
        case shownSeparately
    }

    /// The dock's caption line, and the value of the sheet's `LabeledContent`.
    ///
    /// Two lines, because that is what the strip allows and what a crash needs.
    ///
    /// `@MainActor` because it builds a `View`, and `View` carries that isolation;
    /// the mappings below are plain values and stay off it.
    @MainActor
    static func label(
        of status: RobotAppStatus,
        failure: Failure,
        conversationTurn: ConversationTurn? = nil,
        isReachable: Bool = true,
        wedged: Bool = false,
        actionFailure: String? = nil,
        font: Font = Typography.status
    ) -> ReachyStatusLabel {
        let text = switch failure {
        case .inline: description(
                of: status,
                conversationTurn: conversationTurn,
                isReachable: isReachable,
                wedged: wedged,
                actionFailure: actionFailure
            )
        // No `actionFailure`: a surface that shows the crash separately has a slot
        // for the refusal too, and `AppDetailSheet` already prints it there.
        case .shownSeparately: title(
                of: status,
                conversationTurn: conversationTurn,
                isReachable: isReachable,
                wedged: wedged
            )
        }
        return ReachyStatusLabel(
            text: text,
            tone: tone(of: status, wedged: wedged, actionFailure: actionFailure),
            font: font,
            lineLimit: 2
        )
    }

    /// Only a crash is coloured, and a stuck transition. "Running" stays quiet: the
    /// strip is on screen solely because something is running, so saying it again in
    /// green would tell the reader nothing they cannot already see.
    ///
    /// A wedge is coloured for the opposite reason — nothing else on screen says
    /// this stopped being a normal transition minutes ago.
    static func tone(
        of status: RobotAppStatus,
        wedged: Bool = false,
        actionFailure: String? = nil
    ) -> StatusTone {
        status.state == .error || wedged || actionFailure != nil ? .failed : .idle
    }

    /// The state in one phrase, with no failure detail. What the sheet puts in a
    /// `LabeledContent`, where the traceback gets a row of its own.
    ///
    /// A resolved `String` rather than a `LocalizedStringResource`, and that is
    /// forced rather than chosen: `.unknown(state)` carries the daemon's own word
    /// for a state this build has never heard of, and `description(of:)` below
    /// substitutes a traceback. A slot that has to hold a runtime string alongside
    /// a translated phrase resolves the phrase; it cannot stay a resource.
    static func title(
        of status: RobotAppStatus,
        conversationTurn: ConversationTurn? = nil,
        isReachable: Bool = true,
        wedged: Bool = false
    ) -> String {
        guard isReachable else { return String(localized: .reachy("Robot unreachable")) }
        // Ahead of everything below, including the conversation turn: once the robot
        // is stuck, what the app was last heard doing is no longer the news.
        if wedged {
            return stuck(in: status.state)
        }
        if status.state == .running, let conversationTurn {
            return title(of: conversationTurn)
        }
        return switch status.state {
        case .starting: String(localized: .reachy("Starting…"))
        case .running: String(localized: .reachy("Running"))
        case .stopping: String(localized: .reachy("Stopping…"))
        case .done: String(localized: .reachy("Finished"))
        case .error: String(localized: .reachy("Stopped with an error"))
        // Carried through rather than replaced with "Unknown": a later daemon's
        // own word for the state is more use than ours (project rule 3).
        case let .unknown(state): state
        }
    }

    /// Which transition ran out of time. Its own function rather than a nested
    /// switch, which put `title(of:)` over SwiftLint's cyclomatic limit — and the two
    /// phrases have to differ: a stuck start and a stuck stop leave the robot in
    /// different places and ask different things of the reader.
    private static func stuck(in state: RobotAppStatus.State) -> String {
        switch state {
        case .stopping: String(localized: .reachy("Stuck stopping"))
        case .starting: String(localized: .reachy("Stuck starting"))
        // Unreachable — only those two states are ever timed — but a `default` here
        // would silently caption a future timed state as its normal self.
        case .running, .done, .error, .unknown: String(localized: .reachy("Stuck"))
        }
    }

    /// Delegated rather than duplicated: the dock's strip and the conversation screen
    /// are on screen together whenever that screen is open, and two copies of this
    /// mapping would be two chances for them to say the robot is in two states at once.
    /// The keys are the same literals, so the catalogue is unchanged.
    private static func title(of turn: ConversationTurn) -> String {
        String(localized: ConversationTurnCaption.title(of: turn))
    }

    /// The same, with the failure inlined — `Failure.inline`, and only that.
    /// The dock has one caption line and no room for a second row, so a crash says
    /// so in one phrase and sends the reader to the page, where the output is.
    /// `actionFailure` is the daemon's answer to a Stop or Restart the user just
    /// tapped, and it belongs here for the same reason the crash tail does: the dock
    /// has one caption line, so a refusal shown nowhere is a refusal shown nowhere.
    /// It used to be exactly that — the dock rendered no error at all, and the next
    /// poll then removed the dock, which reads as the Stop having worked.
    ///
    /// Precedence, most important first: a crash, a wedge, the refusal, the state.
    /// A wedge outranks the refusal because it is the durable truth — and because
    /// the two say nearly the same thing, while only one of them leads anywhere.
    static func description(
        of status: RobotAppStatus,
        conversationTurn: ConversationTurn? = nil,
        isReachable: Bool = true,
        wedged: Bool = false,
        actionFailure: String? = nil
    ) -> String {
        guard isReachable else { return title(of: status, isReachable: false) }
        if status.state == .error, status.error != nil {
            return String(localized: .reachy("Crashed — open for details"))
        }
        if !wedged, let actionFailure {
            return actionFailure
        }
        return title(of: status, conversationTurn: conversationTurn, wedged: wedged)
    }
}
