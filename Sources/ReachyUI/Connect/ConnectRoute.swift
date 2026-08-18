import ReachyDesign
import SwiftUI

/// The three ways a robot can be reached, as the segmented control that splits
/// this screen up.
///
/// Setting a robot up over Bluetooth is deliberately not one of them. It is not a
/// way of reaching a robot — it is how a robot that has never been on a network
/// gets onto one, which is precisely the situation where all three of these are
/// failing. It stays a permanent row below the segments for the same reason it has
/// always had a `Section` of its own.
enum ConnectRoute: String, CaseIterable, Identifiable {
    /// The candidate sweep and Bonjour: robots reachable from this Wi-Fi.
    case network
    /// Robots linked to the reader's Hugging Face account, wherever they are.
    case account
    case manual
    /// A robot that is not there at all. Last, because it is the answer for a
    /// reader who has no robot rather than one who cannot find theirs.
    case simulator

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .network: .reachy("This network")
        case .account: .reachy("Hugging Face")
        case .manual: .reachy("Manual")
        case .simulator: .reachy("Simulator")
        }
    }
}

/// Not persisted, and not defaulted to whatever was used last. The screen lives
/// for minutes, and starting on the sweep is right every time: a remembered
/// "Manual" would greet the reader with an empty text field while the robot they
/// want is already sitting in the list one segment over.
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
