import Foundation
import Observation
import ReachyKit

/// Report, hide and the notice — what App Review guideline 1.2 asks of a store that
/// lists other people's work (`docs/adr/0006-js-apps.md`, decision 4).
///
/// A model of its own rather than more state on `AppStoreModel`, because none of it
/// is about a robot: the authors a reader hid and the notice they agreed to belong
/// to the reader and outlive every connection, and the web apps' catalogue owes the
/// same three things. Reporting needs no state — it is the Hub's own form
/// (`RobotApp.reportURL`) — so what lives here is the other two.
///
/// **Only Discover is moderated, and Installed is not.** Discover is every Space
/// tagged as a Reachy Mini app, whoever wrote it. Installed is what is on the robot,
/// put there by its owner — and hiding an author there would leave an app on the
/// robot with no page left to stop or remove it from. So hiding is offered on a
/// catalogue card alone, and a hidden author's app that is already installed stays
/// in Installed until it is removed. Reporting is offered everywhere: it needs
/// nothing but the Space id, and an app worth reporting does not stop being one
/// once installed.
@MainActor
@Observable
final class AppModeration {
    /// Mirrors of the store, so `@Observable` sees a hide land — `pinnedIDs`'
    /// reason. Reading the store in a view would leave the list stale until
    /// something else redrew it.
    private(set) var hiddenAuthors: [String]
    private(set) var hasAcceptedNotice: Bool

    private let store: AppModerationStore

    init(store: AppModerationStore = AppModerationStore()) {
        self.store = store
        hiddenAuthors = store.hiddenAuthors
        hasAcceptedNotice = store.hasAcceptedNotice
    }

    func acceptNotice() {
        store.acceptNotice()
        hasAcceptedNotice = store.hasAcceptedNotice
    }

    /// A card whose author the reader hid. An app the Hub gives no author is never
    /// one — there is nobody to have hidden.
    func isHidden(_ app: RobotApp) -> Bool {
        guard let author = app.author else { return false }
        return hiddenAuthors.contains(author)
    }

    /// Whether a surface may offer to hide this app's author: a catalogue card with
    /// an author. An installed row is not one, for the reason the type's note gives.
    /// A card with an installed twin is not one either, which only the store can
    /// tell — surfaces ask `AppStoreModel.canHideAuthor(of:)`.
    func canHideAuthor(of app: RobotApp) -> Bool {
        !app.isInstalled && app.author?.isEmpty == false
    }

    func hideAuthor(of app: RobotApp) {
        guard canHideAuthor(of: app), let author = app.author else { return }
        store.hide(author)
        hiddenAuthors = store.hiddenAuthors
    }

    func unhide(author: String) {
        store.unhide(author)
        hiddenAuthors = store.hiddenAuthors
    }
}

#if DEBUG
    extension AppModeration {
        /// Parked in one state, and never written through: a preview must not read
        /// the simulator's own choices — a reader who hid somebody there would move a
        /// reference — and must not write to them either.
        static func preview(noticeAccepted: Bool = true, hiddenAuthors: [String] = []) -> AppModeration {
            let moderation = AppModeration()
            moderation.hasAcceptedNotice = noticeAccepted
            moderation.hiddenAuthors = hiddenAuthors
            return moderation
        }
    }
#endif
