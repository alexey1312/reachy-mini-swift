import Foundation
@testable import ReachyKit
import Testing

/// What the session leaves on disk, and what it picks back up. The point of all
/// of it is the frame after a cold start: the catalogues are in memory before the
/// screens that read them exist.
@MainActor
@Suite("Robot session catalogue cache", .timeLimit(.minutes(1)))
struct RobotSessionCatalogueCacheTests {
    private let dances = "pollen-robotics/reachy-mini-dances-library"
    private let emotions = "pollen-robotics/reachy-mini-emotions-library"
    private let music = "Anne-Charlotte/music"

    private func session(
        _ client: AppsRobotClient,
        _ catalogues: RobotCatalogueCache
    ) async throws -> RobotSession {
        try await connectedAppSession(
            client,
            stores: AppSessionStores.make("RobotSessionCatalogueCacheTests"),
            catalogues: catalogues
        )
    }

    @Test("a catalogue listed once is there on the next launch, without asking the robot")
    func warmsTheCatalogue() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            #expect(client.catalogueCalls == 1)
            first.disconnect()

            let second = try await session(client, cache)

            #expect(second.cachedAppCatalogue?.count == 2)
            let served = try await second.appCatalogue()
            #expect(served.count == 2)
            #expect(client.catalogueCalls == 1)
        }
    }

    /// The gate comes down on `.connected`, and the tab shell builds its models
    /// straight after — so anything not warmed by then is a spinner.
    @Test("the catalogue is in memory before the session reports connected")
    func warmsBeforeTheGateLifts() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            _ = try await first.moves(in: dances)
            first.disconnect()

            let second = try await session(client, cache)

            #expect(second.phase == .connected(.init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0")))
            #expect(second.cachedAppCatalogue != nil)
            #expect(second.cachedMoves(in: dances) != nil)
        }
    }

    @Test("every library listed lands in one record, and all of them come back")
    func warmsEveryLibrary() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            client.moveFixtures = [
                dances: ["happy_dance", "wave_hello"],
                emotions: ["curious"],
                music: [],
            ]
            let first = try await session(client, cache)
            for dataset in [dances, emotions, music] {
                _ = try await first.moves(in: dataset)
            }
            first.disconnect()

            let second = try await session(client, cache)

            #expect(second.cachedMoves(in: dances) == ["happy_dance", "wave_hello"])
            #expect(second.cachedMoves(in: emotions) == ["curious"])
            // A library the daemon really answered as empty, which is not the same
            // as one never fetched — `MovesModel` reads exactly that difference.
            #expect(second.cachedMoves(in: music) == [])
            #expect(client.moveCalls.count == 3)
        }
    }

    /// The index is one file, so it ages as one. Listing a library re-writes every
    /// library beside it, and stamping that write with the current date would keep
    /// a library warmed off disk alive for another whole window each time — which
    /// removes the only thing that ever invalidates this slot.
    @Test("listing a new library does not re-date the ones warmed off disk")
    func keepsTheAgeOfTheWarmedMoveIndex() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            client.moveFixtures = [emotions: ["curious"]]
            // Whole seconds, so the JSON round trip is exact rather than nearly so.
            let takenAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
            await cache.write(RobotMoveIndexRecord(
                robotID: "hw",
                movesByDataset: [dances: ["happy_dance"]],
                takenAt: takenAt
            ))

            let warmed = try await session(client, cache)
            _ = try await warmed.moves(in: emotions)

            let stored = try #require(await cache.record(RobotMoveIndexRecord.self, for: "hw"))
            #expect(stored.movesByDataset[dances] == ["happy_dance"])
            #expect(stored.movesByDataset[emotions] == ["curious"])
            #expect(stored.takenAt == takenAt)
        }
    }

    /// The other half of the same rule: with nothing warmed there is no age to
    /// carry, so the first listing of a session dates the record.
    @Test("a move index with nothing behind it is dated when it is written")
    func datesAFreshMoveIndex() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            client.moveFixtures = [dances: ["happy_dance"]]
            let before = Date()

            let fresh = try await session(client, cache)
            _ = try await fresh.moves(in: dances)

            let stored = try #require(await cache.record(RobotMoveIndexRecord.self, for: "hw"))
            #expect(stored.takenAt >= before)
        }
    }

    @Test("a removal drops the stored catalogue, so the next launch re-lists it")
    func forgetsTheCatalogueOnRemoval() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            _ = try await first.removeApp(named: "dance_party")
            first.disconnect()

            let second = try await session(client, cache)

            #expect(second.cachedAppCatalogue == nil)
            _ = try await second.appCatalogue()
            #expect(client.catalogueCalls == 2)
        }
    }

    @Test("reset-apps drops the stored catalogue too")
    func forgetsTheCatalogueOnResetApps() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            try await first.resetApps()
            first.disconnect()

            let second = try await session(client, cache)
            #expect(second.cachedAppCatalogue == nil)
        }
    }

    /// The move index is not invalidated by anything this app does: only Pollen
    /// publishing a dance changes it.
    @Test("a removal leaves the move index alone")
    func keepsTheMoveIndexOnRemoval() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            client.moveFixtures = [dances: ["happy_dance"]]
            let first = try await session(client, cache)
            _ = try await first.moves(in: dances)
            _ = try await first.appCatalogue()
            _ = try await first.removeApp(named: "dance_party")
            first.disconnect()

            let second = try await session(client, cache)

            #expect(second.cachedAppCatalogue == nil)
            #expect(second.cachedMoves(in: dances) == ["happy_dance"])
        }
    }

    /// Letting a robot go is not the same as its app list being wrong, and a cache
    /// cleared on disconnect would never survive the cold start it exists for.
    @Test("disconnecting keeps the stored catalogue")
    func keepsTheCatalogueOnDisconnect() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            first.disconnect()

            let second = try await session(client, cache)
            #expect(second.cachedAppCatalogue != nil)
        }
    }

    @Test("another robot's catalogue is not shown for this one")
    func refusesAnotherRobotsCatalogue() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            let first = try await session(client, cache)
            _ = try await first.appCatalogue()
            first.disconnect()

            client.hardwareID = "hw-2"
            let second = try await session(client, cache)
            #expect(second.cachedAppCatalogue == nil)
        }
    }

    @Test("a catalogue past its window is not warmed")
    func refusesAStaleCatalogue() async throws {
        try await withTemporaryCatalogueCache { cache in
            let client = AppsRobotClient()
            await cache.write(RobotAppCatalogueRecord(
                robotID: "hw",
                apps: RobotApp.previewCatalogue,
                takenAt: Date(timeIntervalSinceNow: -RobotAppCatalogueRecord.freshness - 60)
            ))

            let warmed = try await session(client, cache)
            #expect(warmed.cachedAppCatalogue == nil)
        }
    }

    /// A session with no cache is what every other suite builds, and it must reach
    /// no file system at all.
    @Test("a session with no cache persists nothing")
    func persistsNothingWithoutACache() async throws {
        let client = AppsRobotClient()
        let session = try await connectedAppSession(
            client,
            stores: AppSessionStores.make("RobotSessionCatalogueCacheTests")
        )

        _ = try await session.appCatalogue()
        session.disconnect()

        #expect(session.cachedAppCatalogue == nil)
    }
}
