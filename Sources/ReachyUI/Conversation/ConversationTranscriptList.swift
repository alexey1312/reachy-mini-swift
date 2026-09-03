import ReachyDesign
import ReachyKit
import SwiftUI

/// The record, and the markers where it has holes in it.
///
/// A `ScrollView` over a `LazyVStack` rather than a `List`: there are no swipe actions,
/// no separators and no search, and the rows carry a layout of their own rather than
/// list-row insets. It also leaves `ScrollPosition` unambiguous, which the tail-following
/// below depends on.
struct ConversationTranscriptList: View {
    let entries: [TranscriptEntry]
    /// Drawn above the list when the conversation can no longer be reached. The record
    /// stays readable underneath — it cannot be fetched again from anywhere.
    let isFrozen: Bool

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                if isFrozen {
                    frozenNotice
                }
                ForEach(entries) { entry in
                    TranscriptRow(entry: entry)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .scrollPosition($position)
        // `ScrollPosition` + geometry rather than `LogConsoleScreen`'s zero-height
        // sentinel row: that one predates the iOS 18 floor and measures *row visibility*,
        // which fires during insertion and reports late. This yields the same answer with
        // a tolerance, so a one-point overscroll cannot flip the state back and forth.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - Metrics.bottomTolerance
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        // Follows the tail only while the reader is already at it. Somebody scrolled up
        // to read something is somebody who must not be yanked back by the next utterance.
        .onChange(of: entries.last?.id) {
            guard isAtBottom else { return }
            withAnimation { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom, !entries.isEmpty {
                jumpToLatest
            }
        }
    }

    /// Said once, above the record, rather than repeated on every row.
    private var frozenNotice: some View {
        Text(.reachy("Read-only record"))
            .font(Typography.statusCompact)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, Space.xs)
    }

    private var jumpToLatest: some View {
        Button {
            withAnimation { position.scrollTo(edge: .bottom) }
        } label: {
            Label(.reachy("Jump to latest"), systemImage: "chevron.down")
                .font(Typography.status)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.bottom, Space.sm)
        .accessibilityLabel(.reachy("Jump to the latest message"))
    }

    private enum Metrics {
        /// Half a row of slack. Without it the button flickers on and off as the tail
        /// settles after an insertion.
        static let bottomTolerance: CGFloat = 24
    }
}

/// One utterance, or one marker.
///
/// **The speaker is carried by the caption word and its weight, and by nothing else** —
/// not by which side the row sits on, not by a colour, not by an avatar. Mirroring by
/// speaker is a chat convention that flips under a right-to-left language and says
/// nothing a screen reader cannot already read from the caption.
struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .gap, .ended:
            marker
        case .typed:
            typed
        case .spoken:
            spoken
        }
    }

    private var spoken: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            caption
            Text(entry.text)
                .font(Typography.detail)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .contextMenu { copyLine }
    }

    /// Full width and filled, so it cannot be misread as a chat bubble — and a keyboard
    /// glyph, because this is the one row nobody said out loud.
    private var typed: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "keyboard")
                    .font(Typography.statusCompact)
                    .accessibilityHidden(true)
                caption
            }
            Text(entry.text)
                .font(Typography.detail)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(.fill.tertiary, in: .rect(cornerRadius: Metrics.typedCorner))
        .accessibilityElement(children: .combine)
        .contextMenu { copyLine }
    }

    /// A boundary of the record, drawn in the flow where the next utterance would have
    /// been — so it reads as the end of a list rather than as an interruption of one.
    /// No warning colour and no alert glyph: nothing is broken, the record simply stops.
    private var marker: some View {
        HStack(spacing: Space.md) {
            line
            Text(entry.text)
                .font(Typography.statusCompact)
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .frame(maxWidth: .infinity)
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: Metrics.hairline)
    }

    @ViewBuilder
    private var caption: some View {
        if let title = TranscriptRoleCaption.title(of: entry.kind) {
            Text(title)
                .font(Typography.statusCompact)
                .textCase(.uppercase)
                .foregroundStyle(isRobot ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    /// The robot's own words take the primary label and a person's take the secondary —
    /// weight is the whole of the distinction, which is what lets it survive a
    /// monochrome rendering and a screen reader alike.
    private var isRobot: Bool {
        entry.kind == .spoken(.assistant)
    }

    private var copyLine: some View {
        Button(.reachy("Copy line")) {
            Clipboard.copy(entry.text)
        }
    }

    private enum Metrics {
        static let typedCorner: CGFloat = 10
        static let hairline: CGFloat = 1
    }
}
