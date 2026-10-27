import SwiftUI

/// The toolbar button that puts a sheet away.
///
/// **A word alone does not reach a vertical bar, and that is why this exists.**
/// On iPhone Duo — the outer display, and the inner one in landscape — the
/// system moves a sheet's toolbar to the side, and only items with a symbol go
/// with it: a text-only "Done" stays horizontal at the top, above content the
/// bar no longer covers (Apple, *Raise the bar with iPhone Duo*, 5:56; measured
/// on the iPhone Duo simulator, iOS 27.1). The roles iOS 26 added give each item
/// the system's own symbol and title: `.close` draws an `xmark` and reads
/// "Close", `.confirm` draws a checkmark, and a cancel keeps its word as the
/// title of an `xmark`. Below iOS 26 nothing moves a bar, and the button keeps
/// the word it always had.
///
/// Every sheet here used to spell its own `Button(.reachy("Done"))`, so this is
/// one value with many consumers (project rule 10), not a new control.
public struct ReachySheetDismissButton: View {
    public enum Kind: Sendable {
        /// Nothing to keep or discard: the sheet only showed something.
        case close
        /// The reader's changes are already applied, and this confirms them.
        case done
        /// Something is under way in the sheet, and this abandons it.
        case cancel
    }

    private let kind: Kind
    private let action: () -> Void

    public init(_ kind: Kind = .close, action: @escaping () -> Void) {
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            switch kind {
            case .close: Button(role: .close, action: action)
            case .done: Button(role: .confirm, action: action)
            case .cancel: Button(.reachy("Cancel"), systemImage: "xmark", role: .cancel, action: action)
            }
        } else {
            switch kind {
            case .close, .done: Button(.reachy("Done"), action: action)
            case .cancel: Button(.reachy("Cancel"), role: .cancel, action: action)
            }
        }
    }
}
