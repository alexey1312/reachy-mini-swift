import ReachyDesign
import ReachyKit
import SwiftUI

/// Live teleop: joystick drives head yaw/pitch and turns the body when held
/// sideways, sliders do the rest.
/// Targets stream over `ws/set_target`; the daemon clamps safety limits.
struct ControllerScreen: View {
    let session: RobotSession
    /// The same closure `CameraViewport` gets, built from the one `PresenceModel` in
    /// `LiveTab`: this pad drives the same head, so it owes the same hand-off, and a
    /// second model here would let one joystick turn a behaviour off behind a switch
    /// still showing it on.
    var standDown: TeleopStandDown?

    @State private var driver: TeleopDriver
    @State private var setupError: String?
    @State private var recorder: MoveRecorderModel
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        session: RobotSession,
        standDown: TeleopStandDown? = nil,
        driver: TeleopDriver = TeleopDriver(),
        setupError: String? = nil,
        recorder: MoveRecorderModel? = nil
    ) {
        self.session = session
        self.standDown = standDown
        _driver = State(initialValue: driver)
        _setupError = State(initialValue: setupError)
        _recorder = State(initialValue: recorder ?? MoveRecorderModel())
    }

    /// How often a take samples the driver.
    ///
    /// 10 Hz because that is the daemon's own full-state rate and well inside what
    /// `ws/set_target` accepts — a take is replayed as targets, so sampling faster
    /// buys resolution the robot's own loop would smooth away anyway.
    private static let sampleInterval = Duration.milliseconds(100)

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
            // Above the pad, not under the sliders: a failed setup leaves every control
            // below inert, and the one line saying why used to sit past the fold — the
            // `Controller — setup failed` reference showed a healthy screen for as long
            // as the row was at the bottom.
            if let setupError {
                Section {
                    ReachyErrorRow(setupError, retry: start)
                }
            }
            Group {
                Section(.reachy("Head — drag: yaw / pitch, hold sideways: turn the body")) {
                    JoystickPad(mapping: driver.mapping) { deflection in
                        driver.apply(deflection)
                        standDown?()
                    }
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                }
                recordingSection
                Section(.reachy("Head")) {
                    slider(
                        .reachy("Roll"),
                        value: $driver.roll,
                        range: -driver.mapping.headAngle ... driver.mapping.headAngle,
                        format: .degrees
                    )
                    slider(.reachy("Height"), value: $driver.z, range: -0.03 ... 0.03, format: .millimeters)
                }
                Section(.reachy("Body")) {
                    slider(
                        .reachy("Body yaw"),
                        value: $driver.bodyYaw,
                        range: -TeleopDriver.bodyYawLimit ... TeleopDriver.bodyYawLimit,
                        format: .degrees
                    )
                }
                Section(.reachy("Antennas")) {
                    slider(
                        .reachy("Left"),
                        value: $driver.antennaLeft,
                        range: -antennaRange ... antennaRange,
                        format: .degrees
                    )
                    slider(
                        .reachy("Right"),
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
        .onDisappear {
            // A take that outlived the screen has nothing sampling it, so it would
            // save whatever it happened to hold — end it here rather than keep a
            // stopwatch running over a driver nobody is driving.
            recorder.endRecording(named: Self.defaultName(for: recorder.recordings.count))
            driver.stop()
        }
    }

    /// Recording is here rather than on the Live tab because this is the screen that
    /// drives the robot: what a take captures is the target this screen is setting,
    /// and a button somewhere else would record a joystick the reader cannot see.
    ///
    /// The sampler is a `.task` keyed on `isRecording` — it exists exactly while a
    /// take does, and cancelling it is what stops it. It reads `driver.target`, which
    /// is the same value the channel is being sent, so a take is what the robot was
    /// asked to do rather than a second guess at it.
    private var recordingSection: some View {
        Section {
            Button {
                toggleRecording()
            } label: {
                Label(
                    recorder.isRecording ? .reachy("Stop recording") : .reachy("Record a move"),
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                )
            }
            .tint(recorder.isRecording ? .red : nil)
            if recorder.isRecording {
                LabeledContent(.reachy("Recording")) {
                    Text(.reachy("\(recorder.elapsed.formatted(.number.precision(.fractionLength(1)))) s"))
                        .font(Typography.consoleLine)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(.reachy("Takes are kept on this phone and play back from the Moves tab."))
        }
        .task(id: recorder.isRecording) {
            guard !previewMode, recorder.isRecording else { return }
            while !Task.isCancelled, recorder.isRecording {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled else { return }
                recorder.capture(driver.target)
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.endRecording(named: Self.defaultName(for: recorder.recordings.count))
        } else {
            recorder.beginRecording()
        }
    }

    /// Named rather than prompted: the recording is the thing worth keeping, and a
    /// text field between the reader and the save is where a take gets lost. Renaming
    /// is a swipe away in the Moves tab.
    private static func defaultName(for existing: Int) -> String {
        String(localized: .reachy("Take \(existing + 1)"))
    }

    private enum SliderFormat { case degrees, millimeters }

    private func slider(
        _ title: LocalizedStringResource,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: SliderFormat
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted(value.wrappedValue, as: format))
                    .font(Typography.consoleLine)
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
