import ReachyKit
import SwiftUI

/// What Discover says before it shows anybody's app for the first time.
///
/// App Review guideline 1.2 asks for an agreement before user-generated content is
/// shown, and Discover is exactly that: every Space tagged as a Reachy Mini app,
/// whoever wrote it — which, unlike a web page, then runs on the robot itself.
/// Versioned (`AppModerationStore.noticeVersion`), so a notice that comes to say
/// something new is read again.
///
/// **An overlay over Discover rather than a sheet at launch.** Installed, the dock
/// and everything else in the app are the reader's own robot and owe nobody a
/// notice; and a reader who never opens Discover never meets a stranger's app.
struct CommunityAppsNotice: View {
    let accept: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(.reachy("Apps from the community"), systemImage: "person.2")
        } description: {
            Text(.reachy(
                // swiftlint:disable:next line_length
                "Apps in Discover are published on Hugging Face by their authors, not by this app, and run on your robot with its camera, microphone and motors. Objectionable apps are not welcome: report one from its page and Hugging Face reviews it, or hide its author's apps on this device."
            ))
        } actions: {
            Button(.reachy("Agree and continue"), action: accept)
            if let policy = URL(string: "https://huggingface.co/content-policy") {
                Link(destination: policy) {
                    Text(.reachy("Hugging Face content policy"))
                }
            }
        }
    }
}
