import Foundation
@testable import ReachyKit
import Testing

@Suite("PinnedAppStore")
struct PinnedAppStoreTests {
    /// Its own suite name per test: `swift test --parallel` runs suites concurrently and
    /// `UserDefaults.standard` is one table shared by all of them.
    private func makeStore() throws -> PinnedAppStore {
        let defaults = try #require(UserDefaults(suiteName: "PinnedAppStoreTests.\(UUID().uuidString)"))
        return PinnedAppStore(defaults: defaults)
    }

    @Test("an unpinned robot has nothing pinned")
    func startsEmpty() throws {
        let store = try makeStore()
        #expect(store.pinned(for: "b68ff6bbe47f0608").isEmpty)
    }

    @Test("a pin survives a second store over the same defaults")
    func persists() throws {
        let defaults = try #require(UserDefaults(suiteName: "PinnedAppStoreTests.\(UUID().uuidString)"))
        PinnedAppStore(defaults: defaults).toggle("dance_app", for: "b68ff6bbe47f0608")

        #expect(PinnedAppStore(defaults: defaults).pinned(for: "b68ff6bbe47f0608") == ["dance_app"])
    }

    @Test("toggling twice unpins")
    func togglesOff() throws {
        let store = try makeStore()
        store.toggle("dance_app", for: "b68ff6bbe47f0608")
        store.toggle("dance_app", for: "b68ff6bbe47f0608")

        #expect(store.pinned(for: "b68ff6bbe47f0608").isEmpty)
    }

    /// The order is the reading order of the section, so it is the order they were
    /// pinned in — not the order `Set` would have given back.
    @Test("pins keep the order they were added in")
    func keepsOrder() throws {
        let store = try makeStore()
        for app in ["dance_app", "conversation", "marionette"] {
            store.toggle(app, for: "b68ff6bbe47f0608")
        }

        #expect(store.pinned(for: "b68ff6bbe47f0608") == ["dance_app", "conversation", "marionette"])
    }

    /// Rule 4: a robot is its identity, and two robots on one network are two robots.
    @Test("pins do not leak between robots")
    func keyedByRobot() throws {
        let store = try makeStore()
        store.toggle("dance_app", for: "b68ff6bbe47f0608")

        #expect(store.pinned(for: "0f1e2d3c4b5a6978").isEmpty)
    }
}
