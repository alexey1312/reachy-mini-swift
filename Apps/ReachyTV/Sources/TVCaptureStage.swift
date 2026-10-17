import Foundation

/// The screen a store screenshot or a check asks for, from a launch argument
/// (`--reachy-tv-stage connect`, `drive`, `simulator` or `simulator-drive`).
///
/// A session cannot press the Siri Remote's buttons, so `screenshots/tvos/capture.sh`
/// cannot walk to a screen the way a person does; it launches the app on the screen it
/// wants instead. Debug builds only: a Release build always answers `nil`, so nothing a
/// customer or a reviewer runs can be steered this way.
///
/// No argument is the app as it ships, which reconnects by itself and lands on the robot.
enum TVCaptureStage: String {
    /// The connect screen with the robot in the list: the background sweep does not
    /// start, so nothing connects before the screenshot.
    case connect
    /// The drive screen, opened as soon as the robot screen appears.
    case drive
    /// What "Try without a robot" does: the in-app simulated robot, on the robot screen.
    case simulator
    /// The same, and then the drive screen.
    case simulatorDrive = "simulator-drive"

    static let current: TVCaptureStage? = {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--reachy-tv-stage"), flag + 1 < arguments.count else {
                return nil
            }
            return TVCaptureStage(rawValue: arguments[flag + 1])
        #else
            return nil
        #endif
    }()

    /// Every stage but `drive` keeps the background sweep from connecting by itself.
    var holdsSweep: Bool {
        self != .drive
    }

    var startsSimulator: Bool {
        self == .simulator || self == .simulatorDrive
    }

    var opensDrive: Bool {
        self == .drive || self == .simulatorDrive
    }
}
