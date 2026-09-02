import ReachyDesign
import ReachyKit
import SwiftUI

/// The rail, what it is currently saying, and — when the attempt has stopped — the
/// decision it is waiting on.
///
/// Pinned above the segmented control rather than dropped into the form. That is
/// what lets the failure path stop being a screen of its own: the rail stays the
/// same view in the same place from the first handshake to the last checkmark, so
/// SwiftUI has something to animate rather than a new subtree to build from
/// scratch. The old branch replaced the whole form and reset the fill to zero.
///
/// The sections below stay mounted and disabled instead of being removed. The
/// reasoning the old branch recorded — "the discovery list would only compete with
/// a choice the user has to make" — is answered by them being visibly inert; what
/// it cost was a full relayout at the exact moment the reader is trying to read
/// something.
///
/// **This header is mounted for the whole life of the gate, including `.idle`.**
/// That is not decoration, it is the fix for a reported bug: the candidate sweep
/// beats every 10 s and an automatic attempt falls back to `.idle` rather than
/// `.failed`, so the phase walks `idle → handshaking → idle` forever while nothing
/// answers. Anything conditional on "an attempt is running" therefore mounts and
/// unmounts on that heartbeat, and the screen visibly compressed and expanded with
/// it — which is what the vertical stepper did as a form section. Three unlit nodes
/// cost one strip of height and move nothing.
///
/// The action buttons are still conditional, and deliberately so: they appear only
/// in terminal states, which the reader reached by an attempt stopping rather than
/// by a timer. A layout change there is information, not jitter.
struct ConnectHeader: View {
    let session: RobotSession
    /// The phase the rail draws, which lags `session.phase` on purpose. Everything
    /// else here reads the session directly: a button must act on what is true now,
    /// not on the frame being animated.
    let displayed: RobotSession.ConnectionPhase

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(headerText)
                .font(Typography.status)
                .foregroundStyle(Tone.quiet.style)
                .frame(maxWidth: .infinity, alignment: .leading)
            ConnectRail(phase: displayed, detail: detail)
            actions
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    private var actions: some View {
        if let transition = session.powerTransition {
            HStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(transition.statusText)
                    // The daemon state walks stopped → starting → running on its own
                    // as `waitForDaemonRunning` refreshes it: real progress, not a timer.
                    if let state = session.lastStatus?.state {
                        Text(.reachy("Daemon state: \(String(localized: DaemonStateCaption.text(for: state)))"))
                            .font(Typography.status)
                    }
                }
                .foregroundStyle(Tone.quiet.style)
                Spacer()
            }
        } else if isBackendUnavailable {
            decision(.reachy("Start robot backend")) {
                Task { await session.startBackend() }
            } alternatives: {
                Button(.reachy("Continue anyway")) {
                    session.proceedWithoutBackend()
                }
                .reachyButton(.quiet)
                cancelButton
            }
        } else if isFailed, case let .lan(address) = session.link {
            decision(.reachy("Try again")) {
                Task { await session.connect(to: address) }
            } alternatives: {
                cancelButton
            }
        } else if isFailed {
            // A remote attempt has no address to redial, so cancelling is the whole
            // of what is on offer and there is no action for it to sit beside.
            HStack { cancelButton }
        }
    }

    /// One action across the width, with the ways out on a line of their own beneath
    /// it.
    ///
    /// Three bordered capsules side by side broke "Continue anyway" across two lines
    /// on an iPhone, and stacking them turned the header into a ragged column of
    /// three different widths — both recorded, both wrong. A full-width primary reads
    /// as the answer to the rail above it, and borderless alternatives carry no width
    /// of their own, so they fit on one line at any text size the reader picks.
    ///
    /// It takes the title rather than a built `Button` because **the width has to go
    /// on the label**. `frame(maxWidth: .infinity)` applied outside `buttonStyle`
    /// stretches the container and leaves the capsule hugging its text in the middle
    /// of it — which the third recorded attempt showed as a centred capsule under a
    /// leading-aligned caption and leading-aligned alternatives. `ReachyActionButton`
    /// is that spelling with a name, and it is what every full-width action uses now;
    /// eight onboarding steps carried the wrong one until it existed.
    private func decision(
        _ title: LocalizedStringResource,
        action: @escaping () -> Void,
        @ViewBuilder alternatives: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ReachyActionButton(title, fullWidth: true, action: action)
            HStack(spacing: Space.lg) {
                alternatives()
                Spacer()
            }
        }
    }

    /// `disconnect()` is the whole cancel story: it invalidates the attempt and
    /// pauses automatic reconnect, which is what stops the 10 s rescan from
    /// reopening this very card moments later.
    private var cancelButton: some View {
        Button(.reachy("Cancel"), role: .cancel) {
            session.disconnect()
        }
        .reachyButton(.quiet)
    }

    /// Read off the live phase, not the displayed one: the sentence names what went
    /// wrong, and lagging it behind the rail would leave "Connecting to…" over a red
    /// node for a beat.
    ///
    /// `.idle` gets a sentence of its own because the rail is now permanently
    /// mounted — see the type's note on why — so this line has to read sensibly with
    /// nothing happening at all.
    /// `"the robot"` rather than `"robot"`: the fragment fills a sentence, and a
    /// bare noun there both reads wrong in English ("Connected to robot") and
    /// derives the same `xcstringstool` symbol as the `"Robot"` section title —
    /// a hard build error the moment both are in the catalogue.
    private var headerText: LocalizedStringResource {
        let target = session.link == .none
            ? String(localized: .reachy("the robot"))
            : ConnectionLinkCaption.text(for: session.link)
        if isFailed {
            return .reachy("Couldn't connect to \(target)")
        }
        switch session.phase {
        case .idle: return .reachy("Not connected")
        case .connected, .unreachable: return .reachy("Connected to \(target)")
        case .connecting: return .reachy("Connecting to \(target)")
        }
    }

    /// One line for the whole rail. `needsDaemonUpdate` is absent on purpose — it
    /// has a screen of its own, and this header never renders under it.
    private var detail: String? {
        guard case let .connecting(step) = session.phase else { return nil }
        switch step {
        case let .failed(_, message):
            return message
        case let .backendUnavailable(_, daemonMessage):
            return daemonMessage ?? String(localized: .reachy("The robot backend is not running"))
        case .checkingBackend:
            guard let state = session.lastStatus?.state else { return nil }
            return String(localized: .reachy("Daemon state: \(String(localized: DaemonStateCaption.text(for: state)))"))
        case .handshaking, .needsDaemonUpdate:
            return nil
        }
    }

    private var isBackendUnavailable: Bool {
        if case .connecting(.backendUnavailable) = session.phase {
            return true
        }
        return false
    }

    private var isFailed: Bool {
        if case .connecting(.failed) = session.phase {
            return true
        }
        return false
    }
}
