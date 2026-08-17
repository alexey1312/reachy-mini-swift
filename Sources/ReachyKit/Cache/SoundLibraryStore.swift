import Foundation
import os

/// The sounds this device holds, which is the only durable copy there is.
///
/// **This is not a cache, and that is why it does not live beside one.**
/// ``RobotCatalogueCache`` sits in `Library/Caches` because every record in it is
/// recoverable from the robot; a sound the user imported is not. The robot keeps its
/// copy in `/tmp/reachy_mini_sounds`, so a reboot empties it, and no route hands the
/// bytes back — `GET /api/media/sounds` answers names alone. Losing this directory
/// therefore loses the library, so it is `Library/Application Support`, where the
/// system does not reclaim it and a device backup carries it to the next phone.
///
/// It is **not keyed by robot identity**, unlike everything else under `Cache/`. A
/// library belongs to the person, not to a unit: the same airhorn is meant to reach
/// whichever robot is in front of them, and keying it per robot would make a second
/// robot start empty for no reason a reader could name.
///
/// The app group container is what lets an App Intent read it — the same reason
/// ``RobotCatalogueCache.defaultRoot`` moved there, after `MoveEntityQuery` spent a
/// release answering Shortcuts out of the extension's own empty directory.
public actor SoundLibraryStore {
    private nonisolated static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "SoundLibraryStore"
    )

    private let root: URL

    private nonisolated var fileManager: FileManager {
        .default
    }

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: SoundLibraryStore {
        SoundLibraryStore(root: defaultRoot)
    }

    /// The app group's container where there is one, and the process's own
    /// Application Support where there is not — the degradation
    /// ``KnownRobots/defaults`` makes, so a fork with no entitlement keeps a working
    /// library rather than none.
    static var defaultRoot: URL {
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let group = KnownRobots.appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return own.appendingPathComponent("ReachyMini/sounds", isDirectory: true) }
        return container.appendingPathComponent("Library/Application Support/ReachyMini/sounds", isDirectory: true)
    }

    // MARK: - Reading

    /// The library, sorted by the name a person reads rather than by the filename, so
    /// the screen and the Shortcuts picker agree on an order.
    ///
    /// Anything the daemon would refuse is filtered out rather than offered: a stray
    /// file in this directory is not a sound, and a row that can only fail is worse
    /// than no row.
    public func sounds() -> [RobotSound] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
            .filter { RobotSound.isSafeName($0) && RobotSound.isAllowedExtension($0) }
            .map(RobotSound.init(filename:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The bytes to send, read straight off disk.
    ///
    /// Throws rather than answering nil: a play that cannot find its own file is a
    /// failure worth a sentence, not an empty upload.
    public func data(named name: String) throws -> Data {
        guard RobotSound.isSafeName(name) else { throw ReachyKitError.soundNameRejected(name: name) }
        return try Data(contentsOf: url(for: name))
    }

    public func contains(_ name: String) -> Bool {
        guard RobotSound.isSafeName(name) else { return false }
        return fileManager.fileExists(atPath: url(for: name).path)
    }

    // MARK: - Writing

    /// Takes a copy of a file the user picked, under its own name.
    ///
    /// A same-named import overwrites, which is what the robot's own upload does, so
    /// the two stay one library rather than diverging on the second import of a file
    /// somebody re-downloaded.
    @discardableResult
    public func add(_ data: Data, named name: String) throws -> RobotSound {
        let safe = RobotSound.basename(name)
        guard RobotSound.isSafeName(safe) else { throw ReachyKitError.soundNameRejected(name: safe) }
        guard RobotSound.isAllowedExtension(safe) else { throw ReachyKitError.soundTypeUnsupported(name: safe) }
        guard data.count <= RobotSound.maxUploadBytes else {
            throw ReachyKitError.soundTooLarge(bytes: data.count, limit: RobotSound.maxUploadBytes)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // Atomic for the reason `RobotCatalogueCache.write` is: a kill mid-write would
        // otherwise leave a truncated file that is still a plausible-looking row.
        try data.write(to: url(for: safe), options: .atomic)
        return RobotSound(filename: safe)
    }

    /// Forgets this device's copy. The robot's is a separate deletion, on purpose —
    /// they are two libraries and a person may well want only one of them gone.
    public func remove(named name: String) {
        guard RobotSound.isSafeName(name) else { return }
        let target = url(for: name)
        // Already gone is the outcome asked for, so it is checked rather than caught:
        // a missing file must not log as a failure.
        guard fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            Self.log.warning("Could not remove a stored sound: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func url(for name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }
}
