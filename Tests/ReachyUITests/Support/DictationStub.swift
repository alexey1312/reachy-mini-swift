import Foundation
import ReachyMedia
@testable import ReachyUI

// `ConversationDictationTests`' stand-in for this device and the robot, in a file of
// its own for SwiftLint's length limit.

/// The device and the robot, logging into one list.
@MainActor
final class DictationStub {
    var log: [String] = []
    var authorization: DeviceDictation.Authorization = .ready
    var refusal: DeviceDictation.Refusal?
    var outcome: DeviceDictation.Outcome = .heard("hello")
    var sayFailure: (any Error)?
    var muteFailure: (any Error)?
    var events: (@MainActor (DeviceDictation.Event) -> Void)?

    var holdsAuthorize = false
    var authorizeGate: CheckedContinuation<Void, Never>?
    var holdsMute = false
    var muteGate: CheckedContinuation<Void, Never>?

    var seam: ConversationDictation {
        ConversationDictation(
            authorize: {
                self.log.append("authorize")
                if self.holdsAuthorize {
                    await withCheckedContinuation { self.authorizeGate = $0 }
                }
                return self.authorization
            },
            start: { events in
                self.log.append("start")
                if let refusal = self.refusal {
                    throw refusal
                }
                self.events = events
            },
            finish: { _ in
                self.log.append("finish")
                return self.outcome
            },
            cancel: { self.log.append("cancel") }
        )
    }

    func setMicrophone(_ muted: Bool) async throws -> Bool {
        log.append("mic(\(muted))")
        if let muteFailure, muted {
            throw muteFailure
        }
        if muted, holdsMute {
            await withCheckedContinuation { muteGate = $0 }
            log.append("mic(true) landed")
        }
        return muted
    }

    func interrupt() async throws {
        log.append("interrupt")
    }

    func say(_ text: String) async throws {
        if let sayFailure {
            throw sayFailure
        }
        log.append("say(\(text))")
    }
}
