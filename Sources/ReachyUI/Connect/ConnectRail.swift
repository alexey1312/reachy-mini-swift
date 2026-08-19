import ReachyDesign
import ReachyKit
import SwiftUI

/// The connection attempt as a horizontal rail: three nodes on one track, so the
/// shape of the whole attempt is legible at a glance and a failure still names
/// the step it happened on.
///
/// It reads `RobotSession.ConnectionPhase` directly rather than taking pre-mapped
/// rows. The mapping it needs already exists as a tested table
/// (`RobotSession+ConnectionStage.swift`) and putting a second one in front of it
/// would buy nothing: this is a `ReachyUI` view, and `ReachyKit` is what this
/// target is for. `ReachyDesign` is the module that may not see a domain type.
///
/// **The middle node is never `.active`.** `ConnectionStep.position` maps only
/// `.handshaking → .connect` and `.checkingBackend → .backend`; the version check
/// happens inside the handshake, so `.compatibility` goes from pending straight to
/// done. That is the model telling the truth, not a gap to paper over.
struct ConnectRail: View {
    let phase: RobotSession.ConnectionPhase
    /// One line under the whole rail, not under a node: a daemon message is a
    /// sentence, and a column a third of an iPhone wide turns it into five lines
    /// that drag the neighbouring captions down with it.
    var detail: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stages: [RobotSession.ConnectionStage] {
        RobotSession.ConnectionStage.allCases
    }

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                    column(at: index, stage: stage)
                }
            }
            // One caption line is reserved whether or not there is anything to say.
            // The empty state is the common one, and letting the slot collapse would
            // move everything below it every time a stage produced a message —
            // exactly the jitter this layout exists to remove. A longer message still
            // grows the slot; that happens on a real transition, not on a heartbeat.
            ZStack(alignment: .leading) {
                Text(verbatim: " ")
                    .font(Typography.status)
                    .hidden()
                Text(detail ?? "")
                    .font(Typography.status)
                    .foregroundStyle(detailTone.style)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.stateChange, value: phase)
        .accessibilityElement(children: .combine)
    }

    private func column(at index: Int, stage: RobotSession.ConnectionStage) -> some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: 0) {
                // Both halves are always in the hierarchy, hidden rather than
                // absent at the two ends: dropping them would shift the first and
                // last nodes off their column centres and bow the whole track.
                half(filled: isReached(index), visible: index > 0)
                ConnectRailNode(outcome: outcome(for: stage), reduceMotion: reduceMotion)
                half(filled: isReached(index + 1), visible: index < stages.count - 1)
            }
            Text(caption(for: stage))
                .font(Typography.status)
                .foregroundStyle(Tone.quiet.style)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// 2 pt is optical — the weight a hairline track reads at beside a 22 pt node,
    /// not a step in the layout rhythm.
    private func half(filled: Bool, visible: Bool) -> some View {
        Capsule()
            .fill(filled ? Tone.success.style : AnyShapeStyle(.quaternary))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .opacity(visible ? 1 : 0)
    }

    private func outcome(for stage: RobotSession.ConnectionStage) -> RobotSession.StageOutcome {
        phase.outcome(for: stage)
    }

    /// Whether the attempt got as far as this node, which is what fills the track
    /// leading into it. Both halves of one gap ask about the same node, so the two
    /// can never disagree about the segment they share.
    private func isReached(_ index: Int) -> Bool {
        guard index < stages.count else { return false }
        return outcome(for: stages[index]) != .pending
    }

    /// Shorter than the vertical stepper's row titles by necessity: a third of an
    /// iPhone is about 110 pt, and "Connect to daemon" wraps to three lines there.
    private func caption(for stage: RobotSession.ConnectionStage) -> LocalizedStringResource {
        switch stage {
        case .connect: .reachy("Daemon")
        case .compatibility: .reachy("Version")
        case .backend: .reachy("Backend")
        }
    }

    /// The detail line borrows the tone of whichever node it is explaining, so the
    /// colour and the position answer "where did this break" together.
    private var detailTone: Tone {
        let outcomes = stages.map { outcome(for: $0) }
        if outcomes.contains(.failed) {
            return .danger
        }
        if outcomes.contains(.attention) {
            return .warning
        }
        return .quiet
    }
}

/// One node, and the app's only endlessly repeating animation.
///
/// Split out so the spin's `@State` belongs to the node rather than to the rail —
/// three of these in a `ForEach` keep their own identity, and a stage changing
/// outcome does not restart its neighbours.
private struct ConnectRailNode: View {
    let outcome: RobotSession.StageOutcome
    let reduceMotion: Bool

    @Environment(\.reachyPreviewMode) private var previewMode
    @ScaledMetric private var size = Metrics.railNode
    @State private var spinning = false

    /// Preview mode and Reduce Motion take the same path on purpose. It keeps the
    /// reference images off a phase that depends on where in the run the test
    /// landed, and it means every recorded image shows exactly what a reader who
    /// asked for less movement sees — the resting state gets regression cover
    /// instead of being the one rendering nothing verifies.
    private var isStill: Bool {
        previewMode || reduceMotion
    }

    var body: some View {
        ZStack {
            switch outcome {
            case .pending:
                Circle().strokeBorder(Tone.quiet.style, lineWidth: 2)
            case .active:
                Circle().strokeBorder(.quaternary, lineWidth: 2)
                arc
            case .done:
                filled(Tone.success, symbol: "checkmark")
            case .attention:
                filled(Tone.warning, symbol: "exclamationmark")
            case .failed:
                filled(Tone.danger, symbol: "xmark")
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.stateChange, value: outcome)
    }

    /// A resting arc is still an arc: it reads as "this one, in progress" against
    /// a pending node's complete grey ring even when nothing turns.
    private var arc: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(Tone.brand.style, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .task(id: isStill) { await animateWaitingArc() }
            .onDisappear { spinning = false }
    }

    /// The node survives a failed attempt, so its state does too. Reset before
    /// starting each active arc; assigning `true` to an already-true state on a
    /// retry produces no animation transaction and leaves a static ring.
    private func animateWaitingArc() async {
        spinning = false
        guard !isStill else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(Motion.waiting(reduceMotion: reduceMotion)) { spinning = true }
    }

    private func filled(_ tone: Tone, symbol: String) -> some View {
        ZStack {
            Circle().fill(tone.style)
            Image(systemName: symbol)
                // Optical: the glyph is sized against the disc it sits in.
                .font(.caption2.bold())
                // The one pinned foreground here, and it is pinned against a fill
                // this view owns rather than against an adaptive backdrop: all
                // three tones are dark enough to carry white in either appearance.
                .foregroundStyle(.white)
        }
    }
}
