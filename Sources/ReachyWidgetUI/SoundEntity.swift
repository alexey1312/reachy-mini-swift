import AppIntents
import Foundation
import ReachyKit

/// One sound, as Siri and Shortcuts name it.
///
/// **The identifier is the filename, and that is the whole address.**
/// `POST /api/media/play_sound` takes a bare name, so `entities(for:)` rebuilds an
/// entity from the id alone — no cache, no robot, no join. `MoveEntity` is the only
/// other entity here that can do that; `RobotAppEntity` cannot, because its id is a
/// Hugging Face Space slug that means nothing until it is matched against an installed
/// list. Which is why a shortcut written months ago still resolves.
///
/// What it cannot promise is that the robot still *has* the sound: uploads live in
/// `/tmp/reachy_mini_sounds` and a restart empties it. ``RobotSoundPlayer`` is where
/// that is checked, and it refuses by name rather than reporting a success the daemon
/// would happily have given it.
public struct SoundEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reachy Mini Sound")
    public static let defaultQuery = SoundEntityQuery()

    /// The filename, extension included — exactly as the daemon lists it.
    public let id: String

    public init(filename: String) {
        id = filename
    }

    public var title: String {
        RobotSound.displayName(id)
    }

    /// The filename as the subtitle, because two sounds can reduce to the same spoken
    /// name (`airhorn.wav` and `airhorn.mp3`) and the extension is the only thing that
    /// tells them apart.
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(id)")
    }
}

/// Where the sound picker's list comes from.
///
/// **This device's library, and nothing else.** It is instant, it needs no network from
/// a process that has seconds, and it is the superset: the robot's copy is whatever
/// survived its last restart, while ``SoundLibraryStore`` holds everything the reader
/// has ever added. The same reasoning `MoveEntityQuery` gives for reading the cache
/// rather than the robot, one step further — there is no round trip here at all.
///
/// The cost is a sound that is *only* on the robot, uploaded from another device or by
/// an app. It can be played from the app's own screen and is absent from this picker,
/// because nothing in this process could have the bytes to send it again.
public struct SoundEntityQuery: EntityQuery, EntityStringQuery {
    private let names: @Sendable () async -> [String]

    public init() {
        self.init(names: { await SoundLibraryStore.default.sounds().map(\.filename) })
    }

    /// The seam. `SoundLibraryStore.default` is one directory shared by every suite
    /// `swift test --parallel` runs at once — and, unlike a cache, one whose contents
    /// belong to whoever is running the tests.
    init(names: @escaping @Sendable () async -> [String]) {
        self.names = names
    }

    /// Resolving a saved shortcut or a saved control. **Reads nothing, and never drops
    /// an identifier**: WidgetKit prunes a configuration whose entities come back
    /// short, so a sound the robot has forgotten must still resolve here — the refusal
    /// belongs to the moment the button is pressed, where there is somewhere to say it.
    public func entities(for identifiers: [String]) async throws -> [SoundEntity] {
        identifiers.map(SoundEntity.init(filename:))
    }

    public func suggestedEntities() async throws -> [SoundEntity] {
        await names().map(SoundEntity.init(filename:))
    }

    /// What makes "play the airhorn" resolve. Siri hands over the words it heard, and a
    /// sound is addressed by a filename — so the match is against the spoken form, the
    /// same trade `MoveEntityQuery` makes.
    public func entities(matching string: String) async throws -> [SoundEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await suggestedEntities()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(needle) || $0.id.localizedStandardContains(needle) }
    }
}
