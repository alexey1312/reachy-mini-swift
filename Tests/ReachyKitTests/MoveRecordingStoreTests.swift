import Foundation
@testable import ReachyKit
import Testing

@Suite("Recorded move store")
struct MoveRecordingStoreTests {
    /// Its own suite name per test: `swift test --parallel` shares one `UserDefaults`.
    private func makeStore() throws -> MoveRecordingStore {
        let defaults = try #require(UserDefaults(suiteName: "MoveRecordingStoreTests.\(UUID().uuidString)"))
        return MoveRecordingStore(defaults: defaults)
    }

    private func recording(_ name: String, frames: Int = 2) -> MoveRecording {
        MoveRecording(
            name: name,
            recordedAt: Date(timeIntervalSince1970: 100),
            frames: (0 ..< frames).map {
                MoveRecording.Frame(offset: Double($0) / 10, target: TeleopTarget(yaw: Double($0)))
            }
        )
    }

    @Test("a saved recording survives a second store over the same defaults")
    func persists() throws {
        let defaults = try #require(UserDefaults(suiteName: "MoveRecordingStoreTests.\(UUID().uuidString)"))
        MoveRecordingStore(defaults: defaults).save(recording("Wave"))

        let read = MoveRecordingStore(defaults: defaults).all
        #expect(read.map(\.name) == ["Wave"])
        #expect(read.first?.frames.count == 2)
        #expect(read.first?.frames.last?.target.yaw == 1)
    }

    /// Newest first: a recording is made to be played back straight away, and the one
    /// just captured is the one being tried out.
    @Test("the newest recording is first")
    func newestFirst() throws {
        let store = try makeStore()
        store.save(MoveRecording(name: "Older", recordedAt: Date(timeIntervalSince1970: 100), frames: []))
        store.save(MoveRecording(name: "Newer", recordedAt: Date(timeIntervalSince1970: 200), frames: []))

        #expect(store.all.map(\.name) == ["Newer", "Older"])
    }

    @Test("deleting removes only the one named")
    func deletes() throws {
        let store = try makeStore()
        let keep = recording("Keep")
        let drop = recording("Drop")
        store.save(keep)
        store.save(drop)

        store.delete(drop.id)

        #expect(store.all.map(\.name) == ["Keep"])
    }

    @Test("renaming keeps the frames and the id")
    func renames() throws {
        let store = try makeStore()
        let original = recording("Untitled")
        store.save(original)

        store.rename(original.id, to: "Hello wave")

        #expect(store.all.first?.name == "Hello wave")
        #expect(store.all.first?.id == original.id)
        #expect(store.all.first?.frames.count == 2)
    }

    /// The duration is what a row shows and what playback budgets against, and an
    /// empty recording has to answer something rather than crash on `frames.last`.
    @Test("duration is the last frame's offset, and zero without frames")
    func reportsDuration() {
        #expect(recording("Wave", frames: 3).duration == 0.2)
        #expect(MoveRecording(name: "Empty", recordedAt: Date(), frames: []).duration == 0)
    }
}
