import ReachyDesign
import SwiftUI

/// The Controller screen's switch for `HeadphoneTeleop` (the AirPods spike).
///
/// Absent wherever the model reads `.unsupported`, which is every Mac, every simulator
/// and every capture that does not hand in a state of its own — so adopting it moved no
/// reference that predates it.
struct HeadTrackingSection: View {
    let model: HeadphoneTeleop

    var body: some View {
        if model.status != .unsupported {
            Section {
                Toggle(.reachy("Follow my head"), isOn: Binding(
                    get: { model.isOn },
                    set: { model.setOn($0) }
                ))
                status
            } header: {
                Text(.reachy("Head tracking"))
            } footer: {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "With AirPods or Beats that track your head, the robot turns its head as you turn yours. Look straight ahead when you switch it on."
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.status {
        case .waiting:
            Text(.reachy("Waiting for headphones that track your head."))
                .foregroundStyle(.secondary)
        case .following:
            // The one control the reader needs while following: their own "straight
            // ahead" drifts as they settle into a chair.
            Button(.reachy("Recentre")) { model.recentre() }
            if let reading = model.reading {
                HeadReadingRow(reading: reading, source: model.source)
            }
        case .denied:
            Text(.reachy("Motion & Fitness access is turned off"))
                .foregroundStyle(.secondary)
            PrivacySettingsButton(pane: .motion)
        case .off, .unsupported:
            EmptyView()
        }
    }
}

/// What the headphones report, in Core Motion's own three names and before the mapping.
///
/// A spike's instrument rather than a feature: the first device run showed that a nod
/// and a turn did not reach the robot while a tilt did, and Apple documents the
/// headphones' axes only in a picture. So the reader nods, turns and tilts and reads
/// which number moves, and the mapping's signs and axes follow from that.
struct HeadReadingRow: View {
    let reading: HeadAttitude
    let source: HeadphoneTeleop.Source?

    var body: some View {
        let yaw = degrees(reading.yaw)
        let pitch = degrees(reading.pitch)
        let roll = degrees(reading.roll)
        VStack(alignment: .leading) {
            Text(.reachy("Yaw \(yaw)° · pitch \(pitch)° · roll \(roll)°"))
                .monospacedDigit()
            switch source {
            case .left:
                Text(.reachy("From the left earbud"))
            case .right:
                Text(.reachy("From the right earbud"))
            case .unknown, nil:
                EmptyView()
            }
        }
        .foregroundStyle(.secondary)
    }

    private func degrees(_ radians: Double) -> Int {
        Int((radians * 180 / .pi).rounded())
    }
}
