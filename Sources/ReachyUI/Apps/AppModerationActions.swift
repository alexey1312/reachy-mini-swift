import ReachyKit
import SwiftUI

/// Report and hide — the two things a reader can do about an app somebody else
/// wrote, on its page and in its row's menu.
///
/// One view for both hosts, for the pin button's reason: the menu and the page must
/// not drift into offering different things about the same app. Report opens the
/// Hub's own form in the browser, so Hugging Face's moderation receives it and this
/// app keeps nothing. Hide acts at once and asks nothing: it is undone from the
/// list Discover leads to (`HiddenAuthorsScreen`), and a confirmation would stand
/// between a reader and the one control guideline 1.2 asks to be easy.
struct AppModerationActions: View {
    let app: RobotApp
    let moderation: AppModeration
    /// What the host does once the author is hidden. The page leaves: it is the page
    /// of an app the reader has just asked not to see.
    var afterHiding: () -> Void = {}

    var body: some View {
        if let reportURL = app.reportURL {
            Link(destination: reportURL) {
                Label(.reachy("Report this app"), systemImage: "flag")
            }
        }
        if moderation.canHideAuthor(of: app) {
            Button {
                moderation.hideAuthor(of: app)
                afterHiding()
            } label: {
                Label(.reachy("Hide this author's apps"), systemImage: "eye.slash")
            }
        }
    }
}
