import Foundation
import Network
import Observation
import OpenAPIRuntime

/// Connection lifecycle for one robot: handshake, health polling, wake/sleep and recorded moves.
@MainActor
@Observable
public final class RobotSession {
    public enum ConnectionPhase: Equatable, Sendable {
        case idle
        case connecting(ConnectionStep)
        case connected(RobotIdentity)
        case unreachable(RobotIdentity)
    }

    /// How the robot is being reached, named rather than inferred.
    ///
    /// `address == nil` used to carry this meaning implicitly in four places, and
    /// it was read as "not connected" in three of them — which is what hid the
    /// camera, the log console and the joystick from a perfectly live relay
    /// session. A remote session has no address to dial: by the time its client
    /// arrives it is already talking to the robot.
    public enum Link: Equatable, Sendable {
        case none
        case lan(RobotAddress)
        case remote

        /// What to call this connection in front of a user. Every screen that used
        /// to print `address?.displayString ?? "robot"` was naming the transport
        /// badly for one of the two cases; this names both.
        public var displayString: String {
            switch self {
            case .none: "—"
            case let .lan(address): address.displayString
            case .remote: "Hugging Face relay"
            }
        }
    }

    /// Where a connection attempt currently stands. Split out of `.connecting`
    /// so a failure names the step it happened on instead of collapsing into one
    /// opaque spinner.
    public enum ConnectionStep: Equatable, Sendable {
        case handshaking
        case checkingBackend(RobotIdentity)
        /// The daemon answered but is below the supported baseline. Terminal until
        /// the user updates the robot or backs out — ADR 0001 forbids sending it any
        /// command, and its own `/update/*` route is the way out.
        case needsDaemonUpdate(RobotIdentity, DaemonUpdateRequirement)
        /// The handshake succeeded but the robot backend is down. Terminal until
        /// the user picks one of start / proceed / cancel — starting it here would
        /// move the robot without being asked.
        case backendUnavailable(RobotIdentity, daemonMessage: String?)
        /// Latched for explicit connects only; automatic attempts fall back to
        /// `.idle` so the candidate loop keeps sweeping.
        case failed(ConnectionStage, message: String)
    }

    /// The steps a connection walks through, in order — the stepper's row model.
    public enum ConnectionStage: Int, CaseIterable, Equatable, Sendable {
        case connect
        case compatibility
        case backend
    }

    public enum StageOutcome: Equatable, Sendable {
        case pending, active, done, attention, failed
    }

    /// Wake and sleep are long enough — a cold backend start is budgeted at 90 s —
    /// that the UI has to show what the robot is doing meanwhile.
    public enum PowerTransition: Equatable, Sendable {
        case startingBackend
        case stoppingBackend
        case wakingUp
        case goingToSleep
    }

    public struct MovePlayback: Equatable, Sendable {
        public let dataset: String
        public let move: String
        public let uuid: String
    }

    public struct Configuration: Sendable {
        /// Upstream polls every 3 s (5 s over robot Wi-Fi).
        public var pollInterval: Duration = .seconds(3)
        /// Consecutive successful probes required to leave `.unreachable`.
        public var requiredConsecutiveSuccesses = 2
        /// Move task polling is intentionally cheaper than rendering/state streaming.
        public var movePollInterval: Duration = .milliseconds(500)
        /// Upstream waits this long for a wake/sleep animation before moving on.
        public var moveCompletionTimeout: Duration = .seconds(10)
        /// Backend startup budget — upstream's `STARTUP.TIMEOUT_NORMAL`.
        public var daemonStartTimeout: Duration = .seconds(90)
        /// Shutdown budget. Shorter than the start, and not by guesswork: the
        /// daemon's teardown is the sleep animation plus a backend thread it joins
        /// with a 5 s cap, where a start builds a media pipeline and loads a model.
        public var daemonStopTimeout: Duration = .seconds(60)
        /// Motors need a moment to hold their pose before the animation starts.
        public var motorSettleDelay: Duration = .milliseconds(300)
        /// How long the app holding the robot may take to let go before it is
        /// parked anyway.
        ///
        /// The daemon gives the app 20 s to honour SIGINT and then kills it
        /// (`apps/manager.py:301`) and returns the robot to zero after that, so a
        /// normal stop is over in seconds and a stubborn one in twenty-odd. 30 s
        /// clears both. Anything past it is the daemon's one-way `stopping` wedge,
        /// which no client can open — and holding the head up for it would be the
        /// worse answer.
        public var appStopTimeout: Duration = .seconds(30)
        /// Upstream's job-polling cadence, for the same reason it uses it: somebody
        /// is watching their robot and waiting for it to move.
        public var appStopPollInterval: Duration = .milliseconds(500)
        /// Connect-time readiness budget. We never start a backend during connect,
        /// so a stopped one is reported at once — this only covers the window
        /// between `state == running` and `backend.ready`.
        public var readinessTimeout: Duration = .seconds(8)
        public var readinessPollInterval: Duration = .milliseconds(500)

        public init() {}
    }

    // `internal(set)` rather than `private(set)`: the connect and power protocols
    // live in sibling files, and a `private` setter is scoped to this one. The preview
    // fixtures do the same, parking a session in a state no real connection would reach.
    public internal(set) var phase: ConnectionPhase = .idle
    public internal(set) var link: Link = .none
    public internal(set) var lastStatus: Components.Schemas.DaemonStatus?
    /// The robot's own last failure: it could not be reached, or it would not
    /// change power state. Nothing else belongs here.
    ///
    /// It used to be `lastError` and every funnel in the session wrote to it,
    /// which is how an Apps failure — and, before that, a *cancelled* Apps call —
    /// ended up printed on the robot screen. A feature's failure is its screen's
    /// news and lives in that screen's model; connection and power have no screen
    /// of their own, because they are the state of the robot rather than of a
    /// feature. Write only through `report(_:)`, and only from
    /// `RobotSession+Power` and `RobotSession+Connect`.
    public internal(set) var robotError: String?
    public internal(set) var compatibilityWarning: String?
    /// Answered by the handshake, not by the version string: `/api/daemon/robot-name`
    /// postdates 1.9.0, and the name field is greyed out rather than left to fail on save.
    public internal(set) var supportsRename = true
    public internal(set) var currentMove: MovePlayback?
    public internal(set) var isStoppingMove = false
    /// The app holding the robot, as the daemon last reported it — raw, including
    /// the states the widget snapshot filters out. A dock has to be able to say
    /// "stopped with an error", which is exactly what `isBusy` discards.
    ///
    /// Written only by `recordRunning(_:)`, which every app command already passes
    /// through, so this and the cross-process snapshot can never disagree.
    public internal(set) var runningApp: RobotAppStatus?
    public internal(set) var powerTransition: PowerTransition?
    /// Explicit Disconnect suppresses discovery-driven reconnect until the user connects again.
    public internal(set) var automaticConnectionAllowed = true

    /// The address to dial, and nothing more. Every caller that reads this is
    /// asking for the HTTP transport — the daemon's own API, a WebSocket on port
    /// 8000, a job log — so a remote session correctly answers `nil` and the
    /// features behind it stay closed. What must *not* be inferred from `nil` is
    /// "no robot": ask `phase` for that, or `isRemote` for the reason.
    public var address: RobotAddress? {
        if case let .lan(address) = link {
            address
        } else {
            nil
        }
    }

    public var isRemote: Bool {
        link == .remote
    }

    let configuration: Configuration
    var client: (any RobotAPIClient)?
    var connectionAttemptID = UUID()

    /// Not `private`: `connect(to:)` lives in `RobotSession+Connect.swift`, like
    /// the rest of the connection protocol.
    let makeClient: @Sendable (RobotAddress) throws -> any RobotAPIClient
    /// Where the widget reads what this session last saw. The widget's process
    /// cannot connect to anything, so this is the only thing it has.
    let snapshots: RobotSnapshotStore
    /// The installed apps, for a widget that has to offer a menu of them without
    /// being able to ask. Written wherever this session lists them anyway, so it
    /// costs the robot nothing. Lives in `RobotSession+Apps`.
    let appsCache: RobotAppsCacheStore
    private var pollTask: Task<Void, Never>?
    private var movePollTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var moveCache: [String: [String]] = [:]
    /// Both lists cost the robot a Hugging Face round trip, so they are held for
    /// the life of the connection — and only that long. Not `private`: the store
    /// lives in `RobotSession+Apps`, a sibling file.
    var appCatalogueCache: [RobotApp]?
    var installedAppsCache: [RobotApp]?
    /// The daemon answers `hf-auth/status` by running `whoami` against the Hub, so
    /// this is held for the connection too. Lives in `RobotSession+HFAuth`.
    var hfAccountCache: HFAuthStatus?

    /// Production session talking to a real daemon.
    public convenience init(configuration: Configuration = .init()) {
        self.init(configuration: configuration) { try RobotConnection(address: $0) }
    }

    /// Injectable client factory for tests.
    ///
    /// `snapshots` and `appsCache` are injectable for the same reason the client
    /// is: they write into `UserDefaults`, and `--parallel` runs suites
    /// concurrently against one table.
    public init(
        configuration: Configuration = .init(),
        snapshots: RobotSnapshotStore = RobotSnapshotStore(),
        appsCache: RobotAppsCacheStore = RobotAppsCacheStore(),
        makeClient: @escaping @Sendable (RobotAddress) throws -> any RobotAPIClient
    ) {
        self.configuration = configuration
        self.snapshots = snapshots
        self.appsCache = appsCache
        self.makeClient = makeClient
    }

    /// Returns a session-scoped cached dataset index. Actual move assets stay daemon-side.
    public func moves(in dataset: String, refresh: Bool = false) async throws -> [String] {
        if !refresh, let cached = moveCache[dataset] {
            return cached
        }
        let moves = try await withClient { try await $0.listMoves(dataset: dataset) }
        moveCache[dataset] = moves
        return moves
    }

    /// Throws rather than reporting: a move that would not play is the moves
    /// screen's news, and `MovesModel` is what puts it on screen.
    public func playMove(dataset: String, move: String) async throws {
        guard let client else { throw ReachyKitError.notConnected }
        if currentMove != nil {
            _ = await stopMove()
        }
        let uuid = try await client.playMove(dataset: dataset, move: move)
        let playback = MovePlayback(dataset: dataset, move: move, uuid: uuid)
        currentMove = playback
        startMonitoring(playback, client: client)
    }

    /// Stops both daemon tasks: motion and the separately-owned sound player, and
    /// answers with whatever refused — empty when both stopped.
    ///
    /// Returned rather than thrown because the two are stopped in parallel and
    /// both are seen through: parking the motors matters more than reporting, so
    /// there is no single failure to throw. The caller decides what to do with
    /// the list; `MovesModel.stop` joins it into its own error slot.
    @discardableResult
    public func stopMove() async -> [String] {
        guard let client, let playback = currentMove, !isStoppingMove else { return [] }
        isStoppingMove = true
        movePollTask?.cancel()
        movePollTask = nil

        let errors = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            group.addTask {
                do {
                    try await client.stopMove(uuid: playback.uuid)
                    return nil
                } catch {
                    return "Move: \(error)"
                }
            }
            group.addTask {
                do {
                    try await client.stopSound()
                    return nil
                } catch {
                    return "Sound: \(error)"
                }
            }

            var errors: [String] = []
            for await error in group {
                if let error {
                    errors.append(error)
                }
            }
            return errors
        }

        if currentMove?.uuid == playback.uuid {
            currentMove = nil
        }
        isStoppingMove = false
        return errors.sorted()
    }

    func resetConnectionState() {
        pollTask?.cancel()
        pollTask = nil
        movePollTask?.cancel()
        movePollTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        client = nil
        link = .none
        lastStatus = nil
        compatibilityWarning = nil
        supportsRename = true
        currentMove = nil
        isStoppingMove = false
        powerTransition = nil
        runningApp = nil
        moveCache = [:]
        appCatalogueCache = nil
        installedAppsCache = nil
        hfAccountCache = nil
        phase = .idle
    }

    /// Polls the daemon's authoritative running-task list so natural completion
    /// clears the UI. Two misses avoid racing task registration just after play.
    private func startMonitoring(_ playback: MovePlayback, client: any RobotAPIClient) {
        movePollTask?.cancel()
        movePollTask = Task { [configuration] in
            var consecutiveMisses = 0
            while !Task.isCancelled, currentMove?.uuid == playback.uuid {
                try? await Task.sleep(for: configuration.movePollInterval)
                guard !Task.isCancelled, currentMove?.uuid == playback.uuid else { return }
                do {
                    let running = try await client.runningMoveUUIDs()
                    guard !Task.isCancelled, currentMove?.uuid == playback.uuid else { return }
                    if running.contains(playback.uuid) {
                        consecutiveMisses = 0
                    } else {
                        consecutiveMisses += 1
                        if consecutiveMisses >= 2 {
                            try? await client.stopSound()
                            guard !Task.isCancelled, currentMove?.uuid == playback.uuid else { return }
                            currentMove = nil
                            movePollTask = nil
                            return
                        }
                    }
                } catch {
                    // A transient status failure must not claim that playback ended.
                }
            }
        }
    }

    /// Network changes shouldn't wait for the next poll tick: losing the path
    /// drops to `.unreachable` immediately; regaining it restarts polling now.
    func startPathMonitor(identity: RobotIdentity) {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.pathChanged(satisfied: satisfied, identity: identity)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func pathChanged(satisfied: Bool, identity: RobotIdentity) {
        guard client != nil else { return }
        if !satisfied {
            if case .connected = phase {
                phase = .unreachable(identity)
            }
        } else if case .unreachable = phase {
            startPolling(identity: identity)
        }
    }

    func startPolling(identity: RobotIdentity) {
        pollTask?.cancel()
        pollTask = Task { [configuration] in
            var consecutiveSuccesses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.pollInterval)
                guard !Task.isCancelled, let client = self.client else { return }
                do {
                    let status = try await client.daemonStatus()
                    lastStatus = status
                    // The widget's only source of truth, refreshed wherever the
                    // session already learns something — no extra round trip.
                    recordSnapshot(identity: identity)
                    if case .unreachable = phase {
                        consecutiveSuccesses += 1
                        if consecutiveSuccesses >= configuration.requiredConsecutiveSuccesses {
                            phase = .connected(identity)
                        }
                    } else {
                        consecutiveSuccesses = 1
                    }
                } catch {
                    consecutiveSuccesses = 0
                    phase = .unreachable(identity)
                }
            }
        }
    }
}
