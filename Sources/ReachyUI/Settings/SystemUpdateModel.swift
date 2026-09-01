import Foundation
import Observation
import ReachyDesign
import ReachyKit

/// Drives one robot software update: check, start, stream the log, wait out the
/// restart, confirm the new version.
@MainActor
@Observable
final class SystemUpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        /// The robot itself has no route to PyPI. Nothing the app can fix.
        case robotOffline(current: String)
        case available(current: String, latest: String)
        case installing
        /// The log socket closed, which is what the daemon restarting looks like.
        case restarting
        case finished(version: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Shared with `LogConsoleView`, so pip output gets the same filter, pause and
    /// export the daemon journal has.
    let log = LogConsoleModel()

    private let session: RobotSession
    /// The two steps that cannot be driven through a stubbed client: one needs a live
    /// WebSocket, the other waits out a real reboot. Injected by tests only.
    private let makeEvents: (String) throws -> AsyncStream<UpdateLogEvent>
    private let reconnect: () async -> String?
    /// How long `settleJob` waits between probes, and how long it keeps probing. The
    /// budget is generous because it bounds a wedged daemon, not a normal install.
    private let jobPollInterval: Duration
    private let jobPollBudget: Duration

    init(
        session: RobotSession,
        events: ((String) throws -> AsyncStream<UpdateLogEvent>)? = nil,
        reconnect: (() async -> String?)? = nil,
        jobPollInterval: Duration = .seconds(3),
        jobPollBudget: Duration = .seconds(20 * 60)
    ) {
        self.session = session
        self.jobPollInterval = jobPollInterval
        self.jobPollBudget = jobPollBudget
        makeEvents = events ?? { [session] jobID in try session.updateLog(jobID: jobID) }
        self.reconnect = reconnect ?? { [session] in await session.reconnectAfterUpdate() }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing, .restarting: true
        default: false
        }
    }

    func check(preRelease: Bool) async {
        state = .checking
        do {
            state = switch try await session.availableUpdate(preRelease: preRelease) {
            case let .upToDate(current): .upToDate(current: current)
            case let .robotOffline(current): .robotOffline(current: current)
            case let .available(current, latest): .available(current: current, latest: latest)
            }
        } catch {
            fail(on: error)
        }
    }

    /// Runs to a terminal state. The daemon dies mid-stream by design, so the socket
    /// closing is treated as "installed, now rebooting" rather than as a failure.
    func install(preRelease: Bool) async {
        guard case let .available(current, _) = state else { return }
        state = .installing
        log.clear()

        let jobID: String
        do {
            jobID = try await session.startUpdate(preRelease: preRelease)
        } catch {
            fail(on: error)
            return
        }

        do {
            for await event in try makeEvents(jobID) {
                switch event {
                case let .line(line):
                    log.ingest(line)
                case let .status(status):
                    if status == .failed {
                        state = .failed(String(localized: .reachy("The robot reported that the update failed.")))
                        return
                    }
                case let .rejected(reason):
                    state = .failed(reason)
                    return
                case .closed:
                    break
                }
            }
        } catch {
            fail(on: error)
            return
        }

        await finish(settleJob(jobID), from: current)
    }

    private func finish(_ outcome: JobOutcome, from current: String) async {
        switch outcome {
        case .restarted:
            state = .restarting
            await confirmRestart(from: current)
        case .stillRunning, .cancelled, .failed:
            // `stillRunning` leaves `installing` on screen, which is what is true:
            // announcing a restart here blamed the release for a job still going.
            return
        }
    }

    /// What the closed socket turned out to mean.
    private enum JobOutcome {
        /// The register cannot be reached, or says the job is over — the daemon
        /// went down, which is the ordinary ending.
        case restarted
        /// Still running past the budget.
        case stillRunning
        /// The screen went away. A cancelled call leaves the state exactly as it
        /// was, the rule ``fail(on:)`` keeps and this path used to break by
        /// telling the user to power-cycle a robot mid-install.
        case cancelled
        /// The daemon reported a failure and `state` already says so.
        case failed
    }

    /// Whether the closed socket really was the daemon going down.
    ///
    /// `RobotSession.updateInfo` can never confirm success — the restart takes the
    /// in-memory job register with it — but it answers the other question: is the
    /// job still running? A Wi-Fi blip closes the same socket a restart does, and
    /// without this the screen announced a restart that never happened and then
    /// blamed the release for a version that had not moved.
    ///
    /// An unreachable daemon is the ordinary ending and keeps the old behaviour.
    /// So does a status this client does not recognise: the socket stays the end
    /// signal wherever the register says nothing useful.
    private func settleJob(_ jobID: String) async -> JobOutcome {
        let deadline = ContinuousClock.now + jobPollBudget
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return .cancelled }
            guard let job = try? await session.updateInfo(jobID: jobID) else { return .restarted }
            switch job.status {
            case .failed:
                state = .failed(String(localized: .reachy("The robot reported that the update failed.")))
                return .failed
            case .pending, .inProgress:
                do {
                    try await Task.sleep(for: jobPollInterval)
                } catch {
                    return .cancelled
                }
            case .done, .unknown:
                return .restarted
            }
        }
        return .stillRunning
    }

    private func confirmRestart(from previous: String) async {
        guard let version = await reconnect() else {
            state =
                .failed(
                    String(
                        localized: .reachy(
                            "The robot did not come back after the update. Power-cycle it and try again."
                        )
                    )
                )
            return
        }
        guard version != previous else {
            state = .failed(String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The update finished but the robot still reports \(version). A new enough release may not be published yet."
                )
            ))
            return
        }
        state = .finished(version: version)
    }

    /// A cancelled call leaves the state exactly as it was: the screen the user
    /// was on went away, which is not an update failure and must not be drawn as
    /// one. `RobotSession.message(for:)` logs it either way.
    private func fail(on error: any Error) {
        guard let message = RobotSession.message(for: error) else { return }
        state = .failed(message)
    }
}

#if DEBUG
    extension SystemUpdateModel {
        /// One update parked mid-flight. `events` and `reconnect` are stubbed out rather than
        /// left at their defaults: the real ones open a WebSocket and wait out a reboot.
        static func preview(
            state: State,
            session: RobotSession? = nil,
            log lines: [String] = []
        ) -> SystemUpdateModel {
            let model = SystemUpdateModel(
                session: session ?? .preview(),
                events: { _ in AsyncStream { $0.finish() } },
                reconnect: { nil }
            )
            model.state = state
            for line in lines {
                model.log.ingest(line)
            }
            return model
        }
    }
#endif
