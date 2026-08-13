import Foundation
@testable import ReachyKit
import Testing

@Suite("State stream options")
struct StateStreamOptionsTests {
    /// Existing screens and the daemon-compatibility tests rely on the stream URL
    /// staying exactly as it was before options existed.
    @Test("default options add no query at all")
    func defaultsProduceNoQuery() throws {
        let client = try StateStreamClient(address: RobotAddress(host: "robot.local"))
        #expect(client.url.absoluteString == "ws://robot.local:8000/api/state/ws/full")
        #expect(URLComponents(url: client.url, resolvingAgainstBaseURL: false)?.query == nil)
    }

    @Test("visualization asks for motor angles and a matrix pose")
    func visualizationQuery() throws {
        var configuration = StateStreamClient.Configuration()
        configuration.options = .visualization
        let client = try StateStreamClient(
            address: RobotAddress(host: "robot.local"),
            configuration: configuration
        )
        let query = try #require(URLComponents(url: client.url, resolvingAgainstBaseURL: false)?.query)
        #expect(query == [
            "frequency=20",
            "with_head_pose=true",
            "with_head_joints=true",
            "with_body_yaw=true",
            "with_antenna_positions=true",
            "use_pose_matrix=true",
        ].joined(separator: "&"))
    }

    /// **The three `false`s are the assertion.** The daemon defaults
    /// `with_head_pose`, `with_body_yaw` and `with_antenna_positions` to *true*, so a
    /// preset that merely added `with_doa` would carry a full pose five times a
    /// second for a two-field reading. Leaving them `nil` looks like asking for
    /// nothing and asks for everything.
    @Test("hearing asks for direction of arrival and switches the geometry off")
    func hearingQuery() throws {
        var configuration = StateStreamClient.Configuration()
        configuration.options = .hearing
        let client = try StateStreamClient(
            address: RobotAddress(host: "robot.local"),
            configuration: configuration
        )
        let query = try #require(URLComponents(url: client.url, resolvingAgainstBaseURL: false)?.query)
        #expect(query == [
            "frequency=5",
            "with_head_pose=false",
            "with_head_joints=false",
            "with_body_yaw=false",
            "with_antenna_positions=false",
            "with_passive_joints=false",
            "with_doa=true",
        ].joined(separator: "&"))
    }

    /// The daemon's `with_target_*` flags trip an assertion that a blanket `except`
    /// swallows, leaving a stream that is open but permanently silent. Keeping them
    /// unrepresentable is the fix; this test states the intent so a future author
    /// does not "complete" the option set.
    @Test("no option maps to a with_target_* parameter")
    func targetParametersAreUnreachable() {
        var options = StateStreamOptions()
        options.frequency = 20
        options.headPose = true
        options.headJoints = true
        options.bodyYaw = true
        options.antennaPositions = true
        options.passiveJoints = true
        options.directionOfArrival = true
        options.poseAsMatrix = true
        let names = options.queryItems.map(\.name)
        #expect(names.allSatisfy { !$0.hasPrefix("with_target") })
    }

    @Test("booleans set to false are sent explicitly")
    func explicitFalse() {
        var options = StateStreamOptions()
        options.directionOfArrival = false
        #expect(options.queryItems == [URLQueryItem(name: "with_doa", value: "false")])
    }

    @Test("a whole frequency is not spelled with a decimal point")
    func frequencyFormatting() {
        var options = StateStreamOptions()
        options.frequency = 20
        #expect(options.queryItems.first?.value == "20")
        options.frequency = 12.5
        #expect(options.queryItems.first?.value == "12.5")
    }
}
