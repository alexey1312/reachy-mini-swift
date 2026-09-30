import ReachyDesign
import ReachyKit
import SwiftUI

/// What the control bar needs to know about a take on this device.
struct ConversationTalkState: Equatable {
    var phase: DictationPhase = .idle
    var level: ConversationLevel?
    var notice: DictationNotice?
    var isEnabled = false
}

/// Hold to talk to Reachy from this device, or tap to start and tap again to send.
///
/// **A `Button` whose own action is the accessible path, and whose touches are a
/// gesture.** VoiceOver, Switch Control and Full Keyboard Access reach the action,
/// which toggles; a finger reaches `TalkButtonStyle`'s drag, which reports a press and
/// a release with how long it was held. The two cannot both fire for one touch,
/// because the style never calls the action for a touch — which is exactly what a
/// plain `Button` with a simultaneous gesture cannot promise, and what the robot
/// microphone's hold gets wrong.
struct ConversationTalkButton: View {
    let phase: DictationPhase
    let isEnabled: Bool
    let perform: (TalkGesture) -> Void

    var body: some View {
        Button {
            perform(.toggled)
        } label: {
            Label(DictationCaption.button(for: phase), systemImage: glyph)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(TalkButtonStyle(isActive: !phase.isIdle, press: perform))
        .disabled(!isEnabled)
        .accessibilityLabel(DictationCaption.button(for: phase))
        .accessibilityHint(Text(Self.hint))
        .accessibilityActions {
            if !phase.isIdle {
                Button(.reachy("Discard recording")) { perform(.discarded) }
            }
        }
        .help(Text(Self.hint))
    }

    /// A waveform while it listens, an arrow once a tap has latched it — the one state
    /// where the next touch sends rather than records.
    private var glyph: String {
        if case .recording(_, isLatched: true) = phase {
            return "arrow.up"
        }
        return "waveform"
    }

    /// **The claim this control must not overstate**, and the same honesty the composer
    /// keeps: the robot receives the words, never the voice.
    static let hint = LocalizedStringResource.reachy(
        // swiftlint:disable:next line_length
        "Hold to talk to Reachy from this device, or tap to start and tap again to send. Reachy gets the words this device heard, not your voice."
    )
}

/// The system's own bordered capsule, drawn without its hit-testing, under a drag that
/// reports the press and the release.
///
/// `@GestureState` rather than `onChanged`/`onEnded`: it resets when the system takes
/// the touch away — a permission alert, a disabled control — and `onEnded` never fires
/// then, which would leave a hold that never let go. The reset is what reports the
/// release in that case.
private struct TalkButtonStyle: PrimitiveButtonStyle {
    let isActive: Bool
    let press: (TalkGesture) -> Void

    func makeBody(configuration: Configuration) -> some View {
        TalkButtonBody(configuration: configuration, isActive: isActive, press: press)
    }
}

private struct TalkButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let isActive: Bool
    let press: (TalkGesture) -> Void

    @GestureState private var pressedAt: ContinuousClock.Instant?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        face
            .allowsHitTesting(false)
            .contentShape(Capsule())
            .gesture(hold, including: isEnabled ? .all : .none)
            .onChange(of: pressedAt) { previous, current in
                switch (previous, current) {
                case (nil, .some):
                    press(.pressed)
                case let (.some(start), nil):
                    press(.released(heldFor: ContinuousClock.now - start))
                default:
                    break
                }
            }
            // The face is a button that cannot be touched, so the accessible element is
            // this one, and its activation is the action — the toggle.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { configuration.trigger() }
    }

    @ViewBuilder
    private var face: some View {
        if isActive {
            Button(configuration)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        } else {
            Button(configuration)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }

    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressedAt) { _, state, _ in
                if state == nil {
                    state = .now
                }
            }
    }
}

/// What a take is called on screen — the button, and the state line while it runs.
enum DictationCaption {
    static func button(for phase: DictationPhase) -> LocalizedStringResource {
        switch phase {
        case .idle: .reachy("Talk from this device")
        case .preparing, .recording(_, isLatched: false): .reachy("Release to send")
        case .recording(_, isLatched: true): .reachy("Send what you said")
        case .sending: .reachy("Sending to Reachy…")
        }
    }

    static func state(for phase: DictationPhase) -> LocalizedStringResource {
        switch phase {
        case .idle, .preparing: .reachy("Opening this device's microphone…")
        case .recording(_, isLatched: false): .reachy("Listening on this device…")
        case .recording(_, isLatched: true): .reachy("Listening on this device · tap to send")
        case .sending: .reachy("Sending to Reachy…")
        }
    }
}
