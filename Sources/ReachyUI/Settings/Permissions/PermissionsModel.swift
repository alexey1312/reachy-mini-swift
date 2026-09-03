import Foundation
import Observation
import ReachyKit
import ReachyMedia

/// What the app has been allowed to do, and the four ways to ask for more.
///
/// The governing rule is that **opening the screen must never raise a prompt.**
/// `refresh()` therefore reads only the two sources that can answer without asking —
/// `CBCentralManager.authorization` and the microphone's authorization status — and the
/// local network, which has no such source, stays at whatever is already known until
/// the user asks for it. Every prompting path is a method a button calls.
///
/// The probes are injected rather than called directly so the tests can assert the
/// thing that matters most here: that a refresh does not touch them.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var states: [PermissionKind: PermissionState]
    /// The radio, which authorization cannot report. Only ever set by
    /// `requestBluetooth()`, because reading it costs the prompt.
    private(set) var bluetoothAvailability: BLEAvailability?
    private(set) var busy: PermissionKind?

    private let readBluetooth: @Sendable () -> PermissionState
    private let readMicrophone: @Sendable () -> PermissionState
    private let promptBluetooth: @Sendable () async -> BLEAvailability
    private let promptMicrophone: @Sendable () async -> PermissionState
    private let probeLocalNetwork: @Sendable () async -> PermissionState
    /// Async because `notificationSettings()` is, and still non-prompting — the rule
    /// this screen turns on is "does not ask", not "answers synchronously".
    private let readNotifications: @Sendable () async -> PermissionState
    private let promptNotifications: @Sendable () async -> PermissionState

    /// The probes default to `nil` and are resolved here rather than in the signature.
    /// Two reasons, and both would be compile errors: a bare `BluetoothPermission
    /// .promptForAccess` cannot stand in for a no-argument closure, because a default
    /// argument is not applied when a function is used as a *value*; and a default
    /// argument is evaluated in a nonisolated context, which is the trap this target's
    /// `AGENTS.md` records.
    init(
        initial: [PermissionKind: PermissionState] = [:],
        readBluetooth: (@Sendable () -> PermissionState)? = nil,
        readMicrophone: (@Sendable () -> PermissionState)? = nil,
        promptBluetooth: (@Sendable () async -> BLEAvailability)? = nil,
        promptMicrophone: (@Sendable () async -> PermissionState)? = nil,
        probeLocalNetwork: (@Sendable () async -> PermissionState)? = nil,
        readNotifications: (@Sendable () async -> PermissionState)? = nil,
        promptNotifications: (@Sendable () async -> PermissionState)? = nil
    ) {
        states = PermissionKind.allCases.reduce(into: [:]) { result, kind in
            result[kind] = initial[kind] ?? .undetermined
        }
        self.readBluetooth = readBluetooth ?? { BluetoothPermission.current }
        self.readMicrophone = readMicrophone ?? { MicrophonePermission.current }
        self.promptBluetooth = promptBluetooth ?? { await BluetoothPermission.promptForAccess() }
        self.promptMicrophone = promptMicrophone ?? { await MicrophonePermission.request() }
        self.probeLocalNetwork = probeLocalNetwork ?? { await LocalNetworkProbe.resolve() }
        self.readNotifications = readNotifications ?? { await NotificationPermission.current }
        self.promptNotifications = promptNotifications ?? { await NotificationPermission.request() }
    }

    subscript(kind: PermissionKind) -> PermissionState {
        states[kind] ?? .undetermined
    }

    /// Safe to call on appear: neither source prompts, and the local network — the one
    /// that would — is left exactly as it was.
    func refresh() {
        states[.bluetooth] = readBluetooth()
        states[.microphone] = readMicrophone()
    }

    /// The async half of `refresh()`, and non-prompting for the same reason it is.
    /// Kept separate rather than making `refresh()` async: every existing caller is
    /// synchronous, and turning them all async to carry one more read would be a wide
    /// change for a narrow reason.
    func refreshNotifications() async {
        states[.notifications] = await readNotifications()
    }

    /// A LAN-linked session is proof on its own: every daemon call needs the grant, so
    /// a robot answering over the network cannot be reached without it. Worth taking,
    /// because the probe can only ever confirm a grant by *finding* something — and
    /// over the Hugging Face relay there is no such session, which is exactly when this
    /// screen has something to say.
    func noteLocalNetworkProvenByConnection() {
        states[.localNetwork] = .granted
    }

    func requestMicrophone() async {
        await run(.microphone) { await self.promptMicrophone() }
    }

    /// Reached from two buttons — this screen's Allow, and the Settings toggle. Two
    /// paths to one prompt is not a defect: the system only ever asks once, and the
    /// microphone already has exactly this shape.
    func requestNotifications() async {
        await run(.notifications) { await self.promptNotifications() }
    }

    /// There is no way to check the local network without also asking for it, so this
    /// is a button and never an effect. See `LocalNetworkProbe` for why a result that
    /// finds nothing stays `.undetermined` rather than becoming a refusal.
    func checkLocalNetwork() async {
        await run(.localNetwork) { await self.probeLocalNetwork() }
    }

    /// Prompting for Bluetooth means building a central, so this also learns the radio
    /// state that authorization alone can never report — a switched-off radio or a
    /// Simulator with none at all both read as `.notDetermined` until something asks.
    func requestBluetooth() async {
        guard busy == nil else { return }
        busy = .bluetooth
        defer { busy = nil }
        bluetoothAvailability = await promptBluetooth()
        states[.bluetooth] = readBluetooth()
    }

    private func run(_ kind: PermissionKind, _ work: @escaping () async -> PermissionState) async {
        guard busy == nil else { return }
        busy = kind
        defer { busy = nil }
        states[kind] = await work()
    }
}

#if DEBUG
    extension PermissionsModel {
        /// A model already in its end state, with every probe inert — a preview must be
        /// final on its first frame, and none of these may reach a radio or a network.
        ///
        /// In this file rather than in `Previews/`, because `bluetoothAvailability` is
        /// `private(set)` and only a member of this file may assign it.
        static func preview(
            bluetooth: PermissionState = .granted,
            localNetwork: PermissionState = .granted,
            microphone: PermissionState = .granted,
            notifications: PermissionState = .granted,
            availability: BLEAvailability? = nil
        ) -> PermissionsModel {
            let model = PermissionsModel(
                initial: [
                    .bluetooth: bluetooth,
                    .localNetwork: localNetwork,
                    .microphone: microphone,
                    .notifications: notifications,
                ],
                readBluetooth: { bluetooth },
                readMicrophone: { microphone },
                promptBluetooth: { BLEAvailability.ready },
                promptMicrophone: { microphone },
                probeLocalNetwork: { localNetwork },
                readNotifications: { notifications },
                promptNotifications: { notifications }
            )
            model.bluetoothAvailability = availability
            return model
        }
    }
#endif
