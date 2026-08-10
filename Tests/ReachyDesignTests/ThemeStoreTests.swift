import Foundation
@testable import ReachyDesign
import Testing

/// One suite name per test, because `--parallel` runs suites concurrently and a
/// shared `UserDefaults` table is exactly the global state that makes two green
/// suites turn red together. `KnownRobotStore` takes its defaults for the same
/// reason.
private func makeDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "ThemeStoreTests.\(name)")!
    defaults.removePersistentDomain(forName: "ThemeStoreTests.\(name)")
    return defaults
}

@Suite("Theme store")
struct ThemeStoreTests {
    @Test("an untouched store reports the fallback")
    func emptyStore() {
        let store = ThemeStore(defaults: makeDefaults(#function))
        #expect(store.theme == .graphite)
    }

    @Test("a written theme reads back")
    func roundTrip() {
        let store = ThemeStore(defaults: makeDefaults(#function))
        store.theme = .orchid
        #expect(store.theme == .orchid)
    }

    @Test("a second store over the same defaults sees the write")
    func sharedAcrossInstances() {
        let defaults = makeDefaults(#function)
        ThemeStore(defaults: defaults).theme = .teal
        #expect(ThemeStore(defaults: defaults).theme == .teal)
    }

    /// The downgrade case: a build that predates a theme reads its name and must not
    /// crash or render an empty tint.
    @Test("an unknown raw value falls back")
    func unknownValue() {
        let defaults = makeDefaults(#function)
        defaults.set("chartreuse", forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }

    @Test("a value of the wrong type falls back")
    func wrongType() {
        let defaults = makeDefaults(#function)
        defaults.set(42, forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }
}
