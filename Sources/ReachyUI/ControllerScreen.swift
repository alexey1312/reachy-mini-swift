import ReachyDesign
import ReachyKit
import SwiftUI

/// Live teleop: joystick drives head yaw/pitch and turns the body when held
/// sideways, sliders do the rest.
/// Targets stream over `ws/set_target`; the daemon clamps safety limits.
struct ControllerScreen: View {
    let session: RobotSession

    @State private var driver: TeleopDriver
    @State private var setupError: String?
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        session: RobotSession,
        driver: TeleopDriver = TeleopDriver(),
        setupError: String? = nil
    ) {
        self.session = session
        _driver = State(initialValue: driver)
        _setupError = State(initialValue: setupError)
    }

    /// Comfortable UI ranges; hardware limits (clamped by the daemon anyway):
    /// head pitch/roll ±40°, yaw ±180°. Body yaw is `TeleopDriver.bodyYawLimit`, which
    /// is the URDF's own ±160° rather than a comfortable range — past it the daemon
    /// truncates, and the head's world yaw is computed from the number this slider set.
    private let antennaRange = 150.0 * .pi / 180

    var body: some View {
        @Bindable var driver = driver
        Form {
            if !session.isAwake {
                Section {
                    AsleepBanner(session: session)
                }
            }
            Group {
                Section(.reachy("Head — drag: yaw / pitch, hold sideways: turn the body")) {
                    JoystickPad(mapping: driver.mapping) { driver.apply($0) }
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                Section(.reachy("Head")) {
                    slider(
                        "Roll",
                        value: $driver.roll,
                        range: -driver.mapping.headAngle ... driver.mapping.headAngle,
                        format: .degrees
                    )
                    slider("Height", value: $driver.z, range: -0.03 ... 0.03, format: .millimeters)
                }
                Section(.reachy("Body")) {
                    slider(
                        String(localized: .reachy("Body yaw")),
                        value: $driver.bodyYaw,
                        range: -TeleopDriver.bodyYawLimit ... TeleopDriver.bodyYawLimit,
                        format: .degrees
                    )
                }
                Section(.reachy("Antennas")) {
                    slider(
                        "Left",
                        value: $driver.antennaLeft,
                        range: -antennaRange ... antennaRange,
                        format: .degrees
                    )
                    slider(
                        "Right",
                        value: $driver.antennaRight,
                        range: -antennaRange ... antennaRange,
                        format: .degrees
                    )
                }
                Section {
                    Button(.reachy("Reset to neutral")) { driver.reset() }
                }
            }
            .disabled(!session.isAwake)
            if let setupError {
                Section {
                    Text(setupError)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Controller"))
        .onAppear { start() }
        .onChange(of: session.isAwake) { _, awake in
            // Targets accumulated while asleep would be replayed as one jump.
            if awake {
                driver.reset()
            }
        }
        .onDisappear { driver.stop() }
    }

    private enum SliderFormat { case degrees, millimeters }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: SliderFormat
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted(value.wrappedValue, as: format))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func formatted(_ value: Double, as format: SliderFormat) -> String {
        switch format {
        case .degrees: String(format: "%.0f°", value * 180 / .pi)
        case .millimeters: String(format: "%.0f mm", value * 1000)
        }
    }

    private func start() {
        guard !previewMode else { return }
        do {
            try driver.start { try session.makeTeleop() }
        } catch {
            setupError = RobotSession.describe(error)
        }
    }
}
