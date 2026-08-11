import Foundation

/// Samples a Linux machine's vital signs over an already-open file system.
///
/// The daemon publishes none of this — its OpenAPI surface has no route carrying
/// processor, memory or temperature, and `psutil` is installed on the robot only to
/// manage processes. Reading the kernel's own files is the whole of the mechanism,
/// and it stays reads: no `exec`, in keeping with what this package deliberately
/// does not do.
///
/// An `actor` because it carries state between calls — the previous `/proc/stat`
/// counters, without which there is no CPU percentage — and callers sample it from
/// a timer.
///
/// **Both of the assumptions here were checked against a real Reachy Mini
/// Wireless**, because neither the unit tests nor `sim-daemon` can: the tests stub
/// the file system and the simulator is a Mac with no `/proc` to read.
///
/// - Procfs really does report `size=0` (`/proc/meminfo`, `/proc/stat`,
///   `/proc/uptime`), and an SFTP transfer of `/proc/meminfo` really does return
///   1149 bytes anyway. The size-blind read is necessary and sufficient.
/// - The robot has exactly one thermal zone and it is `thermal_zone0` → type
///   `cpu-thermal`, reading 46738. So the scan below matches on its first attempt;
///   it exists for boards that order their zones differently, not for this one.
public actor SystemMetricsReader {
    private let files: any RobotFileSystem
    private var previousCPU: LinuxProc.CPUSample?
    /// Three-valued on purpose: unset means "not looked for yet", `.some(nil)` means
    /// "looked, this machine has no CPU zone" — which stops the scan below from
    /// running its ten reads again on every sample.
    private var thermalPath: String??

    public init(files: any RobotFileSystem) {
        self.files = files
    }

    /// One reading.
    ///
    /// Throws only when `/proc/stat` is unreachable, which on Linux means the
    /// session is gone rather than that the file is missing. Everything else
    /// degrades to a nil field: a robot whose thermal zone cannot be read still
    /// reports its memory, and saying so is more useful than failing the sample.
    ///
    /// The first call of a session never carries ``LinuxSystemSnapshot/cpuPercent``.
    /// A percentage is the delta between two samples of a monotonic counter, and one
    /// sample is not a delta — the alternative, "busy since boot", is a number that
    /// stops moving after an hour of uptime and tells nobody anything.
    public func sample() async throws -> LinuxSystemSnapshot {
        var snapshot = LinuxSystemSnapshot()

        let current = try await LinuxProc.cpuSample(files.readPseudoFile("/proc/stat"))
        if let current {
            if let previousCPU {
                snapshot.cpuPercent = LinuxProc.cpuPercent(from: previousCPU, to: current)
            }
            // Stored even when the delta came back nil — a reboot resets the
            // counters, and the reading after it is the one that works again.
            previousCPU = current
        }

        if let text = try? await files.readPseudoFile("/proc/meminfo"),
           let memory = LinuxProc.memory(text)
        {
            snapshot.memoryTotalBytes = memory.total
            snapshot.memoryAvailableBytes = memory.available
        }
        if let text = try? await files.readPseudoFile("/proc/loadavg") {
            snapshot.loadAverage1m = LinuxProc.loadAverage1m(text)
        }
        if let text = try? await files.readPseudoFile("/proc/uptime") {
            snapshot.uptime = LinuxProc.uptime(text)
        }
        if let path = await cpuThermalPath(), let text = try? await files.readPseudoFile(path) {
            snapshot.cpuTemperatureCelsius = LinuxProc.celsius(milliCelsius: text)
        }

        return snapshot
    }

    /// Finds the zone that measures the processor, once per reader.
    ///
    /// Zone numbering is not stable across boards — the Raspberry Pi 5 the robot
    /// runs on puts `cpu-thermal` at zone 0, but the index is assigned in device
    /// tree order and a board with a PMIC or a disk sensor ahead of it does not.
    /// So the `type` file decides, not the number.
    private func cpuThermalPath() async -> String? {
        if let thermalPath {
            return thermalPath
        }
        for zone in 0 ..< 10 {
            let base = "/sys/class/thermal/thermal_zone\(zone)"
            guard let type = try? await files.readPseudoFile("\(base)/type") else { continue }
            if type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("cpu") {
                thermalPath = .some("\(base)/temp")
                return "\(base)/temp"
            }
        }
        thermalPath = .some(nil)
        return nil
    }
}
