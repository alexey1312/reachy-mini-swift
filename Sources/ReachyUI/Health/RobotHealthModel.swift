import Foundation
import Observation
import ReachyDesign
import ReachyKit
import ReachySSH

/// The robot's own vital signs, from the two places they come from.
///
/// The split is the whole design. The daemon publishes the **control loop** — the
/// only health figure it has a route for — over the status the session already
/// polls, so that half costs nothing and works over the relay. Processor, memory
/// and temperature exist in no route at all, so that half is read out of `/proc`
/// and `/sys` over SSH, which needs a TCP route to port 22 and a password. Either
/// half can be absent; neither absence is a fault to report.
@MainActor
@Observable
final class RobotHealthModel {
    /// Where the SSH half is. The daemon half has no phase — it is either in the
    /// status or it is not.
    enum Phase: Equatable {
        /// No route to port 22. A relayed session carries WebRTC and not a tunnel
        /// (ADR 0003), so this is not a failure and offers no retry — the section
        /// simply says nothing about the operating system.
        case unavailable
        /// Reachable, but nothing in the Keychain to sign in with.
        case needsPassword
        /// First contact. The key has to be seen before it is pinned.
        case confirmHostKey(HostKeyFingerprint)
        /// A pinned robot answered with a different key. Never auto-accepted.
        case hostKeyChanged(pinned: HostKeyFingerprint, offered: HostKeyFingerprint)
        case connecting
        case sampling
        case failed(String)
    }

    private let files: (any RobotFileSystem)?
    private let credentials: any SSHCredentialStore
    private let robot: String
    private let host: String
    private let port: Int
    private let interval: Duration

    private(set) var phase: Phase
    private(set) var system = LinuxSystemSnapshot()
    private(set) var loop: ControlLoopStats?

    private(set) var frequency = MetricSeries()
    private(set) var cpu = MetricSeries()
    private(set) var memory = MetricSeries()
    private(set) var temperature = MetricSeries()

    /// The password field. Not `private(set)`: the sign-in form binds to it.
    var username: String
    var password = ""

    /// What the robot refused the last sign-in with, for the form to print.
    ///
    /// Distinct from ``Phase/failed(_:)`` because a refused password is not a failed
    /// phase: it goes back to ``Phase/needsPassword``, which is a row offering the
    /// sheet again and has nowhere to say why — while the sheet itself stays up over
    /// it with the field cleared underneath. Without this the whole answer to a
    /// mistyped password is a text field emptying itself. `RobotFilesModel.lastError`
    /// is the same slot, and both fill it through `SSHPasswordForm`.
    private(set) var lastError: String?

    private var reader: SystemMetricsReader?
    private var sampling: Task<Void, Never>?
    private var hasLoadedCredentials = false

    /// `files` is optional so that a relayed session — which has no address to dial
    /// — constructs a model that is honest about having nothing to offer, rather
    /// than one holding a file system it can never connect.
    init(
        files: (any RobotFileSystem)? = nil,
        credentials: any SSHCredentialStore = KeychainSSHCredentialStore(),
        robot: String = "",
        host: String = "",
        port: Int = SSHCredentials.defaultPort,
        interval: Duration = .seconds(5)
    ) {
        self.files = files
        self.credentials = credentials
        self.robot = robot
        self.host = host
        self.port = port
        self.interval = interval
        username = SSHCredentials.defaultUsername
        phase = files == nil ? .unavailable : .needsPassword
    }

    /// Closes the session when nothing holds this model any more.
    ///
    /// `SSHClient` has no `deinit` of its own and `close()` is the only thing that
    /// shuts its channel, so a model released without this leaves a live TCP
    /// connection to the robot behind — one per visit to the tab, for as long as the
    /// app runs. `files` is bound before the `Task` so the closure never captures
    /// `self`, which a `deinit` may not escape. The same shape `RobotFilesModel` uses.
    ///
    /// The sampling task is not cancelled here and does not need to be: a `deinit`
    /// on a `@MainActor` type is nonisolated and may not touch a `var` at all, and
    /// the loop holds `self` weakly — it wakes once more, finds nothing, and returns.
    deinit {
        guard let files else { return }
        Task { await files.disconnect() }
    }

    // MARK: - The daemon's half

    /// Records one control-loop reading. Driven by the view from the session's own
    /// poll rather than by a clock here: the status arrives every three seconds
    /// whether this screen is up or not, and a second timer over it would sample the
    /// same value twice as often as it changes.
    func record(loop: ControlLoopStats?) {
        self.loop = loop
        frequency.append(loop?.frequencyHz)
    }

    // MARK: - The operating system's half

    /// Opens the session if there is a stored password, and starts sampling.
    ///
    /// Never prompts. A health panel that raises a password field the moment the tab
    /// opens has turned a passive reading into a demand, so an absent credential
    /// settles in ``Phase/needsPassword`` and waits for the row to be tapped.
    func start() async {
        guard files != nil, sampling == nil else { return }
        // A `.task` re-firing must not tear down a handshake in flight, and must
        // never step over a fingerprint the reader has not answered yet.
        switch phase {
        case .connecting, .confirmHostKey, .hostKeyChanged: return
        case .unavailable, .needsPassword, .sampling, .failed: break
        }
        loadStoredCredentials()
        guard !password.isEmpty else {
            phase = .needsPassword
            return
        }
        await connect()
    }

    /// Reads the Keychain once, on the first visit rather than in `init`, for the
    /// reason `RobotFilesModel` gives: a `NavigationLink` builds its destination
    /// eagerly, so an initialiser here runs on every render of the parent, and a
    /// synchronous `SecItemCopyMatching` per render is an XPC round trip for nothing.
    private func loadStoredCredentials() {
        guard !hasLoadedCredentials else { return }
        hasLoadedCredentials = true
        guard let stored = try? credentials.credentials(forRobot: robot) else { return }
        username = stored.username
        password = stored.password
    }

    func connect() async {
        guard let files else { return }
        phase = .connecting
        lastError = nil
        do {
            try await files.connect(
                SSHCredentials(host: host, port: port, username: username, password: password)
            )
            try? credentials.save(
                SSHCredentials(host: host, port: port, username: username, password: password),
                forRobot: robot
            )
            reader = SystemMetricsReader(files: files)
            phase = .sampling
            beginSampling()
        } catch let error as ReachySSHError {
            handle(error)
        } catch {
            phase = .failed(String(localized: .reachy("Could not reach the robot over SSH.")))
        }
    }

    /// Accepts the key the last attempt was offered and connects again. Two
    /// connections, because `validateHostKey` has to answer during the handshake and
    /// cannot suspend while a person reads a fingerprint.
    func trustOfferedKey() async {
        let offered: HostKeyFingerprint? = switch phase {
        case let .confirmHostKey(fingerprint): fingerprint
        case let .hostKeyChanged(_, offered): offered
        default: nil
        }
        guard let offered, let files = files as? SSHFileSystem else {
            // A stub file system has no key to pin, so acceptance is a plain retry
            // and previews and tests drive the same button. `RobotFilesModel`'s shape.
            await connect()
            return
        }
        do {
            try await files.trustOfferedHostKey(offered)
        } catch {
            phase = .failed(String(localized: .reachy("Could not store the robot's key.")))
            return
        }
        await connect()
    }

    /// Stops reading and drops the connection, keeping the phase and the readings
    /// already taken.
    ///
    /// Leaving `phase` at `.sampling` is what lets ``start()`` reconnect afterwards
    /// and what keeps the last reading on screen through the gap. That matters for
    /// the caller this exists for — the app going to the background, where the
    /// connection would not survive suspension anyway: a panel that blanks itself
    /// every time the app is put away is a panel nobody trusts, and the values carry
    /// their own age in the series.
    func stop() async {
        sampling?.cancel()
        sampling = nil
        reader = nil
        await files?.disconnect()
    }

    private func handle(_ error: ReachySSHError) {
        switch error {
        case let .hostKeyUnknown(fingerprint):
            phase = .confirmHostKey(fingerprint)
        case let .hostKeyChanged(pinned, offered):
            phase = .hostKeyChanged(pinned: pinned, offered: offered)
        case .authenticationFailed:
            // The stored password goes with the refusal: keeping one the robot has
            // already refused means every return to the foreground spends an SSH
            // handshake failing the same way in silence, because `start()` runs again
            // on each one. The field is cleared with it, so the refusal has to be
            // said in words or the reader is left with a form that emptied itself.
            password = ""
            try? credentials.clear(robot: robot)
            lastError = String(localized: .reachy("That password was refused by the robot."))
            phase = .needsPassword
        default:
            phase = .failed(String(localized: .reachy("Could not reach the robot over SSH.")))
        }
    }

    private func beginSampling() {
        sampling?.cancel()
        sampling = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard let self else { return }
                await sampleOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func sampleOnce() async {
        guard let reader else { return }
        do {
            let snapshot = try await reader.sample()
            guard !Task.isCancelled else { return }
            system = snapshot
            cpu.append(snapshot.cpuPercent)
            memory.append(snapshot.memoryPercent)
            temperature.append(snapshot.cpuTemperatureCelsius)
            if case .failed = phase {
                phase = .sampling
            }
        } catch is CancellationError {
            return
        } catch {
            // A dropped sample is not a dropped session — a robot under load can
            // refuse one read and answer the next — so the loop keeps going and the
            // next good sample puts the phase back on its own.
            //
            // The System rows go with it, because they are gated on `.sampling`: a
            // stale reading under a message saying the robot stopped answering is
            // worse than the message alone. ``stop()`` is the case where they do
            // stay, and leaving its phase untouched is what makes the difference.
            phase = .failed(String(localized: .reachy("Lost the connection to the robot.")))
        }
    }
}

#if DEBUG
    extension RobotHealthModel {
        /// A model already in its end state.
        ///
        /// A preview must be final on its first frame — Prefire captures
        /// synchronously and never lets a `.task` complete — and the series are
        /// handed fixed arrays for a second reason: a sparkline over live samples
        /// would redraw differently on every capture, and a reference image that
        /// cannot repeat itself is a test that fails at random.
        ///
        /// Here rather than in `Previews/` because it writes members that are
        /// `private(set)` to this file, which `@testable` does not reach.
        static func preview(
            phase: Phase = .sampling,
            system: LinuxSystemSnapshot = .previewHealthy,
            loop: ControlLoopStats? = ControlLoopStats(
                frequencyHz: 49.6,
                maxIntervalSeconds: 0.0184,
                errorCount: 0,
                motorController: "ControlLoopStats(period=~20.02ms, read_dt=~1.95 ms, write_dt=~0.44 ms)"
            ),
            history: Bool = true
        ) -> RobotHealthModel {
            let model = RobotHealthModel(files: phase == .unavailable ? nil : PreviewFileSystem())
            model.phase = phase
            model.system = system
            model.loop = loop
            guard history else { return model }
            // The daemon's series fills whenever the status is polled, which is
            // always — including while the SSH half is refused or dead.
            model.frequency = MetricSeries(Self.previewWave(around: 49.6, spread: 0.5, step: 0.7))
            // The other three fill only while sampling, so a model that is not
            // sampling has none. That is what the screen shows the moment SSH drops:
            // the loop keeps drawing and the operating system's rows go.
            guard phase == .sampling else { return model }
            let centre = system.cpuTemperatureCelsius ?? 48.5
            model.cpu = MetricSeries(Self.previewWave(around: system.cpuPercent ?? 24, spread: 13, step: 0.31))
            model.memory = MetricSeries(Self.previewWave(around: system.memoryPercent ?? 22.5, spread: 1.4, step: 0.11))
            model.temperature = MetricSeries(Self.previewWave(around: centre, spread: 2.6, step: 0.19))
            return model
        }

        /// Deterministic on purpose, and not merely because `Math.random` would be:
        /// two sine waves at an irrational ratio look like a measurement and repeat
        /// byte for byte, which is exactly what a reference image needs.
        private static func previewWave(around centre: Double, spread: Double, step: Double) -> [Double] {
            (0 ..< MetricSeries.capacity).map { index in
                let t = Double(index) * step
                return centre + spread * (sin(t) * 0.7 + sin(t * 1.618) * 0.3)
            }
        }
    }

    extension LinuxSystemSnapshot {
        /// A real Reachy Mini Wireless, idling: these totals, this load and this
        /// temperature are what one answered over SSH rather than invented.
        ///
        /// **It is a 4 GB machine.** The fixture said 8 until the robot was asked,
        /// and a preview depicting hardware the product does not ship misleads about
        /// the one thing this row exists to convey — how much headroom is left.
        static let previewHealthy = LinuxSystemSnapshot(
            cpuPercent: 21.4,
            loadAverage1m: 0.88,
            memoryTotalBytes: 3_887_788 * 1024,
            memoryAvailableBytes: 3_347_440 * 1024,
            cpuTemperatureCelsius: 46.7,
            uptime: .seconds(97412)
        )

        /// The same robot with a job on it — the state a reader opens this screen to
        /// diagnose, and the one the colour thresholds have to be right for.
        static let previewLoaded = LinuxSystemSnapshot(
            cpuPercent: 91.7,
            loadAverage1m: 4.31,
            memoryTotalBytes: 3_887_788 * 1024,
            memoryAvailableBytes: 331_604 * 1024,
            cpuTemperatureCelsius: 79.4,
            uptime: .seconds(412)
        )
    }
#endif
