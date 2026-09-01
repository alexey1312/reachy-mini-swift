import Foundation

/// What `GET /api/apps/current-app-status` (and every start/restart reply) says
/// about the app holding the robot.
///
/// Hand-decoded rather than taken from the generated client: the daemon answers
/// this route with a literal `null` when nothing runs, and its `state` is a closed
/// enum in the spec — a value added by a later daemon would throw where it should
/// simply be carried (project rule 3).
public struct RobotAppStatus: Sendable, Equatable, Decodable {
    public enum State: Sendable, Equatable, Decodable {
        case starting
        case running
        case done
        case stopping
        case error
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            try self.init(wire: decoder.singleValueContainer().decode(String.self))
        }

        /// The same mapping, for a caller that already has the daemon's word out of
        /// a payload this type does not decode — the relay's `apps.status` reply.
        public init(wire: String) {
            switch wire {
            case "starting": self = .starting
            case "running": self = .running
            case "done": self = .done
            case "stopping": self = .stopping
            case "error": self = .error
            case let other: self = .unknown(other)
            }
        }

        /// Whether the app still holds the robot. An unfamiliar state counts as
        /// held: the daemon only reports a status at all while an app is loaded,
        /// and offering "Start" for a slot that is taken is the worse mistake.
        public var isBusy: Bool {
            switch self {
            case .starting, .running, .stopping, .unknown: true
            case .done, .error: false
            }
        }
    }

    public let app: RobotApp
    public let state: State
    /// Set when the app died — the daemon's summary line followed by the tail of
    /// the app's stderr, verbatim.
    ///
    /// **Several lines, not one.** It used to be documented as the traceback's
    /// last line, and a surface built on that reading shows an arbitrary window
    /// onto a Python traceback interleaved with uvicorn's own logging. Anything
    /// rendering this needs either the room for all of it or an explicit decision
    /// about what to cut.
    public let error: String?

    public var isBusy: Bool {
        state.isBusy
    }

    public init(app: RobotApp, state: State, error: String? = nil) {
        self.app = app
        self.state = state
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case info, state, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(RobotApp.self, forKey: .info)
        state = try container.decode(State.self, forKey: .state)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// `GET /api/daemon/robot-app-lock-status` — who, if anyone, is driving the robot.
///
/// A local app and a Hugging Face relay session take the same lock, and a screen
/// that cannot tell them apart cannot explain why a button is disabled.
public struct RobotAppLockStatus: Sendable, Equatable, Decodable {
    public enum State: Sendable, Equatable, Decodable {
        case free
        case localApp
        case remoteSession
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "free": self = .free
            case "local_app": self = .localApp
            case "remote_session": self = .remoteSession
            case let other: self = .unknown(other)
            }
        }
    }

    public let state: State
    public let holderName: String?

    /// Anything but `free` — including a state this client has not heard of.
    public var isHeld: Bool {
        state != .free
    }

    public init(state: State, holderName: String? = nil) {
        self.state = state
        self.holderName = holderName
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case holderName = "holder_name"
    }
}

/// `GET /api/apps/check-updates` — which installed apps have moved on upstream.
///
/// The daemon caches this for five minutes and only lists apps that *have* an
/// update, so the two counts are the only way to say "checked 3, none stale".
public struct AppUpdatesSummary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let appName: String
        public let spaceID: String
        public let installedSHA: String
        public let latestSHA: String
        public let lastModified: String?
    }

    public let entries: [Entry]
    public let checked: Int
    /// Apps the daemon could not check — installed without a recorded commit.
    public let skipped: Int

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public init(_ response: Components.Schemas.AppUpdatesResponse) {
        entries = response.appsWithUpdates.map {
            Entry(
                appName: $0.appName,
                spaceID: $0.spaceId,
                installedSHA: $0.installedSha,
                latestSHA: $0.latestSha,
                lastModified: $0.lastModified
            )
        }
        checked = response.appsChecked
        skipped = response.appsSkipped
    }

    /// The daemon files updates under the *installed* name — the Python entry
    /// point's — while the catalogue card knows the same app by its Space. Both
    /// have to answer, or the badge shows on one screen and not the other.
    public func hasUpdate(for app: RobotApp) -> Bool {
        entries.contains { $0.appName == app.name || $0.spaceID == app.spaceID }
    }
}
