import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The record itself: what lands in it, what replaces what, and what happens at its
/// boundaries. Split from `ConversationModelTests` when that file reached SwiftLint's
/// 400-line limit.
///
/// The transcript is the one thing in this app that cannot be fetched again from
/// anywhere — the robot keeps no history — so most of these are about not losing it.
@MainActor
@Suite("Conversation transcript")
struct ConversationTranscriptTests {
    private func model(capacity: Int = 2000) -> ConversationModel {
        var configuration = ConversationModel.Configuration()
        configuration.capacity = capacity
        return ConversationModel(
            configuration: configuration,
            events: { _, _ in AsyncStream { $0.finish() } },
            readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
            readMicrophone: { _, _ in false },
            setMicrophone: { _, _, muted in muted },
            interruptConversation: { _, _ in },
            say: { _, _, _ in }
        )
    }

    // MARK: The transcript

    @Test("one transcript notification is one row")
    func appendsUtterances() {
        let model = model()

        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))
        model.receive(.transcript(ConversationLine(role: .assistant, text: "Hello yourself")))

        #expect(model.entries.count == 2)
        #expect(model.entries.map(\.text) == ["Hello", "Hello yourself"])
        #expect(model.hasTranscript)
    }

    /// The defensive path. Nothing sends a non-final line today — the app's two emission
    /// sites both pass `final: true` — but a fork that streamed deltas would otherwise
    /// draw a staircase of growing prefixes instead of one sentence being written.
    @Test("a non-final line is replaced rather than followed")
    func replacesNonFinalLines() {
        let model = model()

        model.receive(.transcript(ConversationLine(role: .user, text: "Hel", isFinal: false)))
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello", isFinal: false)))
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello there", isFinal: true)))

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.text == "Hello there")
    }

    /// Only of the same role: the other speaker starting is a new row, whatever the state
    /// of the last one.
    @Test("a non-final line from the other role does not replace it")
    func keepsNonFinalLinesOfAnotherRole() {
        let model = model()

        model.receive(.transcript(ConversationLine(role: .user, text: "Hel", isFinal: false)))
        model.receive(.transcript(ConversationLine(role: .assistant, text: "Yes?")))

        #expect(model.entries.count == 2)
    }

    @Test("past the cap the oldest rows go and the tail is intact")
    func trimsToCapacity() {
        let model = model(capacity: 3)

        for index in 0 ..< 5 {
            model.receive(.transcript(ConversationLine(role: .user, text: "line \(index)")))
        }

        #expect(model.entries.count == 3)
        #expect(model.entries.map(\.text) == ["line 2", "line 3", "line 4"])
    }

    // MARK: Gaps

    /// The robot keeps no history, so a dropped feed is a hole nothing can fill. Saying
    /// so is the only honest thing to draw there.
    @Test("a dropped feed leaves one gap in the record")
    func marksTheGap() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))

        model.receive(.closed)

        #expect(model.phase == .interrupted)
        #expect(model.entries.count == 2)
        if case .gap = model.entries.last?.kind {} else {
            Issue.record("expected a gap row")
        }
    }

    /// A second close with nothing in between describes the same hole. Two markers would
    /// claim two.
    @Test("a second close with nothing between adds no second gap")
    func marksOneGapPerInterruption() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))
        model.receive(.closed)

        model.receive(.closed)

        #expect(model.entries.count == 2)
    }

    /// Nothing was recorded, so nothing was missed. A gap over an empty transcript would
    /// be this app inventing a loss.
    @Test("a feed that dropped before anything was said leaves no gap")
    func marksNoGapWithNothingRecorded() {
        let model = model()
        model.receive(.opened)

        model.receive(.closed)

        #expect(model.entries.isEmpty)
    }

    /// A frame arriving is the conversation demonstrably working, whatever the previous
    /// failure suggested — so it is the one thing that promotes the phase upward.
    @Test("a frame after an interruption puts the conversation back")
    func recoversOnTheNextFrame() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))
        model.receive(.closed)
        #expect(model.phase == .interrupted)

        model.receive(.turn(.listening))

        #expect(model.phase == .live)
    }

    // MARK: The record

    /// The transcript cannot be fetched again from anywhere, so it is kept and the
    /// ending is appended to it. Discarding a record to show a sentence already on it
    /// would be the worse of the two wrongs.
    @Test("an app that stopped keeps the transcript and says where it ends")
    func keepsTheRecordWhenTheAppStops() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))

        model.noteAppEnded()

        #expect(model.phase == .unavailable(.appStopped))
        #expect(model.entries.count == 2)
        #expect(model.entries.first?.text == "Hello")
        #expect(model.entries.last?.kind == .ended(.appStopped))
    }

    @Test("a second ending adds no second row")
    func endsOnlyOnce() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))

        model.noteAppEnded()
        model.noteAppEnded()

        #expect(model.entries.count == 2)
    }

    /// **Deliberately not localised.** A record leaving the app has to be diffable and
    /// searchable, and speaker labels that change with the phone's language are not.
    @Test("the exported transcript names its speakers and drops the commentary")
    func exportsUtterancesOnly() {
        let model = model()
        model.receive(.opened)
        model.receive(.transcript(ConversationLine(role: .user, text: "Hello")))
        model.receive(.transcript(ConversationLine(role: .assistant, text: "Hello yourself")))
        model.appendTyped("happy birthday")
        model.receive(.closed)

        #expect(model.transcriptText == """
        You: Hello
        Reachy: Hello yourself
        You (typed): happy birthday
        """)
    }
}
