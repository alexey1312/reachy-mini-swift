import Foundation

/// One reading of the robot's own operating system, taken from `/proc` and `/sys`.
///
/// Every field is optional and independently so: a robot with no readable thermal
/// zone still reports its memory, and the very first reading of a session has no
/// CPU figure because a percentage is a delta between two samples and one sample is
/// not a delta.
public struct LinuxSystemSnapshot: Sendable, Equatable {
    /// Busy time as a share of wall time since the previous reading, 0–100.
    public var cpuPercent: Double?
    /// Runnable-plus-uninterruptible processes averaged over a minute. Unlike
    /// ``cpuPercent`` this is not a percentage and is not bounded by the core
    /// count — 4.0 on a four-core Pi means saturated, 8.0 means a queue.
    public var loadAverage1m: Double?
    public var memoryTotalBytes: UInt64?
    /// What a new process could actually get, which is not `total - free`: Linux
    /// spends every spare page on cache and hands it back on demand. `MemFree` on a
    /// healthy machine is alarmingly small and means nothing.
    public var memoryAvailableBytes: UInt64?
    public var cpuTemperatureCelsius: Double?
    public var uptime: Duration?

    public init(
        cpuPercent: Double? = nil,
        loadAverage1m: Double? = nil,
        memoryTotalBytes: UInt64? = nil,
        memoryAvailableBytes: UInt64? = nil,
        cpuTemperatureCelsius: Double? = nil,
        uptime: Duration? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.loadAverage1m = loadAverage1m
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.uptime = uptime
    }

    public var memoryUsedBytes: UInt64? {
        guard let memoryTotalBytes, let memoryAvailableBytes else { return nil }
        return memoryTotalBytes - min(memoryAvailableBytes, memoryTotalBytes)
    }

    /// 0–100, or nil when either half is missing.
    public var memoryPercent: Double? {
        guard let memoryTotalBytes, memoryTotalBytes > 0, let used = memoryUsedBytes else { return nil }
        return Double(used) / Double(memoryTotalBytes) * 100
    }

    /// Whether this reading found anything at all. A snapshot of six nils is what a
    /// robot answers when every path was unreadable, and showing it as a panel of
    /// em dashes would claim a working connection that is doing nothing.
    public var isEmpty: Bool {
        self == LinuxSystemSnapshot()
    }
}

/// Parsing the handful of kernel files this package reads.
///
/// Free functions over strings, deliberately: the formats below are stable kernel
/// ABI and every one of their edge cases can be pinned with a fixture, which is
/// worth far more than exercising them through a socket.
enum LinuxProc {
    /// The aggregate `cpu` line of `/proc/stat`, in USER_HZ ticks since boot.
    struct CPUSample: Sendable, Equatable {
        var idle: UInt64
        var total: UInt64
    }

    /// Reads the leading `cpu ` line, which sums every core.
    ///
    /// Only the first eight counters are added. The ninth and tenth — `guest` and
    /// `guest_nice` — are already included in `user` and `nice`, so a naive sum of
    /// the whole line double-counts them and understates the busy share on any
    /// machine running a VM.
    static func cpuSample(_ text: String) -> CPUSample? {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix("cpu ") || $0 == "cpu" })
        else { return nil }
        let counters = line.split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst()
            .prefix(8)
            .compactMap { UInt64($0) }
        // user, nice, system, idle — the shortest line worth trusting.
        guard counters.count >= 4 else { return nil }
        // `iowait` is idle: the core had nothing to run. Counting it as busy is the
        // classic way to report 90% CPU on a machine that is only waiting on a disk.
        let idle = counters[3] + (counters.count > 4 ? counters[4] : 0)
        return CPUSample(idle: idle, total: counters.reduce(0, +))
    }

    /// Busy share between two samples, 0–100.
    ///
    /// Nil when the counters did not advance (two readings inside one tick) or went
    /// backwards (the robot rebooted between them, which resets every counter to
    /// zero and would otherwise underflow).
    static func cpuPercent(from previous: CPUSample, to current: CPUSample) -> Double? {
        guard current.total > previous.total, current.idle >= previous.idle else { return nil }
        let elapsed = Double(current.total - previous.total)
        let idle = Double(current.idle - previous.idle)
        return min(100, max(0, (elapsed - idle) / elapsed * 100))
    }

    /// `MemTotal` and `MemAvailable` from `/proc/meminfo`, in bytes.
    ///
    /// The file's unit is `kB` but means KiB — a kernel misnomer old enough that
    /// fixing it would break every parser in the world, this one included.
    static func memory(_ text: String) -> (total: UInt64, available: UInt64)? {
        var total: UInt64?
        var available: UInt64?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let value = UInt64(fields[1]) else { continue }
            switch fields[0] {
            case "MemTotal:": total = value * 1024
            case "MemAvailable:": available = value * 1024
            default: continue
            }
            if total != nil, available != nil {
                break
            }
        }
        guard let total, let available else { return nil }
        return (total, available)
    }

    /// The one-minute figure, the first of the three in `/proc/loadavg`.
    static func loadAverage1m(_ text: String) -> Double? {
        text.split(separator: " ", omittingEmptySubsequences: true).first.flatMap { Double($0) }
    }

    /// The first field of `/proc/uptime`, seconds since boot with the second field
    /// being idle time across all cores — which is not what anyone means by uptime.
    static func uptime(_ text: String) -> Duration? {
        guard let seconds = text.split(separator: " ", omittingEmptySubsequences: true)
            .first.flatMap({ Double($0) }), seconds >= 0
        else { return nil }
        return .seconds(seconds)
    }

    /// A thermal zone's `temp`, which the kernel reports in thousandths of a degree.
    ///
    /// Bounded because an unpopulated zone reports `0` and a disconnected sensor can
    /// report a large negative number, and a panel saying `-273 °C` is worse than
    /// one saying nothing.
    static func celsius(milliCelsius text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let celsius = value / 1000
        return (1 ... 150).contains(celsius) ? celsius : nil
    }
}
