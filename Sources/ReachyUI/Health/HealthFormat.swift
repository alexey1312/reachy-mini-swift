import Foundation
import ReachyDesign
import ReachySSH

/// Rendering the robot's vital signs as text.
///
/// Its own type because two screens spell the same numbers: the Robot tab shows
/// the loop rate beside the link to the detail, and the detail shows it again at
/// the top. Two copies of a formatter is two answers to "how fast is the loop"
/// that can disagree by a decimal place.
///
/// `Measurement` throughout rather than hand-built strings — it puts the number
/// and its unit in the reader's own locale, decimal separator included.
enum HealthFormat {
    static func hertz(_ value: Double) -> String {
        Measurement(value: value, unit: UnitFrequency.hertz)
            .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(1))
            ))
    }

    /// **`usage: .asProvided`, so this stays Celsius everywhere.** The default
    /// converts to the locale's unit, which would print °F in the United States —
    /// and every threshold the colour beside it encodes is a Celsius figure off the
    /// Raspberry Pi's datasheet. A number and its colour disagreeing about units is
    /// worse than a number in a unit the reader converts themselves.
    static func celsius(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(1))
            ))
    }

    /// Whole degrees: the sensor's own noise is larger than a tenth, so a decimal
    /// here would be a digit that never settles.
    static func degrees(_ value: Double) -> String {
        Measurement(value: value.rounded(), unit: UnitAngle.degrees)
            .formatted(.measurement(
                width: .narrow,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            ))
    }

    /// Seconds on the wire, milliseconds on screen: a loop interval is 0.0184 s,
    /// and a reader counting decimal places is a reader doing the formatter's job.
    static func milliseconds(_ seconds: Double) -> String {
        Measurement(value: seconds * 1000, unit: UnitDuration.milliseconds)
            .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(1))
            ))
    }

    /// A round trip, which is a different quantity from the loop interval above and
    /// so carries a different precision: a network figure varies by whole
    /// milliseconds, and a tenth of one is a digit that changes without meaning.
    ///
    /// The attoseconds are not optional — every round trip worth printing is under a
    /// second, so `components.seconds` alone rounds all of them to zero.
    static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        return Measurement(value: seconds * 1000, unit: UnitDuration.milliseconds)
            .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            ))
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The share and the absolute together, because neither alone is actionable:
    /// 78% of an unknown total says nothing, and 1.8 GB used says nothing either.
    static func memory(_ system: LinuxSystemSnapshot) -> String? {
        guard let share = system.memoryPercent,
              let used = system.memoryUsedBytes,
              let total = system.memoryTotalBytes
        else { return nil }
        let usedText = Int64(used).formatted(.byteCount(style: .memory))
        let totalText = Int64(total).formatted(.byteCount(style: .memory))
        return String(localized: .reachy("\(percent(share)) · \(usedText) of \(totalText)"))
    }

    static func loadAverage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func uptime(_ uptime: Duration) -> String {
        uptime.formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}
