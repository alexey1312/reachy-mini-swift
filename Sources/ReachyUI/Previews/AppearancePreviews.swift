import ReachyDesign
@testable import ReachyUI
import SwiftUI

#Preview("Appearance — picker") {
    Form {
        AppearanceSection()
    }
    .formStyle(.grouped)
}

// The one state the picker can reach that nothing else captures: iOS refused the
// icon while the theme was saved anyway. `.rose` rather than a seventh theme because
// `Appearance — rose` already writes that value into the shared preview suite, so
// the two cannot disagree about what is selected.
#Preview("Appearance — icon refused") {
    Form {
        AppearanceSection.preview(.rose, iconChangeFailed: true)
    }
    .formStyle(.grouped)
    .reachyTheme(.rose)
}

#Preview("Appearance — graphite") { themedSample(.graphite) }
#Preview("Appearance — bronze") { themedSample(.bronze) }
#Preview("Appearance — teal") { themedSample(.teal) }
#Preview("Appearance — indigo") { themedSample(.indigo) }
#Preview("Appearance — orchid") { themedSample(.orchid) }
#Preview("Appearance — rose") { themedSample(.rose) }

/// One screen per theme, so a reference exists for each accent rather than for the
/// default alone. A `Form` with the controls that actually carry the tint — a
/// button, a link-styled row, a toggle, a segmented picker — plus `AppearanceSection`
/// itself, reading a preview suite that already has `theme` written into it. Without
/// that seam every gallery capture would show the fallback tile selected regardless
/// of which theme is applied above it: `.reachyTheme(_:)` sets the environment and
/// the tint, never the store.
///
/// `AppearanceSection.preview(theme)` writes that store, so it is called here rather
/// than from inside `ThemeSample.body` — SwiftUI may re-run a `body` arbitrarily
/// often, and a write there would fire on every one of those re-runs instead of once.
@MainActor
func themedSample(_ theme: ReachyTheme) -> some View {
    ThemeSample(appearance: AppearanceSection.preview(theme))
        .reachyTheme(theme)
}

private struct ThemeSample: View {
    let appearance: AppearanceSection
    @State private var isOn = true
    @State private var segment = 0

    var body: some View {
        Form {
            Section {
                Button(.reachy("Set up a new robot over Bluetooth")) {}
                Toggle(.reachy("Automatic reconnect"), isOn: $isOn)
                // Borrowed from the connect screen rather than invented, and it has
                // to be: `check-catalogue.py` scans `Sources/` and not `Previews/`,
                // so a key spelled only here is dead copy by its reckoning and gets
                // reconciled away. Every literal in this sample is one a real screen
                // also uses.
                Picker(.reachy("Source"), selection: $segment) {
                    Text(.reachy("Local")).tag(0)
                    Text(.reachy("HF")).tag(1)
                }
                .pickerStyle(.segmented)
            }
            appearance
        }
        .formStyle(.grouped)
    }
}
