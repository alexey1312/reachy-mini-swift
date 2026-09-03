import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

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
        .help(Text(.reachy("Restart")))
        .disabled(!canAct)
    }

    private var stopButton: some View {
        ReachyActionButton(.destructive) {
            perform(.stop)
        } label: {
            Label(.reachy("Stop"), systemImage: "stop.fill")
                .labelStyle(.iconOnly)
        }
        .buttonBorderShape(.circle)
        .help(Text(.reachy("Stop")))
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
        .help(Text(isMicrophoneMuted ? .reachy("Unmute the robot") : .reachy("Mute the robot")))
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
        .help(Text(.reachy("Stop talking")))
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
        .help(Text(.reachy("Dismiss")))
    }
}
