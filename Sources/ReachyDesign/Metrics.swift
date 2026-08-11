import CoreGraphics

/// Sizes fixed by what they represent rather than by the text inside them.
///
/// These are what clip at AX5, which is why `@ScaledMetric` belongs on the
/// component that reads one and never on the constant: at the default text size
/// the multiplier is 1, so adopting it moves no reference image.
public enum Metrics {
    /// Telegram's `minimizedNavigationHeight` — the running-app strip.
    public static let dockStrip: CGFloat = 56
    public static let joystickKnob: CGFloat = 56
    /// A store row's artwork, and the smaller tile the dock and the widget draw.
    public static let artwork: CGFloat = 52
    public static let artworkCompact: CGFloat = 30
    /// The Appearance picker's tile — a theme's icon gradient, not a rendered icon.
    public static let themeTile: CGFloat = 56
    /// A node on the connection rail. Fixed by the glyph it has to hold — a
    /// checkmark, a cross, a turning arc — and not by anything around it.
    ///
    /// It replaces `stepperIconColumn`, the gutter the vertical connection stepper
    /// was meant to align on. That token had no call site: the stepper it was
    /// written for spelled the same number as a literal, and the stepper is gone.
    public static let railNode: CGFloat = 22
    /// The live view floating over the interface — wide enough to read what the
    /// robot is doing, narrow enough to leave a list legible beside it.
    public static let floatingViewport = CGSize(width: 160, height: 112)
    /// What that window leaves at the edge once it is switched off. 44 pt across
    /// because the tab is the only way back and nothing else can be aimed at.
    public static let viewportTab = CGSize(width: 44, height: 72)
    /// Room for the floating tab bar, for anything drawn *over* a `TabView`.
    ///
    /// The bar insets the safe area of each **tab's content** and reports none of
    /// it to an overlay on the `TabView` itself, which is a `GeometryReader` that
    /// sees the home indicator and nothing else. Measured off `Root — unreachable`,
    /// where the first version of the floating viewport landed squarely on the
    /// Apps and Settings labels.
    public static let tabBarAllowance: CGFloat = 56
    /// Room for the tab accessory the running-app strip is drawn in, over and above
    /// the bar — and invisible to an overlay on the `TabView` for the same reason
    /// the bar is.
    ///
    /// The system slot measures 56 pt: on an iPhone 17 Pro running iOS 26.4 a tab's
    /// content reports a bottom safe area of 139 pt with the accessory and 83 pt
    /// without, and the system's own container makes up the difference between that
    /// and the 33.3 pt it offers the content. This reserves more, for the two
    /// reasons a single measurement cannot cover: the fallback strip is that 56 plus
    /// its own gap to the bar, and either one carries a shadow. Recorded at 56 the
    /// floating window came to rest 2 pt off the strip, which
    /// `Root — floating viewport over the dock` exists to catch. Reserving the
    /// larger leaves the window slightly high in the other placement, which is the
    /// same trade `tabBarAllowance` makes and the safe way to be wrong.
    public static let tabAccessoryAllowance: CGFloat = 68
    /// The line under a reading in the robot's state section. Tall enough for a
    /// shape to be a shape and short enough that four of them still read as rows
    /// rather than as a dashboard.
    public static let sparklineHeight: CGFloat = 28
    /// A `Form` left to itself fills a 1024 pt iPad and reads as broken.
    public static let readableForm: CGFloat = 560
    /// What the app's window asks to open at on macOS, where nothing else says.
    ///
    /// A `WindowGroup` declaring no size gets one from its content, which came out
    /// short enough to cut the connection screen's last card off at the bottom edge
    /// on a first launch. Taller than it is wide on purpose: every screen here is a
    /// column of cards capped at `readableForm`, so height is what they need and
    /// width past the cap is only margin.
    ///
    /// **Asks, and does not get all of it.** A `WindowGroup`'s resizability is
    /// `.automatic`, which clamps the window to what its content will accept, so
    /// this is an upper request rather than a measurement: with it the window opens
    /// at ~634x593 and without it at ~619x531 — measured on a 1512 pt display with
    /// the saved frame deleted, which is the only state that reads this at all.
    /// macOS persists the frame from then on, so changing this moves nothing for
    /// anyone who has already opened the app.
    public static let window = CGSize(width: 720, height: 680)
    /// How wide a sheet is on macOS, where nothing else supplies a width.
    ///
    /// A sheet there is sized by its content's *ideal* size, and neither a `Form`
    /// nor a `ScrollView` offers an ideal width — so AppKit picks something cramped
    /// and clips what does not fit rather than laying it out again. Wide enough for
    /// the widest thing a sheet here holds: a `Form` at `readableForm`, plus its
    /// margins. **Only the width is declared** — `reachySheet()` measures the
    /// height, and says why a constant there was wrong. iOS supplies its own sheet
    /// geometry and never reads this.
    public static let sheetWidth: CGFloat = 600
}
