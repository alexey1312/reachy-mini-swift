import ReachyDesign
import SwiftUI

/// The network picker, the typed name for a network the scan left out, and the
/// password — the three rows both ways onto a network ask for, once.
///
/// The Bluetooth flow and the Wi-Fi sheet used to spell these separately, and they
/// had already drifted: one had a permanent "Other network…" row and a footer
/// explaining why, the other a scan failure line. They are one set of rows now,
/// and the host supplies the footer it needs.
///
/// "Other network…" is a permanent row, not an escape hatch: over Bluetooth the
/// robot answers a scan in one 180-byte message with no pagination and no flag
/// saying anything was dropped, so a missing network is the ordinary case rather
/// than the broken one — and over Wi-Fi a hidden network is missing by design.
struct NetworkCredentialsFields: View {
    let networks: [String]
    @Binding var selected: String?
    @Binding var manualSSID: String
    @Binding var password: String
    let isScanning: Bool
    /// The last scan's failure, where the host has one to show here rather than in
    /// a row of its own.
    var scanFailure: String?
    let scanAgain: () -> Void

    var body: some View {
        Picker(.reachy("Network"), selection: $selected) {
            ForEach(networks, id: \.self) { network in
                Text(network).tag(String?.some(network))
            }
            Text(.reachy("Other network…")).tag(String?.none)
        }
        if selected == nil {
            TextField(.reachy("Network name"), text: $manualSSID)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
        }
        SecureField(.reachy("Wi-Fi password"), text: $password)
            .textContentType(.password)
        Button(action: scanAgain) {
            Label(.reachy("Scan again"), systemImage: "arrow.clockwise")
        }
        .disabled(isScanning)
        if let scanFailure {
            Text(scanFailure)
                .font(Typography.status)
                .foregroundStyle(Tone.warning.style)
        }
    }
}
