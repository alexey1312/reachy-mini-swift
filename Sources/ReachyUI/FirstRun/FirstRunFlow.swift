import ReachyDesign
import ReachyKit
import ReachyMedia
import ReachyScene
import SwiftUI

/// A first run of this app's own, standing in for the shell while the robot reads as
/// never woken (#169): Welcome → Name → Motors → Camera → Microphone → Speaker → Done.
///
/// Over the relay its camera and its pose come off the relay link; on the LAN the
/// pose comes off the daemon's own socket and the camera off the data-channel link
/// the root opened to read the flag (`FirstRunLANLink`), when it opened.
///
/// **In place of the shell rather than over it**, as the fork in `ReachyRootView`
/// draws it. Pollen's apps keep the robot asleep until their wizard has run, and the
/// shell is where every Wake up button lives; it is also where the viewport's own
/// `RealityView` would be mounted beside this flow's twin. Nothing here outlives the
/// run — the session withdrawing ``RobotSession/offersFirstRun`` is what swaps it for
/// the shell, and a dropped relay is what swaps it for the gate.
struct FirstRunFlow: View {
    @State private var model: FirstRunModel
    private let camera: CameraSession?

    @MainActor
    init(session: RobotSession, remoteLink: RemoteRobotLink?, model: FirstRunModel? = nil) {
        camera = remoteLink?.camera
        if let model {
            _model = State(initialValue: model)
            return
        }
        if case let .lan(address) = session.link, let stream = try? RobotStateStream(address: address) {
            // On the LAN the pose comes off the daemon's own socket, pushed rather than
            // polled; the link, when there is one, is the camera and the flag.
            let reader = FirstRunStateReader(stream: stream)
            _model = State(initialValue: FirstRunModel(
                session: session,
                readPose: { try await reader.next() },
                makeTwin: { RobotSceneModel(stream: stream, client: BundledGeometryClient()) }
            ))
            return
        }
        guard let connection = remoteLink?.client else {
            _model = State(initialValue: FirstRunModel(session: session, readPose: nil))
            return
        }
        _model = State(initialValue: FirstRunModel(
            session: session,
            readPose: { try await connection.stateFrame() },
            // Not the viewport's twin: the pose channel hands its frames to one reader,
            // and the viewport takes it once the shell appears. Five frames a second
            // is plenty to watch a head laid down by hand, with the check polling
            // beside it over the same channel.
            makeTwin: {
                RobotSceneModel(
                    stream: RemoteStateStream(connection: connection, maximumFrequency: 5),
                    client: BundledGeometryClient()
                )
            }
        ))
    }

    var body: some View {
        NavigationStack {
            step
                .navigationTitle(title)
                .firstRunTitleStyle()
                .toolbar {
                    if model.step != .done {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.reachy("Skip setup")) {
                                Task { await model.finish() }
                            }
                        }
                    }
                }
        }
    }

    private var title: LocalizedStringResource {
        switch model.step {
        case .welcome, .done: .reachy("Getting started")
        case .name: .reachy("Check 1 of 5")
        case .motors: .reachy("Check 2 of 5")
        case .camera: .reachy("Check 3 of 5")
        case .microphone: .reachy("Check 4 of 5")
        case .speaker: .reachy("Check 5 of 5")
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome:
            FirstRunWelcomeStep(model: model)
        case .name:
            FirstRunNameStep(model: model)
        case .motors:
            FirstRunMotorsStep(model: model)
        case .camera:
            FirstRunCameraStep(model: model, camera: camera)
        case .microphone:
            FirstRunMicrophoneStep(model: model)
        case .speaker:
            FirstRunSpeakerStep(model: model)
        case .done:
            FirstRunDoneStep(model: model)
        }
    }
}

/// The plain secondary action every check carries: move on without answering.
struct FirstRunSkipButton: View {
    let model: FirstRunModel

    var body: some View {
        Button(.reachy("Skip")) { model.advance() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    func firstRunTitleStyle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
