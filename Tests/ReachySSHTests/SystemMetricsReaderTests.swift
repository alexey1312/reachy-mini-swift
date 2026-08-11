import Foundation
@testable import ReachySSH
import Testing

@Suite("System metrics reader")
struct SystemMetricsReaderTests {
    private static let meminfo = """
    MemTotal:        8244316 kB
    MemFree:         6329848 kB
    MemAvailable:    7715384 kB
    """

    /// A Pi 5 as the robot ships it: the processor's zone is the first one.
    private static func pi(
        stat: String = "cpu  25438 129 12971 1893516 1122 0 233 0 0 0\n",
        thermalZones: [Int: String] = [0: "cpu-thermal"],
        temperature: String = "47238\n",
        omitting: Set<String> = []
    ) -> PreviewFileSystem {
        var contents: [String: Data] = [
            "/proc/stat": Data(stat.utf8),
            "/proc/meminfo": Data(meminfo.utf8),
            "/proc/loadavg": Data("0.32 0.41 0.38 2/312 4711\n".utf8),
            "/proc/uptime": Data("13594.21 51988.44\n".utf8),
        ]
        for (zone, type) in thermalZones {
            contents["/sys/class/thermal/thermal_zone\(zone)/type"] = Data("\(type)\n".utf8)
            contents["/sys/class/thermal/thermal_zone\(zone)/temp"] = Data(temperature.utf8)
        }
        for path in omitting {
            contents[path] = nil
        }
        return PreviewFileSystem(contents: contents)
    }

    /// A percentage is a delta between two readings of a monotonic counter, so the
    /// first one cannot carry it. The alternative — busy-since-boot — is a number
    /// that stops moving after an hour of uptime.
    @Test("leaves CPU empty on the first sample and fills it on the second")
    func cpuNeedsTwoSamples() async throws {
        let files = Self.pi()
        let reader = SystemMetricsReader(files: files)

        let first = try await reader.sample()
        #expect(first.cpuPercent == nil)
        #expect(first.memoryTotalBytes == 8_244_316 * 1024)

        // 100 ticks pass, 75 of them idle.
        try await files.write(
            Data("cpu  25463 129 12971 1893566 1147 0 233 0 0 0\n".utf8),
            to: "/proc/stat"
        )
        let second = try await reader.sample()
        let percent = try #require(second.cpuPercent)
        #expect(abs(percent - 25) < 0.001)
    }

    @Test("reads the rest of the vital signs")
    func readsEverythingElse() async throws {
        let reader = SystemMetricsReader(files: Self.pi())

        let snapshot = try await reader.sample()

        #expect(snapshot.loadAverage1m == 0.32)
        #expect(snapshot.uptime == .seconds(13594.21))
        #expect(snapshot.cpuTemperatureCelsius == 47.238)
        #expect(snapshot.memoryAvailableBytes == 7_715_384 * 1024)
        #expect(!snapshot.isEmpty)
    }

    /// Zone numbering follows device tree order, not meaning. The Pi 5 happens to
    /// put the processor first; a board with a PMIC or disk sensor ahead of it does
    /// not, and reading zone 0 blindly would report that sensor's temperature as
    /// the CPU's.
    @Test("finds the processor's zone by its type rather than by its index")
    func findsThermalZoneByType() async throws {
        let files = Self.pi(
            thermalZones: [0: "pmic-thermal", 1: "disk-thermal", 2: "cpu-thermal"],
            temperature: "51500\n"
        )
        let reader = SystemMetricsReader(files: files)

        let snapshot = try await reader.sample()

        #expect(snapshot.cpuTemperatureCelsius == 51.5)
        #expect(files.calls.contains("readPseudoFile(/sys/class/thermal/thermal_zone2/temp)"))
    }

    /// The scan costs up to ten round trips. Paying it once per session is fine;
    /// paying it every five seconds for the life of the screen is not.
    @Test("scans for the thermal zone once, not on every sample")
    func scansForThermalZoneOnce() async throws {
        let files = Self.pi(thermalZones: [0: "pmic-thermal", 1: "cpu-thermal"])
        let reader = SystemMetricsReader(files: files)

        _ = try await reader.sample()
        let afterFirst = files.calls.filter { $0.hasSuffix("/type)") }.count
        _ = try await reader.sample()
        let afterSecond = files.calls.filter { $0.hasSuffix("/type)") }.count

        #expect(afterFirst == 2)
        #expect(afterSecond == 2)
    }

    /// A robot exposing no CPU zone at all still has memory and load worth showing.
    /// Failing the whole sample over one unreadable file would blank the panel.
    @Test("reports everything else when there is no readable thermal zone")
    func survivesMissingThermalZone() async throws {
        let reader = SystemMetricsReader(files: Self.pi(thermalZones: [:]))

        let snapshot = try await reader.sample()

        #expect(snapshot.cpuTemperatureCelsius == nil)
        #expect(snapshot.memoryTotalBytes != nil)
        #expect(snapshot.loadAverage1m == 0.32)
    }

    @Test("reports everything else when meminfo is unreadable")
    func survivesMissingMeminfo() async throws {
        let reader = SystemMetricsReader(files: Self.pi(omitting: ["/proc/meminfo"]))

        let snapshot = try await reader.sample()

        #expect(snapshot.memoryTotalBytes == nil)
        #expect(snapshot.memoryPercent == nil)
        #expect(snapshot.loadAverage1m == 0.32)
    }

    /// On Linux `/proc/stat` is not a file that can go missing. Failing to read it
    /// means the session is gone, and that is worth propagating rather than
    /// answering with a snapshot of nils that looks like a working connection.
    @Test("throws when /proc/stat cannot be read at all")
    func throwsWhenStatUnreadable() async throws {
        let reader = SystemMetricsReader(files: Self.pi(omitting: ["/proc/stat"]))

        await #expect(throws: ReachySSHError.self) {
            try await reader.sample()
        }
    }

    @Test("an untouched snapshot reports itself empty")
    func emptySnapshotSaysSo() {
        #expect(LinuxSystemSnapshot().isEmpty)
        #expect(!LinuxSystemSnapshot(loadAverage1m: 0.1).isEmpty)
    }
}
