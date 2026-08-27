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

    @Test("missing or malformed versions degrade to unknown", arguments: [nil, "", "dev", "1.9"] as [String?])
    func unknown(version: String?) {
        #expect(DaemonCompatibilityPolicy.evaluate(version) == .unknown(reported: version))
    }
}
