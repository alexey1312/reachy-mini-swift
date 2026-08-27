import Foundation

/// Result of comparing a daemon version with the client compatibility baseline.
public enum DaemonCompatibility: Equatable, Sendable {
    case supported
    case untestedNewer(reported: String, tested: String)
    case unknown(reported: String?)
    case unsupported(reported: String, minimum: String)

    public var warningMessage: String? {
        switch self {
        case .supported:
            nil
        case let .untestedNewer(reported, tested):
            "Daemon \(reported) is newer than the tested baseline \(tested); optional features may be unavailable."
        case let .unknown(reported):
            "Daemon version \(reported ?? "was not reported") could not be verified; compatibility is limited."
        case let .unsupported(reported, minimum):
            "Daemon \(reported) is unsupported; version \(minimum) is required."
        }
    }
}

/// Compatibility policy for the daemon API snapshot and hand-written WebSockets.
public enum DaemonCompatibilityPolicy {
    public static let minimumVersion = "1.9.0"
    /// Raised to 1.10.0 against a Wireless unit on that daemon. The spec diff was
    /// additive but for one rename: `DoAInfo` became `DoaSnapshot` with the same two
    /// fields, so no generated type any caller names actually moved. `/api/state/imu`
    /// and `FullState.imu` are new, and rule 3 already covers an unread field.
    public static let testedVersion = "1.10.0"

    public static func evaluate(_ reported: String?) -> DaemonCompatibility {
        guard let reported, let current = SemanticVersion(reported),
              let minimum = SemanticVersion(minimumVersion),
              let tested = SemanticVersion(testedVersion)
        else { return .unknown(reported: reported) }

        guard current.major == tested.major, current >= minimum else {
            return .unsupported(reported: reported, minimum: minimumVersion)
        }
        return current > tested
            ? .untestedNewer(reported: reported, tested: testedVersion)
            : .supported
    }
}

private struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let normalized = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        guard let core = normalized.split(separator: "-", maxSplits: 1).first else { return nil }
        let components = core.split(separator: ".")
        guard components.count >= 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
