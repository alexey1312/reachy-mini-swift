import Foundation
import Observation
import ReachyDesign

/// One explanation, and what it was made from.
struct LogExplanation: Equatable, Sendable {
    var text: String
    var coverage: LogExcerpt.Coverage
    /// The console's own words for the filter in force, reused verbatim so the sheet
    /// cannot describe the same filter differently from the status bar above it.
    var filterSummary: String?
}

/// Reads what is on screen and asks the on-device model what it shows.
///
/// The `SystemUpdateModel` shape — a state enum plus collaborators injected as
/// closures with `nil` defaults resolved in the body — because a default argument is
/// evaluated in a nonisolated context. Both seams exist so this can be driven on a Mac
/// with no Apple Intelligence, which is what `mise run test` and every preview are.
@MainActor
@Observable
final class LogExplanationModel {
    enum Phase: Equatable {
        /// The gate said no. **Not a failure**: it offers no retry, reports no error,
        /// and takes the entry point off the screen entirely — the shape
        /// `RobotHealthModel.Phase.unavailable` already has for "no route, and nothing
        /// to be done about it". It carries the reason so `refresh()` can notice
        /// `.modelNotReady` turning into `.available`.
        case unavailable(ModelAvailability)
        case idle
        case explaining
        case explained(LogExplanation)
        /// A Foundation Models failure is not a daemon failure, so it carries its own
        /// message rather than going through `recordDaemonFailure` — the same reason
        /// `OnboardingModel` and `HFSignInModel` keep their own.
        case failed(String)
    }

    typealias ReadAvailability = @MainActor () -> ModelAvailability
    typealias Respond = @MainActor (_ instructions: String, _ prompt: String) async throws -> String

    private(set) var phase: Phase

    private let readAvailability: ReadAvailability
    private let respond: Respond
    private let budget: LogExcerpt.Budget

    init(
        availability: ReadAvailability? = nil,
        respond: Respond? = nil,
        budget: LogExcerpt.Budget = .default
    ) {
        let read = availability ?? { OnDeviceLanguageModel.availability() }
        readAvailability = read
        self.respond = respond ?? { try await OnDeviceLanguageModel.respond(instructions: $0, prompt: $1) }
        self.budget = budget
        let now = read()
        phase = now == .available ? .idle : .unavailable(now)
    }

    /// What the toolbar item asks. False for every unavailable reason, which is the
    /// issue's own rule: the feature does not appear rather than appearing greyed out
    /// with an explanation nobody asked for.
    var isOffered: Bool {
        if case .unavailable = phase {
            false
        } else {
            true
        }
    }

    var isBusy: Bool {
        phase == .explaining
    }

    /// Re-reads the gate. Called on every appearance, because `.modelNotReady` becomes
    /// `.available` while the assets finish downloading and nothing exists to tell us.
    /// A run in flight is left alone.
    func refresh() {
        guard !isBusy else { return }
        let now = readAvailability()
        switch (now, phase) {
        case (.available, .unavailable):
            phase = .idle
        case (.available, _):
            break
        default:
            phase = .unavailable(now)
        }
    }

    /// One run over a frozen excerpt.
    ///
    /// Takes `[LogEntry]` by value rather than the console's model: the corpus must not
    /// change under the reader while the model is generating, and a test needs no
    /// console to drive this.
    func explain(_ entries: [LogEntry], filterSummary: String? = nil) async {
        guard !isBusy, isOffered else { return }
        phase = .explaining
        let excerpt = LogExcerpt.build(from: entries, budget: budget)
        do {
            let text = try await respond(LogExplanationPrompt.instructions, LogExplanationPrompt.prompt(for: excerpt))
            phase = .explained(
                LogExplanation(text: text, coverage: excerpt.coverage, filterSummary: filterSummary)
            )
        } catch {
            phase = Self.outcome(of: error)
        }
    }

    /// A dismissed sheet cancels the task, and a cancellation must not paint a failure
    /// nobody asked about — the rule `SystemUpdateModel.fail(on:)` keeps by refusing to
    /// assign at all.
    ///
    /// Everything else takes the framework's own sentence. `GenerationError` conforms
    /// to `LocalizedError`, so `localizedDescription` is already a real sentence, and
    /// naming its cases to substitute our own would mean naming a type the 27 SDK
    /// deprecates for the sake of copy the SDK already writes.
    private static func outcome(of error: any Error) -> Phase {
        if error is CancellationError || Task.isCancelled {
            return .idle
        }
        return .failed(error.localizedDescription)
    }
}

#if DEBUG
    extension LogExplanationModel {
        /// A model already in its end state. In this file rather than in `Previews/`
        /// because `phase` is `private(set)`, the same reason `PermissionsModel.preview`
        /// lives beside its type.
        ///
        /// **The gate is derived from the phase rather than fixed, and that is not
        /// tidiness.** The screen calls `refresh()` from a `.task`, so a stub that
        /// always answered `.available` would overwrite a seeded `.unavailable` the
        /// moment the effect ran — and Prefire renders one instance twice, light then
        /// dark. The light capture would show no button and the dark one would show it,
        /// from the same preview. Measured, not reasoned about: that is exactly what
        /// eighteen dark references did before this line.
        static func preview(_ phase: Phase) -> LogExplanationModel {
            let gate: ModelAvailability = if case let .unavailable(reason) = phase {
                reason
            } else {
                .available
            }
            let model = LogExplanationModel(
                availability: { gate },
                respond: { _, _ in "" }
            )
            model.phase = phase
            return model
        }

        /// A summary that reads like one the model would actually return, so the
        /// reference shows real wrapping rather than lorem ipsum.
        static var previewExplanation: LogExplanation {
            LogExplanation(
                text: """
                This excerpt shows a failure. The daemon's app manager crashed while starting an app.

                - The app process exited during start-up. The line that shows it is \
                "ERROR reachy_mini.apps: Traceback (most recent call last)".
                - The WebRTC producer never registered afterwards, so the camera stayed dark.

                Next steps:
                - Restart the app from the Apps tab and watch the log for the same traceback.
                - If it repeats, reinstall the app — the excerpt does not say which dependency failed.
                """,
                coverage: LogExcerpt.Coverage(
                    includedLines: 180,
                    totalLines: 5000,
                    omittedLines: 4820,
                    clampedLines: 1
                ),
                filterSummary: nil
            )
        }
    }
#endif
