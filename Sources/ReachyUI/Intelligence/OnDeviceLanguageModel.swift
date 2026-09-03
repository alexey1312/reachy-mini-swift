import Foundation
import FoundationModels

/// Why the on-device model is or is not there, in terms a type at this app's iOS 18
/// floor may hold.
///
/// It mirrors `SystemLanguageModel.Availability` and adds the one case that type
/// cannot express: the system is too old for the framework to have an opinion at all.
enum ModelAvailability: Equatable, Sendable {
    case available
    /// Below iOS 26 / macOS 26. Not a refusal — there is nothing there to refuse.
    case unsupportedSystem
    /// The hardware cannot run it. Permanent, and there is nothing to offer.
    case deviceNotEligible
    /// Apple Intelligence is switched off in Settings. The reader owns this one.
    case appleIntelligenceNotEnabled
    /// Assets still downloading, or the device is too hot or too low on battery.
    /// Transient without anybody doing anything, which is why availability is re-read
    /// on every appearance rather than once at construction.
    case modelNotReady
    /// A reason a later SDK added. Treated as unavailable.
    case unavailableForAnotherReason
}

/// This target's entire surface onto Foundation Models.
///
/// Nothing else in `ReachyUI` imports the framework or names a type from it. Both
/// functions are callable at the iOS 18 floor because every 26-only symbol lives
/// inside `Gate`, which carries the annotation — the same trick
/// `ReachyPlacedAccessory` plays with a property wrapper that cannot be conditionally
/// available, in a value flavour rather than a `View` one.
///
/// **No session is stored, and that is the design rather than a way around the
/// floor.** One explanation is one prompt over a frozen excerpt; a reused session
/// would carry the previous excerpt in its transcript and hit the context window on
/// the second run. Building one per request happens to also remove the problem of a
/// 26-only stored property on an 18-floor type, which is a bonus and not the reason.
///
/// **Every symbol named below is `iOS 26.0 / macOS 26.0`, checked against the SDK's
/// own `.swiftinterface` rather than assumed**, because the local Xcode is a 27 beta
/// and the job that compiles every SwiftPM target runs 26.2 — where a 27 symbol is
/// simply absent and `@available` does not save it. Three traps found that way and
/// avoided here:
///
/// - **`GenerationOptions` is never constructed.** `init(samplingMode:…)` is iOS 27
///   (back-deployed, so it *runs* on 26 but only exists in the 27 SDK) and the 26
///   spelling `init(sampling:…)` takes its first argument without a default. So
///   `GenerationOptions(temperature:…)` compiles here and fails there. Letting the
///   framework supply its own default argument sidesteps the whole question.
/// - **Every `init(model: some LanguageModel, …)` is iOS 27.** The 26 initialiser
///   takes `SystemLanguageModel` and defaults it, which is what `instructions:` alone
///   resolves to.
/// - `tokenCount(for:)` is 26.4 and `LanguageModelError`, `usage` and `ContextOptions`
///   are 27, so none of them appears here either.
enum OnDeviceLanguageModel {
    static func availability() -> ModelAvailability {
        guard #available(iOS 26.0, macOS 26.0, *) else { return .unsupportedSystem }
        return Gate.availability()
    }

    /// One prompt, one answer, plain text. No tools, no network, no actuator — the
    /// structural reason this feature's worst outcome is a wrong sentence in a sheet.
    static func respond(instructions: String, prompt: String) async throws -> String {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw ModelUnavailable() }
        return try await Gate.respond(instructions: instructions, prompt: prompt)
    }

    /// Thrown only where the gate said no and something asked anyway, which the UI
    /// prevents by not offering the button at all.
    struct ModelUnavailable: Error {}

    @available(iOS 26.0, macOS 26.0, *)
    private enum Gate {
        static func availability() -> ModelAvailability {
            switch SystemLanguageModel.default.availability {
            case .available:
                .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible: .deviceNotEligible
                case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
                case .modelNotReady: .modelNotReady
                // `UnavailableReason` is not `@frozen`; without this a later SDK
                // adding a case breaks the build.
                @unknown default: .unavailableForAnotherReason
                }
            }
        }

        static func respond(instructions: String, prompt: String) async throws -> String {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
    }
}
