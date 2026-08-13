import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

@MainActor
@Suite("App store pins", .timeLimit(.minutes(1)))
struct AppStorePinTests {
    /// Its own suite name: `swift test --parallel` shares one `UserDefaults` table.
    private func pinStore() throws -> PinnedAppStore {
        let defaults = try #require(UserDefaults(suiteName: "AppStorePinTests.\(UUID().uuidString)"))
        return PinnedAppStore(defaults: defaults)
    }

    private func loaded(pins: PinnedAppStore, client: StoreRobotClient = StoreRobotClient()) async -> AppStoreModel {
        let session = RobotSession { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        let model = AppStoreModel(session: session, pins: pins)
        await model.load(session: session)
        model.section = .discover
        return model
    }

    /// The context menu offers Start without the detail sheet's banner beneath it,
    /// so every condition that sheet renders as a sentence has to be a condition here.
    @Test("Start is offered for an installed app on a running backend")
    func offersStart() async throws {
        let model = try await loaded(pins: pinStore())
        model.section = .installed
        let installed = try #require(model.visibleApps.first)

        #expect(model.canStart(installed))
    }

    @Test("Start is withheld from an app that is not installed")
    func withholdsStartWhenNotInstalled() async throws {
        let model = try await loaded(pins: pinStore())
        let chess = try #require(model.visibleApps.first { $0.title == "Chess Coach" })

        #expect(!model.canStart(chess))
    }

    /// A stopped backend is a 90 s job to undo — the detail sheet says so in a banner
    /// rather than letting a tap meet the failure, and a menu has nowhere to say it.
    ///
    /// Built from a preview session rather than by stopping the client mid-test:
    /// `connect` refuses a stopped backend outright, and the predicate reads
    /// `lastStatus`, which only a poll would refresh.
    @Test("Start is withheld while the backend is stopped")
    func withholdsStartWhenBackendStopped() throws {
        let model = AppStoreModel.preview(
            session: .preview(status: .preview(state: .stopped)),
            section: .installed
        )
        let installed = try #require(model.visibleApps.first)

        #expect(!model.canStart(installed))
    }

    @Test("Start is withheld while another app holds the robot")
    func withholdsStartWhileBusy() throws {
        let model = AppStoreModel.preview(
            session: .preview(runningApp: .preview(.running)),
            section: .installed
        )
        let installed = try #require(model.visibleApps.first)

        #expect(!model.canStart(installed))
    }

    @Test("a pinned app is lifted above the daemon's ordering")
    func pinnedFirst() async throws {
        let model = try await loaded(pins: pinStore())
        let chess = try #require(model.visibleApps.first { $0.title == "Chess Coach" })

        model.togglePin(chess)

        #expect(model.visibleApps.map(\.title) == ["Chess Coach", "Dance Party"])
        #expect(model.isPinned(chess))
    }

    /// Unpinning has to restore the daemon's order rather than leave the app where
    /// the lift put it — the curated ordering is the store's only editorial signal.
    @Test("unpinning gives the daemon's ordering back")
    func unpinRestoresOrder() async throws {
        let model = try await loaded(pins: pinStore())
        let chess = try #require(model.visibleApps.first { $0.title == "Chess Coach" })

        model.togglePin(chess)
        model.togglePin(chess)

        #expect(model.visibleApps.map(\.title) == ["Dance Party", "Chess Coach"])
        #expect(!model.isPinned(chess))
    }

    /// A pin is a shortcut, never a filter: a search that excludes it still excludes it.
    @Test("search still wins over a pin")
    func searchOutranksPin() async throws {
        let model = try await loaded(pins: pinStore())
        let chess = try #require(model.visibleApps.first { $0.title == "Chess Coach" })
        model.togglePin(chess)

        model.searchText = "dance"

        #expect(model.visibleApps.map(\.title) == ["Dance Party"])
    }

    /// The pin has to survive the model being rebuilt — the shell builds a fresh one
    /// on every connection, and a pin that lived only in memory would read as lost.
    @Test("a pin is read back by the next model over the same store")
    func survivesAModel() async throws {
        let pins = try pinStore()
        let first = await loaded(pins: pins)
        let chess = try #require(first.visibleApps.first { $0.title == "Chess Coach" })
        first.togglePin(chess)

        let second = await loaded(pins: pins)

        #expect(second.visibleApps.map(\.title) == ["Chess Coach", "Dance Party"])
    }
}
