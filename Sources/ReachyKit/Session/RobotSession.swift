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
        /// Which recorded move this is. Absent for playback the app did not start:
        /// `/api/move/running` answers with UUIDs and nothing else — no dataset, no
        /// name — so a move found already running after a relaunch can only be
        /// named when the UUID matches the one this app persisted.
        public struct Identity: Equatable, Sendable {
            public let dataset: String
            public let move: String

            public init(dataset: String, move: String) {
                self.dataset = dataset
                self.move = move
            }
        }

        public let uuid: String
        public let identity: Identity?

        public init(uuid: String, identity: Identity?) {
            self.uuid = uuid
            self.identity = identity
        }

        public var dataset: String? {
            identity?.dataset
        }

        public var move: String? {
            identity?.move
        }
    }

    /// What the robot is doing about moves, as one value.
    ///
    /// Three independent flags would allow combinations that do not exist —
    /// stopping and parking at once — and the screen would have to rule them out
    /// by hand. `currentMove` and `isStoppingMove` are derived from this rather
    /// than stored beside it, so they cannot disagree with it.
    public enum MoveActivity: Equatable, Sendable {
        case playing(MovePlayback)
        case stopping(MovePlayback)
        /// The daemon's own zero pose, which is a move task like any other.
        case recentring(uuid: String)

        /// `nil` while parking: returning to neutral is not playback. It has no
        /// dataset, no row to highlight in the library, and nothing to stop.
        public var playback: MovePlayback? {
            switch self {
            case let .playing(playback), let .stopping(playback): playback
            case .recentring: nil
            }
        }

        var uuid: String {
            switch self {
            case let .playing(playback), let .stopping(playback): playback.uuid
            case let .recentring(uuid): uuid
            }
        }
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
    public internal(set) var moveActivity: MoveActivity?

    public var currentMove: MovePlayback? {
        moveActivity?.playback
    }

    public var isStoppingMove: Bool {
        if case .stopping = moveActivity {
            true
        } else {
            false
        }
    }

    /// The robot is walking back to its zero pose. Nothing to stop, and the
    /// library is briefly unavailable — a play issued now would be dropped by
    /// `_try_start_move` without a word.
    public var isRecentring: Bool {
        if case .recentring = moveActivity {
            true
        } else {
            false
        }
    }

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
    /// What this session last asked the robot to play, kept across launches so a
    /// move found still running can be named rather than merely noticed.
    let playbacks: MovePlaybackStore
    private var pollTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Not `private`: recorded moves live in `RobotSession+Moves`, a sibling file.
    var movePollTask: Task<Void, Never>?
    var moveRestoreTask: Task<Void, Never>?
    var moveCache: [String: [String]] = [:]
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
        playbacks: MovePlaybackStore = MovePlaybackStore(),
        makeClient: @escaping @Sendable (RobotAddress) throws -> any RobotAPIClient
    ) {
        self.configuration = configuration
        self.snapshots = snapshots
        self.appsCache = appsCache
        self.playbacks = playbacks
        self.makeClient = makeClient
    }

    func resetConnectionState() {
        pollTask?.cancel()
        pollTask = nil
        movePollTask?.cancel()
        movePollTask = nil
        moveRestoreTask?.cancel()
        moveRestoreTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        client = nil
        link = .none
        lastStatus = nil
        compatibilityWarning = nil
        supportsRename = true
        moveActivity = nil
        powerTransition = nil
        runningApp = nil
        moveCache = [:]
        appCatalogueCache = nil
        installedAppsCache = nil
        hfAccountCache = nil
        phase = .idle
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
