import Foundation
@testable import ReachyKit
import Testing

/// A relayed robot from 1.10.0 on: the Hub's catalogue, `apps.install` by name, and
/// none of the daemon's own store. Shaped like `RemoteRobotConnection`'s apps half,
/// with the same identity `AppsRobotClient` reports, so one robot can be met over
/// both links against one catalogue cache.
private final class RelayStoreClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private let version: String?
    private(set) var catalogueCalls = 0
    private(set) var installs: [String] = []
    var outcome: AppJobMonitor.Outcome = .succeeded

    init(version: String? = "1.11.0") {
        self.version = version
    }

    var offersAppStore: Bool {
        false
    }

    var installsFromCatalogue: Bool {
        true
    }

    var offersRestart: Bool {
        false
    }

    func handshake() async throws -> RobotConnection.Handshake {
        try await .init(
            identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: version ?? "unknown"),
            status: daemonStatus()
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        .preview(state: .running, wirelessVersion: false, version: version)
    }

    func wakeUp() async throws -> String {
        ""
    }

    func gotoSleep() async throws -> String {
        ""
    }

    func availableApps() async throws -> [RobotApp] {
        lock.withLock { catalogueCalls += 1 }
        return [AppsRobotClient.app(name: "reachy_mini_radio", kind: "hf_space")]
    }

    func installFromCatalogue(named name: String) async throws -> AppJobMonitor.Outcome {
        lock.withLock { installs.append(name) }
        return outcome
    }
}

@MainActor
@Suite("Robot session — the store over the relay", .timeLimit(.minutes(1)))
struct RobotSessionRelayStoreTests {
    private func relayed(
        _ client: RelayStoreClient,
        catalogues: RobotCatalogueCache? = nil
    ) async throws -> RobotSession {
        let stores = try AppSessionStores.make("RobotSessionRelayStoreTests")
        let session = RobotSession(snapshots: stores.snapshots, appsCache: stores.apps, catalogues: catalogues) { _ in
            client
        }
        #expect(await session.connect(using: client))
        return session
    }

    /// Two flags, and the relay is the case where they part: no daemon store, and
    /// still something to browse and install from.
    @Test("a relayed robot offers the Hub's store and not the daemon's")
    func offersTheRelayStore() async throws {
        let session = try await relayed(RelayStoreClient())

        #expect(session.canInstallFromCatalogue)
        #expect(!session.canManageApps)
        #expect(session.canBrowseApps)
        #expect(!session.canRestartApp)
    }

    /// 1.9.0 mounts no JSON-RPC relay at all, so an Install there would spend three
    /// minutes learning nothing. Withheld on evidence, like every other relay gate.
    @Test("a relayed robot older than 1.10 offers no store")
    func withholdsTheStoreFromAnOldDaemon() async throws {
        let session = try await relayed(RelayStoreClient(version: "1.9.0"))

        #expect(!session.canInstallFromCatalogue)
        #expect(!session.canBrowseApps)
    }

    /// The daemon looks the name up as the catalogue lists it — the Space slug —
    /// and the outcome is the transport's, passed through untouched.
    @Test("an install is sent by the slug and answers the robot's outcome")
    func installsBySlug() async throws {
        let client = RelayStoreClient()
        client.outcome = .failed("could not install app")
        let session = try await relayed(client)
        let app = RobotApp.preview(name: "reachy_mini_radio")

        let outcome = try await session.installFromCatalogue(app)

        #expect(client.installs == ["reachy_mini_radio"])
        #expect(outcome == .failed("could not install app"))
    }

    @Test("a LAN session cannot install by name")
    func refusesWithoutTheRelay() async throws {
        let session = try await connectedAppSession(
            AppsRobotClient(),
            stores: AppSessionStores.make("RobotSessionRelayStoreTests")
        )

        #expect(!session.canInstallFromCatalogue)
        #expect(session.canRestartApp)
        await #expect(throws: ReachyKitError.appsUnavailable) {
            _ = try await session.installFromCatalogue(.preview(name: "reachy_mini_radio"))
        }
    }

    /// The record on disk is the robot's own store, installed rows and all. Over the
    /// relay nothing can confirm it, and serving it would answer `appCatalogue()`
    /// with the daemon's list instead of the Hub's.
    @Test("the LAN catalogue is neither shown over the relay nor overwritten by it")
    func keepsTheLANRecordApart() async throws {
        try await withTemporaryCatalogueCache { cache in
            let lanClient = AppsRobotClient()
            let lan = try await connectedAppSession(
                lanClient,
                stores: AppSessionStores.make("RobotSessionRelayStoreTests"),
                catalogues: cache
            )
            _ = try await lan.appCatalogue()
            lan.disconnect()

            let relayClient = RelayStoreClient()
            let relay = try await relayed(relayClient, catalogues: cache)
            #expect(relay.cachedAppCatalogue == nil)
            #expect(try await relay.appCatalogue().map(\.name) == ["reachy_mini_radio"])
            #expect(relayClient.catalogueCalls == 1)
            relay.disconnect()

            let back = try await connectedAppSession(
                lanClient,
                stores: AppSessionStores.make("RobotSessionRelayStoreTests"),
                catalogues: cache
            )
            #expect(back.cachedAppCatalogue?.count == 2)
        }
    }

    /// The same rule every LAN job follows: a record of the robot's apps taken before
    /// an install is wrong rather than old.
    @Test("an install over the relay forgets the stored LAN catalogue")
    func forgetsTheRecordOnInstall() async throws {
        try await withTemporaryCatalogueCache { cache in
            let lanClient = AppsRobotClient()
            let lan = try await connectedAppSession(
                lanClient,
                stores: AppSessionStores.make("RobotSessionRelayStoreTests"),
                catalogues: cache
            )
            _ = try await lan.appCatalogue()
            lan.disconnect()

            let relay = try await relayed(RelayStoreClient(), catalogues: cache)
            _ = try await relay.installFromCatalogue(.preview(name: "reachy_mini_radio"))
            relay.disconnect()

            let back = try await connectedAppSession(
                lanClient,
                stores: AppSessionStores.make("RobotSessionRelayStoreTests"),
                catalogues: cache
            )
            #expect(back.cachedAppCatalogue == nil)
        }
    }
}
