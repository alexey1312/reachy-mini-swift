import Foundation

/// A bounded window of one measurement, for a sparkline to draw.
///
/// Two readings of the same robot arrive on different clocks — the daemon's status
/// is polled every three seconds and the system metrics every five — so a series is
/// indexed by sample rather than by time. That is honest for a sparkline, whose
/// whole claim is "the shape of the recent past", and would not be for anything
/// with an axis on it.
struct MetricSeries: Equatable, Sendable {
    /// Three minutes of daemon polls, five of system samples. Long enough that a
    /// slow drift is visible and short enough that a spike has not scrolled off
    /// before anyone looks.
    static let capacity = 60

    private(set) var values: [Double] = []

    init(_ values: [Double] = []) {
        self.values = Array(values.suffix(Self.capacity))
    }

    /// A nil reading is skipped rather than recorded as zero. The daemon writes its
    /// dictionary key by key, so a missing frequency means "not measured yet" — and
    /// a zero drawn for it is a line plunging to the floor and back, which reads as
    /// a robot that stalled.
    mutating func append(_ value: Double?) {
        guard let value, value.isFinite else { return }
        values.append(value)
        if values.count > Self.capacity {
            values.removeFirst(values.count - Self.capacity)
        }
    }

    var latest: Double? {
        values.last
    }

    /// A sparkline needs at least a segment. One point is a dot that says nothing
    /// the row above it does not already say in words.
    var isDrawable: Bool {
        values.count >= 2
    }
}
