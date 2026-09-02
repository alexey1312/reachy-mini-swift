import Foundation
@testable import ReachyKit
import Testing

/// What the daemon does **not** send about the app it is running.
///
/// `AppManager.start_app` files the status as
/// `AppInfo(name=app_name, source_kind=INSTALLED)` and nothing else, so a client
/// that takes it at face value shows a running app it can say nothing about — no
/// title, no icon, no description, and no settings page to open. The join lives in
/// `RobotSession.describedFromInstalled`; this is what holds it.
@MainActor
@Suite("Running app metadata", .timeLimit(.minutes(1)))
struct RunningAppMetadataTests {
    private func connected(_ client: any RobotAPIClient) async throws -> RobotSession {
        try await connectedAppSession(client, stores: .make("RunningAppMetadataTests"))
    }

    /// `AppManager.start_app` builds the status as
    /// `AppInfo(name=app_name, source_kind=INSTALLED)`, so `extra` arrives empty:
    /// no title, no emoji, no description and no `custom_app_url`. That last one
    /// is why a running app offered no Settings row while the same app in the
    /// store showed everything.
    @Test("the running app takes the title and the settings port from the installed list")
    func describesTheRunningAppFromTheInstalledList() async throws {
        let client = AppsRobotClient()
        client.installedFixtures = [AppsRobotClient.describedApp(
            name: "reachy_mini_conversation_app",
            spaceID: "pollen-robotics/reachy_mini_conversation_app",
            port: 7860
        )]
        let session = try await connected(client)
        client.setRunning(AppsRobotClient.status(name: "reachy_mini_conversation_app"))

        _ = try await session.currentApp()

        let app = try #require(session.runningApp?.app)
        #expect(app.title == "Reachy Mini Conversation App")
        #expect(app.customAppPort == 7860)
        #expect(app.emoji == "🎤")
        #expect(session.appSettingsURL(for: app)?.absoluteString == "http://127.0.0.1:7860/")
    }

    /// The join key is the entry point name, which is what both sides carry. A
    /// name that matches nothing passes through untouched: a wrong match would put
    /// another app's settings port on this one, which is worse than no port.
    @Test("an app with no installed twin is left exactly as the daemon sent it")
    func leavesAnUnknownRunningAppAlone() async throws {
        let client = AppsRobotClient()
        let session = try await connected(client)
        client.setRunning(AppsRobotClient.status(name: "someone_elses_app"))

        _ = try await session.currentApp()

        #expect(session.runningApp?.app.title == "Someone Elses App")
        #expect(session.runningApp?.app.customAppPort == nil)
    }

    /// The dock polls every ten seconds. Reading the installed list on each tick
    /// would be a Hugging Face round trip on the robot for a value that only
    /// changes when an app is installed or removed — both of which drop the cache
    /// themselves.
    @Test("the installed list is read once, however often the running app is polled")
    func readsTheInstalledListOnce() async throws {
        let client = AppsRobotClient()
        let session = try await connected(client)
        client.setRunning(AppsRobotClient.status(name: "dance_party"))

        _ = try await session.currentApp()
        _ = try await session.currentApp()

        #expect(client.installedCalls == 1)
    }

    /// A newer daemon that fills `extra` in itself needs no lookup at all.
    @Test("a status that already describes itself costs no extra call")
    func skipsTheLookupWhenTheDaemonDescribedTheApp() async throws {
        let client = AppsRobotClient()
        let session = try await connected(client)
        client.setRunning(RobotAppStatus(
            app: AppsRobotClient.describedApp(
                name: "reachy_mini_conversation_app",
                spaceID: "pollen-robotics/reachy_mini_conversation_app",
                port: 7860
            ),
            state: .running
        ))

        _ = try await session.currentApp()

        #expect(client.installedCalls == 0)
        #expect(session.runningApp?.app.customAppPort == 7860)
    }
}
