import SwiftUI

/// Text roles, each one a semantic `Font`. Nothing here names a point size, so
/// Dynamic Type costs nothing to support.
public enum Typography {
    public static let screenTitle: Font = .title2
    /// The title of one step in a flow that owns the whole screen, where the step
    /// name is the only heading the reader gets.
    public static let stepTitle: Font = .title2.bold()
    public static let rowTitle: Font = .headline
    /// The same title on a strip 56 pt tall that carries a caption under it.
    public static let rowTitleCompact: Font = .subheadline
    /// And on a widget tile, which is narrower again — a caption doing a title's job.
    public static let tileTitle: Font = .caption
    /// The name of the thing a sheet is about, above the sheet's own detail.
    public static let identityTitle: Font = .title3.weight(.semibold)
    /// A second line under a title: the author, the version, the one-line summary.
    public static let subtitle: Font = .subheadline
    /// The heading of a notice the reader did not ask for — an empty state, a
    /// warning strip. Louder than `subtitle`, quieter than any title.
    public static let noticeTitle: Font = .subheadline.weight(.semibold)
    /// The one line a banner leads with, sized to sit inside a row rather than above one.
    public static let bannerTitle: Font = .callout.weight(.medium)
    public static let detail: Font = .callout
    public static let status: Font = .caption
    /// The same caption where a widget tile has no room for `.caption`.
    public static let statusCompact: Font = .caption2
    /// A value the reader has to read aloud or type somewhere else — a PIN, a
    /// pairing code. Monospaced so no two digits can be confused.
    public static let code: Font = .title3.monospaced()
    public static let console: Font = .body.monospaced()
    public static let consoleLine: Font = .caption.monospaced()
    /// The same log line where the console is a strip rather than a screen.
    public static let consoleLineCompact: Font = .caption2.monospaced()
    /// The last line of a screen: the hint under a field, the note under a step.
    public static let footer: Font = .footnote
}

/// A glyph sized off its container rather than off the text scale.
///
/// `AppArtworkTile` draws an emoji or an SF Symbol *as artwork*, which is the one
/// place `.font(.system(size:))` is right: the glyph has to track the tile, not
/// the reader's text size. These are the two ratios it uses.
public enum IconRatio {
    public static let emoji: CGFloat = 0.5
    public static let symbol: CGFloat = 0.42
}
