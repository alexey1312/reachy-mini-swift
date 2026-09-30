import AVFoundation
import Speech

/// The half of `DeviceDictation` that runs off the main actor: the tap on the audio
/// thread and the result handler on the recognizer's queue, and the values they send
/// back. A file of its own so the take's own logic stays readable in the other.
extension DeviceDictation {
    // The tap runs on the audio thread and the result handler on the recognizer's
    // queue. Both are built here, in nonisolated factories, and both are `@Sendable`:
    // a closure written inside a `@MainActor` method inherits that isolation, and Swift
    // then asserts the main queue when the audio thread calls it — `abort_with_payload`
    // and a `LIBDISPATCH` line in the log, the trap `ReachyUI/AGENTS.md` records for
    // `ASWebAuthenticationSession`.

    enum Update: Sendable {
        case text(String, isFinal: Bool)
        case failed(domain: String, code: Int)
        case level(Double)
    }

    struct Failure: Equatable {
        let domain: String
        let code: Int

        /// "No speech detected", and the cancellation `finish` itself causes. The codes
        /// are the ones the framework is known to use; confirm them on a device.
        var meansNothingWasSaid: Bool {
            (domain == "kAFAssistantErrorDomain" && code == 1110)
                || (domain == "kLSRErrorDomain" && code == 301)
        }
    }

    /// The request is appended to from the tap thread, as Apple's own sample does.
    final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }
    }

    nonisolated static func tap(
        appendingTo box: RequestBox,
        reporting continuation: AsyncStream<Update>.Continuation
    ) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            box.request.append(buffer)
            continuation.yield(.level(level(of: buffer)))
        }
    }

    nonisolated static func results(
        into continuation: AsyncStream<Update>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { @Sendable result, error in
            if let result {
                continuation.yield(.text(result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
            if let error {
                let error = error as NSError
                continuation.yield(.failed(domain: error.domain, code: error.code))
            }
            if result?.isFinal == true || error != nil {
                continuation.finish()
            }
        }
    }

    /// RMS of the first channel, scaled the way the robot's own meter is (× 6, clamped),
    /// so the two meters on one screen mean the same thing.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0 ..< count {
            sum += samples[index] * samples[index]
        }
        return min(1, Double((sum / Float(count)).squareRoot()) * 6)
    }
}
