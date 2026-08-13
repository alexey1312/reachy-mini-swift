import Foundation
import ReachyKit
import ReachySSH
@testable import ReachyUI
import Testing

@MainActor
@Suite("Robot health", .timeLimit(.minutes(1)))
struct RobotHealthModelTests {
    /// Remembers what it was asked to forget, which is the assertion the refused-
    /// password case needs and `EphemeralCredentialStore` cannot make.
    private final class RecordingCredentialStore: SSHCredentialStore, @unchecked Sendable {
        var stored: SSHCredentials?
        private(set) var cleared: [String] = []

        init(stored: SSHCredentials? = nil) {
            self.stored = stored
        }

        func credentials(forRobot _: String) throws -> SSHCredentials? {
            stored
        }

        func save(_ credentials: SSHCredentials, forRobot _: String) throws {
            stored = credentials
        }

        func clear(robot: String) throws {
            cleared.append(robot)
            stored = nil
        }
    }

    private static let procfs: [String: Data] = [
        "/proc/stat": Data("cpu  25438 129 12971 1893516 1122 0 233 0 0 0\n".utf8),
        "/proc/meminfo": Data("MemTotal: 8244316 kB\nMemAvailable: 6389211 kB\n".utf8),
        "/proc/loadavg": Data("0.42 0.41 0.38 2/312 4711\n".utf8),
        "/proc/uptime": Data("97412.10 51988.44\n".utf8),
        "/sys/class/thermal/thermal_zone0/type": Data("cpu-thermal\n".utf8),
        "/sys/class/thermal/thermal_zone0/temp": Data("48600\n".utf8),
    ]

    private func model(
        _ files: (any RobotFileSystem)?,
        credentials: any SSHCredentialStore = RecordingCredentialStore(
            stored: SSHCredentials(host: "", username: "pollen", password: "root")
        )
    ) -> RobotHealthModel {
        RobotHealthModel(
            files: files,
            credentials: credentials,
            robot: "unit-test",
            host: "reachy-mini.local",
            interval: .milliseconds(1)
        )
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    // MARK: - The daemon's half

    /// The daemon half must survive without the SSH half, because over the relay
    /// that is the only half there is.
    @Test("records the control loop with no file system at all")
    func recordsLoopWithoutSSH() {
        let model = model(nil)

        model.record(loop: ControlLoopStats(frequencyHz: 99.4))

        #expect(model.phase == .unavailable)
        #expect(model.loop?.frequencyHz == 99.4)
        #expect(model.frequency.latest == 99.4)
    }

    /// The daemon writes its dictionary key by key, so a missing frequency means
    /// "not measured yet". Recording it as zero draws a line plunging to the floor,
    /// which reads as a robot that stalled.
    @Test("skips a reading with no frequency in it rather than recording a zero")
    func skipsAbsentFrequency() {
        let model = model(nil)

        model.record(loop: ControlLoopStats(frequencyHz: 99.4))
        model.record(loop: ControlLoopStats(motorController: "FeetechController"))
        model.record(loop: nil)

        #expect(model.frequency.values == [99.4])
        #expect(model.loop == nil)
    }

    @Test("keeps the series bounded")
    func boundsTheSeries() {
        let model = model(nil)

        for index in 0 ..< (MetricSeries.capacity * 2) {
            model.record(loop: ControlLoopStats(frequencyHz: Double(index)))
        }

        #expect(model.frequency.values.count == MetricSeries.capacity)
        #expect(model.frequency.latest == Double(MetricSeries.capacity * 2 - 1))
        // The window slid rather than stopped: the oldest reading is gone.
        #expect(model.frequency.values.first == Double(MetricSeries.capacity))
    }

    // MARK: - Reaching the operating system

    /// A relayed session has no TCP route to port 22 (ADR 0003). Offering a sign-in
    /// there would be offering something that cannot connect.
    @Test("offers nothing over a relay, and opens no socket looking")
    func relaySessionIsUnavailable() async {
        let model = model(nil)

        await model.start()

        #expect(model.phase == .unavailable)
    }

    /// A health panel that raises a password field the moment the tab opens has
    /// turned a passive reading into a demand.
    @Test("settles on needing a password without asking the network anything")
    func neverPromptsOnItsOwn() async {
        let files = PreviewFileSystem(contents: Self.procfs)
        let model = model(files, credentials: RecordingCredentialStore())

        await model.start()

        #expect(model.phase == .needsPassword)
        #expect(files.calls.isEmpty)
    }

    @Test("connects with a stored password and starts filling the series")
    func samplesWithAStoredPassword() async {
        let files = PreviewFileSystem(contents: Self.procfs)
        let model = model(files)

        await model.start()
        await settle { model.temperature.isDrawable }

        #expect(model.phase == .sampling)
        #expect(model.system.memoryTotalBytes == 8_244_316 * 1024)
        #expect(model.system.cpuTemperatureCelsius == 48.6)
        #expect(model.temperature.latest == 48.6)
        // A fixture whose `/proc/stat` never changes is a machine whose counters
        // never advance, and a busy share between two identical samples is not a
        // share. Recording a zero there would draw an idle processor.
        #expect(model.cpu.values.isEmpty)

        // 100 ticks pass, 75 of them idle.
        try? await files.write(
            Data("cpu  25463 129 12971 1893566 1147 0 233 0 0 0\n".utf8),
            to: "/proc/stat"
        )
        await settle { model.cpu.latest != nil }

        let percent = model.cpu.latest
        #expect(percent.map { abs($0 - 25) < 0.001 } == true)
        await model.stop()
    }

    /// Keeping a password the robot has already refused means the next visit fails
    /// the same way, in silence — and `.needsPassword` is a row offering the sheet
    /// again, so the refusal has nowhere to be read but `lastError`. Without it the
    /// whole answer to a mistyped password is a field that emptied itself.
    @Test("forgets a refused password, says so, and goes back to asking")
    func forgetsARefusedPassword() async {
        let store = RecordingCredentialStore(
            stored: SSHCredentials(host: "", username: "pollen", password: "wrong")
        )
        let model = model(PreviewFileSystem(failure: .authenticationFailed), credentials: store)

        await model.start()

        #expect(model.phase == .needsPassword)
        #expect(model.password.isEmpty)
        #expect(store.cleared == ["unit-test"])
        #expect(model.lastError != nil)
    }

    /// A sign-in that succeeds must not leave the previous attempt's refusal under
    /// the field — `connect()` clears the slot on the way in, before it knows how
    /// this attempt ends.
    @Test("carries no refusal into a session that connected")
    func clearsTheRefusalOnConnect() async {
        let model = model(PreviewFileSystem(contents: Self.procfs))

        await model.start()

        #expect(model.phase == .sampling)
        #expect(model.lastError == nil)
        await model.stop()
    }

    @Test("stops at the fingerprint on first contact instead of pinning it")
    func stopsAtAnUnknownHostKey() async {
        guard let fingerprint = HostKeyFingerprint(
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJhX0bF0uV3M1jHkKcvbJ1v0Vt0ZL2W0GxKQOgPqRsTu"
        ) else {
            Issue.record("the test's own key literal did not parse")
            return
        }
        let model = model(PreviewFileSystem(failure: .hostKeyUnknown(fingerprint)))

        await model.start()

        #expect(model.phase == .confirmHostKey(fingerprint))
    }

    /// A `.task` re-firing must not step over a fingerprint nobody has answered.
    @Test("a second start leaves a pending key confirmation alone")
    func secondStartKeepsThePendingKey() async {
        guard let fingerprint = HostKeyFingerprint(
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJhX0bF0uV3M1jHkKcvbJ1v0Vt0ZL2W0GxKQOgPqRsTu"
        ) else {
            Issue.record("the test's own key literal did not parse")
            return
        }
        let files = PreviewFileSystem(failure: .hostKeyUnknown(fingerprint))
        let model = model(files)

        await model.start()
        let afterFirst = files.calls.count
        await model.start()

        #expect(model.phase == .confirmHostKey(fingerprint))
        #expect(files.calls.count == afterFirst)
    }

    /// A robot that cannot be read is not a robot with a broken control loop. The
    /// two halves fail independently, and the daemon's has to survive the other's.
    @Test("a dead SSH session leaves the daemon's readings on screen")
    func sshFailureKeepsTheLoopReadings() async {
        let model = model(PreviewFileSystem(failure: .transport("connection reset")))

        model.record(loop: ControlLoopStats(frequencyHz: 99.4))
        await model.start()

        #expect(model.loop?.frequencyHz == 99.4)
        #expect(model.frequency.latest == 99.4)
        guard case .failed = model.phase else {
            Issue.record("expected a failed phase, got \(model.phase)")
            return
        }
    }
}

@MainActor
@Suite("Health thresholds")
struct HealthLevelTests {
    @Test("a busy processor is not a processor in trouble")
    func cpuThresholds() {
        #expect(HealthLevel.cpu(24) == .normal)
        #expect(HealthLevel.cpu(74.9) == .normal)
        #expect(HealthLevel.cpu(80) == .elevated)
        #expect(HealthLevel.cpu(99) == .critical)
    }

    @Test("memory pressure turns before it runs out")
    func memoryThresholds() {
        #expect(HealthLevel.memory(22) == .normal)
        #expect(HealthLevel.memory(82) == .elevated)
        #expect(HealthLevel.memory(95) == .critical)
    }

    /// The Raspberry Pi 5 soft-throttles at 80 °C, so `elevated` has to arrive
    /// before that rather than after — the warning is only useful while there is
    /// still something to do about it.
    @Test("temperature warns before the board starts throttling")
    func temperatureThresholds() {
        #expect(HealthLevel.temperature(48.6) == .normal)
        #expect(HealthLevel.temperature(69.9) == .normal)
        #expect(HealthLevel.temperature(72) == .elevated)
        #expect(HealthLevel.temperature(79.9) == .elevated)
        #expect(HealthLevel.temperature(81) == .critical)
    }

    /// **49.59 Hz is what a real Reachy Mini Wireless reports, and it is healthy.**
    /// The nominal was 100 for a while, which scored it 0.496 and painted the row
    /// red on a robot with nothing wrong with it. The daemon hard-codes 50.
    @Test("the control loop is judged against the rate the daemon actually targets")
    func frequencyThresholds() {
        #expect(HealthLevel.frequency(49.59) == .normal)
        #expect(HealthLevel.frequency(40) == .elevated)
        #expect(HealthLevel.frequency(15) == .critical)
        #expect(HealthLevel.frequency(90, nominal: 100) == .normal)
        // A nominal of zero would divide by it.
        #expect(HealthLevel.frequency(49.59, nominal: 0) == .normal)
    }

    /// A relay session legitimately answers slower than a LAN one, so the bands are
    /// wide enough that reaching a robot from outside its network is amber rather
    /// than red. They are a starting point measured against nothing yet — like every
    /// feel constant in the teleop path, only a robot settles them.
    @Test("round trip bands leave room for a session that is not on this network")
    func roundTripThresholds() {
        #expect(HealthLevel.roundTrip(.milliseconds(8)) == .normal)
        #expect(HealthLevel.roundTrip(.milliseconds(149)) == .normal)
        #expect(HealthLevel.roundTrip(.milliseconds(150)) == .elevated)
        #expect(HealthLevel.roundTrip(.milliseconds(499)) == .elevated)
        #expect(HealthLevel.roundTrip(.milliseconds(500)) == .critical)
        #expect(HealthLevel.roundTrip(.seconds(2)) == .critical)
    }

    /// **The conversion is the part that can be wrong.** A `Duration` truncated to
    /// its whole-second component reads every round trip a robot on a local network
    /// answers with as zero, and the chip would print `0 ms` forever.
    /// The precision differs from the loop interval's on purpose: a network figure
    /// varies by whole milliseconds, so a tenth of one changes without meaning.
    @Test("a sub-second round trip does not truncate to nothing")
    func roundTripFormatting() {
        #expect(HealthFormat.milliseconds(Duration.milliseconds(8)).contains("8"))
        #expect(!HealthFormat.milliseconds(Duration.milliseconds(8)).hasPrefix("0"))
        #expect(HealthFormat.milliseconds(Duration.milliseconds(12)) == "12 ms")
    }

    /// The floor is what keeps a robot that was already degraded when the screen
    /// opened from being judged against its own worst rate — its best would be its
    /// worst, and everything would read normal.
    @Test("the nominal rate calibrates upward from what was seen, never downward")
    func nominalCalibration() {
        #expect(HealthMetric.nominalFrequency(observed: nil) == 50)
        #expect(HealthMetric.nominalFrequency(observed: 30) == 50)
        #expect(HealthMetric.nominalFrequency(observed: 99.8) == 99.8)
        // A robot stuck at 30 Hz since the screen opened is still reported as stuck:
        // 30 against the floor of 50 is 0.6, under the 0.7 the `critical` step sits at.
        #expect(HealthLevel.frequency(30, nominal: HealthMetric.nominalFrequency(observed: 30)) == .critical)
    }
}
