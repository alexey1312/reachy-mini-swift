import ReachyDesign
import ReachyKit
import SwiftUI

/// The list at the top of the `Local` segment: everything the sweep and Bonjour
/// between them can find, and the copy explaining why the list may be empty. The
/// address field its footer points at is `ManualAddressSection`, directly below.
///
/// Robots that answered a handshake before are listed whether or not Bonjour finds
/// them — mDNS does not reach every network, and an absent robot is worth showing
/// as absent rather than not at all.
///
/// A refused Local Network permission used to be reported here and is not any more.
/// It breaks every route, not just this one, so it belongs to the screen — see
/// `ConnectionScreen.privacySection`. This section is about robots.
struct NetworkRobotsSection: View {
    let session: RobotSession
    let browser: RobotBrowser
    let entries: [KnownRobotsModel.Entry]
    var connect: (RobotAddress) -> Void
    var connectToService: (RobotBrowser.DiscoveredService) -> Void
    var forget: (String) -> Void
    /// Which service is having its endpoint resolved, if any. Resolution is the
    /// screen's business — this section only reports it.
    var resolving: String?

    var body: some View {
        Section {
            if !session.automaticConnectionAllowed {
                Label(.reachy("Automatic reconnect paused"), systemImage: "pause.circle")
                    .foregroundStyle(Tone.quiet.style)
            }
            if isSearching {
                Text(.reachy("Searching…"))
                    .foregroundStyle(Tone.quiet.style)
            }
            ForEach(entries) { entry in
                Button {
                    connect(entry.robot.address)
                } label: {
                    LabeledContent(entry.robot.name ?? entry.robot.address.displayString) {
                        KnownRobotStatusLabel(status: entry.status)
                    }
                }
                .swipeActions {
                    Button(.reachy("Forget"), role: .destructive) {
                        forget(entry.id)
                    }
                }
            }
            ForEach(undiscoveredServices) { service in
                Button {
                    connectToService(service)
                } label: {
                    LabeledContent(service.name) {
                        if resolving == service.id {
                            ProgressView()
                        } else {
                            Text(service.type).font(Typography.consoleLine)
                        }
                    }
                }
            }
        } footer: {
            // The gate's own orientation copy, which used to sit above every section
            // on the screen. It only ever described this one — a robot reached
            // through Hugging Face is not on this Wi-Fi, and a typed address is not
            // waiting to appear — so it belongs under this list and nowhere else.
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(.reachy("Your Reachy Mini appears below once it is powered on and joined to this Wi-Fi network."))
                if isSearching {
                    Text(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "Known addresses are retried every 10 s. A robot whose daemon isn't running answers nothing on the network — power it on, or enter its address below."
                        )
                    )
                }
            }
        }
    }

    /// Nothing found yet, from either source. The state this screen spends most of
    /// its life in, and the only one the second paragraph is about.
    private var isSearching: Bool {
        entries.isEmpty && undiscoveredServices.isEmpty
    }

    /// A robot already listed from storage must not appear twice. The advert's TXT
    /// `unit_id` is the same string the handshake stored, so the two are matched on
    /// identity, not address (project rule 4). An advert without one — the legacy
    /// `_http._tcp` type — is always shown.
    private var undiscoveredServices: [RobotBrowser.DiscoveredService] {
        let known = Set(entries.map(\.id))
        return browser.services.filter { service in
            service.hardwareID.map { !known.contains($0) } ?? true
        }
    }
}
