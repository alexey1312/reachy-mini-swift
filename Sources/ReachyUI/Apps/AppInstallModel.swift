import Foundation
import Observation
import ReachyDesign
import ReachyKit

/// Drives one install, update or removal from the moment the daemon accepts the
/// job to the moment there is something honest to tell the user.
///
/// The daemon answers all three with a job id straight away and reports the work
/// out of band, so nothing here can be learned from an HTTP status: a job that
/// fails still returns 200, and a job whose daemon restarted stops existing
/// altogether. `AppJobMonitor` reconciles the socket and the poll; this turns its
/// four outcomes into four things a screen can say.
@MainActor
@Observable
final class AppInstallModel {
    enum Operation: Equatable {
        case install(RobotApp)
        case update(RobotApp)
        case remove(RobotApp)

        var app: RobotApp {
            switch self {
            case let .install(app), let .update(app), let .remove(app): app
            }
        }

        /// One whole sentence per case (a sentence is one key): a translator
        /// cannot reorder an English fragment interpolated into a format string.
        var progressCaption: LocalizedStringResource {
            switch self {
            case let .install(app): .reachy("Installing \(app.title)…")
            case let .update(app): .reachy("Updating \(app.title)…")
            case let .remove(app): .reachy("Removing \(app.title)…")
            }
        }

        var notificationKind: JobNotificationPlan.Kind {
            switch self {
            case .install: .appInstall
            case .update: .appUpdate
            case .remove: .appRemove
            }
        }

        /// Upstream's budgets, which are what the robot was tested against.
        var configuration: AppJobMonitor.Configuration {
            switch self {
            case .install: .install
            case .update: .update
            case .remove: .removal
            }
        }
    }

    enum State: Equatable {
        case idle
        case running(Operation)
        case succeeded(Operation)
        case failed(Operation, String)
        /// The daemon restarted mid-job and took its job register with it. The work
        /// may well have finished — the installed list is the only way to know.
        case daemonRestarted(Operation)
    }

    private(set) var state: State = .idle
    /// Shared with `LogConsoleView`, so `uv pip install` output gets the same
    /// filter, pause and export the daemon journal has.
    let log = LogConsoleModel()

    private let session: RobotSession
    /// The one step a stubbed client cannot drive: it opens a WebSocket and polls
    /// alongside it. Injected by tests and previews.
    private let makeEvents: (String, AppJobMonitor.Configuration) throws -> AsyncStream<AppJobMonitor.Event>
    /// How this model tells anyone a long job began and ended. A closure, so nothing
    /// here imports `UserNotifications`; the default is resolved in the body rather
    /// than in the signature, because a default argument is evaluated in a nonisolated
    /// context.
    private let notify: JobNotify
    /// The job in flight, captured when it starts, so a rename or a reconnection
    /// midway cannot change what the announcement is about.
    private var pending: JobNotificationPlan.Notice?

    init(
        session: RobotSession,
        events: ((String, AppJobMonitor.Configuration) throws -> AsyncStream<AppJobMonitor.Event>)? = nil,
        notify: JobNotify? = nil
    ) {
        self.session = session
        makeEvents = events ?? { [session] jobID, configuration in
            try session.appJobEvents(jobID: jobID, configuration: configuration)
        }
        self.notify = notify ?? { JobNotificationCenter.shared.receive($0) }
    }

    var isBusy: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    var operation: Operation? {
        switch state {
        case .idle: nil
        case let .running(operation), let .succeeded(operation),
             let .failed(operation, _), let .daemonRestarted(operation):
            operation
        }
    }

    func perform(_ operation: Operation) async {
        state = .running(operation)
        announceStart(of: operation)
        log.clear()

        let jobID: String
        do {
            jobID = try await start(operation)
        } catch {
            fail(on: error, operation: operation)
            return
        }

        do {
            for await event in try makeEvents(jobID, operation.configuration) {
                switch event {
                case let .line(line):
                    log.ingest(line)
                case .status:
                    // The terminal status arrives again as an outcome; showing it
                    // twice would just make the log noisier.
                    break
                case let .finished(outcome):
                    state = Self.state(for: outcome, operation: operation)
                    announce(Self.result(for: outcome))
                }
            }
        } catch {
            fail(on: error, operation: operation)
        }
    }

    func dismiss() {
        state = .idle
        log.clear()
    }

    private func start(_ operation: Operation) async throws -> String {
        switch operation {
        case let .install(app):
            // A private Space cannot be installed by posting its `AppInfo`: the
            // files are only readable with the token the robot stores, so the
            // daemon has to fetch it through its own route.
            if app.isPrivate, let spaceID = app.spaceID {
                return try await session.installPrivateSpace(id: spaceID)
            }
            return try await session.installApp(app)
        case let .update(app):
            return try await session.updateApp(named: app.name)
        case let .remove(app):
            return try await session.removeApp(named: app.name)
        }
    }

    private static func state(for outcome: AppJobMonitor.Outcome, operation: Operation) -> State {
        switch outcome {
        case .succeeded:
            .succeeded(operation)
        case let .failed(reason):
            .failed(operation, reason ?? String(localized: .reachy("The robot did not say why.")))
        case .daemonRestarted:
            .daemonRestarted(operation)
        case .timedOut:
            .failed(
                operation,
                String(localized: .reachy("The robot took too long to answer. Check the app list before trying again."))
            )
        }
    }

    /// The announcement rides `AppJobMonitor.Outcome`, **not** `State`, and the two
    /// mappings are deliberately not one function.
    ///
    /// `state(for:operation:)` collapses `.timedOut` into `.failed`, which is right on
    /// screen — the sheet is in front of someone who can go and look — and wrong in a
    /// notification, where "failed" would be a verdict inferred from a timer about a
    /// register that simply never answered. Unifying the two is the one refactor that
    /// would break this silently.
    private static func result(for outcome: AppJobMonitor.Outcome) -> JobNotificationPlan.Result {
        switch outcome {
        case .succeeded:
            .succeeded(detail: nil)
        case let .failed(reason):
            .failed(reason ?? String(localized: .reachy("The robot did not say why.")))
        case .daemonRestarted:
            .inconclusive
        case .timedOut:
            .unanswered
        }
    }

    private func announceStart(of operation: Operation) {
        let app = operation.app
        let notice = JobNotificationPlan.Notice(
            key: .init(
                kind: operation.notificationKind,
                robotID: session.connectedRobotID,
                // The daemon's own name, never the title: a title is display text and
                // may change under a job that is already running.
                subject: app.name
            ),
            robotName: session.connectedIdentity?.name,
            subjectTitle: app.title
        )
        pending = notice
        notify(.started(notice, at: Date()))
    }

    private func announce(_ result: JobNotificationPlan.Result) {
        guard let notice = pending else { return }
        pending = nil
        notify(.settled(notice, result, at: Date()))
    }

    /// A cancelled call leaves the state exactly as it was: the sheet the user was
    /// watching went away, which is not an install failure and must not be drawn
    /// as one. `RobotSession.message(for:)` logs it either way.
    ///
    /// The announcement inherits that rule for free: a cancelled call returns before
    /// the assignment, so nothing is said about a job whose screen went away.
    private func fail(on error: any Error, operation: Operation) {
        guard let message = RobotSession.message(for: error) else { return }
        state = .failed(operation, message)
        announce(.failed(message))
    }
}

#if DEBUG
    extension AppInstallModel {
        /// One job parked mid-flight. `events` is stubbed rather than left at its
        /// default, which opens a socket.
        static func preview(
            state: State,
            session: RobotSession? = nil,
            log lines: [String] = []
        ) -> AppInstallModel {
            let model = AppInstallModel(
                session: session ?? .preview(),
                events: { _, _ in AsyncStream { $0.finish() } },
                // A preview must not put a banner on anybody's Lock Screen.
                notify: { _ in }
            )
            model.state = state
            for line in lines {
                model.log.ingest(line)
            }
            return model
        }
    }
#endif
