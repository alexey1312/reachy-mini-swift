import Foundation
@testable import ReachyUI
import Testing

/// Every test builds its own inbox rather than reaching for `shared`: `--parallel`
/// runs suites concurrently in one process, and a process-global mailbox two suites
/// both post into is a flake waiting for a loaded runner.
@Suite("App search inbox")
@MainActor
struct AppSearchInboxTests {
    @Test("a request arrives as something the shell can notice")
    func filesARequest() {
        let inbox = AppSearchInbox()

        inbox.receive(term: "chess")

        #expect(inbox.pending?.term == "chess")
    }

    /// SwiftUI notices a *change*, so the second of two identical searches has to
    /// carry a different value or `onChange` never fires for it — the bug
    /// `QuickActionInbox`'s token was written for, in a third place.
    @Test("two identical searches arrive as two values")
    func distinguishesRepeatedRequests() throws {
        let inbox = AppSearchInbox()

        inbox.receive(term: "chess")
        let first = try #require(inbox.pending)
        inbox.receive(term: "chess")
        let second = try #require(inbox.pending)

        #expect(first != second)
        #expect(second.term == first.term)
    }

    /// A term of spaces would select the Apps tab and change nothing, which reads
    /// as a search that failed rather than as one nobody made.
    @Test("a blank term is not a search")
    func refusesABlankTerm() {
        let inbox = AppSearchInbox()

        inbox.receive(term: "   \n ")

        #expect(inbox.pending == nil)
    }

    @Test("surrounding whitespace is not part of what was asked for")
    func trimsTheTerm() {
        let inbox = AppSearchInbox()

        inbox.receive(term: "  chess  ")

        #expect(inbox.pending?.term == "chess")
    }

    /// Spent rather than left standing: a request that survived being honoured
    /// would re-fill a field the reader has since cleared, every time they came
    /// back to the tab.
    @Test("an honoured request is spent")
    func dropsAnHonouredRequest() {
        let inbox = AppSearchInbox()
        inbox.receive(term: "chess")

        inbox.drop()

        #expect(inbox.pending == nil)
    }

    /// The shell reads this with `initial: true`, so a request made while the
    /// connect gate was up is still there on the frame the shell first appears.
    /// Nothing expires it — unlike a call request, filling a field opens nothing.
    @Test("a request waits rather than expiring")
    func waitsForAReader() {
        let inbox = AppSearchInbox()

        inbox.receive(term: "chess")

        #expect(inbox.pending?.term == "chess")
    }
}
