import Foundation
import ReachyDesign
import ReachyKit

/// The robot's microphone profiles in words, and what each one is for.
///
/// The profile is a set of audio-board registers, and a register name says nothing
/// to a reader: `PP_MIN_NN` is the floor a babble-noise suppressor may reach. So the
/// screen names the room instead of the register, the way ``DaemonStateCaption``
/// names the state instead of the wire value.
enum MicrophoneProfileCaption {
    static func title(for profile: MicrophoneProfile) -> LocalizedStringResource {
        switch profile {
        case .standard: .reachy("Standard")
        case .sensitive: .reachy("More sensitive")
        case .noisy: .reachy("Noisy room")
        }
    }

    static func detail(for profile: MicrophoneProfile) -> LocalizedStringResource {
        switch profile {
        case .standard: .reachy("The settings the robot comes with.")
        case .sensitive: .reachy("Hears a quiet voice, and a voice from across the room.")
        case .noisy: .reachy("Holds back background noise, at the cost of some range.")
        }
    }

    /// Shown for a board somebody tuned by hand — a state to report, not to correct.
    static var custom: LocalizedStringResource {
        .reachy("Custom")
    }

    static var customDetail: LocalizedStringResource {
        .reachy("This robot's audio board holds values no profile matches.")
    }
}
