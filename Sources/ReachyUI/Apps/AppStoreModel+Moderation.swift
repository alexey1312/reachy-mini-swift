import ReachyKit

/// Where `AppModeration` meets the store's lists: the notice in front of Discover,
/// and the row that says Discover is hiding something.
extension AppStoreModel {
    /// Whether Discover has to show the notice rather than its apps.
    ///
    /// Not folded into `visibleApps`, unlike the sign-in gate: the list is still the
    /// list, and every test of it would otherwise have to agree to a notice first.
    /// The screen hides the rows while this is true.
    var showsCommunityNotice: Bool {
        shownSection == .discover && !moderation.hasAcceptedNotice
    }

    /// Whether hiding is what took something out of the list on screen — the cue
    /// for the row that says so and leads to the list of hidden authors. Over the
    /// whole catalogue rather than the search or the scope: the sentence is true of
    /// Discover either way, and a row that came and went with each keystroke would
    /// read as a result.
    var hidesSomeOfDiscover: Bool {
        shownSection == .discover && !discoverNeedsHFSignIn && !showsCommunityNotice
            && catalogue.contains(where: moderation.isHidden)
    }
}
