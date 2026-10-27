import Foundation

/// The robot's anonymous usage telemetry, as daemon 1.13.0 reports it
/// (`GET /api/telemetry`, `get_telemetry` on the data channel).
///
/// The daemon sends Pollen a few anonymous events while this is on — its own start,
/// a daily heartbeat, app starts and installs, update results and the kinds of
/// client that connect. The choice belongs to the robot, so it holds for every app
/// that talks to it. Pollen's desktop and mobile apps show it as "Share anonymous
/// usage data"; this app shows the same switch.
public struct RobotTelemetry: Equatable, Sendable {
    /// The owner's choice, as the robot stored it.
    public var isEnabled: Bool
    /// `REACHY_MINI_TELEMETRY=0`, `DO_NOT_TRACK` or `HF_HUB_DISABLE_TELEMETRY` on the
    /// robot. Nothing is sent then, whatever ``isEnabled`` says, and a write still
    /// stores the choice for the day the variable goes.
    public var isDisabledByEnvironment: Bool

    public init(isEnabled: Bool, isDisabledByEnvironment: Bool) {
        self.isEnabled = isEnabled
        self.isDisabledByEnvironment = isDisabledByEnvironment
    }

    /// Whether the robot sends anything at all.
    public var isSharing: Bool {
        isEnabled && !isDisabledByEnvironment
    }
}

/// Reads and changes ``RobotTelemetry``.
///
/// A protocol of its own, `AudioLevelClient`'s shape: conforming is the
/// capability, so the in-app simulator, which has no daemon, offers no switch.
public protocol RobotTelemetryClient: Sendable {
    /// Nil when the daemon predates the setting: before 1.13.0 the LAN route
    /// answers 404.
    func telemetry() async throws -> RobotTelemetry?
    /// The robot's state after the write, which is the one to show.
    func setTelemetry(enabled: Bool) async throws -> RobotTelemetry
}

public extension RobotSession {
    /// Whether to ask the robot about telemetry at all.
    ///
    /// The relay needs a version known to be 1.13.0 or newer: an older daemon
    /// answers an unknown data-channel command with an `error` that names no
    /// command, which matches no waiter, so the read would sit out the whole reply
    /// budget. The LAN asks any version and reads its 404 as absent.
    var canShareTelemetry: Bool {
        guard client is any RobotTelemetryClient else { return false }
        switch link {
        case .lan:
            return true
        case .remote:
            return DaemonCompatibilityPolicy.isKnownAtLeast("1.13.0", reported: lastStatus?.version)
        case .none, .simulated:
            return false
        }
    }

    /// Nil when this robot has no such setting.
    func robotTelemetry() async throws -> RobotTelemetry? {
        guard canShareTelemetry else { return nil }
        return try await withTelemetryClient { try await $0.telemetry() }
    }

    func setRobotTelemetry(enabled: Bool) async throws -> RobotTelemetry {
        try await withTelemetryClient { try await $0.setTelemetry(enabled: enabled) }
    }
}

extension RobotSession {
    /// Through ``withClient``, so the daemon-version gate fires first; then throws
    /// and says nothing else — a switch that failed belongs to its own section.
    func withTelemetryClient<T>(_ call: (any RobotTelemetryClient) async throws -> T) async throws -> T {
        try await withClient { client in
            guard let telemetry = client as? any RobotTelemetryClient else {
                throw ReachyKitError.telemetryUnavailable
            }
            return try await call(telemetry)
        }
    }
}
