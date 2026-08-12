import CryptoKit
import Foundation
import os
import ReachyJSON

/// On-disk store for the catalogues a robot answers slowly.
///
/// Both of them cost the robot a Hugging Face round trip, and both used to live
/// only as long as a connection did — so every cold start showed a spinner for
/// something the app had already been told. What is kept here outlives the
/// process; what it is checked against on the way out is `RobotCatalogueRecord`.
///
/// Everything here is recoverable from the robot, which is why it lives in
/// `Caches` and may be evicted by the system at any time — the same contract
/// ``GeometryCache`` records. Three things are deliberately not what that cache
/// does:
///
/// - **No manifest marker.** A geometry entry is many files, so "downloaded
///   halfway" looks like a working cache. A record here is one file written with
///   `.atomic`, so completeness is free.
/// - **Softer eviction.** `GeometryCache.removeEntries(keeping:)` keeps exactly
///   one digest, because the alternative is megabytes of meshes. These are
///   kilobytes, and returning to the robot you used yesterday should not cost a
///   full re-listing.
/// - **A refused write is not an error.** This is an optimisation; an oversized
///   record is skipped and the previous one stays, because it is still valid and
///   merely older.
public actor RobotCatalogueCache {
    public enum Slot: String, Sendable, CaseIterable {
        case apps
        case moves

        var filename: String {
            "\(rawValue).json"
        }
    }

    /// Bumped when the *meaning* of a field changes, not its shape: an unknown key
    /// is something decoding already survives (project rule 3).
    public static let schema = 1
    /// `AppInfo.extra` is whatever the daemon read out of the Hub, so a catalogue
    /// has no shape-imposed ceiling — and the realistic figure is megabytes, not the
    /// tens of kilobytes guessed here first. Measured against a Wireless robot on
    /// 2026-08-12: 406 apps, a 3.84 MB record, of which 3.2 MiB is `extra.siblings`,
    /// the Hub's file listing per Space. At the 2 MB this started at, every write was
    /// refused and the cache stored a catalogue not once. What the headroom buys is
    /// the Hub roughly doubling; past that a cold start goes back to a spinner, which
    /// is the one failure this store is allowed to have.
    static let maxRecordBytes = 8 * 1024 * 1024
    /// The connected robot plus three. Enough that moving between two robots is
    /// free, small enough that the directory cannot grow without bound.
    static let keptRobots = 4

    private nonisolated static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "RobotCatalogueCache"
    )

    private let root: URL
    /// `FileManager` is not `Sendable`, so it is reached for per call rather than
    /// stored — `.default` is documented as safe to use from any thread.
    private nonisolated var fileManager: FileManager {
        .default
    }

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: RobotCatalogueCache {
        RobotCatalogueCache(root: defaultRoot)
    }

    /// The app group's container where there is one, and the process's own
    /// `Caches` where there is not.
    ///
    /// **An extension has its own caches directory, so the old root made this
    /// store invisible to every App Intent.** `MoveEntityQuery` answers out of the
    /// moves slot; running in the widget's process it read an empty directory and
    /// offered Shortcuts a picker with nothing in it. The apps slot never showed
    /// the bug because the widget reads `RobotAppsCacheStore`, which was in the
    /// group suite all along.
    ///
    /// Degrading to `.cachesDirectory` rather than failing is the same trade
    /// `KnownRobots.defaults` makes, for the same reason: a fork without the
    /// entitlement keeps a working cache instead of none.
    ///
    /// Nothing is migrated across the move. Every record here is recoverable from
    /// the robot, so the whole cost is one Hugging Face round trip on the first
    /// connection after the update — which is what a cold start cost before this
    /// cache existed. The `Library/Caches` sub-path is kept so the directory still
    /// reads as purgeable rather than as user data.
    static var defaultRoot: URL {
        let ownCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let group = KnownRobots.appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return ownCaches.appendingPathComponent("ReachyMini/catalogue", isDirectory: true) }
        return container.appendingPathComponent("Library/Caches/ReachyMini/catalogue", isDirectory: true)
    }

    // MARK: - Layout

    /// A digest rather than the key itself. A robot's name is free text somebody
    /// typed, and a `/` or a `..` in it would leave the cache directory on write —
    /// `GeometryCache.isSafeMeshName` refuses such a name, and here hashing is
    /// cheaper than refusing.
    ///
    /// The raw key is stored *inside* the record and checked on the way out, so a
    /// directory that has been tampered with still cannot hand over another
    /// robot's menu.
    nonisolated func directory(for robotID: String) -> URL {
        let digest = SHA256.hash(data: Data(robotID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    /// Internal rather than private so a test can put a file where the store will
    /// look for it — the in-record identity check is only worth having if
    /// something can reach past the path.
    nonisolated func url(_ slot: Slot, for robotID: String) -> URL {
        directory(for: robotID).appendingPathComponent(slot.filename)
    }

    // MARK: - Reading

    /// `nil` for anything that cannot be shown: absent, unreadable, truncated,
    /// written by another schema, belonging to another robot, or past its window.
    public func record<Record: RobotCatalogueRecord>(
        _ type: Record.Type,
        for robotID: String,
        at date: Date = Date()
    ) -> Record? {
        guard let data = try? Data(contentsOf: url(Record.slot, for: robotID)),
              let record = try? JSONCodec.stored.decode(Record.self, from: data),
              record.isUsable(for: robotID, at: date)
        else { return nil }
        return record
    }

    // MARK: - Writing

    public func write(_ record: some RobotCatalogueRecord) {
        let destination = url(type(of: record).slot, for: record.robotID)
        guard let data = try? JSONCodec.stored.encode(record) else { return }
        guard data.count <= Self.maxRecordBytes else {
            Self.log.warning("Catalogue record too large to cache: \(data.count, privacy: .public) bytes")
            return
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a partial file left by a kill would otherwise survive the
            // restart it is meant to serve and decode into nothing.
            try data.write(to: destination, options: .atomic)
        } catch {
            Self.log.warning("Could not cache catalogue record: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops one slot for one robot, leaving the other alone.
    public func remove(_ slot: Slot, for robotID: String) {
        try? fileManager.removeItem(at: url(slot, for: robotID))
    }

    /// Keeps the connected robot and the `keptRobots - 1` most recently written
    /// others, and drops the rest.
    public func evict(keeping robotID: String) {
        let kept = directory(for: robotID).lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let others = entries
            .filter { $0.lastPathComponent != kept }
            .sorted { modified($0) > modified($1) }
        for entry in others.dropFirst(Self.keptRobots - 1) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private nonisolated func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
