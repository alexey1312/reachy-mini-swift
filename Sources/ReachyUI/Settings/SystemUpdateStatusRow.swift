import ReachyDesign
import SwiftUI

/// The one renderer for a `SystemUpdateCaption.Row`.
///
/// A view of its own because two screens draw it — rule 10's second independent
/// consumer — and because keeping the three shapes here is what leaves each
/// screen's status row a single expression instead of a nine-arm `@ViewBuilder`.
struct SystemUpdateStatusRow: View {
    let row: SystemUpdateCaption.Row

    var body: some View {
        switch row {
        case let .label(text, symbol, tone):
            // `if let` rather than `.foregroundStyle(tone?.style ?? .primary)`: there
            // is no shape style that means "leave it alone", five of the nine rows
            // apply no modifier at all today, and whether `.primary` renders
            // identically to no modifier is a question only a reference could answer.
            if let tone {
                Label(text, systemImage: symbol).foregroundStyle(tone.style)
            } else {
                Label(text, systemImage: symbol)
            }
        case let .value(title, value):
            LabeledContent(title, value: value)
        case let .versions(title, value):
            LabeledContent(title) { Text(value).monospaced() }
        }
    }
}
