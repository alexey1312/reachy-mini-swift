import SwiftUI

/// What a colour *means* here, resolved against the system styles.
///
/// The palette behind `.brand` is `ReachyTheme` — six generated colour sets, one of
/// which the scene root applies as its tint. The other four roles stay system
/// colours on purpose: a role that pinned its own literal could not adapt under
/// chrome, which is the trap `ReachyUI/AGENTS.md` records the app falling into
/// twice.
public enum Tone: Sendable, CaseIterable {
    case danger
    case warning
    case success
    /// The app's own accent, wherever a control means "this is the action".
    case brand
    /// Present but not the point: captions, settled states, secondary detail.
    case quiet
}

public extension Tone {
    var style: AnyShapeStyle {
        switch self {
        case .danger: AnyShapeStyle(.red)
        case .warning: AnyShapeStyle(.orange)
        case .success: AnyShapeStyle(.green)
        // `.tint` rather than `.accentColor`: it follows a `.tint(_:)` set
        // anywhere above, which is what a widget's accented rendering relies on.
        case .brand: AnyShapeStyle(.tint)
        case .quiet: AnyShapeStyle(.secondary)
        }
    }
}
