import Foundation

/// Result of comparing a daemon version with the client compatibility baseline.
public enum DaemonCompatibility: Equatable, Sendable {
    case supported
    case untestedNewer(reported: String, tested: String)
    case unknown(reported: String?)
    case unsupported(reported: String, minimum: String)
}

/// Compatibility policy for the daemon API snapshot and hand-written WebSockets.
public enum DaemonCompatibilityPolicy {
    public static let minimumVersion = "1.9.0"
    /// Raised to 1.13.0. It adds `GET/PUT /api/telemetry` and its two data-channel
    /// commands, reads an `X-Reachy-Client` header (pollen-robotics/reachy_mini#1472,
    /// #1487), and gives the JSON-RPC relay the installed list, removals, updates,
    /// restart and followed jobs (#1471, #1477). It also changes behaviour this client
    /// meets: the relay keeps a session whose peer link is live when an `endSession`
    /// carries no reason (#1480), and `motors/set_mode` answers 409 for gravity
    /// compensation without Placo (#1454). The committed spec is the v1.13.0 tag's.
    /// 1.12.0 before it changed no surface: it brought the credential store (#1367),
    /// the `Host` guard (#1423), fixed sign-in sentences (#1363) and `message_chunk`
    /// frames (#1438).
    public static let testedVersion = "1.13.0"

    /// Whether the daemon is *known* to be older than `floor`.
    ///
    /// False for a version this client cannot read, and false for none at all: a
    /// feature is withheld on evidence, never on the absence of it.
    public static func isKnownOlder(than floor: String, reported: String?) -> Bool {
        guard let parsedFloor = SemanticVersion(floor) else {
            // Every caller passes a literal, so an unreadable floor is a typo — and
            // one that disables the gate it was written to close, silently.
            assertionFailure("unreadable version floor: \(floor)")
            return false
        }
        guard let reported, let current = SemanticVersion(reported) else { return false }
        return current < parsedFloor
    }

    /// Whether the daemon is *known* to be at `floor` or newer — the mirror of
    /// ``isKnownOlder(than:reported:)``, for a message that names a version and so
    /// must not be shown on a guess.
    public static func isKnownAtLeast(_ floor: String, reported: String?) -> Bool {
        guard let parsedFloor = SemanticVersion(floor) else {
            assertionFailure("unreadable version floor: \(floor)")
            return false
        }
        guard let reported, let current = SemanticVersion(reported) else { return false }
        return current >= parsedFloor
    }

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
              let major = Self.leadingNumber(components[0]),
              let minor = Self.leadingNumber(components[1]),
              let patch = Self.leadingNumber(components[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The digits a component starts with, or nil when it starts with none.
    ///
    /// PyPI spells a pre-release with no separator at all, so the daemon reports
    /// `1.10.0rc5` and the patch arrives glued to its suffix. Reading the digits
    /// off the front treats an RC as the release it precedes, which is what the
    /// compatibility question asks: `1.10.0rc5` carries the 1.10.0 API.
    private static func leadingNumber(_ component: Substring) -> Int? {
        Int(component.prefix(while: \.isNumber))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
