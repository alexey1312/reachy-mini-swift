import Foundation
@testable import ReachyUI
import Testing

/// Records what the model asked the seam, and lets a test drive a re-entrant call
/// without any scheduling.
@MainActor
private final class RespondSpy {
    private(set) var calls = 0
    private(set) var prompts: [String] = []
    var answer = "a summary"
    var error: (any Error)?
    /// Set after construction, so the stub can call back into the model it belongs to.
    var model: LogExplanationModel?
    var reentrantCalls = 0

    func respond(_: String, _ prompt: String) async throws -> String {
        calls += 1
        prompts.append(prompt)
        if let model {
            // Re-entrant, while the phase is `.explaining`. Must be refused.
            await model.explain([LogEntry(id: 0, raw: "again")])
            reentrantCalls = calls - 1
        }
        if let error {
            throw error
        }
        return answer
    }
}

@MainActor
@Suite("Log explanation model")
struct LogExplanationModelTests {
    private func entries(_ lines: [String]) -> [LogEntry] {
        lines.enumerated().map { LogEntry(id: $0.offset, raw: $0.element) }
    }

    private func model(
        _ availability: ModelAvailability = .available,
        spy: RespondSpy? = nil
    ) -> LogExplanationModel {
        let spy = spy ?? RespondSpy()
        return LogExplanationModel(availability: { availability }, respond: { try await spy.respond($0, $1) })
    }

    // MARK: - The gate

    /// The branch that must *not* run: an unavailable model means the seam is never
    /// reached at all, not that it is reached and its answer discarded.
    @Test("a gate that says no keeps the feature off the screen and never asks the model")
    func unavailableNeverAsks() async {
        let spy = RespondSpy()
        let model = model(.deviceNotEligible, spy: spy)

        #expect(model.isOffered == false)
        await model.explain(entries(["ERROR something"]))
        #expect(spy.calls == 0)
    }

    @Test("every unavailable reason hides the feature")
    func everyUnavailableReasonHides() {
        let reasons: [ModelAvailability] = [
            .unsupportedSystem, .deviceNotEligible, .appleIntelligenceNotEnabled,
            .modelNotReady, .unavailableForAnotherReason,
        ]
        let offered = reasons.map { model($0).isOffered }.filter(\.self)
        #expect(offered.isEmpty)
    }

    /// Assets finish downloading with nothing to tell the app, so the entry point has
    /// to be able to appear without a relaunch.
    @Test("a model that becomes ready is offered on the next refresh")
    func becomesOfferedWhenReady() {
        var answer = ModelAvailability.modelNotReady
        let model = LogExplanationModel(availability: { answer }, respond: { _, _ in "" })
        #expect(model.isOffered == false)

        answer = .available
        model.refresh()
        #expect(model.isOffered)
        #expect(model.phase == .idle)
    }

    /// And the reverse: Apple Intelligence switched off between visits takes it away
    /// again rather than leaving a button that can only fail.
    @Test("a model that goes away is withdrawn on the next refresh")
    func withdrawnWhenNoLongerAvailable() {
        var answer = ModelAvailability.available
        let model = LogExplanationModel(availability: { answer }, respond: { _, _ in "" })
        #expect(model.isOffered)

        answer = .appleIntelligenceNotEnabled
        model.refresh()
        #expect(model.phase == .unavailable(.appleIntelligenceNotEnabled))
    }

    // MARK: - Running

    @Test("a successful run reports the summary and what it was made from")
    func explainsAndReportsCoverage() async {
        let spy = RespondSpy()
        spy.answer = "It shows a failure."
        let model = model(spy: spy)

        await model.explain(entries(["ERROR boom", "INFO fine"]), filterSummary: "errors only")

        guard case let .explained(explanation) = model.phase else {
            Issue.record("expected an explanation, got \(model.phase)")
            return
        }
        #expect(explanation.text == "It shows a failure.")
        #expect(explanation.coverage.totalLines == 2)
        #expect(explanation.filterSummary == "errors only")
    }

    /// The model is handed a frozen corpus, so a line the reader filtered out cannot
    /// reach the prompt by any route.
    @Test("only the entries it was handed reach the prompt")
    func sendsOnlyWhatItWasGiven() async {
        let spy = RespondSpy()
        let model = model(spy: spy)

        await model.explain(entries(["visible line", "ERROR visible failure"]))

        #expect(spy.prompts.count == 1)
        #expect(spy.prompts[0].contains("visible failure"))
        #expect(spy.prompts[0].contains("filtered away") == false)
    }

    /// Deterministic rather than timed: the stub calls back into the model while the
    /// phase is `.explaining`, so the guard is exercised with no scheduling at all.
    @Test("a second request while one is running is refused")
    func secondRequestIsRefused() async {
        let spy = RespondSpy()
        let model = model(spy: spy)
        spy.model = model

        await model.explain(entries(["ERROR boom"]))

        #expect(spy.calls == 1)
        #expect(spy.reentrantCalls == 0)
    }

    // MARK: - Failing

    @Test("a failure lands in its own slot, with the framework's own sentence")
    func failureLandsInItsOwnSlot() async {
        struct Boom: LocalizedError {
            var errorDescription: String? {
                "the model declined"
            }
        }
        let spy = RespondSpy()
        spy.error = Boom()
        let model = model(spy: spy)

        await model.explain(entries(["ERROR boom"]))

        #expect(model.phase == .failed("the model declined"))
    }

    /// A dismissed sheet cancels the task, and that must not paint a failure nobody
    /// asked about — the rule `SystemUpdateModel.fail(on:)` keeps in its own way.
    @Test("a cancelled run goes quiet rather than reporting a failure")
    func cancellationIsSilent() async {
        let spy = RespondSpy()
        spy.error = CancellationError()
        let model = model(spy: spy)

        await model.explain(entries(["ERROR boom"]))

        #expect(model.phase == .idle)
    }

    /// **The regression this exists for was found in a reference, not a test.** The
    /// screen refreshes the gate from a `.task`, and Prefire renders one preview
    /// instance twice — light, then dark. A factory whose stub gate disagreed with the
    /// phase it seeded therefore produced a light capture with no button and a dark
    /// one with it, from the same preview. Every seeded phase has to survive the
    /// effect the screen will run over it.
    @Test("a seeded preview phase survives the refresh the screen fires over it")
    func previewPhasesSurviveARefresh() {
        let phases: [LogExplanationModel.Phase] = [
            .idle,
            .unavailable(.deviceNotEligible),
            .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.unsupportedSystem),
            .explained(LogExplanationModel.previewExplanation),
            .failed("nope"),
        ]
        for phase in phases {
            let model = LogExplanationModel.preview(phase)
            let before = model.isOffered
            model.refresh()
            #expect(model.isOffered == before, "\(phase) changed its mind when refreshed")
        }
    }

    /// A run in flight must not be withdrawn underneath itself by a refresh the
    /// screen's own `.task` fires.
    @Test("a refresh during a run leaves the run alone")
    func refreshDoesNotDisturbARun() async {
        var answer = ModelAvailability.available
        let spy = RespondSpy()
        let model = LogExplanationModel(
            availability: { answer },
            respond: { _, prompt in
                answer = .modelNotReady
                return try await spy.respond("", prompt)
            }
        )

        await model.explain(entries(["ERROR boom"]))

        guard case .explained = model.phase else {
            Issue.record("expected the run to survive, got \(model.phase)")
            return
        }
    }
}
