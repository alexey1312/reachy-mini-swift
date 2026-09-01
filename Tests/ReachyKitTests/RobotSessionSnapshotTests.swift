import Foundation
@testable import ReachyKit
import Testing

/// The widget shows what the session last saw, so the session has to leave it
/// somewhere — and take it away again when there is nothing left to describe.
@MainActor
@Suite("Session snapshot", .timeLimit(.minutes(1)))
struct RobotSessionSnapshotTests {
    private final class Client: RobotAPIClient, MovePlaybackClient, @unchecked Sendable {
        let identity = RobotIdentity(hardwareID: "hw-widget", name: "kitchen", daemonVersion: "1.9.0")
        var motorMode: Components.Schemas.MotorControlMode = .enabled

        func handshake() async throws -> RobotConnection.Handshake {
            try await .init(identity: identity, status: daemonStatus())
        }

        func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            .preview(state: .running, motorMode: motorMode, wirelessVersion: false)
        }

        func wakeUp() async throws -> String {
            ""
        }

        func gotoSleep() async throws -> String {
            ""
        }
    }

    private func store() throws -> RobotSnapshotStore {
        try RobotSnapshotStore(
            defaults: #require(UserDefaults(suiteName: "RobotSessionSnapshotTests.\(UUID().uuidString)"))
        )
    }

    private func session(_ client: Client, _ store: RobotSnapshotStore) -> RobotSession {
        RobotSession(snapshots: store) { _ in client }
    }

    @Test("connecting records what the widget will show")
    func recordsOnConnect() async throws {
        let store = try store()
        let session = session(Client(), store)

        await session.connect(to: RobotAddress(host: "127.0.0.1"))

        let snapshot = try #require(store.current)
        #expect(snapshot.robotName == "kitchen")
        #expect(snapshot.isAwake)
    }

    /// A robot with its motors off is a different thing to show, and the widget
    /// has no way to work that out for itself.
    @Test("an asleep robot is recorded as asleep")
    func recordsSleep() async throws {
        let store = try store()
        let client = Client()
        client.motorMode = .disabled

        await session(client, store).connect(to: RobotAddress(host: "127.0.0.1"))

        #expect(try #require(store.current).isAwake == false)
    }

    /// Disconnecting is deliberate. Leaving the last reading behind would have the
    /// widget keep describing a robot the user let go of.
    @Test("disconnecting takes the snapshot away")
    func clearsOnDisconnect() async throws {
        let store = try store()
        let session = session(Client(), store)
        await session.connect(to: RobotAddress(host: "127.0.0.1"))
        #expect(store.current != nil)

        session.disconnect()

        #expect(store.current == nil)
    }

    /// A failed attempt has nothing to describe, and must not overwrite a good
    /// reading with a blank one.
    @Test("a failed connection leaves an earlier snapshot alone")
    func keepsTheSnapshotOnFailure() async throws {
        let store = try store()
        let earlier = RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        store.write(earlier)
        let session = RobotSession(snapshots: store) { _ in
            throw ReachyKitError.daemonRejected(statusCode: 503)
        }

        await session.connect(to: RobotAddress(host: "127.0.0.1"))

        #expect(store.current == earlier)
    }

    @Test("connecting another robot does not inherit the previous robot's app")
    func dropsAnotherRobotsRunningApp() async throws {
        let store = try store()
        let earlier = RobotSnapshot(
            robotID: "another-robot",
            robotName: "office",
            isAwake: true,
            runningApp: "Dance Party",
            runningAppName: "dance_party",
            runningAppTakenAt: Date(),
            takenAt: Date()
        )
        store.write(earlier)

        await session(Client(), store).connect(to: RobotAddress(host: "127.0.0.1"))

        let current = try #require(store.current)
        #expect(current.robotID == "hw-widget")
        #expect(current.runningApp == nil)
        #expect(current.runningAppName == nil)
    }
}
