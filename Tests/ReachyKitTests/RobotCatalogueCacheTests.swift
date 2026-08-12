import Foundation
@testable import ReachyKit
import Testing

/// The catalogues that outlive the process. Unlike the widget's `RobotAppsCache`
/// these carry everything the daemon sent, because a screen has to render a card
/// from them and an install has to hand the object back.
@Suite("Robot catalogue cache", .timeLimit(.minutes(1)))
struct RobotCatalogueCacheTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let robotID = "robot-a"

    private func appsRecord(
        robotID: String? = nil,
        apps: [RobotApp] = RobotApp.previewCatalogue,
        takenAt: Date? = nil
    ) -> RobotAppCatalogueRecord {
        RobotAppCatalogueRecord(robotID: robotID ?? self.robotID, apps: apps, takenAt: takenAt ?? now)
    }

    /// The whole reason the catalogue is stored in full rather than as summaries:
    /// `extra` is what `POST /api/apps/install` takes back.
    @Test("a catalogue comes back with every field the daemon sent")
    func roundTripsTheCatalogue() async throws {
        try await withTemporaryCatalogueCache { cache in
            let written = appsRecord(apps: [.previewConversation])
            await cache.write(written)

            let read = try #require(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now))
            #expect(read == written)
            #expect(read.apps[0].info.extra == RobotApp.previewConversation.info.extra)
            #expect(read.apps[0].customAppPort == 7860)
        }
    }

    @Test("a move index comes back")
    func roundTripsTheMoveIndex() async {
        await withTemporaryCatalogueCache { cache in
            let written = RobotMoveIndexRecord(
                robotID: robotID,
                movesByDataset: ["pollen-robotics/dances": ["happy_dance", "wave_hello"], "someone/music": []],
                takenAt: now
            )
            await cache.write(written)

            #expect(await cache.record(RobotMoveIndexRecord.self, for: robotID, at: now) == written)
        }
    }

    @Test("an empty cache knows nothing")
    func startsEmpty() async {
        await withTemporaryCatalogueCache { cache in
            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)
        }
    }

    @Test("a catalogue is visible only to the robot that produced it")
    func bindsTheCatalogueToRobotIdentity() async {
        await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) != nil)
            #expect(await cache.record(RobotAppCatalogueRecord.self, for: "robot-b", at: now) == nil)
        }
    }

    /// The path is a digest of the identity, so a mismatch normally cannot happen.
    /// The check inside the record is what makes a tampered directory harmless.
    @Test("a record for another robot is refused even where this one's is looked for")
    func refusesAMisplacedRecord() async throws {
        try await withTemporaryCatalogueCache { cache in
            let destination = cache.url(.apps, for: robotID)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(appsRecord(robotID: "robot-b")).write(to: destination)

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)
        }
    }

    @Test("a record written by another schema is refused")
    func refusesAnotherSchema() async throws {
        try await withTemporaryCatalogueCache { cache in
            let destination = cache.url(.apps, for: robotID)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let alien = RobotAppCatalogueRecord(
                schema: RobotCatalogueCache.schema + 1,
                robotID: robotID,
                apps: RobotApp.previewCatalogue,
                takenAt: now
            )
            try JSONEncoder().encode(alien).write(to: destination)

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)
        }
    }

    @Test("a truncated file reads as nothing rather than throwing")
    func survivesATruncatedFile() async throws {
        try await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())
            let destination = cache.url(.apps, for: robotID)
            let full = try Data(contentsOf: destination)
            try full.prefix(full.count / 2).write(to: destination)

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)
        }
    }

    @Test("a record past its window is refused, and the window differs by catalogue")
    func refusesAStaleRecord() async {
        await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())

            let window = RobotAppCatalogueRecord.freshness
            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now + window) != nil)
            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now + window + 1) == nil)
        }
        // A dataset index changes only when Pollen publishes a dance; an app list
        // changes whenever somebody installs one.
        #expect(RobotMoveIndexRecord.freshness > RobotAppCatalogueRecord.freshness)
        #expect(RobotAppCatalogueRecord.freshness == RobotAppsCache.freshness)
    }

    /// A clock that went backwards is not a record from the future gone old.
    @Test("a record dated in the future is not stale")
    func toleratesAClockGoingBackwards() async {
        await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now - 3600) != nil)
        }
    }

    /// The cache is an optimisation. Refusing an unreasonable payload is cheaper
    /// than defending a growing `Caches`, and the previous answer is still good.
    @Test("an oversized record is skipped and leaves the previous one standing")
    func refusesAnOversizedRecord() async {
        await withTemporaryCatalogueCache { cache in
            let good = appsRecord()
            await cache.write(good)

            let huge = String(repeating: "x", count: RobotCatalogueCache.maxRecordBytes)
            await cache.write(RobotMoveIndexRecord(
                robotID: robotID,
                movesByDataset: ["big": [huge]],
                takenAt: now
            ))
            await cache.write(appsRecord(apps: [.preview(name: huge, installed: true)]))

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == good)
            #expect(await cache.record(RobotMoveIndexRecord.self, for: robotID, at: now) == nil)
        }
    }

    @Test("one slot is dropped without the other")
    func removesOneSlot() async {
        await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())
            await cache.write(RobotMoveIndexRecord(robotID: robotID, movesByDataset: ["a": ["b"]], takenAt: now))

            await cache.remove(.apps, for: robotID)

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)
            #expect(await cache.record(RobotMoveIndexRecord.self, for: robotID, at: now) != nil)
        }
    }

    @Test("eviction keeps the connected robot and the most recent others")
    func evictsTheOldestRobots() async {
        await withTemporaryCatalogueCache { cache in
            let robots = (0 ..< RobotCatalogueCache.keptRobots + 2).map { "robot-\($0)" }
            for robot in robots {
                await cache.write(appsRecord(robotID: robot))
                // `contentModificationDate` has a resolution the loop can outrun.
                try? await Task.sleep(for: .milliseconds(20))
            }

            await cache.evict(keeping: robots[0])

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robots[0], at: now) != nil)
            let survivors = robots.suffix(RobotCatalogueCache.keptRobots - 1)
            for robot in survivors {
                #expect(await cache.record(RobotAppCatalogueRecord.self, for: robot, at: now) != nil)
            }
            for robot in robots.dropFirst().dropLast(RobotCatalogueCache.keptRobots - 1) {
                #expect(await cache.record(RobotAppCatalogueRecord.self, for: robot, at: now) == nil)
            }
        }
    }

    /// The system may empty `Caches` at any moment, which has to read as an empty
    /// cache rather than as a broken one.
    @Test("a vanished directory reads as empty and is rebuilt on the next write")
    func survivesAnEvictedCachesDirectory() async {
        await withTemporaryCatalogueCache { cache in
            await cache.write(appsRecord())
            try? FileManager.default.removeItem(at: cache.directory(for: robotID))

            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) == nil)

            await cache.write(appsRecord())
            #expect(await cache.record(RobotAppCatalogueRecord.self, for: robotID, at: now) != nil)
        }
    }

    /// A test bundle names no app group, which is the same shape as a fork without
    /// the entitlement — and the store has to keep working there rather than lose
    /// its root. The group arm cannot be exercised from here: `containerURL` is
    /// answered by the sandbox, not by anything injectable.
    @Test("with no app group named, the root stays in this process's own caches")
    func fallsBackToItsOwnCachesDirectory() {
        #expect(KnownRobots.appGroupIdentifier == nil)

        let root = RobotCatalogueCache.defaultRoot
        #expect(root.pathComponents.suffix(2) == ["ReachyMini", "catalogue"])

        let ownCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #expect(root.deletingLastPathComponent().deletingLastPathComponent() == ownCaches)
    }
}
