import Foundation

/// Where the chosen theme lives, bound to one `UserDefaults`.
///
/// The defaults are injected rather than reached for: `--parallel` runs suites
/// concurrently over a single `.standard` table, and production passes the shared
/// app-group suite so the widget process reads the same value. This type knows
/// about neither — it takes what it is given, exactly as `KnownRobotStore` does.
public struct ThemeStore {
    public static let key = "ReachyDesign.theme"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var theme: ReachyTheme {
        get {
            guard let raw = defaults.string(forKey: Self.key),
                  let theme = ReachyTheme(rawValue: raw)
            else { return .fallback }
            return theme
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
