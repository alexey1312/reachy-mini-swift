import SwiftUI

/// A theme the user can pick: one accent colour and, on iOS, one app icon.
///
/// The values live here as constants rather than only in the asset catalogue
/// because three consumers need the same numbers — SwiftUI reads the generated
/// catalogue, the icon script reads the gradient, and `ReachyThemeTests` reads the
/// accents to check them. One source, so a rendered colour cannot differ from a
/// verified one.
public enum ReachyTheme: String, CaseIterable, Sendable, Identifiable {
    case graphite
    case bronze
    case teal
    case indigo
    case orchid
    case rose

    /// What an absent or unrecognised stored value resolves to — the latter happens
    /// to anyone who downgrades to a build that predates a theme.
    public static let fallback = ReachyTheme.graphite

    public var id: String {
        rawValue
    }
}

public extension ReachyTheme {
    /// sRGB, one accent per appearance plus the two gradient stops the icon uses.
    struct Palette: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32
        public let gradientTop: UInt32
        public let gradientBottom: UInt32
    }

    var palette: Palette {
        switch self {
        case .graphite:
            Palette(light: 0x3E4757, dark: 0xA9B6CC, gradientTop: 0x9AA6B8, gradientBottom: 0x3E4757)
        case .bronze:
            Palette(light: 0xB26708, dark: 0xE3A24A, gradientTop: 0xFFC96B, gradientBottom: 0xB26708)
        case .teal:
            Palette(light: 0x00A0A8, dark: 0x4FD6DE, gradientTop: 0x5FE0CE, gradientBottom: 0x00A0A8)
        case .indigo:
            Palette(light: 0x4B47D6, dark: 0x8E8CF0, gradientTop: 0x9B9BF5, gradientBottom: 0x4B47D6)
        case .orchid:
            Palette(light: 0x9038D9, dark: 0xC58AF0, gradientTop: 0xE8AEFF, gradientBottom: 0x9038D9)
        case .rose:
            Palette(light: 0xD6248A, dark: 0xFF7ABA, gradientTop: 0xFFA8CE, gradientBottom: 0xD6248A)
        }
    }
}
