import ReachyDesign
import ReachyKit
import SwiftUI

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// A hosted JS app, full screen, with a Close that waits for the robot.
    ///
    /// Closing is never a swipe: the page has the robot, and it gives it back by
    /// putting it to sleep when asked (`JSAppHostModel.leave()`), which takes a few
    /// seconds the reader is shown rather than skipped.
    ///
    /// Part of the #159 prototype, behind `DEBUG`: it ships to nobody, and none of its
    /// states has a reference — the page is the whole of `.live`, and a web view
    /// renders nothing headless (`AppSettingsScreen` records the same limit). ADR 0006
    /// says what a shipping version owes rule 8.
    struct JSAppHostScreen: View {
        @State private var model: JSAppHostModel
        private let onClosed: () -> Void
        @Environment(\.openURL) private var openURL
        @Environment(\.reachyPreviewMode) private var previewMode

        init(model: JSAppHostModel, onClosed: @escaping () -> Void) {
            _model = State(initialValue: model)
            self.onClosed = onClosed
        }

        var body: some View {
            NavigationStack {
                content
                    .navigationTitle(Text(verbatim: model.app.title))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.reachy("Close"), action: close)
                                .disabled(model.phase == .leaving)
                        }
                    }
            }
            .onChange(of: model.closeRequested) { _, requested in
                if requested {
                    close()
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            switch model.phase {
            case let .failed(reason):
                ContentUnavailableView {
                    Label(.reachy("The app stopped"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: reason)
                } actions: {
                    Button(.reachy("Close"), action: close)
                }
            default:
                page
                    .contentLoading(isPresented: caption != nil, title: caption ?? .reachy("Loading the app…"))
            }
        }

        @ViewBuilder
        private var page: some View {
            if previewMode {
                Color.clear
            } else {
                JSAppWebView(model: model) { url in openURL(url) }
                    .ignoresSafeArea(edges: .bottom)
            }
        }

        /// What the page is doing while it is not yet the app — every step the SDK
        /// reports, because a minute of one unexplained spinner is how a slow relay
        /// reads as a broken app.
        private var caption: LocalizedStringResource? {
            switch model.phase {
            case .loading:
                .reachy("Loading the app…")
            case .connecting(.link):
                .reachy("Reaching the robot through Hugging Face…")
            case .connecting(.session):
                .reachy("Opening a session with the robot…")
            case .connecting(.wake):
                .reachy("Waking the robot…")
            case .connecting(nil):
                .reachy("Connecting to the robot…")
            case .leaving:
                .reachy("Putting the robot to sleep…")
            case .live, .left, .failed:
                nil
            }
        }

        private func close() {
            Task {
                await model.leave()
                onClosed()
            }
        }
    }
#endif
