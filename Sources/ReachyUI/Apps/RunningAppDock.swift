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

    var body: some View {
        if let status = model.visibleStatus(for: session) {
            RunningAppDockContent(
                status: status,
                conversationTurn: model.conversationTurn,
                isMicrophoneMuted: model.isMicrophoneMuted,
                offersConversationControls: model.offersConversationControls,
                isReachable: model.isReachable(session),
                busy: model.busy,
                wedged: model.wedged != nil,
                actionFailure: model.lastError,
                expand: { model.isExpanded = true },
                perform: perform
            )
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
                await model.setMicrophoneMuted(!model.isMicrophoneMuted, on: session, app: app)
            case .interrupt:
                guard let app = model.visibleStatus(for: session)?.app else { return }
                await model.interrupt(on: session, app: app)
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
        install: AppInstallModel
    ) -> some View {
        modifier(RunningAppModifier(session: session, model: model, store: store, install: install))
    }
}

private struct RunningAppModifier: ViewModifier {
    let session: RobotSession
    let model: RunningAppModel
    let store: AppStoreModel
    let install: AppInstallModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.reachyPreviewMode) private var previewMode

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
        model.conversationStreamKey(for: visibleStatus, session: session, active: polls)
    }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.isExpanded) {
                // Read afresh rather than captured: an app that stops while the
                // sheet is open should close it, not leave a page about a process
                // that no longer exists.
                if let status = visibleStatus {
                    NavigationStack {
                        AppDetailSheet(
                            app: status.app,
                            model: store,
                            session: session,
                            install: install,
                            runningApp: self.model
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
            .task(id: conversationStreamKey) {
                let status = conversationStreamKey == nil ? nil : visibleStatus
                await self.model.observeConversation(status: status, session: session)
            }
            .onChange(of: visibleStatus) { _, status in
                self.model.visibleStatusChanged(status)
            }
    }
}

/// The strip itself. Split from its container so it can be previewed at
/// `.sizeThatFitsLayout` without a root view around it.
struct RunningAppDockContent: View {
    enum Action {
        case stop
        case restart
        /// Only offered for a dead app: there is nothing left to stop, and the row
        /// would otherwise sit there forever.
        case dismiss
        case toggleMicrophone
        /// Offered only while the robot is speaking — which is the moment anybody
        /// reaches for it, and what keeps the row from growing a fourth control.
        case interrupt
    }

    let status: RobotAppStatus
    var conversationTurn: ConversationTurn?
    var isMicrophoneMuted = false
    var offersConversationControls = false
    var isReachable = true
    var busy = false
    /// The transition has outlasted its deadline: only the robot's software can end
    /// it now. See ``RunningAppModel/wedged``.
    var wedged = false
    /// What the daemon answered the last Stop or Restart with. The strip's one
    /// caption line is the only place it can be read from here.
    var actionFailure: String?
    let expand: () -> Void
    let perform: (Action) -> Void

    @Environment(\.reachyAccessoryPlacement) private var placement

    private var hasFailed: Bool {
        status.state == .error
    }

    /// **Both controls are refused by the daemon once the slot is wedged**, and
    /// refused identically: `stop_current_app` raises on `STOPPING` and
    /// `restart_current_app` calls it first, so each answers the same 400
    /// (`apps/manager.py:275-279`, `:357-369`). Leaving them live invited exactly
    /// the tapping that filled the 2026-08-08 timeline with 400s.
    private var canAct: Bool {
        !busy && isReachable && !wedged
    }

    var body: some View {
        switch placement {
        case .inline:
            inlineRow
        case .expanded:
            // No surface: the system's slot draws a capsule of its own, and an
            // opaque fill inside it renders as a second, differently rounded one.
            expandedRow
        case .standalone:
            // Inset after the fill, so the capsule and its shadow move in together
            // — the shape the system's own container has, at the one place that has
            // to build it by hand.
            expandedRow
                .background { windowEdge }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.xs)
        }
    }

    private var expandedRow: some View {
        HStack(spacing: Space.md) {
            Button(action: expand) {
                AppRowLabel(
                    artwork: AppArtwork(app: status.app),
                    title: status.app.title,
                    layout: .dock,
                    status: RunningAppCaption.label(
                        of: status,
                        failure: .inline,
                        conversationTurn: conversationTurn,
                        isReachable: isReachable,
                        wedged: wedged,
                        actionFailure: actionFailure
                    )
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(.reachy("Opens the running app"))

            if hasFailed {
                dismissButton
            } else if isTalking {
                // Restart gives way rather than making a fourth control: the same
                // trade `inlineRow` documents, and Restart is still one tap away
                // through the row itself.
                microphoneButton
                if conversationTurn == .speaking {
                    interruptButton
                }
                stopButton
            } else {
                restartButton
                stopButton
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: Metrics.dockStrip)
    }

    /// A conversation this dock can actually reach. `conversationTurn` is nil for
    /// every other app, for an old build, and over the relay — so it is the one
    /// condition, rather than a second guess at the same thing.
    private var isTalking: Bool {
        offersConversationControls && conversationTurn != nil
    }

    /// Merged into a minimised tab bar: one row the height of the bar, and a
    /// fraction of its width.
    ///
    /// The caption goes — a crash tail cannot be read in a tab bar, and
    /// `RunningAppCaption.Failure.inline` exists because the expanded row's one
    /// caption line is the only place it *can* be read. Restart goes too: three
    /// controls do not fit, and Stop is the action that ends the situation. Both
    /// are still one tap away, because tapping the row opens `AppDetailSheet`.
    private var inlineRow: some View {
        HStack(spacing: Space.sm) {
            Button(action: expand) {
                AppRowLabel(
                    artwork: AppArtwork(app: status.app),
                    title: status.app.title,
                    layout: .dock
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(.reachy("Opens the running app"))

            if hasFailed {
                dismissButton
            } else {
                stopButton
            }
        }
        .padding(.horizontal, Space.sm)
    }

    /// The container the system draws on iOS 26.1, drawn by hand where there is no
    /// system slot to draw it: a rounded capsule, inset from both edges, raised off
    /// the tab bar by a shadow.
    ///
    /// **All four corners, and no `ignoresSafeArea`.** It used to round only its top
    /// two and reach past the home indicator, because it was meant to be a window
    /// crossing the bottom edge of the screen. It sits above the tab bar now, well
    /// inside the safe area, so an `ignoresSafeArea` here would stretch the opaque
    /// fill down through the bar and reproduce the very look this change removes.
    ///
    /// The `.window` role stays: it is the raised, opaque, glass-free surface, and
    /// glass-free is what makes it the one role that flips correctly in a dark
    /// reference. It is placed as a fill rather than applied to the content so the
    /// caption keeps its colour — a crashed app says so in red, and glass renders
    /// what it wraps vibrantly.
    private var windowEdge: some View {
        ReachySurfaceFill(.window, in: Radius.rect(Radius.window))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 1)
    }

    private var restartButton: some View {
        Button {
            perform(.restart)
        } label: {
            Label(.reachy("Restart"), systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
        .reachyButton()
        .buttonBorderShape(.circle)
        .disabled(!canAct)
    }

    private var stopButton: some View {
        Button {
            perform(.stop)
        } label: {
            Label(.reachy("Stop"), systemImage: "stop.fill")
                .labelStyle(.iconOnly)
        }
        .reachyButton(.prominent)
        .buttonBorderShape(.circle)
        .tint(Tone.danger.style)
        .disabled(!canAct)
    }

    /// The **robot's** microphone, not this phone's — nothing here records.
    private var microphoneButton: some View {
        Button {
            perform(.toggleMicrophone)
        } label: {
            Label(
                isMicrophoneMuted ? .reachy("Unmute the robot") : .reachy("Mute the robot"),
                systemImage: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
            )
            .labelStyle(.iconOnly)
        }
        .reachyButton()
        .buttonBorderShape(.circle)
        .disabled(!canAct)
    }

    private var interruptButton: some View {
        Button {
            perform(.interrupt)
        } label: {
            Label(.reachy("Stop talking"), systemImage: "hand.raised.fill")
                .labelStyle(.iconOnly)
        }
        .reachyButton()
        .buttonBorderShape(.circle)
        .disabled(!canAct)
    }

    private var dismissButton: some View {
        Button {
            perform(.dismiss)
        } label: {
            Label(.reachy("Dismiss"), systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .reachyButton()
        .buttonBorderShape(.circle)
    }
}
