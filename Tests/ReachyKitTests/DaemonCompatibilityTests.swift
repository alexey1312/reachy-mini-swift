@testable import ReachyKit
import Testing

@Suite("DaemonCompatibilityPolicy")
struct DaemonCompatibilityTests {
    @Test("tested baseline is supported")
    func baseline() {
        #expect(DaemonCompatibilityPolicy.evaluate("1.10.0") == .supported)
        #expect(DaemonCompatibilityPolicy.evaluate("v1.10.0") == .supported)
    }

    /// A daemon between the minimum and the tested baseline is supported outright,
    /// not warned about — the warning is for versions this client has never seen.
    @Test("daemons between the minimum and the baseline are supported", arguments: ["1.9.0", "1.9.5"])
    func withinRange(version: String) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .supported)
    }

    @Test("older and different-major daemons are blocked", arguments: ["1.8.9", "2.0.0", "0.99.0"])
    func unsupported(version: String) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .unsupported(
            reported: version,
            minimum: DaemonCompatibilityPolicy.minimumVersion
        ))
    }

    @Test("newer compatible versions connect with a warning", arguments: ["1.10.1", "1.11.0"])
    func newer(version: String) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .untestedNewer(
            reported: version,
            tested: DaemonCompatibilityPolicy.testedVersion
        ))
    }

    /// PyPI writes a pre-release with no separator, so the daemon reports `1.10.0rc5`
    /// and the patch arrives glued to its suffix. An RC carries the API of the release
    /// it precedes, so it answers as that release does.
    @Test("PEP 440 pre-releases read as the release they precede", arguments: [
        "1.10.0rc5", "1.10.0a1", "1.10.0b2", "1.10.0.dev3", "1.10.0+local", "v1.10.0rc5",
    ])
    func preRelease(version: String) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .supported)
    }

    @Test("a pre-release below the minimum is blocked like its release")
    func preReleaseBelowTheMinimum() {
        #expect(DaemonCompatibilityPolicy.evaluate("1.8.9rc1") == .unsupported(
            reported: "1.8.9rc1",
            minimum: DaemonCompatibilityPolicy.minimumVersion
        ))
    }

    @Test(
        "missing or malformed versions degrade to unknown",
        arguments: [nil, "", "dev", "1.9", "rc5", "1.10.rc5"] as [String?]
    )
    func unknown(version: String?) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .unknown(reported: version))
    }
}
