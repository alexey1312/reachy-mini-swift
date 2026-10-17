import Foundation

/// The screen a store screenshot asks for, from a launch argument
/// (`--reachy-tv-stage connect` or `--reachy-tv-stage drive`).
///
/// A session cannot press the Siri Remote's buttons, so `screenshots/tvos/capture.sh`
/// cannot walk to a screen the way a person does; it launches the app on the screen it
/// wants instead. Debug builds only: a Release build always answers `nil`, so nothing a
/// customer runs can be steered this way.
///
/// No argument is the app as it ships, which reconnects by itself and lands on the robot.
enum TVCaptureStage: String {
    /// The connect screen with the robot in the list: the background sweep does not
    /// start, so nothing connects before the screenshot.
    case connect
    /// The drive screen, opened as soon as the robot screen appears.
    case drive

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
}
