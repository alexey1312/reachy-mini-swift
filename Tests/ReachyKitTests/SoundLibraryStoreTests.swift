import Foundation
@testable import ReachyKit
import Testing

/// The device's own sound library — the durable copy, since the robot keeps its in
/// `/tmp` and no route hands the bytes back.
@Suite("Sound library store", .timeLimit(.minutes(1)))
struct SoundLibraryStoreTests {
    /// A root per test. There are no suites for a file system, so a shared default
    /// would have every `--parallel` suite writing into one directory — the reason
    /// `RobotSession.catalogues` defaults to `nil` rather than to a real store.
    private func withStore(_ body: (SoundLibraryStore, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SoundLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(SoundLibraryStore(root: root), root)
    }

    @Test("a sound survives being added and comes back by name")
    func addsAndReads() async throws {
        try await withStore { store, _ in
            let audio = Data([0x52, 0x49, 0x46, 0x46])
            try await store.add(audio, named: "airhorn.wav")

            #expect(await store.contains("airhorn.wav"))
            #expect(try await store.data(named: "airhorn.wav") == audio)
            #expect(await store.sounds().map(\.filename) == ["airhorn.wav"])
        }
    }

    /// By the name a person reads, so the screen and the Shortcuts picker cannot
    /// disagree about the order.
    @Test("the library is sorted by display name")
    func sortsByDisplayName() async throws {
        try await withStore { store, _ in
            for name in ["zebra.wav", "airhorn.wav", "Doorbell.mp3"] {
                try await store.add(Data([0x00]), named: name)
            }

            #expect(await store.sounds().map(\.filename) == ["airhorn.wav", "Doorbell.mp3", "zebra.wav"])
        }
    }

    /// The directory is not a library of everything: a stray file cannot become a row
    /// that can only fail, whether it arrived through this store or was dropped into the
    /// container by something else.
    @Test("a file the robot could not play is not offered as a sound")
    func ignoresWhatTheRobotWouldRefuse() async throws {
        try await withStore { store, root in
            try await store.add(Data([0x00]), named: "airhorn.wav")
            await #expect(throws: ReachyKitError.soundTypeUnsupported(name: "notes.txt")) {
                try await store.add(Data([0x00]), named: "notes.txt")
            }
            // Past the store, the way a file synced or copied into the group container
            // would arrive.
            try Data([0x00]).write(to: root.appendingPathComponent("readme.txt"))

            #expect(await store.sounds().map(\.filename) == ["airhorn.wav"])
        }
    }

    /// **Sanitising a name would be worse than refusing it.** The name *is* the
    /// identity here, so a silently rewritten one makes the device's copy and the
    /// robot's two different sounds, and a saved shortcut point at neither.
    @Test("a name that would leave the directory is refused, not repaired")
    func refusesUnsafeNames() async throws {
        try await withStore { store, _ in
            await #expect(throws: ReachyKitError.self) {
                try await store.add(Data([0x00]), named: "..")
            }
            await #expect(throws: ReachyKitError.soundNameRejected(name: #"a"b.wav"#)) {
                try await store.add(Data([0x00]), named: #"a"b.wav"#)
            }
            #expect(await store.sounds().isEmpty)
        }
        #expect(!RobotSound.isSafeName("sub/airhorn.wav"))
        #expect(!RobotSound.isSafeName(""))
        #expect(!RobotSound.isSafeName("bell\n.wav"))
        #expect(RobotSound.isSafeName("airhorn.wav"))
    }

    /// A path traversal in an import is reduced to its last component, the way the
    /// daemon reduces the one it is sent.
    @Test("an added name is reduced to its basename")
    func storesTheBasename() async throws {
        try await withStore { store, _ in
            let sound = try await store.add(Data([0x00]), named: "../../etc/airhorn.wav")

            #expect(sound.filename == "airhorn.wav")
            #expect(await store.sounds().map(\.filename) == ["airhorn.wav"])
        }
    }

    @Test("removing what is not there is the outcome that was asked for")
    func removesIdempotently() async throws {
        try await withStore { store, _ in
            try await store.add(Data([0x00]), named: "airhorn.wav")
            await store.remove(named: "airhorn.wav")
            await store.remove(named: "airhorn.wav")

            #expect(await store.sounds().isEmpty)
            #expect(await store.contains("airhorn.wav") == false)
        }
    }

    @Test("a file past the cap is refused, because the daemon's own is never applied")
    func refusesAnOversizedFile() async throws {
        try await withStore { store, _ in
            await #expect(throws: ReachyKitError.self) {
                try await store.add(Data(repeating: 0, count: RobotSound.maxUploadBytes + 1), named: "huge.wav")
            }
            #expect(await store.sounds().isEmpty)
        }
    }
}
