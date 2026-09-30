import Foundation
import Observation

/// One Bluetooth session with a robot: find it, unlock it with the PIN printed on its
/// base, and then either hand it a Wi-Fi password or drive it out of whatever state left
/// it unreachable (`BLELink+Recovery.swift`).
///
/// Both jobs share the link because they share the pump — one command at a time on a
/// single response characteristic that carries no correlation id, so a second session on
/// the same transport would race the first for its replies.
///
/// The parallel to `RobotSession` is deliberate — the same shape over a different
/// transport — but this one exists only for the minutes when the network cannot be used.
@MainActor
@Observable
public final class BLELink {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        /// Linked. The robot answers reads, but nothing that needs the PIN.
        case connected
        case failed(String)
    }

    public struct Configuration: Sendable {
        /// Covers the robot's own budget: `nmcli` makes three attempts, each settling
        /// for 2 s and pausing 3 s afterwards.
        public var joinTimeout: Duration = .seconds(60)
        public var joinPollInterval: Duration = .seconds(2)

        public init() {}
    }

    public private(set) var availability: BLEAvailability = .unknown
    public private(set) var discovered: [BLEPeripheralSnapshot] = []
    public private(set) var phase: Phase = .idle
    public internal(set) var pin = BLEPinSession()
    /// The join key between this robot and the one that will appear on the LAN.
    public private(set) var hardwareID: String?
    public private(set) var networkStatus: WiFiStatus?
    /// Where the robot is reachable, which only the Bluetooth characteristic reports —
    /// `GET /wifi/status` carries no address. Worth having: after a join it points
    /// straight at the robot, with no LAN sweep in between.
    public private(set) var robotAddress: String?
    /// Always incomplete — the robot caps its reply at 180 bytes — so a screen offering
    /// this list must also offer manual entry.
    public private(set) var networks: [String] = []
    public internal(set) var lastError: String?

    /// What one command can carry over the current link, beside what CoreBluetooth would
    /// accept by fragmenting. The sealed Wi-Fi payload runs to roughly 260 bytes and the
    /// robot reassembles nothing, so the pair of them is what says whether Bluetooth
    /// provisioning can work on a given phone.
    public var singlePacketWriteLength: Int {
        transport.maximumWriteLength
    }

    public var attributeWriteLength: Int {
        transport.attributeWriteLength
    }

    // Internal rather than private because the recovery half of this type lives in the
    // neighbouring file, and both halves must share the one pump.
    let transport: any BLETransport
    let pump: BLECommandPump
    private let provisioning: BLEProvisioningTransport
    private let configuration: Configuration
    private var eventTask: Task<Void, Never>?
    /// Held because the PIN is the HKDF salt: the password cannot be sealed without it,
    /// and sealing happens several screens after it was typed. It lives here rather than
    /// in a view model so that it dies with the link it belongs to, and it is never
    /// written anywhere — ADR 0001 leaves stored credentials to a real pairing protocol.
    private var verifiedPIN: String?

    public init(
        transport: any BLETransport = CoreBluetoothTransport(),
        configuration: Configuration = .init()
    ) {
        self.transport = transport
        self.configuration = configuration
        pump = BLECommandPump(transport: transport)
        provisioning = BLEProvisioningTransport(pump: pump, transport: transport)
        observe()
    }

    @discardableResult
    public func startScan() -> Bool {
        do {
            try transport.startScan()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    public func stopScan() {
        transport.stopScan()
    }

    public func connect(to id: UUID) async -> Bool {
        phase = .connecting
        lastError = nil
        // A new link is a new session: the robot dropped the old one on disconnect and
        // kept any lockout, which is the asymmetry `BLEPinSession` exists to model.
        pin.invalidate()
        verifiedPIN = nil
        do {
            try await transport.connect(id)
            try await pump.prepare()
            let identifier = try await text(from: .hardwareID)
            hardwareID = identifier.isEmpty ? nil : identifier
            let reading = try await WiFiNetworkStatus(parsing: text(from: .networkStatus))
            networkStatus = reading?.status
            robotAddress = reading?.address
            phase = .connected
            return true
        } catch {
            let reason = Self.message(for: error)
            phase = .failed(reason)
            lastError = reason
            return false
        }
    }

    /// Opens the robot's 300-second session. A wrong PIN is reported through `pin`, not
    /// as a throw, because the remaining attempts are what the screen has to show.
    public func authenticate(_ code: String) async -> Bool {
        guard pin.lockoutRemaining() == nil else {
            lastError = BLECommandError.lockedOut(seconds: 0).errorDescription
            return false
        }
        lastError = nil
        do {
            _ = try await pump.send(.authenticate(pin: code)).value()
            pin.authenticated()
            verifiedPIN = code
            return true
        } catch let error as BLECommandError {
            // The robot's own count is authoritative: it is global to the robot and may
            // already have been advanced by another phone.
            if case let .lockedOut(seconds) = error {
                pin.lockedOut(for: seconds)
            } else if error == .incorrectPIN {
                pin.failed()
            }
            lastError = error.errorDescription
            return false
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    public func refreshNetworks() async -> Bool {
        do {
            networks = try await provisioning.scanNetworks()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    /// What a rename over Bluetooth came to.
    public enum RenameOutcome: Equatable, Sendable {
        /// The name the robot now reports, which the daemon applies live — status,
        /// central and mDNS — without a restart.
        case named(String)
        /// A 1.9.x robot, which echoes `SET_NAME` back. It can be renamed over the
        /// network once it is on one, and not before.
        case unsupported
    }

    /// Names the robot over Bluetooth (`SET_NAME`, daemon 1.10.0). Needs the PIN
    /// session, like every command the robot proxies to its daemon.
    public func rename(to name: String) async throws -> RenameOutcome {
        let reply = try await pump.send(.setName(name))
        if case .echo = reply {
            return .unsupported
        }
        // `OK: Named <name>` — the name as the robot stored it.
        let text = try reply.value()
        return .named(text.hasPrefix("Named ") ? String(text.dropFirst("Named ".count)) : name)
    }

    /// Seals the password, hands it over, and waits for the robot to report itself on
    /// the network. Throwing here means the robot refused the payload; a robot that
    /// simply never joined comes back as `.gaveUp`.
    public func join(ssid: String, password: String) async throws -> WiFiJoinOutcome {
        guard let verifiedPIN else { throw BLECommandError.notAuthenticated }
        try await WiFiProvisioning.join(
            ssid: ssid,
            password: password,
            pin: verifiedPIN,
            using: provisioning
        )
        let outcome = try await WiFiProvisioning.awaitJoin(
            using: provisioning,
            timeout: configuration.joinTimeout,
            pollInterval: configuration.joinPollInterval
        )
        switch outcome {
        case let .joined(status):
            networkStatus = status
            // One more characteristic read, for the address the shared status type has
            // nowhere to carry — this is what the handoff aims the LAN client at.
            robotAddress = try? await provisioning.networkStatus().address
        case let .gaveUp(last):
            networkStatus = last ?? networkStatus
        }
        return outcome
    }

    public func disconnect() {
        transport.disconnect()
        phase = .idle
    }

    /// Ends the session for good. The onboarding flow calls this on its way out, which
    /// is also what releases the PIN.
    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        transport.stopScan()
        transport.disconnect()
        verifiedPIN = nil
        networks = []
        phase = .idle
    }
}

private extension BLELink {
    func observe() {
        eventTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard let self else { return }
                apply(event)
            }
        }
    }

    func apply(_ event: BLETransportEvent) {
        switch event {
        case let .availabilityChanged(value):
            availability = value
        case let .discoveredChanged(list):
            discovered = list
        case let .disconnected(reason):
            // The robot drops the PIN session the instant BLE goes; the lockout it keeps.
            pin.invalidate()
            verifiedPIN = nil
            networks = []
            if phase == .connected {
                phase = .failed(reason ?? "The robot disconnected.")
            }
            lastError = reason ?? lastError
        }
    }

    func text(from characteristic: BLECharacteristicID) async throws -> String {
        let data = try await transport.read(characteristic)
        guard let value = String(bytes: data, encoding: .utf8) else {
            throw BLETransportError.characteristicMissing(characteristic)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension BLELink {
    static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
    public extension BLELink {
        /// A link already in the state a preview wants to draw.
        ///
        /// Here rather than in `Preview/PreviewFixtures.swift` because every field below is
        /// `private(set)`, which only this file can write. Nothing is connected and no
        /// command is ever sent — a preview renders one frame and must not wait on a radio.
        static func preview(
            availability: BLEAvailability = .ready,
            discovered: [BLEPeripheralSnapshot] = [],
            phase: Phase = .connected,
            hardwareID: String? = "a1b2c3d4e5f60718",
            networkStatus: WiFiStatus? = nil,
            robotAddress: String? = nil,
            networks: [String] = [],
            lastError: String? = nil,
            failedPINAttempts: Int = 0
        ) -> BLELink {
            let link = BLELink(
                transport: PreviewBLETransport(availability: availability, discovered: discovered)
            )
            link.availability = availability
            link.discovered = discovered
            link.phase = phase
            link.hardwareID = hardwareID
            link.networkStatus = networkStatus
            link.robotAddress = robotAddress
            link.networks = networks
            link.lastError = lastError
            for _ in 0 ..< failedPINAttempts {
                link.pin.failed()
            }
            return link
        }
    }
#endif
