import Foundation
import Observation
import ReachyKit

/// What the flow hands back on its way out: enough to recognise the robot once it turns
/// up on the network, and a head start on where to look.
struct OnboardingOutcome: Equatable, Sendable {
    /// Rule 4's join key. The address the robot was provisioned at is exactly the thing
    /// that changes, so identity is the only usable handle.
    var hardwareID: String?
    /// Read off the Bluetooth status characteristic after the join — the one place the
    /// robot's new address is reported at all.
    var address: RobotAddress?
}

/// Drives first-run setup: find a robot over Bluetooth, unlock it with the PIN from its
/// base, hand it a Wi-Fi password, and point the LAN sweep at the result.
///
/// Never a gate. Every step can be abandoned, and a robot already on the network is
/// found by `ConnectionScreen` without any of this.
@MainActor
@Observable
final class OnboardingModel {
    /// The naming step comes straight after the PIN, while the robot's 300-second
    /// session is fresh: `SET_NAME` needs it, and a reader who lingers over the Wi-Fi
    /// password could otherwise outlast it. Daemon 1.9.0 has no `SET_NAME` and echoes
    /// it back, so on such a robot the step says the name has to wait for Settings.
    enum Step: Hashable {
        case welcome
        case scan
        case pin
        case name
        case network
        case joining
        case handoff
    }

    enum JoinState: Equatable {
        case working
        /// The robot refused the payload outright — a bad PIN, a stale key, or a message
        /// too long for one write.
        case refused(String)
        /// The password was handed over and the robot never came up on the network. It
        /// has raised its own access point again by now.
        case gaveUp
        case joined
    }

    private(set) var step: Step = .welcome
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var joinState: JoinState = .working
    /// Ticked here because `BLEPinSession` derives the remaining time from a clock, and
    /// nothing would otherwise tell the view to look again.
    private(set) var lockoutSeconds: Int?

    var pinInput = ""
    var nameInput = ""
    /// The robot echoed `SET_NAME`: a 1.9.x robot, which can be named only over the
    /// network, once it is on one.
    private(set) var nameIsUnsupported = false
    var manualSSID = ""
    var password = ""
    /// Nil means the "Other network…" row. It is a required part of the screen rather
    /// than a fallback: the robot truncates its scan at 180 bytes and never says how many
    /// names it dropped.
    var selectedSSID: String?

    /// Built on leaving the welcome screen, not in `init`: constructing it is what
    /// prompts for Bluetooth permission, and that sheet should land on a screen that has
    /// just explained what it is for.
    private(set) var session: BLELink?
    private let makeSession: @MainActor () -> BLELink
    private var lockoutTask: Task<Void, Never>?

    init(session: (@MainActor () -> BLELink)? = nil) {
        makeSession = session ?? { BLELink() }
    }

    // MARK: - Derived state

    var availability: BLEAvailability {
        session?.availability ?? .unknown
    }

    var discovered: [BLEPeripheralSnapshot] {
        session?.discovered ?? []
    }

    var networks: [String] {
        session?.networks ?? []
    }

    var attemptsBeforeLockout: Int {
        session?.pin.attemptsBeforeLockout ?? BLEPinSession.freeAttempts
    }

    /// The robot was already on a network when it was unlocked, so the whole Wi-Fi part
    /// of the flow is optional for it.
    var isAlreadyOnNetwork: Bool {
        session?.networkStatus?.mode == .wlan
    }

    var ssid: String {
        (selectedSSID ?? manualSSID).trimmingCharacters(in: .whitespaces)
    }

    var canSubmitPIN: Bool {
        !isBusy && lockoutSeconds == nil && pinInput.count == BLEPinSession.length
    }

    /// The daemon's own bounds on a name (`RobotNameRequest`, 1 to 64 characters).
    var canSubmitName: Bool {
        !isBusy && (1 ... 64).contains(trimmedName.count)
    }

    private var trimmedName: String {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canJoin: Bool {
        !isBusy && !ssid.isEmpty && !password.isEmpty
    }

    /// Back is only offered where going back means something: once the password is on its
    /// way to the robot there is nothing to return to.
    var canGoBack: Bool {
        switch step {
        case .scan, .pin, .name, .network: true
        case .welcome, .joining, .handoff: false
        }
    }

    // MARK: - Steps

    func beginScan() {
        let session = session ?? makeSession()
        self.session = session
        step = .scan
        errorMessage = nil
        if !session.startScan() {
            errorMessage = session.lastError
        }
    }

    func retryScan() {
        guard let session else { return }
        errorMessage = nil
        if !session.startScan() {
            errorMessage = session.lastError
        }
    }

    func connect(to id: UUID) async {
        guard let session else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        if await session.connect(to: id) {
            session.stopScan()
            pinInput = ""
            step = .pin
        } else {
            errorMessage = session.lastError
        }
    }

    func submitPIN() async {
        guard let session else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        if await session.authenticate(pinInput) {
            pinInput = ""
            step = .name
        } else {
            errorMessage = session.lastError
            startLockoutCountdown()
        }
    }

    /// Names the robot over Bluetooth. A robot that echoes the command back stays on
    /// this step and says why, rather than moving on as if the name had been taken.
    func submitName() async {
        guard let session, canSubmitName else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch try await session.rename(to: trimmedName) {
            case .named:
                await proceedToNetwork()
            case .unsupported:
                nameIsUnsupported = true
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// The name is optional: the robot keeps the one it has, and Settings renames it
    /// later over the network.
    func skipName() async {
        await proceedToNetwork()
    }

    private func proceedToNetwork() async {
        errorMessage = nil
        step = .network
        await loadNetworks()
    }

    /// A failed scan is not a dead end — the manual row covers every network the robot
    /// could not fit into its reply anyway.
    func loadNetworks() async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        if await session.refreshNetworks() {
            selectedSSID = session.networks.first
        } else {
            selectedSSID = nil
            errorMessage = session.lastError
        }
    }

    func join() async {
        guard let session else { return }
        step = .joining
        joinState = .working
        errorMessage = nil
        let ssid = ssid
        do {
            switch try await session.join(ssid: ssid, password: password) {
            case .joined:
                password = ""
                joinState = .joined
            case .gaveUp:
                joinState = .gaveUp
            }
        } catch {
            joinState = .refused(Self.describe(error))
        }
    }

    /// The robot answered its status read with `wlan` before any of this, so there is
    /// nothing left to configure — the point of the flow was only ever to get it there.
    func skipNetwork() {
        joinState = .joined
        step = .handoff
    }

    /// Returns to the network step with the password intact — the overwhelmingly likely
    /// correction is one typed character, not a different network.
    func editNetwork() {
        joinState = .working
        step = .network
    }

    func continueAfterJoin() {
        step = .handoff
    }

    /// Drops Bluetooth and hands the robot over to the LAN sweep. The hardware id is
    /// persisted rather than passed along only because the app may not survive the trip
    /// back to the home Wi-Fi network.
    func finish() -> OnboardingOutcome {
        let outcome = OnboardingOutcome(
            hardwareID: session?.hardwareID,
            address: session?.robotAddress.flatMap(RobotAddress.init(parsing:))
        )
        KnownRobots.pendingProvisionedHardwareID = outcome.hardwareID
        KnownRobots.hasCompletedOnboarding = true
        stop()
        return outcome
    }

    /// Leaving early still counts as having seen the flow: it should not reopen itself on
    /// the next launch after the user closed it deliberately.
    func cancel() {
        KnownRobots.hasCompletedOnboarding = true
        stop()
    }

    func back() {
        switch step {
        case .scan:
            session?.stopScan()
            step = .welcome
        case .pin:
            session?.disconnect()
            step = .scan
            retryScan()
        case .name:
            errorMessage = nil
            step = .pin
        case .network:
            step = .name
        case .welcome, .joining, .handoff:
            break
        }
    }

    private func stop() {
        lockoutTask?.cancel()
        lockoutTask = nil
        password = ""
        pinInput = ""
        session?.stop()
    }

    /// Mirrors the robot's throttle locally so the field can stay disabled with a visible
    /// countdown. The robot's own count is what armed it; this only watches it run out.
    private func startLockoutCountdown() {
        lockoutTask?.cancel()
        guard session?.pin.lockoutRemaining() != nil else {
            lockoutSeconds = nil
            return
        }
        lockoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let remaining = session?.pin.lockoutRemaining() else {
                    self?.lockoutSeconds = nil
                    return
                }
                lockoutSeconds = Int(remaining.components.seconds) + 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
    extension OnboardingModel {
        /// A flow parked on one step. The link is handed over already built, because `session`
        /// is otherwise only assigned by `beginScan()` — which is exactly the Bluetooth call a
        /// preview must not make.
        static func preview(
            step: Step,
            link: BLELink? = .preview(),
            isBusy: Bool = false,
            errorMessage: String? = nil,
            joinState: JoinState = .working,
            lockoutSeconds: Int? = nil,
            pinInput: String = "",
            nameInput: String = "",
            nameIsUnsupported: Bool = false,
            selectedSSID: String? = nil,
            manualSSID: String = "",
            password: String = ""
        ) -> OnboardingModel {
            let model = OnboardingModel()
            model.session = link
            model.step = step
            model.isBusy = isBusy
            model.errorMessage = errorMessage
            model.joinState = joinState
            model.lockoutSeconds = lockoutSeconds
            model.pinInput = pinInput
            model.nameInput = nameInput
            model.nameIsUnsupported = nameIsUnsupported
            model.selectedSSID = selectedSSID
            model.manualSSID = manualSSID
            model.password = password
            return model
        }
    }
#endif
