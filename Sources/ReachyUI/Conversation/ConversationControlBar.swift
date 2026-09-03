import ReachyDesign
import ReachyKit
import SwiftUI

/// The state line and the three controls, pinned below the transcript.
///
/// **The geometry never restructures.** Across every state the bar is the same state
/// line above the same three slots; a conversation that cannot be reached dims them
/// rather than removing them, so the screen stays recognisably the same place. A bar
/// that rebuilt itself per state would make each failure look like a different screen.
struct ConversationControlBar: View {
    let turn: ConversationTurn?
    let level: ConversationLevel?
    let isMicrophoneMuted: Bool
    let isEnabled: Bool
    let offersControls: Bool
    let failure: String?
    let perform: (Action) -> Void
    let hold: (Bool) -> Void

    enum Action {
        case toggleMicrophone
        case interrupt
        case compose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let failure {
                Text(failure)
                    .font(Typography.status)
                    .foregroundStyle(Tone.warning.style)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            stateLine
            if offersControls {
                controls
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .reachySurface(.scrim, ignoringSafeArea: .bottom)
    }

    // MARK: The state line

    private var stateLine: some View {
        HStack(spacing: Space.sm) {
            Text(turn.map(ConversationTurnCaption.title) ?? ConversationTurnCaption.unknown)
                .font(Typography.status)
                .foregroundStyle(.secondary)
            if isEnabled {
                ConversationLevelMeter(level: level)
            }
            Spacer(minLength: 0)
        }
        // One element rather than three, and it updates without the reader acting — which
        // is what `updatesFrequently` is the spelling for.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(.reachy("Reachy is"))
        .accessibilityValue(Text(turn.map(ConversationTurnCaption.title) ?? ConversationTurnCaption.unknown))
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: The controls

    private var controls: some View {
        HStack(spacing: Space.md) {
            microphone
            interrupt
            Spacer(minLength: 0)
            compose
        }
    }

    /// **Muted reads as an inverted key, not a coloured one.** The fill, the slashed
    /// glyph and the sentence beside it all carry the state, so it survives a
    /// monochrome rendering, a colour-blind reader and a screen reader alike.
    ///
    /// A real `Toggle` rather than the dock's `Button` with a changing label: VoiceOver
    /// gets switch semantics for free, and the press-and-hold is an enhancement over a
    /// control that is already fully operable by activation alone.
    private var microphone: some View {
        Toggle(isOn: .init(get: { !isMicrophoneMuted }, set: { _ in perform(.toggleMicrophone) })) {
            Label(
                ConversationTurnCaption.microphone(isMuted: isMicrophoneMuted),
                systemImage: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
            )
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .disabled(!isEnabled)
        .accessibilityLabel(.reachy("Robot microphone"))
        .help(Text(ConversationTurnCaption.microphone(isMuted: isMicrophoneMuted)))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in hold(true) }
                .onEnded { _ in hold(false) }
        )
    }

    /// Permanent, unlike the dock's — which is gated on `.speaking` because it has a
    /// three-control budget in a strip. A screen has room, and the turn changes several
    /// times per exchange: a control mounting and unmounting under a thumb at
    /// conversational speed is the failure this app has hit before. Barging in while the
    /// robot is listening is harmless, so there is nothing to gate on.
    private var interrupt: some View {
        Button {
            perform(.interrupt)
        } label: {
            Label(.reachy("Stop talking"), systemImage: "hand.raised.fill")
                .font(Typography.status)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(!isEnabled)
    }

    private var compose: some View {
        Button {
            perform(.compose)
        } label: {
            Label(.reachy("Type to Reachy"), systemImage: "keyboard")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!isEnabled)
        .accessibilityLabel(.reachy("Type to Reachy"))
    }
}

/// The robot's audio level, about fifteen readings a second.
///
/// `accessibilityHidden` on purpose: the caption beside it already states what the robot
/// is doing in words, and voicing fifteen samples a second is that same fact fifteen
/// times a second. The same rule the health sparklines carry, with the multiplier turned
/// up.
struct ConversationLevelMeter: View {
    let level: ConversationLevel?

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(0 ..< Metrics.bars, id: \.self) { bar in
                Capsule()
                    .fill(isLit(bar) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: Metrics.barWidth, height: height(of: bar))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func isLit(_ bar: Int) -> Bool {
        guard let level else { return false }
        return Double(bar) / Double(Metrics.bars) < level.rms
    }

    /// A fixed domain, never scaled to the readings seen so far: a meter that rescaled
    /// itself would make a quiet room look exactly like a loud one.
    private func height(of bar: Int) -> CGFloat {
        let peak = Metrics.minimumHeight + (Metrics.maximumHeight - Metrics.minimumHeight)
            * sin(Double(bar + 1) / Double(Metrics.bars) * .pi)
        return isLit(bar) ? peak : Metrics.minimumHeight
    }

    private enum Metrics {
        static let bars = 5
        static let barWidth: CGFloat = 2
        static let minimumHeight: CGFloat = 3
        static let maximumHeight: CGFloat = 12
    }
}
