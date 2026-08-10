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
    init(defaults: UserDefaults = KnownRobots.defaults) {
        _rawTheme = AppStorage(
            wrappedValue: ReachyTheme.fallback.rawValue,
            ThemeStore.key,
            store: defaults
        )
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
        }
    }

    private func tile(_ theme: ReachyTheme) -> some View {
        Button {
            rawTheme = theme.rawValue
            #if !os(macOS)
                WidgetCenter.shared.reloadAllTimelines()
            #endif
        } label: {
            VStack(spacing: Space.sm) {
                Radius.rect(Radius.lg)
                    .fill(gradient(theme))
                    .frame(width: Metrics.themeTile, height: Metrics.themeTile)
                    .overlay {
                        Radius.rect(Radius.lg)
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

    private func gradient(_ theme: ReachyTheme) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: theme.palette.gradientTop),
                Color(hex: theme.palette.gradientBottom),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
        static func preview(_ theme: ReachyTheme) -> AppearanceSection {
            let defaults = UserDefaults(suiteName: "ReachyUI.previews") ?? .standard
            ThemeStore(defaults: defaults).theme = theme
            return AppearanceSection(defaults: defaults)
        }
    }
#endif
