import AppIntents
import Foundation
import ReachyKit

/// One recorded move, as Siri and Shortcuts name it.
///
/// **The identifier carries the whole address of the move**, because the daemon
/// gives a move no identifier at all: `play/recorded-move-dataset/{dataset}/{move}`
/// takes two path components and `GET /api/move/running` answers with task UUIDs
/// that say nothing about what is playing. So an id here is `dataset#move`, and it
/// is self-sufficient — `entities(for:)` rebuilds an entity from the id alone,
/// with no cache and no robot, which is what lets a year-old shortcut still run.
///
/// `#` rather than `/`: a dataset name is itself `owner/name`, so a slash would
/// have to be split from the right and read as a convention. Neither a Hugging
/// Face dataset name nor a move's file stem can contain a `#`.
public struct MoveEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reachy Mini Move")
    public static let defaultQuery = MoveEntityQuery()

    static let separator: Character = "#"

    public let id: String
    public let dataset: String
    public let move: String

    public init(dataset: String, move: String) {
        id = "\(dataset)\(Self.separator)\(move)"
        self.dataset = dataset
        self.move = move
    }

    /// `nil` for an id that is not a move at all. The caller decides what an
    /// unparseable saved value becomes — see `MoveEntityQuery.entities(for:)`.
    public init?(id: String) {
        guard let index = id.firstIndex(of: Self.separator) else { return nil }
        let dataset = String(id[id.startIndex ..< index])
        let move = String(id[id.index(after: index)...])
        guard !dataset.isEmpty, !move.isEmpty else { return nil }
        self.init(dataset: dataset, move: move)
    }

    public var title: String {
        MoveLibrary.displayName(move)
    }

    /// The library's name as the subtitle, so "Happy" from Emotions and "Happy"
    /// from Dances are two rows a person can tell apart. A dataset the app does
    /// not know about is named as the robot spells it rather than hidden.
    public var displayRepresentation: DisplayRepresentation {
        guard let library = MoveLibrary.named(dataset) else {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(dataset)")
        }
        return DisplayRepresentation(title: "\(title)", subtitle: library.title)
    }
}

/// Where the move picker's list comes from.
///
/// **The cache and nothing else, unlike `RobotAppQuery`.** Listing the libraries
/// costs the robot a Hugging Face round trip *per dataset*, and there are three of
/// them — a picker that made a person wait for that would be worse than one
/// showing what the app last saw. `RobotCatalogueCache` keeps the index for a
/// week precisely because only Pollen publishing a new dance can invalidate it.
///
/// **And it never writes.** `RobotSession.persistMoveIndex` carries
/// `moveIndexTakenAt` across each write so the record ages as one unit; a second
/// writer stamping `Date()` from an extension would re-date every library the app
/// had merely read off disk, and the index would then never expire. Reading is
/// this side's whole job.
public struct MoveEntityQuery: EntityQuery, EntityStringQuery {
    private let index: @Sendable () async -> [String: [String]]

    public init() {
        self.init(index: {
            guard let robotID = RobotIntentTarget.knownRobot?.key else { return [:] }
            let record = await RobotCatalogueCache.default.record(RobotMoveIndexRecord.self, for: robotID)
            return record?.movesByDataset ?? [:]
        })
    }

    /// The seam. `RobotCatalogueCache.default` is one directory shared by every
    /// suite `swift test --parallel` runs at once.
    init(index: @escaping @Sendable () async -> [String: [String]]) {
        self.index = index
    }

    /// Resolving a saved shortcut. **Reads nothing at all**: the id is the move.
    ///
    /// This is the one entity in the app that can do that, and it is worth saying
    /// why the others cannot — `RobotAppEntity.id` is a Hugging Face Space slug
    /// that has to be joined against an installed list to mean anything, while a
    /// move is addressed by exactly the two strings its id contains. So a shortcut
    /// written a year ago against a robot that is asleep still resolves, and an
    /// identifier is never dropped.
    public func entities(for identifiers: [String]) async throws -> [MoveEntity] {
        identifiers.compactMap(MoveEntity.init(id:))
    }

    /// Filling the picker, in the libraries' own order rather than the dictionary's.
    public func suggestedEntities() async throws -> [MoveEntity] {
        let index = await index()
        let known = MoveLibrary.all.map(\.dataset)
        let extras = index.keys.filter { !known.contains($0) }.sorted()
        return (known + extras).flatMap { dataset in
            (index[dataset] ?? []).map { MoveEntity(dataset: dataset, move: $0) }
        }
    }

    /// What makes "play the happy dance" resolve. Siri hands over the words it
    /// heard, and the move's own name is a file stem — so the match is against the
    /// spoken form (`happy dance`), not against `happy_dance`.
    public func entities(matching string: String) async throws -> [MoveEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await suggestedEntities()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(needle) }
    }
}
