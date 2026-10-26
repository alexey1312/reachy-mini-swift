import SwiftUI

/// Which side of iPhone Duo's fold a piece of content goes to.
public enum FoldSide: Sendable {
    /// Whichever side has more room — for content that is only read, such as a
    /// centred empty state.
    case larger
    /// Leading in book pose and top in tabletop pose, whatever the room — for
    /// content whose controls hang off the opposite corner. HIG: in tabletop,
    /// viewing content on top and interactive controls on the bottom.
    case leadingOrTop
}

/// The insets that keep content off a fold.
///
/// iPhone Duo's inner display folds down the middle, and content across the fold
/// is hard to see — "like a photo across a book's spine" (Apple, *Strike a pose
/// with adaptive layouts on iPhone Duo*, 1:29). The fold reaches a view as an
/// active **division** region and as nothing else: no safe-area inset, no layout
/// margin, no trait. A vertical band is book pose and a horizontal one tabletop
/// (4:09). The region's frame already carries the 20 pt margin either side of
/// the crease, so content placed against the frame clears it.
///
/// Pure arithmetic, so `ReachyDesignTests` holds it on a Mac, where no fold exists.
public enum FoldInsets {
    /// `fold` is the active division in the view's own coordinates, or `nil`.
    /// A side shorter than `minimumLength` is no place for the content, and then
    /// nothing moves: content across a fold is worse than content cramped beside it
    /// only while there is room to put it beside.
    public static func clearing(
        _ fold: CGRect?,
        in size: CGSize,
        toward side: FoldSide,
        minimumLength: CGFloat
    ) -> EdgeInsets {
        guard let fold, size.width > 0, size.height > 0,
              fold.intersects(CGRect(origin: .zero, size: size))
        else { return EdgeInsets() }
        if fold.height >= fold.width {
            let before = max(0, fold.minX)
            let after = max(0, size.width - fold.maxX)
            let leading = side == .leadingOrTop || before >= after
            guard (leading ? before : after) >= minimumLength else { return EdgeInsets() }
            return leading
                ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: size.width - fold.minX)
                : EdgeInsets(top: 0, leading: fold.maxX, bottom: 0, trailing: 0)
        }
        let above = max(0, fold.minY)
        let below = max(0, size.height - fold.maxY)
        let top = side == .leadingOrTop || above >= below
        guard (top ? above : below) >= minimumLength else { return EdgeInsets() }
        return top
            ? EdgeInsets(top: 0, leading: 0, bottom: size.height - fold.minY, trailing: 0)
            : EdgeInsets(top: fold.maxY, leading: 0, bottom: 0, trailing: 0)
    }
}

public extension View {
    /// Moves this view's content to one side of an active fold.
    ///
    /// For a centred, discrete block — an empty state, a loading label. Scrolling
    /// content flows across the fold instead, and nothing should move it (111463,
    /// 3:45). Off iOS 27.1, and with no fold, the insets are zero and the view
    /// lays out as it always did.
    func reachyClearOfFold(toward side: FoldSide = .larger, minimumLength: CGFloat = 200) -> some View {
        modifier(ClearOfFold(side: side, minimumLength: minimumLength))
    }

    /// Reports the insets that would clear an active fold, for a view that applies
    /// them to part of its content only — the viewport moves its picture and leaves
    /// its controls where they were.
    func reachyFoldInsets(
        toward side: FoldSide,
        minimumLength: CGFloat = 200,
        _ action: @escaping (EdgeInsets) -> Void
    ) -> some View {
        modifier(FoldInsetsReader(side: side, minimumLength: minimumLength, action: action))
    }
}

private struct ClearOfFold: ViewModifier {
    let side: FoldSide
    let minimumLength: CGFloat
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .padding(insets)
            .reachyFoldInsets(toward: side, minimumLength: minimumLength) { insets = $0 }
    }
}

/// Reads the fold where the view lays out, never at a scene transition: the
/// regions are current whenever layout runs, and a fold changes them without
/// changing the view's size (`iphone-duo-layout` › Query during layout).
private struct FoldInsetsReader: ViewModifier {
    let side: FoldSide
    let minimumLength: CGFloat
    let action: (EdgeInsets) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                content.onGeometryChange(for: EdgeInsets.self) { proxy in
                    // Active regions only: `nil` while the device is flat or closed.
                    let fold = proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame
                    return FoldInsets.clearing(fold, in: proxy.size, toward: side, minimumLength: minimumLength)
                } action: { insets in
                    action(insets)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}
