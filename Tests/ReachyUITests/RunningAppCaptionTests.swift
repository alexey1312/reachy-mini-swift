import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// What the dock and the sheet *say* about a running app, as opposed to when they
/// say anything at all (`RunningAppModelTests`). Split off because the caption is a
/// pure mapping over a status and a turn — it needs no model, no session and no
/// client — and because the two together no longer fit one file.
@MainActor
@Suite("Running app caption", .timeLimit(.minutes(1)))
struct RunningAppCaptionTests {
    private static let app = RobotApp.previewInstalled[0]
    private static let conversationApp = RobotApp.previewConversation

    private func status(_ state: RobotAppStatus.State, error: String? = nil) -> RobotAppStatus {
        RobotAppStatus(app: Self.app, state: state, error: error)
    }

    @Test("conversation captions use the released semantic vocabulary", arguments: [
        (ConversationTurn.listening, "Listening…"),
        (.thinking, "Thinking…"),
        (.speaking, "Speaking…"),
        (.ready, "Ready"),
        (.unknown("waiting_for_tool"), "waiting_for_tool"),
    ])
    func semanticCaption(turn: ConversationTurn, caption: String) {
        let conversation = RobotAppStatus(app: Self.conversationApp, state: .running)
        #expect(RunningAppCaption.title(of: conversation, conversationTurn: turn) == caption)
    }

    @Test("process transitions and reachability still take precedence")
    func processStatePrecedesConversationTurn() {
        let stopping = RobotAppStatus(app: Self.conversationApp, state: .stopping)
        let running = RobotAppStatus(app: Self.conversationApp, state: .running)

        #expect(RunningAppCaption.title(of: stopping, conversationTurn: .speaking) == "Stopping…")
        #expect(RunningAppCaption.title(
            of: running,
            conversationTurn: .speaking,
            isReachable: false
        ) == "Robot unreachable")
    }

    /// The daemon's `error` is a stderr tail. The state phrase never carries it,
    /// and the dock's caption says only that the app crashed and where to read
    /// the output — two lines of traceback in a strip were not readable there.
    @Test("a crash is named in the caption and never in the state phrase")
    func crashStaysOutOfTheStatePhrase() {
        let tail = """
        Process exited with code 1
        Traceback (most recent call last):
        ModuleNotFoundError: No module named 'cv2'
        """
        let crashed = status(.error, error: tail)

        #expect(RunningAppCaption.title(of: crashed) == "Stopped with an error")
        #expect(RunningAppCaption.description(of: crashed) == String(localized: .reachy("Crashed — open for details")))
        #expect(!RunningAppCaption.description(of: crashed).contains(tail))
    }

    /// **"Stopping…" for a slot the robot will never release is the lie the
    /// 2026-08-08 incident was read through.** Both surfaces have to name it, and
    /// name which transition it was — a stuck start and a stuck stop need different
    /// things from the reader.
    @Test("a stuck transition says so on both surfaces")
    func wedgeIsNamed() {
        #expect(RunningAppCaption.title(of: status(.stopping), wedged: true) == "Stuck stopping")
        #expect(RunningAppCaption.title(of: status(.starting), wedged: true) == "Stuck starting")
        #expect(RunningAppCaption.description(of: status(.stopping), wedged: true) == "Stuck stopping")
    }

    /// The conversation app keeps reporting turns over its own socket until its
    /// process dies, and the process is already dead here. "Speaking…" over a robot
    /// nobody can free is the least useful true thing on the screen.
    @Test("a stuck transition outranks whatever the app last said")
    func wedgePrecedesConversationTurn() {
        let stopping = RobotAppStatus(app: Self.conversationApp, state: .stopping)

        #expect(RunningAppCaption.title(of: stopping, conversationTurn: .speaking, wedged: true) == "Stuck stopping")
    }

    /// A crash outranks a wedge: `error` is terminal and carries the app's own last
    /// words, which are worth more than the fact that a transition timed out.
    @Test("a crash still wins, and unreachable wins over everything")
    func crashAndUnreachableOutrankTheWedge() {
        let crashed = status(.error, error: "Process exited with code 1")

        #expect(RunningAppCaption
            .description(of: crashed, wedged: true) == String(localized: .reachy("Crashed — open for details")))
        #expect(RunningAppCaption.title(of: status(.stopping), isReachable: false, wedged: true) == "Robot unreachable")
    }

    /// The dock renders no error slot of its own, so a refused Stop had nowhere to go
    /// and the next poll then removed the dock — which reads as the Stop having
    /// worked. It goes in the one caption line, below a wedge and above the state.
    @Test("a refused action is readable in the dock's one line")
    func refusalIsInlined() {
        let refusal = "No app is currently running (HTTP 400)"

        #expect(RunningAppCaption.description(of: status(.running), actionFailure: refusal) == refusal)
        #expect(RunningAppCaption.description(
            of: status(.stopping),
            wedged: true,
            actionFailure: refusal
        ) == "Stuck stopping")
        // The sheet prints refusals in a slot of its own, so the state phrase stays.
        #expect(RunningAppCaption.title(of: status(.running)) == "Running")
    }

    @Test("a stuck transition is coloured like a failure, because it is one")
    func wedgeIsToned() {
        #expect(RunningAppCaption.tone(of: status(.stopping)) == .idle)
        #expect(RunningAppCaption.tone(of: status(.stopping), wedged: true) == .failed)
        #expect(RunningAppCaption.tone(of: status(.running), actionFailure: "refused") == .failed)
    }
}
