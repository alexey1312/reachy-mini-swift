import ReachyDesign
import SwiftUI

/// The three ways a robot can be reached, as the segmented control that splits
/// this screen up.
///
/// **A typed address is not a fourth way, and it used to be a segment of its own.**
/// It answers the same question `local` does — how to reach a robot on this
/// network — and it is where a reader goes the moment the list above it stays
/// empty, which is exactly the moment discovery has failed and a second tab is the
/// last thing to go looking through. The list's own copy already said "or enter its
/// address below" while the field was a segment away. So the field sits under the
/// list, and `ManualAddressSection` keeps its name because what it is has not
/// changed: a first-class way in, not a fallback.
///
/// Setting a robot up over Bluetooth is deliberately not one of them either. It is
/// not a way of reaching a robot — it is how a robot that has never been on a
/// network gets onto one, which is precisely the situation where all three of these
/// are failing. It stays a permanent row below the segments for the same reason it
/// has always had a `Section` of its own.
///
/// **The titles are as short as they can be said**, because four segments of prose
/// truncated on an iPhone and a segment nobody can read is a segment nobody opens.
/// "HF" is the one piece of jargon, and it is the reader's own account's jargon.
enum ConnectRoute: String, CaseIterable, Identifiable {
    /// The candidate sweep, Bonjour, and a typed address: robots reachable from
    /// this Wi-Fi, however they are found.
    case local
    /// Robots linked to the reader's Hugging Face account, wherever they are.
    case account
    /// A robot that is not there at all. Last, because it is the answer for a
    /// reader who has no robot rather than one who cannot find theirs.
    case simulator

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .local: .reachy("Local")
        case .account: .reachy("HF")
        case .simulator: .reachy("Simulator")
        }
    }
}

/// Not persisted, and not defaulted to whatever was used last. The screen lives
/// for minutes, and starting on the sweep is right every time.
struct ConnectRoutePicker: View {
    @Binding var route: ConnectRoute

    var body: some View {
        Picker(.reachy("How to reach the robot"), selection: $route) {
            ForEach(ConnectRoute.allCases) { route in
                Text(route.title).tag(route)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
