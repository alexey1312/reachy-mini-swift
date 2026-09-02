import ReachyDesign
import ReachyKit
import SwiftUI
import WidgetKit

/// The theme picker.
///
/// A tile is the theme's own icon gradient rather than a rendered app icon: the
/// gradient *is* the icon's background, it costs no asset, and it does not promise
/// an icon change on macOS, where there is none.
struct AppearanceSection: View {
    @AppStorage(ThemeStore.key) private var rawTheme: String = ReachyTheme.fallback.rawValue

    /// Injectable so a preview can show a theme both applied and selected.
    /// `.reachyTheme(_:)` only sets the environment value and the tint — it never
    /// writes the store — so a gallery preview reading the real `KnownRobots.defaults`
    /// would always render the fallback selected underneath a differently-tinted
    /// screen. Same shape as `ThemeFromSettings.init(defaults:)` in `ThemeSettings.swift`.
    /// Set when `setAlternateIconName` refuses. Injectable for the same reason the
    /// defaults suite is: a preview cannot reach a refusal, and an uncovered failure
    /// caption is one nobody looks at until a reader reports it.
    @State private var iconChangeFailed: Bool
    /// Scaled with the caption under it, and the ring's radius follows the side so
    /// the corners stay concentric at every size.
    @ScaledMetric(relativeTo: .body) private var tileSide = Metrics.themeTile

    init(defaults: UserDefaults = KnownRobots.defaults, iconChangeFailed: Bool = false) {
        _rawTheme = AppStorage(
            wrappedValue: ReachyTheme.fallback.rawValue,
            ThemeStore.key,
            store: defaults
        )
        _iconChangeFailed = State(initialValue: iconChangeFailed)
    }

    private var selection: ReachyTheme {
        ReachyTheme(rawValue: rawTheme) ?? .fallback
    }

    var body: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.md) {
                        ForEach(ReachyTheme.allCases) { theme in
                            tile(theme)
                        }
                    }
                    .padding(.vertical, Space.sm)
                    // The selection ring bleeds Space.xs outside its tile (see the
                    // overlay below); without this the trailing tile's ring is
                    // sliced flat against the scroll view's edge.
                    .padding(.horizontal, Space.xs)
                }
                // Only five of six tiles fit at rest, so the row must bring the chosen
                // one on screen itself — otherwise picking a theme off the fold and
                // coming back reads as if the choice reverted.
                .onAppear { proxy.scrollTo(selection.id) }
                .onChange(of: selection) { _, newSelection in
                    withAnimation { proxy.scrollTo(newSelection.id) }
                }
            }
        } header: {
            Text(.reachy("Appearance"))
        } footer: {
            if iconChangeFailed {
                Text(.reachy("The app icon didn't change."))
                    .foregroundStyle(Tone.danger.style)
            }
        }
    }

    private func tile(_ theme: ReachyTheme) -> some View {
        Button {
            rawTheme = theme.rawValue
            WidgetCenter.shared.reloadAllTimelines()
            // The theme is already saved; the icon is best effort. Awaiting it here
            // would block the tile's highlight behind iOS's own alert.
            Task { iconChangeFailed = await AppIconSwitcher.apply(theme) == false }
        } label: {
            VStack(spacing: Space.sm) {
                Radius.rect(tileRadius)
                    .fill(theme.iconSwatch)
                    .frame(width: tileSide, height: tileSide)
                    .overlay {
                        // Concentric: a ring pushed out by `Space.xs` needs its radius
                        // grown by the same amount, or the gap it leaves is narrower at
                        // the corners than along the sides and the corner reads pinched.
                        Radius.rect(tileRadius + Space.xs)
                            .strokeBorder(theme.accent, lineWidth: theme == selection ? 3 : 0)
                            .padding(-Space.xs)
                    }
                Text(theme.title)
                    .font(Typography.status)
                    .foregroundStyle(theme == selection ? Tone.brand.style : Tone.quiet.style)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.title))
        .accessibilityAddTraits(theme == selection ? [.isSelected] : [])
        .id(theme.id)
    }

    /// A tile stands for the app icon, so it takes the icon's corner proportion rather
    /// than a layout radius — the same `Radius.tile` the store and dock artwork use, so
    /// all three read as one object at three sizes. `Radius.lg` was 16 pt on a 56 pt
    /// tile, which is 29 % where an iOS icon's squircle is 22 %.
    private var tileRadius: CGFloat {
        Radius.tile(side: tileSide)
    }
}

#if DEBUG
    extension AppearanceSection {
        /// A suite nothing else reads, with `theme` already written into it — so a
        /// preview can show the picker with that theme both applied (via
        /// `.reachyTheme(_:)` on the caller) and selected here, which the tint alone
        /// cannot prove. Same suite `KnownRobotsModel.preview` and
        /// `FloatingViewportPreferences.preview` already share, under a key neither
        /// of them touches.
        static func preview(_ theme: ReachyTheme, iconChangeFailed: Bool = false) -> AppearanceSection {
            let defaults = UserDefaults(suiteName: "ReachyUI.previews") ?? .standard
            ThemeStore(defaults: defaults).theme = theme
            return AppearanceSection(defaults: defaults, iconChangeFailed: iconChangeFailed)
        }
    }
#endif
