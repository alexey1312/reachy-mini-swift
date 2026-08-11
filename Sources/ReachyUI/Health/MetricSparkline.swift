import Charts
import ReachyDesign
import SwiftUI

/// The recent shape of one measurement: a line, and nothing else.
///
/// Swift Charts rather than a hand-drawn `Path`, and rather than a dependency —
/// it ships with the OS well below this project's iOS 18 / macOS 15 floor, and it
/// brings the things a hand-rolled sparkline gets wrong: it clips to the plot area
/// on its own, it respects the accessibility text sizes, and it renders the same
/// in both appearances without a colour being pinned anywhere.
struct MetricSparkline: View {
    let series: MetricSeries
    /// Fixed, never fitted to the data. See `HealthMetric`.
    let domain: ClosedRange<Double>
    let tone: Tone

    /// On the component rather than on the token, which is the rule for every
    /// `Metrics` constant: at the default text size the multiplier is 1, so adopting
    /// it moves no reference image.
    @ScaledMetric private var height = Metrics.sparklineHeight

    var body: some View {
        Chart(Array(series.values.enumerated()), id: \.offset) { sample in
            // The fill is what makes this readable as a level rather than as a rule.
            // Against a fixed domain the line's *height* is the whole message, and a
            // bare 1.5 pt stroke pinned near the top of its frame — which is where a
            // healthy 99.4 Hz loop sits on a 0…110 scale — is indistinguishable from
            // an underline of the row above, with the rest of the frame reading as
            // dead space. Filled, the same row reads as nine tenths full.
            AreaMark(
                x: .value("sample", sample.offset),
                y: .value("value", sample.element)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tone.style.opacity(0.16))
            LineMark(
                // Not user-facing: both axes are hidden and the chart is hidden from
                // VoiceOver, which reads the row above instead. Identifiers, which
                // project rule 9 exempts.
                x: .value("sample", sample.offset),
                y: .value("value", sample.element)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .foregroundStyle(tone.style)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .frame(height: height)
        // The row above states the current value in words, so voicing sixty data
        // points here would be the same fact at sixty times the length.
        .accessibilityHidden(true)
    }
}

/// One reading: its name, its number, and its recent shape underneath.
///
/// A `LabeledContent` and a chart in one `VStack` rather than two rows, so the
/// line belongs visibly to the number it explains.
struct MetricRow: View {
    let title: LocalizedStringResource
    let value: String?
    let series: MetricSeries
    let domain: ClosedRange<Double>
    let level: HealthLevel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            LabeledContent(title) {
                Text(value ?? "—")
                    .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : level.tone.style)
                    .monospacedDigit()
            }
            if series.isDrawable {
                MetricSparkline(series: series, domain: domain, tone: level.tone)
            }
        }
    }
}
