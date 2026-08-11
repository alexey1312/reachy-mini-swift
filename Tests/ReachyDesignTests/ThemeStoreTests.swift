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

    /// `UserDefaults.string(forKey:)` coerces a stored number to its string
    /// representation ("42"), so this falls back through the *second* guard —
    /// `ReachyTheme(rawValue:)` rejecting a raw value that matches no case — the
    /// same path `unknownValue` above already covers, not a genuine type mismatch.
    @Test("a stored number coerces to a string that matches no case, and falls back")
    func wrongTypeCoercesToString() {
        let defaults = makeDefaults(#function)
        defaults.set(42, forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }

    /// `Data` is not coerced to a string at all, so `string(forKey:)` genuinely
    /// returns nil here — the first guard, and the case `wrongTypeCoercesToString`
    /// above cannot exercise.
    @Test("a value string(forKey:) cannot coerce at all falls back")
    func wrongTypeReturnsNil() {
        let defaults = makeDefaults(#function)
        defaults.set(Data(), forKey: ThemeStore.key)
        #expect(ThemeStore(defaults: defaults).theme == .graphite)
    }
}
