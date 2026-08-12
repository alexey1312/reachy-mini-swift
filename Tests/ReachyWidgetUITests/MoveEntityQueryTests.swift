import Foundation
@testable import ReachyWidgetUI
import Testing

/// The move picker, and how a saved shortcut is resolved.
///
/// The interesting property is that resolution reads nothing at all: a move's
/// identifier carries its dataset and its name, which is what lets a shortcut
/// written a year ago still run against a robot that is asleep.
@Suite("Move entity query", .timeLimit(.minutes(1)))
struct MoveEntityQueryTests {
    private let dances = "pollen-robotics/reachy-mini-dances-library"
    private let emotions = "pollen-robotics/reachy-mini-emotions-library"

    private func query(_ index: [String: [String]]) -> MoveEntityQuery {
        MoveEntityQuery(index: { index })
    }

    // MARK: - The identifier is the move

    @Test("an identifier round-trips through a dataset and a move name")
    func roundTripsTheIdentifier() throws {
        let entity = MoveEntity(dataset: dances, move: "happy_dance")

        #expect(entity.id == "\(dances)#happy_dance")

        let parsed = try #require(MoveEntity(id: entity.id))
        #expect(parsed.dataset == dances)
        #expect(parsed.move == "happy_dance")
    }

    /// A dataset name is itself `owner/name`, which is the whole reason the
    /// separator is not a slash.
    @Test("a dataset's own slash is not mistaken for the separator")
    func survivesASlashInTheDataset() throws {
        let parsed = try #require(MoveEntity(id: "\(dances)#sad2"))

        #expect(parsed.dataset == dances)
        #expect(parsed.move == "sad2")
    }

    @Test("an identifier that is not a move resolves to nothing")
    func refusesAnUnparseableIdentifier() {
        #expect(MoveEntity(id: "not-a-move") == nil)
        #expect(MoveEntity(id: "#happy_dance") == nil)
        #expect(MoveEntity(id: "\(dances)#") == nil)
    }

    /// The one entity in this app that resolves with no cache and no robot.
    @Test("a saved shortcut resolves without reading the index at all")
    func resolvesWithoutTheIndex() async throws {
        let resolved = try await query([:]).entities(for: ["\(dances)#happy_dance"])

        #expect(resolved.map(\.id) == ["\(dances)#happy_dance"])
        #expect(resolved.first?.title == "happy dance")
    }

    // MARK: - Filling the picker

    /// The libraries' own order, not the dictionary's — `[String: [String]]` has
    /// none, so without this the picker reshuffles itself between launches.
    @Test("the picker lists the libraries in their declared order")
    func listsLibrariesInOrder() async throws {
        let listed = try await query([
            emotions: ["sad2"],
            dances: ["happy_dance"],
        ]).suggestedEntities()

        #expect(listed.map(\.dataset) == [dances, emotions])
    }

    /// A dataset the app does not declare is still in the cache if the robot ever
    /// listed it, and dropping it would hide moves the user can see in the app.
    @Test("a library the app does not know about is listed after the ones it does")
    func keepsUnknownLibraries() async throws {
        let listed = try await query([
            "someone/experimental": ["wiggle"],
            dances: ["happy_dance"],
        ]).suggestedEntities()

        #expect(listed.map(\.dataset) == [dances, "someone/experimental"])
    }

    @Test("an empty index offers an empty picker rather than throwing")
    func offersNothingQuietly() async throws {
        #expect(try await query([:]).suggestedEntities().isEmpty)
    }

    // MARK: - Matching a spoken name

    /// Siri hands over words, and a move's name is a file stem — so the match has
    /// to be against the spoken form rather than against `happy_dance`.
    @Test("a spoken name matches the move's displayed form, not its file stem")
    func matchesTheSpokenForm() async throws {
        let matched = try await query([dances: ["happy_dance", "sad2"]]).entities(matching: "happy dance")

        #expect(matched.map(\.move) == ["happy_dance"])
    }

    @Test("matching ignores case and takes a fragment")
    func matchesAFragment() async throws {
        let matched = try await query([dances: ["happy_dance", "sad2"]]).entities(matching: "HAPPY")

        #expect(matched.map(\.move) == ["happy_dance"])
    }

    @Test("no match is an empty list rather than every move")
    func refusesToGuess() async throws {
        let matched = try await query([dances: ["happy_dance"]]).entities(matching: "tango")

        #expect(matched.isEmpty)
    }

    // MARK: - What the picker shows

    /// Two libraries can hold a move of the same name, so the subtitle is what
    /// tells the rows apart.
    @Test("a move is subtitled with the library it came from")
    func namesTheLibrary() throws {
        let library = try #require(MoveLibrary.named(dances))

        #expect(library.title == .reachy("Dances"))
        #expect(MoveEntity(dataset: dances, move: "happy").title == "happy")
        #expect(MoveLibrary.named("someone/experimental") == nil)
    }
}
