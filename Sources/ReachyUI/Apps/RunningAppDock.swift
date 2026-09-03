import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// The running app, in the tab accessory above the tab bar.
///
/// **It used to claim the row *below* the bar, and it never had it.** The strip was
/// a bottom `safeAreaInset` on the root `TabView`, on the reasoning that growing
/// that view's safe area would push the bar up and leave the strip underneath it —
/// the shape Telegram gives a minimized Mini App. A `safeAreaInset` does not shrink
/// the frame it is applied to, and the boundary between SwiftUI and the tab bar's
/// own controller does not carry the safe area across, so nothing moved: measured
/// off the reference images, the tab's content was byte-identical either way and
/// the bar was drawn straight under the opaque strip. With an app running there was
/// no tab bar on screen at all, for five releases.
///
/// So it is the Apple-Music accessory now, which is a slot the platform actually
/// has: `ReachyAccessoryPlacement` says which of the three shapes this is being
/// drawn in, and `ReachyTabAccessory` is where the fork lives. Tapping it opens the
/// full sheet; dismissing that sheet comes back here without stopping the app.
///
/// Presence, its animation and the keyboard all belong to whichever placement
/// modifier mounted it — the system animates its own slot, and two animations on
/// one arrival fight.
struct RunningAppDock: View {
    let session: RobotSession
    let model: RunningAppModel
    /// The conversation state the strip's two controls read and write. Owned by
    /// `ReachyTabShell`, so the strip and the conversation screen can never disagree
    /// about the robot's own microphone.
    let conversation: ConversationModel

    var body: some View {
        if let status = model.visibleStatus(for: session) {
            RunningAppDockContent(
                status: status,
                conversationTurn: conversation.turn,
                isMicrophoneMuted: conversation.isMicrophoneMuted,
                offersConversationControls: conversation.offersControls,
                isReachable: model.isReachable(session),
                busy: model.busy,
                wedged: model.wedged != nil,
                actionFailure: model.lastError,
                expand: { model.isExpanded = true },
                perform: perform
            )
            // A crash arrives on a poll rather than on a tap, so nothing else marks it.
            .sensoryFeedback(.error, trigger: status.state == .error) { wasFailed, isFailed in
                !wasFailed && isFailed
            }
        }
    }

    private func perform(_ action: RunningAppDockContent.Action) {
        Task {
            switch action {
            case .stop: await model.stop(session: session)
            case .restart: await model.restart(session: session)
            case .dismiss: model.dismissFailure(session)
            case .toggleMicrophone:
                guard let app = model.visibleStatus(for: session)?.app else { return }
                await conversation.setMicrophoneMuted(!conversation.isMicrophoneMuted, app: app, session: session)
            case .interrupt:
                guard let app = model.visibleStatus(for: session)?.app else { return }
                await conversation.interrupt(app: app, session: session)
            }
        }
    }
}

extension View {
    /// Opens the running app's page and keeps its reading fresh: the detail sheet,
    /// the status poll and the conversation stream.
    ///
    /// **The strip's placement is not here.** It is mounted by `ReachyTabShell`,
    /// through `reachyTabAccessory` on the `TabView` and `reachyTabAccessoryFallback`
    /// on each tab's content — exactly one of which is live. Hiding a layout effect
    /// behind a modifier called `runningAppDock` is what let this view assert for
    /// five releases that it moved the tab bar, with no call site in a position to
    /// notice that it did not.
    ///
    /// It lives here rather than in the root view because that reasoning belongs
    /// next to the thing it is about — and because the root view is already at its
    /// length limit.
    ///
    /// `store` and `install` are the shell's, not this modifier's: expanding the
    /// dock opens `AppDetailSheet`, the one page about an app, and that page can
    /// install, update and remove as well as stop. A model built here would be a
    /// second copy of the store's, disagreeing with it the moment either acted.
    func runningApp(
        session: RobotSession,
        model: RunningAppModel,
        store: AppStoreModel,
        install: AppInstallModel,
        conversation: ConversationModel
    ) -> some View {
        modifier(RunningAppModifier(
            session: session,
            model: model,
            store: store,
            install: install,
            conversation: conversation
        ))
    }
}

private struct RunningAppModifier: ViewModifier {
    let session: RobotSession
    let model: RunningAppModel
    let store: AppStoreModel
    let install: AppInstallModel
    let conversation: ConversationModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.reachyPreviewMode) private var previewMode
    /// The app the open sheet is about, captured when it appears.
    ///
    /// **Captured rather than re-read, which is what #70 changed here.** The content used
    /// to be `if let status = visibleStatus`, so a stopped app emptied the sheet and
    /// `visibleStatusChanged` dismissed it — taking any conversation screen pushed from
    /// it, and the transcript with it, which cannot be fetched again from anywhere.
    ///
    /// `AppStoreScreen`'s `.sheet(item:)` already did the right thing by holding the app,
    /// and the two were only different because this one read it out of the status. **It
    /// does not weaken "Stop closes the sheet"** — that is a separate, deliberate line in
    /// `RunningAppModel.stop(session:)`. What the old collapse actually covered was a
    /// crash, a widget stop and a self-exit, and in all three the honest result is the
    /// app's own page, frozen, saying what happened.
    @State private var expandedApp: RobotApp?

    /// Which app holds the robot has no push channel — `/api/state/ws/full` carries
    /// nothing about apps — so it has to be asked for. Not while backgrounded, and
    /// not over a relay: `RemoteRobotConnection` does not speak the apps protocol,
    /// so every tick would simply throw `.appsUnavailable`.
    private var polls: Bool {
        scenePhase == .active && model.canPoll(session) && !previewMode
    }

    private var visibleStatus: RobotAppStatus? {
        model.visibleStatus(for: session)
    }

    private var conversationStreamKey: String? {
        conversation.streamKey(for: visibleStatus, session: session, active: polls)
    }

    /// The app whose conversation is being followed, if any.
    private var conversationApp: RobotApp? {
        conversationStreamKey == nil ? nil : visibleStatus?.app
    }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.isExpanded) {
                if let app = expandedApp ?? visibleStatus?.app {
                    NavigationStack {
                        AppDetailSheet(
                            app: app,
                            model: store,
                            session: session,
                            install: install,
                            runningApp: self.model,
                            conversation: conversation
                        ) {
                            self.model.isExpanded = false
                        }
                    }
                    .presentationDetents([.large])
                    .reachySheet()
                }
            }
            .task(id: polls) {
                guard polls else { return }
                await self.model.poll(session: session)
            }
            // Mounted at the dock rather than on the conversation screen, so the record
            // covers the whole foreground session rather than only the seconds a screen
            // was open. It costs nothing new: this socket was already open here, and its
            // transcript and level frames were already arriving and being discarded.
            .task(id: conversationStreamKey) {
                await conversation.observe(app: conversationApp, session: session)
            }
            .onChange(of: visibleStatus) { _, status in
                self.model.visibleStatusChanged(status)
                if let app = status?.app {
                    expandedApp = app
                } else {
                    // The record says where it stops. The sheet stays: see `expandedApp`.
                    conversation.noteAppEnded()
                }
            }
    }
}
