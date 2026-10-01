import Foundation
import Observation
import ReachyKit
import ReachyScene

/// The first run's steps and what each one has learned (#169).
///
/// Forward-only, like Pollen's mobile wizard: every step but the first and the last
/// can be passed over, and **Skip setup** ends the whole run from any of them —
/// both write the robot's flag through ``RobotSession/finishFirstRun()``, which is
/// the only thing that makes the shell appear.
///
/// Each check is a person's judgement except two. The sleep-position check reads the
/// motors (``SleepPosition``) and holds the wake-up until a limp robot lies where
/// `goto_sleep` left it, because waking a robot with two cables swapped drives each
/// motor to the other's target. The microphone check listens for the robot's own
/// array to report speech (`doa.speech_detected`), which is the robot hearing rather
/// than this device. Both fail open where the robot cannot answer — a daemon without
/// the field must not leave somebody stuck on a screen they cannot pass.
@MainActor
@Observable
final class FirstRunModel {
    enum Step: Int, CaseIterable {
        case welcome, name, motors, camera, microphone, speaker, done
    }

    /// Where the sleep-position check stands. Separate from the reading itself so the
    /// first frame's absence is not mistaken for a daemon that has no such field.
    enum PoseCheck: Equatable {
        case reading
        case checked(SleepPosition.Reading)
    }

    enum Hearing: Equatable {
        case listening
        case heard
        /// The robot reports no direction of arrival — no array, or firmware below the
        /// 2.1.0 the daemon needs to read one. Nothing here can tell it heard anything.
        case unsupported
    }

    typealias ReadPose = @MainActor () async throws -> RobotStateFrame?
    typealias Rename = @MainActor (RobotSession, String) async throws -> String
    typealias Power = @MainActor (RobotSession) async -> Void
    typealias Finish = @MainActor (RobotSession) async -> Void

    /// The daemon's own ceiling (`MAX_ROBOT_NAME_LENGTH` in `utils/robot_name.py`).
    static let maximumNameLength = 64
    /// Frames in a row with speech in them before the robot counts as having heard.
    static let speechFrames = 2
    /// Frames with no direction at all before the check gives up on the field.
    static let silentFrames = 4
    /// Failed pose reads before the check stops holding the wake-up.
    static let unreadableFrames = 3

    let session: RobotSession
    private(set) var step: Step = .welcome

    var nameInput: String
    private(set) var isSavingName = false
    private(set) var nameError: String?

    /// The robot drawn beside the check, built the first time the motors step asks
    /// for it — a model holds a RealityKit lighting rig, and the root rebuilds this
    /// flow's initialiser on every phase change, so constructing one eagerly would
    /// build a rig per redraw for nothing.
    private(set) var twin: RobotSceneModel?
    private(set) var poseCheck: PoseCheck = .reading
    /// This run stood the robot up. Sticky: the step's question becomes "did it move",
    /// and a robot the owner woke elsewhere has not answered that.
    private(set) var hasWoken = false

    private(set) var hearing: Hearing = .listening

    /// The speaker's level and the test sound, through the model Settings already
    /// uses — one place that knows the slider writes only when a gesture ends.
    let audio: AudioSettingsModel
    private(set) var hasPlayedSound = false

    /// The current step's troubleshooting note is open. Reset on every step, so a note
    /// about the camera is never left open over the microphone.
    private(set) var needsHelp = false

    @ObservationIgnored private let readPose: ReadPose?
    @ObservationIgnored private let makeTwin: (@MainActor () -> RobotSceneModel)?
    @ObservationIgnored private let rename: Rename
    @ObservationIgnored private let wake: Power
    @ObservationIgnored private let sleep: Power
    @ObservationIgnored private let finishRun: Finish
    @ObservationIgnored private let pollInterval: Duration

    /// - Parameter readPose: one frame off the robot, motor by motor. `nil` where there
    ///   is no relay connection to ask — the check then reads as unavailable rather
    ///   than waiting for ever.
    init(
        session: RobotSession,
        readPose: ReadPose?,
        makeTwin: (@MainActor () -> RobotSceneModel)? = nil,
        rename: @escaping Rename = { try await $0.rename(to: $1) },
        wake: @escaping Power = { await $0.wake() },
        sleep: @escaping Power = { await $0.sleep() },
        finish: @escaping Finish = { await $0.finishFirstRun() },
        audio: AudioSettingsModel? = nil,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.session = session
        self.audio = audio ?? AudioSettingsModel()
        self.readPose = readPose
        self.makeTwin = makeTwin
        self.rename = rename
        self.wake = wake
        self.sleep = sleep
        finishRun = finish
        self.pollInterval = pollInterval
        nameInput = session.connectedIdentity?.name ?? ""
    }

    // MARK: - Moving through the run

    /// Every step after the welcome and before the end, which is what the progress
    /// line counts — the two ends are not checks.
    var checkNumber: Int? {
        switch step {
        case .welcome, .done: nil
        default: step.rawValue
        }
    }

    static var checkCount: Int {
        Step.allCases.count - 2
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        needsHelp = false
    }

    func showHelp() {
        needsHelp = true
    }

    /// Finished or skipped, the same call: the session withdraws the offer and the
    /// root swaps this flow for the shell.
    func finish() async {
        await finishRun(session)
    }

    // MARK: - Name

    private var trimmedName: String {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nameIsTooLong: Bool {
        trimmedName.count > Self.maximumNameLength
    }

    var canSaveName: Bool {
        !trimmedName.isEmpty && !nameIsTooLong && !isSavingName && session.supportsRename
    }

    /// An unchanged name costs the robot nothing: it already holds it.
    func saveName() async {
        guard canSaveName else { return }
        guard trimmedName != session.connectedIdentity?.name else {
            advance()
            return
        }
        isSavingName = true
        defer { isSavingName = false }
        do {
            nameInput = try await rename(session, trimmedName)
            nameError = nil
            advance()
        } catch {
            nameError.recordDaemonFailure(error)
        }
    }

    // MARK: - Motors

    /// The robot may be woken: it is asleep, nothing is changing its power, and the
    /// check has either passed or has nothing to say.
    var canWake: Bool {
        guard !session.isAwake, session.powerTransition == nil else { return false }
        switch poseCheck {
        case .reading: return false
        case let .checked(reading): return reading.allowsWake
        }
    }

    /// Reads the motors until the run wakes the robot or the step goes away. A read
    /// that fails keeps the last answer — only a reading that arrived may change it —
    /// unless none ever has, in which case the check stops holding the wake-up.
    func watchPose() async {
        var failures = 0
        while !Task.isCancelled, !hasWoken {
            do {
                let frame = try await readPose?()
                let wasInPosition = poseCheck == .checked(.inPosition)
                poseCheck = .checked(SleepPosition.reading(
                    headJoints: frame?.headJoints,
                    antennas: frame?.antennas,
                    wasInPosition: wasInPosition
                ))
                failures = 0
            } catch {
                failures += 1
                if poseCheck == .reading, failures >= Self.unreadableFrames {
                    poseCheck = .checked(.unavailable)
                }
            }
            guard readPose != nil else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Builds the twin on first use and starts it; the step stops it on the way out.
    func startTwin() {
        if twin == nil {
            twin = makeTwin?()
        }
        twin?.start()
    }

    func stopTwin() {
        twin?.stop()
    }

    /// An awake robot cannot lie in its sleep pose, so the check offers to put it there.
    func putToSleep() async {
        await sleep(session)
    }

    func wakeUp() async {
        guard canWake else { return }
        await wake(session)
        hasWoken = session.isAwake
    }

    // MARK: - Microphone

    /// Listens until the robot reports speech twice in a row, or until it has shown it
    /// reports no direction at all. A read that fails says nothing either way.
    func listen() async {
        var speech = 0
        var silent = 0
        while !Task.isCancelled, hearing == .listening {
            guard let readPose else {
                hearing = .unsupported
                return
            }
            if let frame = try? await readPose() {
                if let direction = frame.directionOfArrival {
                    silent = 0
                    speech = direction.speechDetected ? speech + 1 : 0
                    if speech >= Self.speechFrames {
                        hearing = .heard
                        return
                    }
                } else {
                    silent += 1
                    if silent >= Self.silentFrames {
                        hearing = .unsupported
                        return
                    }
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - Speaker

    /// A reply is not proof anything was heard — `play_sound` answers the same into
    /// silence — so this only moves the step on to asking.
    func playTestSound() async {
        await audio.playTestSound(session: session)
        guard audio.errorMessage == nil else { return }
        hasPlayedSound = true
        needsHelp = false
    }
}

private extension SleepPosition.Reading {
    /// Out of position is the one reading that holds the wake-up.
    var allowsWake: Bool {
        if case .outOfPosition = self {
            false
        } else {
            true
        }
    }
}

#if DEBUG
    extension FirstRunModel {
        /// Parked on one step in a final state, with no robot behind it — every effect
        /// a step's `.task` would start is answered by `readPose: nil` or never runs
        /// under `reachyPreviewMode`.
        static func preview(
            session: RobotSession,
            step: Step,
            name: String? = nil,
            nameError: String? = nil,
            isSavingName: Bool = false,
            poseCheck: PoseCheck = .reading,
            twin: RobotSceneModel? = nil,
            hasWoken: Bool = false,
            hearing: Hearing = .listening,
            hasPlayedSound: Bool = false,
            audio: AudioSettingsModel = .preview(),
            needsHelp: Bool = false
        ) -> FirstRunModel {
            let model = FirstRunModel(session: session, readPose: nil, audio: audio)
            model.step = step
            if let name {
                model.nameInput = name
            }
            model.nameError = nameError
            model.isSavingName = isSavingName
            model.poseCheck = poseCheck
            model.twin = twin
            model.hasWoken = hasWoken
            model.hearing = hearing
            model.hasPlayedSound = hasPlayedSound
            model.needsHelp = needsHelp
            return model
        }
    }
#endif
