import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The IMU is read two ways and each spells "no reading" differently. Every shape
/// here comes from upstream: `routers/state.py` for REST (1.11.0), and
/// `process_command`'s `GetImuCmd` branch with its own tests
/// (`test_get_imu_with_reading`, `test_get_imu_without_imu`) for the relay.
@Suite("Reading the IMU from the robot", .timeLimit(.minutes(1)))
struct RobotIMUTransportTests {
    private static let reading = #"""
    {"accelerometer": [0.01, -0.02, 9.81], "gyroscope": [0.001, 0.002, -0.003],
     "quaternion": [1.0, 0.0, 0.0, 0.0], "temperature": 31.5}
    """#

    private func connection(answering stub: StubURLProtocol.Stub) throws -> RobotConnection {
        try RobotConnection(
            address: RobotAddress(host: "10.42.0.1"),
            session: StubURLProtocol.makeSession(["/api/state/imu": stub])
        )
    }

    // MARK: REST

    @Test("a reading comes through with its units intact")
    func readsAReading() async throws {
        let imu = try #require(await connection(answering: .init(statusCode: 200, json: Self.reading)).imuReading())

        #expect(imu.accelerometer == [0.01, -0.02, 9.81])
        #expect(imu.quaternion == [1.0, 0.0, 0.0, 0.0])
        #expect(imu.temperatureCelsius == 31.5)
    }

    /// A Lite unit, the simulator and a stale Wireless reading all answer `null`,
    /// which the generated client throws on inside the call rather than handing
    /// back — so this is the case the catch exists for.
    @Test("a null reading is no reading, not a failure")
    func nullIsAbsence() async throws {
        let imu = try await connection(answering: .init(statusCode: 200, json: "null")).imuReading()

        #expect(imu == nil)
    }

    /// Measured on a 1.10.0 Wireless: the relay already answered `get_imu`, the
    /// REST route did not exist yet.
    @Test("a daemon without the route has no reading to offer")
    func missingRouteIsAbsence() async throws {
        let imu = try await connection(answering: .init(statusCode: 404, json: #"{"detail":"Not Found"}"#))
            .imuReading()

        #expect(imu == nil)
    }

    /// Read as "none", a restarting daemon would make a robot with an IMU look like
    /// a Lite unit — and the health screen would clear the row it is showing.
    @Test("a restarting daemon is a failure, not a missing sensor")
    func unavailableBackendThrows() async throws {
        let connection = try connection(answering: .init(statusCode: 503, json: #"{"detail":"Backend not running"}"#))

        await #expect(throws: ReachyKitError.backendNotRunning) {
            try await connection.imuReading()
        }
    }

    /// Only a `null` at the top of the document is forgiven; a reading that is
    /// there but malformed is the daemon saying something this client misreads.
    @Test("a malformed reading is a failure")
    func malformedReadingThrows() async throws {
        let connection = try connection(answering: .init(statusCode: 200, json: #"{"accelerometer": "level"}"#))

        await #expect(throws: (any Error).self) {
            try await connection.imuReading()
        }
    }

    // MARK: Relay

    @Test("over the relay the reading arrives nested under the echoed command")
    func readsARelayedReading() async throws {
        let channel = FakeDataChannel(replies: [
            "get_imu": #"{"command": "get_imu", "imu": \#(Self.reading)}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        let imu = try #require(await connection.imuReading())

        #expect(imu.gyroscope == [0.001, 0.002, -0.003])
        #expect(imu.temperatureCelsius == 31.5)
    }

    @Test("over the relay a null reading is no reading")
    func relayedNullIsAbsence() async throws {
        let channel = FakeDataChannel(replies: [
            "get_imu": #"{"command": "get_imu", "imu": null}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.imuReading() == nil)
    }
}
