import Foundation
import OpenAPIRuntime
@testable import ReachyKit
import Testing

/// Fails every call with whatever it was handed. The point of both suites is
/// which errors reach `robotError`, so the double does nothing else.
private final class FailingClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":false,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"enabled","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        try throwIfFailing()
        return status
    }

    func wakeUp() async throws -> String {
        try throwIfFailing()
        return "wake"
    }

    func gotoSleep() async throws -> String {
        try throwIfFailing()
        return "sleep"
    }

    func availableApps() async throws -> [RobotApp] {
        try throwIfFailing()
        return []
    }

    func volume() async throws -> AudioLevel {
        try throwIfFailing()
        return AudioLevel(percent: 42, platform: "pulseaudio", device: "speaker")
    }

    private func throwIfFailing() throws {
        if let failure = lock.withLock({ failure }) {
            throw failure
        }
    }
}

/// The shape a cancelled request actually arrives in: the generated client wraps
/// the transport failure, and `URLSession` reports an abandoned task as -999 with
/// `NSLocalizedDescription = "cancelled"`.
private func wrappedCancellation() -> any Error {
    ClientError(
        operationID: "list_available_apps",
        operationInput: "",
        causeDescription: "Transport threw an error.",
        underlyingError: URLError(.cancelled)
    )
}

@MainActor
@Suite("A cancelled call is not a robot failure", .timeLimit(.minutes(1)))
struct RobotSessionCancellationTests {
    @Test("a cancelled transport call has nothing to say")
    func cancellationHasNoMessage() {
        #expect(RobotSession.message(for: wrappedCancellation()) == nil)
    }

    @Test("a structured concurrency cancellation is treated the same as -999")
    func swiftCancellationHasNoMessageEither() {
        #expect(RobotSession.message(for: CancellationError()) == nil)
    }

    @Test("a real failure still yields its sentence")
    func realFailureHasAMessage() {
        #expect(
            RobotSession.message(for: URLError(.cannotConnectToHost))
                == "Nothing answered. Check that the robot is on and on this network."
        )
    }

    @Test("reporting a cancellation writes nothing")
    func reportingCancellationWritesNothing() {
        let session = RobotSession.preview(error: nil)

        session.report(wrappedCancellation())

        #expect(session.robotError == nil)
    }

    @Test("reporting a cancellation does not erase the error already on screen")
    func reportingCancellationPreservesStandingError() {
        let standing = "The daemon rejected the request (HTTP 503)"
        let session = RobotSession.preview(error: standing)

        session.report(wrappedCancellation())

        #expect(session.robotError == standing)
    }

    @Test("reporting a real failure writes its sentence")
    func reportingRealFailureWrites() {
        let session = RobotSession.preview(error: nil)

        session.report(ReachyKitError.daemonRejected(statusCode: 503))

        #expect(session.robotError == ReachyKitError.daemonRejected(statusCode: 503).errorDescription)
    }

    @Test("a cancelled wake leaves the robot screen blank rather than saying \"cancelled\"")
    func cancelledWakeIsSilent() async {
        let session = RobotSession.preview(error: nil, client: FailingClient(failure: wrappedCancellation()))

        await session.wake()

        #expect(session.robotError == nil)
    }

    @Test("a wake the robot genuinely refused still reaches the robot screen")
    func refusedWakeIsReported() async {
        let refusal = ReachyKitError.daemonRejected(statusCode: 503)
        let session = RobotSession.preview(error: nil, client: FailingClient(failure: refusal))

        await session.wake()

        #expect(session.robotError == refusal.errorDescription)
    }
}

/// `robotError` is the robot's connection and power, and nothing else. A feature
/// funnel throws; the screen that called it owns the message. This is the suite
/// that keeps an Apps failure off the Robot tab.
@MainActor
@Suite("A feature failure belongs to its own screen", .timeLimit(.minutes(1)))
struct RobotSessionErrorOwnershipTests {
    private static let standingPowerFailure = "Robot backend did not start within 90 seconds."

    @Test("a refused apps call throws without touching the session")
    func appsFailureStaysOutOfTheSession() async {
        let refusal = ReachyKitError.daemonRejected(statusCode: 503)
        let session = RobotSession.preview(error: nil, client: FailingClient(failure: refusal))

        await #expect(throws: refusal) {
            _ = try await session.appCatalogue(refresh: true)
        }

        #expect(session.robotError == nil)
    }

    @Test("a refused apps call cannot overwrite a power failure being read")
    func appsFailureCannotOverwritePowerFailure() async {
        let refusal = ReachyKitError.daemonRejected(statusCode: 503)
        let session = RobotSession.preview(
            error: Self.standingPowerFailure,
            client: FailingClient(failure: refusal)
        )

        await #expect(throws: refusal) {
            _ = try await session.appCatalogue(refresh: true)
        }

        #expect(session.robotError == Self.standingPowerFailure)
    }

    @Test("a successful apps call cannot clear a power failure being read")
    func successfulAppsCallCannotClearPowerFailure() async throws {
        let session = RobotSession.preview(error: Self.standingPowerFailure, client: FailingClient())

        _ = try await session.appCatalogue(refresh: true)

        #expect(session.robotError == Self.standingPowerFailure)
    }

    @Test("a refused audio call throws without touching the session")
    func audioFailureStaysOutOfTheSession() async {
        let refusal = ReachyKitError.daemonRejected(statusCode: 422)
        let session = RobotSession.preview(error: nil, client: FailingClient(failure: refusal))

        await #expect(throws: refusal) {
            _ = try await session.volume()
        }

        #expect(session.robotError == nil)
    }
}
