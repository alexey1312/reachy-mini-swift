import Foundation
@testable import ReachyKit
import Testing

private final class HFRobotClient: RobotAPIClient, HFAuthClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var statusCalls = 0
    private(set) var savedTokens: [String] = []
    private(set) var refreshCalls = 0
    private(set) var deleteCalls = 0
    var refreshIsSkipped = false

    private var daemonState: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"enabled","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: daemonState)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        daemonState
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        "sleep"
    }

    func hfAuthStatus() async throws -> HFAuthStatus {
        lock.withLock { statusCalls += 1 }
        let linked = lock.withLock { !savedTokens.isEmpty && deleteCalls == 0 }
        return HFAuthStatus(isLoggedIn: linked, username: linked ? "alexey1312" : nil)
    }

    @discardableResult
    func saveHFToken(_ token: String) async throws -> String? {
        lock.withLock { savedTokens.append(token) }
        return "alexey1312"
    }

    func deleteHFToken() async throws {
        lock.withLock { deleteCalls += 1 }
    }

    @discardableResult
    func refreshRelay() async throws -> RelayRefresh {
        lock.withLock { refreshCalls += 1 }
        return RelayRefresh(
            status: refreshIsSkipped ? "skipped" : "requested",
            tokenAvailable: true,
            reason: refreshIsSkipped ? "relay_not_running" : nil
        )
    }
}

@MainActor
@Suite("Robot session Hugging Face account", .timeLimit(.minutes(1)))
struct RobotSessionHFAuthTests {
    private func connected(_ client: any RobotAPIClient) async -> RobotSession {
        let session = RobotSession { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    /// Reading the status costs the robot a `whoami` against the Hub every single
    /// time, so a screen that asks on every appearance would be paying for a
    /// network round trip to learn something that changes twice a year.
    @Test("the robot's account is read once and remembered")
    func cachesTheAccount() async throws {
        let client = HFRobotClient()
        let session = await connected(client)

        _ = try await session.robotHFAccount()
        _ = try await session.robotHFAccount()
        #expect(client.statusCalls == 1)

        _ = try await session.robotHFAccount(refresh: true)
        #expect(client.statusCalls == 2)
    }

    /// Linking is two calls: store the token, then kick the relay so the robot
    /// appears in "Your Reachies" without waiting for its next retry.
    @Test("linking stores the token and restarts the relay")
    func linksTheRobot() async throws {
        let client = HFRobotClient()
        let session = await connected(client)

        let refresh = try await session.linkRobot(token: "hf_token")

        #expect(client.savedTokens == ["hf_token"])
        #expect(client.refreshCalls == 1)
        #expect(refresh.didStart)
    }

    /// `save-token` already answers with the account name, so the linked state is
    /// known without asking the robot to run `whoami` again.
    @Test("linking leaves the account known without another round trip")
    func linkingFillsTheCache() async throws {
        let client = HFRobotClient()
        let session = await connected(client)

        _ = try await session.linkRobot(token: "hf_token")
        let account = try await session.robotHFAccount()

        #expect(account.isLoggedIn)
        #expect(account.username == "alexey1312")
        #expect(client.statusCalls == 0)
    }

    /// The daemon skips the reconnect when there is no relay to reconnect — and
    /// its own docstring warns that waiting for a state change then hangs forever.
    /// The caller has to be able to tell.
    @Test("a skipped relay refresh is reported rather than hidden")
    func reportsSkippedRefresh() async throws {
        let client = HFRobotClient()
        client.refreshIsSkipped = true
        let session = await connected(client)

        let refresh = try await session.linkRobot(token: "hf_token")

        #expect(refresh.didStart == false)
        #expect(refresh.reason == "relay_not_running")
    }

    @Test("unlinking clears the token and what was remembered about it")
    func unlinksTheRobot() async throws {
        let client = HFRobotClient()
        let session = await connected(client)
        _ = try await session.linkRobot(token: "hf_token")

        try await session.unlinkRobot()
        let account = try await session.robotHFAccount()

        #expect(client.deleteCalls == 1)
        #expect(account.isLoggedIn == false)
        #expect(client.statusCalls == 1)
    }

    @Test("a robot with no Hugging Face surface says so")
    func reportsMissingCapability() async {
        let session = await connected(HFRobotClient())
        #expect(session.canLinkHuggingFace)
    }
}

/// Taking a token away reaches further than putting one there: the data channel
/// carries `delete_hf_token` and no other part of the account.
@MainActor
@Suite("Unlinking over the relay")
struct RobotSessionUnlinkTests {
    /// Conforms to the narrow protocol alone, the way `RemoteRobotConnection` does.
    private final class RelayClient: RobotAPIClient, RobotUnlinkClient, @unchecked Sendable {
        private let lock = NSLock()
        private var deletions = 0

        var deleteCount: Int {
            lock.withLock { deletions }
        }

        func handshake() async throws -> RobotConnection.Handshake {
            .init(identity: .preview, status: .preview())
        }

        func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            .preview()
        }

        func wakeUp() async throws -> String {
            ""
        }

        func gotoSleep() async throws -> String {
            ""
        }

        func deleteHFToken() async throws {
            lock.withLock { deletions += 1 }
        }
    }

    /// A double that speaks neither protocol, which is what a Lite robot's client
    /// looks like to this question.
    private struct MuteClient: RobotAPIClient {
        func handshake() async throws -> RobotConnection.Handshake {
            .init(identity: .preview, status: .preview())
        }

        func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            .preview()
        }

        func wakeUp() async throws -> String {
            ""
        }

        func gotoSleep() async throws -> String {
            ""
        }
    }

    @Test("a relayed robot can be unlinked but not linked")
    func offersOnlyTheUnlink() {
        let session = RobotSession.preview(client: RelayClient())
        #expect(session.canUnlinkRobot)
        #expect(!session.canLinkHuggingFace)
    }

    @Test("the call reaches the narrow client")
    func sendsTheDeletion() async throws {
        let client = RelayClient()
        let session = RobotSession.preview(client: client)
        try await session.unlinkRobot()
        #expect(client.deleteCount == 1)
    }

    @Test("a client that speaks neither protocol refuses rather than pretending")
    func refusesWithoutTheCapability() async {
        let session = RobotSession.preview(client: MuteClient())
        #expect(!session.canUnlinkRobot)
        await #expect(throws: (any Error).self) { try await session.unlinkRobot() }
    }
}
