import Foundation
@testable import ReachySSH
import Testing

/// The fixtures are the real files as a Raspberry Pi 5 running the robot's Debian
/// writes them. These formats are stable kernel ABI, which is what makes pinning
/// them with strings worth more than reaching a live machine.
@Suite("Linux /proc parsing")
struct LinuxProcParsingTests {
    private let stat = """
    cpu  25438 129 12971 1893516 1122 0 233 0 0 0
    cpu0 6982 33 3428 472819 285 0 89 0 0 0
    cpu1 6104 31 3201 473688 279 0 51 0 0 0
    cpu2 6221 32 3175 473497 281 0 47 0 0 0
    cpu3 6131 33 3167 473512 277 0 46 0 0 0
    intr 12894471 0 0 0 0 0
    ctxt 24719302
    btime 1770000000
    """

    private let meminfo = """
    MemTotal:        8244316 kB
    MemFree:         6329848 kB
    MemAvailable:    7715384 kB
    Buffers:           58128 kB
    Cached:          1245392 kB
    SwapTotal:        204796 kB
    """

    // MARK: - /proc/stat

    @Test("sums the aggregate line, counting iowait as idle")
    func readsAggregateLine() throws {
        let sample = try #require(LinuxProc.cpuSample(stat))

        // idle 1893516 + iowait 1122. A core waiting on a disk is not a busy core,
        // and folding iowait into the busy side is the classic way to report 90%
        // CPU on a machine that is doing nothing but waiting.
        #expect(sample.idle == 1_894_638)
        #expect(sample.total == 25438 + 129 + 12971 + 1_893_516 + 1122 + 0 + 233 + 0)
    }

    /// `guest` and `guest_nice` are already counted inside `user` and `nice`, so a
    /// sum of the whole line double-counts them and understates the busy share.
    /// Only a machine running VMs has non-zero values there, which is exactly why
    /// this is easy to get wrong and never notice.
    @Test("ignores the guest counters, which are already inside user and nice")
    func ignoresGuestCounters() throws {
        let withGuests = "cpu  100 10 50 800 20 0 5 0 400 40\n"
        let sample = try #require(LinuxProc.cpuSample(withGuests))

        #expect(sample.total == 100 + 10 + 50 + 800 + 20 + 0 + 5 + 0)
    }

    @Test("computes the busy share between two samples")
    func computesBusyShare() {
        let before = LinuxProc.CPUSample(idle: 1000, total: 2000)
        let after = LinuxProc.CPUSample(idle: 1075, total: 2100)

        // 100 ticks elapsed, 75 of them idle.
        #expect(LinuxProc.cpuPercent(from: before, to: after) == 25)
    }

    @Test("answers nil when the counters have not advanced")
    func nilWhenCountersStand() {
        let sample = LinuxProc.CPUSample(idle: 1000, total: 2000)

        #expect(LinuxProc.cpuPercent(from: sample, to: sample) == nil)
    }

    /// A reboot between two samples resets every counter to zero. Subtracting
    /// unsigned integers the wrong way round traps at runtime, so this is a crash
    /// the moment a robot restarts while its panel is on screen.
    @Test("answers nil when the counters went backwards, which is a reboot")
    func nilAcrossReboot() {
        let before = LinuxProc.CPUSample(idle: 1_894_638, total: 1_933_409)
        let after = LinuxProc.CPUSample(idle: 412, total: 503)

        #expect(LinuxProc.cpuPercent(from: before, to: after) == nil)
    }

    @Test("answers nil for a file with no aggregate line")
    func nilWithoutAggregateLine() {
        #expect(LinuxProc.cpuSample("cpu0 1 2 3 4\nintr 5\n") == nil)
        #expect(LinuxProc.cpuSample("") == nil)
    }

    @Test("answers nil for a truncated aggregate line")
    func nilForTruncatedLine() {
        #expect(LinuxProc.cpuSample("cpu  100 10\n") == nil)
    }

    // MARK: - /proc/meminfo

    /// The file's unit says `kB` and means KiB — a kernel misnomer old enough that
    /// every parser in the world, this one included, has to reproduce it.
    @Test("reads MemTotal and MemAvailable, converting KiB to bytes")
    func readsMemory() throws {
        let memory = try #require(LinuxProc.memory(meminfo))

        #expect(memory.total == 8_244_316 * 1024)
        #expect(memory.available == 7_715_384 * 1024)
    }

    /// `MemFree` is the trap: Linux spends every spare page on cache and returns it
    /// on demand, so free is alarmingly small on a healthy machine and means
    /// nothing. Reading it instead of `MemAvailable` reports a robot at 77% memory
    /// pressure while it is idle.
    @Test("uses MemAvailable and not MemFree")
    func prefersAvailableOverFree() throws {
        let memory = try #require(LinuxProc.memory(meminfo))

        #expect(memory.available != 6_329_848 * 1024)
    }

    @Test("answers nil when MemAvailable is absent")
    func nilWithoutAvailable() {
        #expect(LinuxProc.memory("MemTotal: 8244316 kB\nMemFree: 6329848 kB\n") == nil)
    }

    @Test("derives used bytes and a percentage from the pair")
    func derivesUsage() throws {
        let memory = try #require(LinuxProc.memory(meminfo))
        let snapshot = LinuxSystemSnapshot(
            memoryTotalBytes: memory.total,
            memoryAvailableBytes: memory.available
        )

        #expect(snapshot.memoryUsedBytes == (8_244_316 - 7_715_384) * 1024)
        let percent = try #require(snapshot.memoryPercent)
        #expect(abs(percent - 6.42) < 0.01)
    }

    /// Available briefly exceeding total is possible mid-read, and unsigned
    /// subtraction traps rather than going negative.
    @Test("clamps used bytes when available exceeds total")
    func clampsInvertedMemory() {
        let snapshot = LinuxSystemSnapshot(memoryTotalBytes: 1000, memoryAvailableBytes: 1200)

        #expect(snapshot.memoryUsedBytes == 0)
        #expect(snapshot.memoryPercent == 0)
    }

    // MARK: - The one-liners

    @Test("reads the one-minute load average")
    func readsLoadAverage() {
        #expect(LinuxProc.loadAverage1m("0.32 0.41 0.38 2/312 4711\n") == 0.32)
        #expect(LinuxProc.loadAverage1m("") == nil)
    }

    @Test("reads uptime, ignoring the idle-time field beside it")
    func readsUptime() {
        #expect(LinuxProc.uptime("13594.21 51988.44\n") == .seconds(13594.21))
        #expect(LinuxProc.uptime("garbage\n") == nil)
    }

    @Test("converts thousandths of a degree")
    func readsTemperature() {
        #expect(LinuxProc.celsius(milliCelsius: "47238\n") == 47.238)
    }

    /// An unpopulated zone reports `0` and a disconnected sensor can report a large
    /// negative value. A panel reading `-273 °C` is worse than one reading nothing.
    @Test("rejects readings no processor could produce")
    func rejectsImpossibleTemperatures() {
        #expect(LinuxProc.celsius(milliCelsius: "0") == nil)
        #expect(LinuxProc.celsius(milliCelsius: "-274000") == nil)
        #expect(LinuxProc.celsius(milliCelsius: "999000") == nil)
        #expect(LinuxProc.celsius(milliCelsius: "not a number") == nil)
    }
}
