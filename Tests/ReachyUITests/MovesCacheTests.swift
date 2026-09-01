import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// What the moves screen shows before the robot has answered, and what a
/// revalidation nobody asked for is allowed to say.
///
/// A file of its own because `MovesModelTests` is at SwiftLint's length limit;
/// `MovesUIClient` is shared with it.
@MainActor
@Suite("Moves cache", .timeLimit(.minutes(1)))
struct MovesCacheTests {
    /// The frame after a cold start: rows, not a spinner.
    @Test("a warmed library has its moves before anything is loaded")
    func warmedLibraryShowsMovesBeforeLoading() async throws {
        let client = MovesUIClient(movesByDataset: [MovesModel.libraries[0].dataset: ["dance_one"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: MovesModel.libraries[0].dataset)
        } body: { session in
            let model = MovesModel(session: session)

            #expect(!model.isContentLoading)
            #expect(model.moves == ["dance_one"])
        }
    }

    /// The regression this guards: without forcing the refresh, the early return
    /// for "already on screen" swallows the fetch and the robot is never asked.
    @Test("a warmed library still asks the robot, exactly once")
    func warmedLibraryRevalidates() async throws {
        let client = MovesUIClient(movesByDataset: [MovesModel.libraries[0].dataset: ["dance_one"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: MovesModel.libraries[0].dataset)
        } body: { session in
            let model = MovesModel(session: session)
            let before = client.listCalls

            await model.load(session: session)
            #expect(client.listCalls == before + 1)

            await model.load(session: session)
            #expect(client.listCalls == before + 1)
        }
    }

    @Test("a silent revalidation that fails says nothing and keeps the rows")
    func silentRevalidationFailureIsQuiet() async throws {
        let dataset = MovesModel.libraries[0].dataset
        let client = MovesUIClient(movesByDataset: [dataset: ["dance_one"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: dataset)
        } body: { session in
            let model = MovesModel(session: session)
            client.setDataset(dataset, failing: true)

            await model.load(session: session)

            #expect(model.moves == ["dance_one"])
            #expect(model.lastError == nil)
            #expect(!model.isContentLoading)
        }
    }

    @Test("an explicit refresh over warmed rows still reports its failure")
    func warmedRefreshReportsFailure() async throws {
        let dataset = MovesModel.libraries[0].dataset
        let client = MovesUIClient(movesByDataset: [dataset: ["dance_one"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: dataset)
        } body: { session in
            let model = MovesModel(session: session)
            client.setDataset(dataset, failing: true)

            await model.load(session: session, refresh: true)

            #expect(model.lastError?.isEmpty == false)
            #expect(model.moves == ["dance_one"])
        }
    }

    /// Warming is per library, so a library nobody opened last time is still an
    /// honest content-loading state rather than an empty one.
    @Test("a library the cache never saw still loads from scratch")
    func unwarmedLibraryStillLoads() async throws {
        let warmed = MovesModel.libraries[0].dataset
        let client = MovesUIClient(movesByDataset: [warmed: ["dance_one"], MovesModel.libraries[1].dataset: ["joy"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: warmed)
        } body: { session in
            let model = MovesModel(session: session)
            model.selection = 1

            #expect(model.isContentLoading)
            #expect(model.moves.isEmpty)

            await model.load(session: session)
            #expect(model.moves == ["joy"])
        }
    }

    /// The relay plays moves and cannot list them: `play_recorded_move` is on the
    /// data channel and no index route is. The list this app kept off the same
    /// robot's own network is what it offers instead.
    @Test("a transport with no index route falls back to what was kept")
    func fallsBackToTheWarmedIndex() async throws {
        let dataset = MovesModel.libraries[0].dataset
        let client = MovesUIClient(movesByDataset: [dataset: ["dance_one"]])
        try await withWarmedSession(client: client) { session in
            _ = try await session.moves(in: dataset)
        } body: { session in
            client.setIndexRoute(false)

            let model = MovesModel(session: session)
            await model.load(session: session, refresh: true)

            #expect(model.moves == ["dance_one"])
            // Silent, unlike a refusal the daemon made: there was nothing to report
            // — this transport was never going to answer, and it did not fail to.
            #expect(model.lastError == nil)
        }
    }

    /// And with nothing kept there is nothing to show, so the refusal stands.
    @Test("no route and no kept list is still a failure")
    func reportsWhenNothingWasKept() async {
        let client = MovesUIClient(movesByDataset: [:])
        client.setIndexRoute(false)
        let session = RobotSession.preview(client: client)

        let model = MovesModel(session: session)
        await model.load(session: session, refresh: true)

        #expect(model.moves.isEmpty)
        #expect(model.lastError?.isEmpty == false)
    }
}
