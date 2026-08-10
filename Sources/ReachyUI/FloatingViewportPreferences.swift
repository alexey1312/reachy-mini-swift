import Foundation

/// Where the floating window's one preference lives between launches.
///
/// It is a preference rather than a placement, and the docked tab is what makes
/// the difference readable: a tab at the edge is somewhere the window *is*, so it
/// belongs to the connection and comes back with the next one. Being switched off
/// is not a place, and a reader who switched it off means it for longer than one
/// session — which is the whole complaint the switch answers.
///
/// Injectable for the reason `MovePlaybackStore` is: `swift test --parallel` runs
/// suites concurrently against one `UserDefaults` table, so a shared store makes
/// one suite's writes another's reads. `.standard` rather than the App Group's
/// suite because the widget has no floating window to have an opinion about.
struct FloatingViewportPreferences {
    static let key = "floatingViewport.isEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Absent reads as on: the window is what this app has always done, and a
    /// reader who has never found the switch has not asked for it to be off.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

#if DEBUG
    extension FloatingViewportPreferences {
        /// A suite nothing else reads, so a preview and a recorded reference cannot
        /// be changed by whatever the last run of the app left behind.
        static var preview: Self {
            Self(defaults: UserDefaults(suiteName: "ReachyUI.previews") ?? .standard)
        }
    }
#endif
