import Foundation
import Observation
import ReachyKit

/// The soundboard: this device's library, the robot's temporary copy, and the gap
/// between them.
///
/// **Two libraries, and the screen is about which sounds are in both.** The robot keeps
/// uploads in `/tmp/reachy_mini_sounds`, so a reboot empties it and no route hands the
/// bytes back — `GET /api/media/sounds` answers names alone. The durable copy is
/// ``SoundLibraryStore`` on this device, and every play therefore sends the file first
/// when the robot is not known to have it. That is also the only defence against the
/// route's silence: `play_sound` answers `{"status": "ok"}` for a name that matches
/// nothing at all, so "it played" is never something the reply can establish.
@MainActor
@Observable
final class SoundboardModel {
    /// Where a sound is. **`unknown` is not a fourth shade of absent** — it is what a
    /// row says when the robot has not answered, and it exists so the screen never
    /// claims the robot is missing a sound it merely could not ask about.
    enum Presence: Sendable, Equatable {
        case both
        case deviceOnly
        case robotOnly
        case unknown
    }

    struct Row: Identifiable, Sendable, Equatable {
        let sound: RobotSound
        var presence: Presence
        var id: String {
            sound.filename
        }
    }

    /// Which copy a confirmed deletion is aimed at. One dialog for both, because they are
    /// the same gesture with opposite consequences: the robot's copy comes back with a
    /// tap, this device's does not come back at all.
    ///
    /// On the model rather than in the screen — the shape `RobotFilesModel.confirming`
    /// already has — because **a `confirmationDialog` captures as nothing**. Its wording
    /// is the only part a test can reach, and this is what makes it reachable.
    enum Confirmation: Equatable {
        case robot(Row)
        case device(Row)
    }

    /// Not `private(set)`: the screen sets it from a swipe and clears it on dismissal.
    var confirming: Confirmation?

    private(set) var rows: [Row] = []
    /// Whether the robot has answered a listing since this screen opened. Separate
    /// from `rows.isEmpty` for the reason every catalogue here keeps them separate: an
    /// empty library and a library nobody has asked about look identical on screen and
    /// must not, or the first frame claims an answer it does not have.
    private(set) var hasListed = false
    /// Whether a listing has been *tried*. Without it a failed load over an empty
    /// library leaves the spinner up for ever, with the reason it failed underneath it
    /// and invisible — the shape `MovesModel.isContentLoading` already carries.
    private(set) var hasAttempted = false
    private(set) var loading = false
    /// The name a transfer, a deletion or a play is in flight for, so one row can say
    /// so without the rest going dead.
    private(set) var busy: String?
    /// The last sound this app asked the robot to play. **A request, not a reading**:
    /// nothing reports whether a sound is playing, so the row says it was played and
    /// never that it is playing.
    private(set) var lastPlayed: String?
    private(set) var lastError: String?

    private let library: SoundLibraryStore

    init(library: SoundLibraryStore = .default) {
        self.library = library
    }

    /// A spinner over the whole content area only while there is nothing real to draw:
    /// nothing has answered, there is nothing stored on this device either, and a
    /// listing is either running or has not been tried yet.
    var isContentLoading: Bool {
        !hasListed && rows.isEmpty && (loading || !hasAttempted)
    }

    var missingFromRobot: [Row] {
        rows.filter { $0.presence == .deviceOnly }
    }

    /// Playing needs a backend — `play_sound` sits behind `get_backend` and answers 503
    /// without one — and needs nothing else. **It does not need an awake robot**: the
    /// speaker is not a motor, and a parked robot plays a sound perfectly well, so
    /// gating these rows on `isAwake` would refuse something that works.
    func rowsAreEnabled(_ session: RobotSession) -> Bool {
        busy == nil && session.canManageSounds && session.isBackendRunning
    }

    // MARK: - Listing

    func load(session: RobotSession) async {
        loading = true
        defer {
            loading = false
            hasAttempted = true
        }
        let stored = await library.sounds()
        do {
            let onRobot = try await session.sounds()
            rows = Self.merge(stored: stored, onRobot: onRobot)
            hasListed = true
        } catch {
            // The device's library is real whether or not the robot answered, so it
            // stays on screen — as `unknown`, because the one thing this app cannot do
            // here is say what the robot has.
            rows = stored.map { Row(sound: $0, presence: .unknown) }
            lastError.recordDaemonFailure(error)
        }
    }

    static func merge(stored: [RobotSound], onRobot: [RobotSound]) -> [Row] {
        let robotNames = Set(onRobot.map(\.filename))
        let storedNames = Set(stored.map(\.filename))
        let mine = stored.map {
            Row(sound: $0, presence: robotNames.contains($0.filename) ? .both : .deviceOnly)
        }
        // A sound the robot has and this device does not is somebody else's upload, or
        // this app's own from before a reinstall. It can be played and deleted and
        // never restored, because no route returns the bytes.
        let theirs = onRobot
            .filter { !storedNames.contains($0.filename) }
            .map { Row(sound: $0, presence: .robotOnly) }
        return sortedByName(mine + theirs)
    }

    /// One comparator, because a second copy is a second answer to what order this
    /// screen is in — and `sorted(by:)` is not stable, so the tie-break on the
    /// filename is what keeps two sounds with the same display name from swapping
    /// places between redraws.
    private static func sortedByName(_ rows: [Row]) -> [Row] {
        rows.sorted {
            let order = $0.sound.displayName.localizedCaseInsensitiveCompare($1.sound.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    // MARK: - Playing

    /// Sends the file first unless the robot is known to hold it, then plays it.
    ///
    /// The order is the whole feature: a sound the robot forgot over a reboot would
    /// otherwise be a tap that reports success and makes no noise.
    func play(_ row: Row, session: RobotSession) async {
        await perform(row.id) {
            if row.presence != .both, row.presence != .robotOnly {
                try await sendBytes(named: row.id, session: session)
            }
            try await session.playSound(named: row.id)
            lastPlayed = row.id
        }
    }

    /// Ends whatever the daemon's media player is playing, which may be a recorded
    /// move's music rather than anything on this screen — one player, one Stop.
    func stop(session: RobotSession) async {
        await perform(nil) {
            try await session.stopSound()
        }
    }

    // MARK: - Transfers

    func send(_ row: Row, session: RobotSession) async {
        await perform(row.id) {
            try await sendBytes(named: row.id, session: session)
        }
    }

    /// One tap after a robot restart. Sequential rather than concurrent: the daemon
    /// probes each file with GStreamer before answering, and a phone throwing six
    /// uploads at that in parallel is how a well-meaning refresh times out.
    func sendMissing(session: RobotSession) async {
        for row in missingFromRobot {
            await send(row, session: session)
            guard lastError == nil else { return }
        }
    }

    /// Takes a copy of a picked file, then sends it, so an import is one action rather
    /// than two rows to reconcile.
    func importFile(at url: URL, session: RobotSession?) async {
        let name = RobotSound.basename(url.lastPathComponent)
        await perform(name) {
            let data = try await PickedFile.read(at: url, limit: RobotSound.maxUploadBytes) {
                ReachyKitError.soundTooLarge(bytes: $0, limit: RobotSound.maxUploadBytes)
            }
            try await library.add(data, named: name)
            markStored(name)
            guard let session else { return }
            try await session.uploadSound(named: name, data: data)
            mark(name, as: .both)
        }
    }

    // MARK: - Removing

    /// Deletes the robot's copy and keeps this device's, which is what makes it
    /// recoverable with one tap.
    func deleteFromRobot(_ row: Row, session: RobotSession) async {
        await perform(row.id) {
            do {
                try await session.deleteSound(named: row.id)
            } catch let error as ReachyKitError where error.statusCode == 404 {
                // Already gone is the outcome that was asked for — and the 404 is real,
                // measured on 2026-08-17 rather than assumed: `delete_sound` is the one
                // route here that distinguishes a file that exists from one that does
                // not. Recognised by status rather than by case, because whether the
                // daemon attached a `detail` decides which case carries it.
            }
            if row.presence == .robotOnly {
                rows.removeAll { $0.id == row.id }
            } else {
                mark(row.id, as: .deviceOnly)
            }
        }
    }

    /// Forgets this device's copy. The robot's is a separate deletion on purpose: they
    /// are two libraries, and freeing space here is not the same wish as silencing the
    /// robot.
    func removeFromDevice(_ row: Row) async {
        await perform(row.id) {
            await library.remove(named: row.id)
            if row.presence == .both {
                mark(row.id, as: .robotOnly)
            } else {
                rows.removeAll { $0.id == row.id }
            }
        }
    }

    // MARK: - What a confirmation says

    /// **Titles that differ by more than punctuation from the buttons that open them.**
    /// The catalogue derives one Swift symbol per key, so `Remove from this device` and
    /// `Remove from this device?` would be a hard `xcstringstool` error rather than a
    /// warning — the trap `MaintenanceCard` had to dodge the same way.
    var confirmationTitle: LocalizedStringResource {
        switch confirming {
        case .device: .reachy("Forget this sound?")
        case .robot, nil: .reachy("Delete from the robot?")
        }
    }

    /// Each sentence says what survives, because that is the only difference between the
    /// two deletions and the one thing a reader has to know before tapping.
    func confirmationMessage(for target: Confirmation) -> LocalizedStringResource {
        switch target {
        case let .robot(row) where row.presence == .robotOnly:
            .reachy("\(row.sound.displayName) is not saved on this device, so this cannot be undone.")
        case let .robot(row):
            .reachy("\(row.sound.displayName) stays on this device and can be sent again.")
        case let .device(row) where row.presence == .both:
            .reachy("\(row.sound.displayName) stays on the robot until it restarts.")
        case let .device(row):
            .reachy("\(row.sound.displayName) is only on this device, so this cannot be undone.")
        }
    }

    // MARK: - Plumbing

    private func sendBytes(named name: String, session: RobotSession) async throws {
        let data = try await library.data(named: name)
        try await session.uploadSound(named: name, data: data)
        mark(name, as: .both)
    }

    private func mark(_ name: String, as presence: Presence) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        rows[index].presence = presence
    }

    /// A freshly imported sound is on the device and nowhere else until the upload
    /// lands, and it has to appear before then — the upload is the slow half.
    private func markStored(_ name: String) {
        guard !rows.contains(where: { $0.id == name }) else { return }
        rows.append(Row(sound: RobotSound(filename: name), presence: .deviceOnly))
        rows.sort {
            $0.sound.displayName.localizedCaseInsensitiveCompare($1.sound.displayName) == .orderedAscending
        }
    }

    /// One busy flag, one error slot, and a cancellation that changes neither.
    private func perform(_ name: String?, _ work: () async throws -> Void) async {
        busy = name
        defer { busy = nil }
        lastError = nil
        do {
            try await work()
        } catch {
            lastError.recordDaemonFailure(error)
        }
    }
}

#if DEBUG
    extension SoundboardModel {
        /// Lives here rather than in `Previews/`: every property this writes is
        /// `private(set)`, which `@testable` does not reach from another module.
        ///
        /// It takes rows directly rather than a library, because a preview has to be
        /// final on its first frame and both halves of a real load are asynchronous.
        static func preview(
            rows: [Row] = SoundboardModel.previewRows,
            hasListed: Bool = true,
            loading: Bool = false,
            busy: String? = nil,
            lastPlayed: String? = nil,
            error: String? = nil
        ) -> SoundboardModel {
            let model = SoundboardModel(library: SoundLibraryStore(root: previewRoot))
            model.rows = rows
            model.hasListed = hasListed
            model.loading = loading
            model.busy = busy
            model.lastPlayed = lastPlayed
            model.lastError = error
            return model
        }

        /// A directory nothing writes to. A preview that reached the real container
        /// would render whatever the developer's own library happens to hold.
        static var previewRoot: URL {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "ReachyMiniPreviewSounds",
                isDirectory: true
            )
        }

        static let previewRows: [Row] = [
            Row(sound: RobotSound(filename: "airhorn.wav"), presence: .both),
            Row(sound: RobotSound(filename: "doorbell.mp3"), presence: .both),
            Row(sound: RobotSound(filename: "rimshot.ogg"), presence: .deviceOnly),
            Row(sound: RobotSound(filename: "tada.m4a"), presence: .robotOnly),
        ]

        static let previewDeviceOnlyRows: [Row] = previewRows.map {
            Row(sound: $0.sound, presence: .deviceOnly)
        }

        static let previewUnknownRows: [Row] = previewRows.map {
            Row(sound: $0.sound, presence: .unknown)
        }
    }
#endif
