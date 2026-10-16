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
    /// Raised to 1.12.0, which adds no route and no data-channel command type to
    /// 1.11.0. What it changes is behaviour this client meets: a credential store of
    /// its own that signs every robot out once (pollen-robotics/reachy_mini#1367), a
    /// guard that refuses a `Host` that is not an IP literal, `localhost` or a
    /// `.local` name (#1423), fixed sentences for a failed Hugging Face sign-in
    /// (#1363), and data-channel messages over 60 000 bytes split into
    /// `message_chunk` frames (#1438). The committed spec is the v1.12.0 tag's.
    /// 1.11.0 before it brought the IMU on REST and nothing else this client sends.
    public static let testedVersion = "1.12.0"

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
