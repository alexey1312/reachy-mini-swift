import ReachyDesign
import ReachyKit
import SwiftUI

/// The theme picker.
///
/// A tile is the theme's own icon gradient rather than a rendered app icon: the
/// gradient *is* the icon's background, it costs no asset, and it does not promise
/// an icon change on macOS, where there is none.
struct AppearanceSection: View {
    @AppStorage(ThemeStore.key, store: KnownRobots.defaults)
    private var rawTheme: String = ReachyTheme.fallback.rawValue

    private var selection: ReachyTheme {
        ReachyTheme(rawValue: rawTheme) ?? .fallback
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.md) {
                    ForEach(ReachyTheme.allCases) { theme in
                        tile(theme)
                    }
                }
                .padding(.vertical, Space.sm)
            }
        } header: {
            Text(.reachy("Appearance"))
        }
    }

    private func tile(_ theme: ReachyTheme) -> some View {
        Button {
            rawTheme = theme.rawValue
        } label: {
            VStack(spacing: Space.sm) {
                Radius.rect(Radius.lg)
                    .fill(gradient(theme))
                    .frame(width: 56, height: 56)
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
