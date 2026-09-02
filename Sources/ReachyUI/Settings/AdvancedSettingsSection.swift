import ReachyDesign
import ReachyKit
import ReachySSH
import SwiftUI

/// The row at the foot of Settings, and the screen behind it.
///
/// Everything behind it is either irreversible, diagnostic, or a way around the
/// daemon — none of it belongs within reach of someone who opened Settings to turn
/// the volume down. It was a `DisclosureGroup`, which put six rows of it under a
/// chevron nobody opens and could not be captured through `SettingsScreen` at all:
/// closed on a real screen and below the fold on both snapshot devices. A pushed
/// screen is what a reader expects behind a word like Advanced, and it is captured
/// standalone the way `MaintenanceCard` is.
struct AdvancedSettingsSection: View {
    let session: RobotSession

    var body: some View {
        Section {
            NavigationLink {
                AdvancedScreen(session: session)
            } label: {
                Label(.reachy("Advanced"), systemImage: "gearshape.2")
            }
        } footer: {
            Text(.reachy("Diagnostics, irreversible actions, and the robot's own file system over SSH."))
        }
    }
}

/// The rows themselves. The network and maintenance cards used to sit at the top
/// level of Settings; each has a screen of its own (`AdvancedCardScreens`) so that
/// a card built as a `Section` needs no reshaping to be pushed from here.
struct AdvancedScreen: View {
    let session: RobotSession

    /// The app target's own screen, if it has one. Read from the environment rather
    /// than passed in: an optional `@MainActor` closure as an initialiser argument
    /// defeats the type checker outright — a ternary between a closure literal and
    /// `nil` produces "failed to produce diagnostic for expression", which names the
    /// enclosing function and nothing useful. A preview writes the environment value.
    @Environment(\.reachyDeveloperScreen) private var developerScreen

    var body: some View {
        Form {
            Section {
                if session.canConfigureWiFi {
                    NavigationLink {
                        WiFiSettingsScreen(session: session)
                    } label: {
                        Label(.reachy("Network"), systemImage: "wifi")
                    }
                }
                if session.canPerformMaintenance {
                    NavigationLink {
                        MaintenanceScreen(session: session)
                    } label: {
                        Label(.reachy("Maintenance"), systemImage: "trash")
                    }
                }
                if session.canReadDaemonLogs {
                    NavigationLink {
                        LogConsoleScreen(session: session)
                    } label: {
                        Label(.reachy("Daemon logs"), systemImage: "terminal")
                    }
                }
                filesLink
                NavigationLink {
                    BLEConsoleScreen()
                } label: {
                    Label(.reachy("Recovery over Bluetooth"), systemImage: "wrench.and.screwdriver")
                }
                if let developerScreen {
                    NavigationLink {
                        developerScreen()
                    } label: {
                        Label(.reachy("Developer tools"), systemImage: "stethoscope")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Advanced"))
    }

    /// SFTP needs a TCP route to port 22, which a relay session does not have — the
    /// Hugging Face relay carries WebRTC, not a tunnel (ADR 0003). So the row is
    /// absent rather than present and failing, the same way `canConfigureWiFi` gates
    /// the network row.
    @ViewBuilder
    private var filesLink: some View {
        if let address = session.address, let robot = identity?.deduplicationKey {
            NavigationLink {
                // Built in the destination closure rather than held here:
                // `RobotFilesScreen` adopts it into `@State`, so a re-run does not
                // replace a live session — the shape `YourReachiesScreen` uses.
                RobotFilesScreen(
                    model: RobotFilesModel(
                        files: SSHFileSystem(robot: robot),
                        robot: robot,
                        host: address.host
                    )
                )
            } label: {
                Label(.reachy("Robot files"), systemImage: "folder")
            }
        }
    }

    private var identity: RobotIdentity? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity
        default: nil
        }
    }
}
