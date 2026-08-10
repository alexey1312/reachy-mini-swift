import ReachyDesign
@testable import ReachyUI
import SwiftUI

#Preview("Appearance — picker") {
    Form {
        AppearanceSection()
    }
    .formStyle(.grouped)
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
                Picker(.reachy("Source"), selection: $segment) {
                    Text(.reachy("This network")).tag(0)
                    Text(.reachy("Manual")).tag(1)
                }
                .pickerStyle(.segmented)
            }
            appearance
        }
        .formStyle(.grouped)
    }
}
