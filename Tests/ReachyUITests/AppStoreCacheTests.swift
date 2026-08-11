import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// What the store shows before the robot has answered, and what a revalidation
/// nobody asked for is allowed to say.
///
/// A file of its own because `AppStoreModelTests` is at SwiftLint's length limit;
/// `StoreRobotClient` is shared with it.
@MainActor
@Suite("App store cache", .timeLimit(.minutes(1)))
struct AppStoreCacheTests {
    /// The frame after a cold start. `.task` has not run, and the store is already
    /// a store rather than a spinner.
    @Test("a warmed store has its rows before anything is loaded")
    func warmedStoreShowsRowsBeforeLoading() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)

            #expect(!model.isContentLoading)
            model.section = .discover
            #expect(model.visibleApps.map(\.name) == ["reachy-mini-dance", "chess"])
            model.section = .installed
            #expect(model.visibleApps.map(\.name) == ["reachy_mini_dance"])
        }
    }

    /// Warmed rows are still owed a reading: without forcing the refresh the
    /// session would answer out of the very memory it was warmed into, and the
    /// robot would never be asked at all.
    @Test("a warmed store still asks the robot, exactly once")
    func warmedStoreRevalidates() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)
            let before = client.catalogueCalls

            await model.load(session: session)
            #expect(client.catalogueCalls == before + 1)

            // The debt is paid: a second visit to the tab is free again.
            await model.load(session: session)
            #expect(client.catalogueCalls == before + 1)
        }
    }

    /// Nobody asked for this read, so nothing about it is news — a red line under
    /// a perfectly usable menu is noise with nothing to act on.
    @Test("a silent revalidation that fails says nothing and keeps the rows")
    func silentRevalidationFailureIsQuiet() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)
            model.section = .discover
            let titles = model.visibleApps.map(\.title)
            client.failsCatalogue = true

            await model.load(session: session)

            #expect(model.visibleApps.map(\.title) == titles)
            #expect(model.lastError == nil)
            #expect(!model.isContentLoading)
        }
    }

    /// The failed revalidation left the debt unpaid, so the next visit tries again
    /// rather than settling for the cached list forever.
    @Test("a silent revalidation that failed is retried on the next visit")
    func silentRevalidationRetries() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)
            client.failsCatalogue = true
            await model.load(session: session)
            client.failsCatalogue = false
            let before = client.catalogueCalls

            await model.load(session: session)

            #expect(client.catalogueCalls == before + 1)
            #expect(model.lastError == nil)
        }
    }

    /// The user asked, so the answer is theirs.
    @Test("an explicit refresh over warmed rows still reports its failure")
    func warmedRefreshReportsFailure() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)
            client.failsCatalogue = true

            await model.load(session: session, refresh: true)

            #expect(model.lastError?.isEmpty == false)
            #expect(!model.visibleApps.isEmpty)
        }
    }

    /// A background read must not clear a refusal somebody is still reading.
    @Test("a silent revalidation that succeeds does not clear an action's failure")
    func silentRevalidationKeepsAnActionFailure() async throws {
        let client = StoreRobotClient()
        try await withWarmedSession(client: client) { session in
            _ = try await session.appCatalogue()
        } body: { session in
            let model = AppStoreModel(session: session)
            client.failsCatalogue = true
            await model.load(session: session, refresh: true)
            let reported = try #require(model.lastError)
            client.failsCatalogue = false

            await model.load(session: session)

            #expect(model.lastError == reported)
        }
    }
}
