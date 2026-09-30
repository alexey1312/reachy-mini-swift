import AVFoundation
import OSLog
import ReachyKit
import Speech

/// One recording on this device, turned into text.
///
/// It exists because the robot's conversation app only ever hears the robot's own
/// microphone — `conversation.mic` is mute and unmute, and the daemon drops whatever
/// audio a client sends once it has played it. So "talk from this device" records
/// here, transcribes here, and hands the words over as text.
///
/// One instance is one take: `start`, then `finish` or `cancel`, never twice. The audio
/// session is borrowed from `MediaAudioSession` for exactly that span, and every rule
/// about who gives way — a call refuses a take, a camera's WebRTC audio stands down for
/// one — is `DictationAudioPlan`'s.
///
/// `SFSpeechRecognizer` alone, on device where the language allows it and through
/// Apple's service where it does not; the usage string and the privacy policy both say
/// so. `SpeechAnalyzer` would be a second path for iOS 26 and later, and is not this.
@MainActor
public final class DeviceDictation {
    public enum Authorization: Sendable, Equatable {
        case ready
        /// A system prompt was shown. The press that raised it records nothing: the
        /// alert took the touch, so its release may never arrive.
        case askedJustNow
        case microphoneBlocked(PermissionState)
        case speechBlocked(PermissionState)
    }

    public enum Refusal: Error, Sendable, Equatable {
        /// During a call this device's microphone already goes to the robot's speaker.
        case callInProgress
        /// No recognizer for this language, or it is unavailable right now.
        case recognizerUnavailable
        case microphoneUnavailable
    }

    public enum Event: Sendable, Equatable {
        /// The words so far. Replaces the previous reading rather than extending it.
        case heard(String)
        /// This device's input level, 0…1 on the robot meter's scale, about 15 a second.
        case level(Double)
        /// A call, an interruption or a route change took the microphone. The take is
        /// already over; nothing will be sent.
        case preempted
    }

    public enum Outcome: Sendable, Equatable {
        case heard(String)
        /// Silence, or nothing the recognizer could make words of.
        case nothing
        case failed
    }

    /// Prompts only for what has never been answered — microphone first, then speech.
    public static func authorize() async -> Authorization {
        var asked = false
        var microphone = MicrophonePermission.current
        if microphone == .undetermined {
            microphone = await MicrophonePermission.request()
            asked = true
        }
        guard microphone == .granted else { return .microphoneBlocked(microphone) }
        var speech = SpeechRecognitionPermission.current
        if speech == .undetermined {
            speech = await SpeechRecognitionPermission.request()
            asked = true
        }
        guard speech == .granted else { return .speechBlocked(speech) }
        return asked ? .askedJustNow : .ready
    }

    private let locale: Locale
    private var events: (@MainActor (Event) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var consumer: Task<Void, Never>?
    private var holdsSession = false
    private var isCancelled = false
    private var configurationObserver: NSObjectProtocol?

    private var latest = ""
    private var isFinal = false
    private var failure: Failure?
    private var isStreamFinished = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waiterDeadline: Task<Void, Never>?
    private var lastLevel = ContinuousClock.now

    private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "DeviceDictation")

    /// Touches nothing — not the audio session, not Speech. A preview builds one.
    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Opens the microphone and starts transcribing.
    ///
    /// The order is the point: the recognizer is resolved before anything touches the
    /// session, so a refusal costs nothing; the session is borrowed before anything
    /// reads `inputNode`, which builds an audio unit of its own. Anything failing after
    /// the session was borrowed gives it back.
    public func start(events: @escaping @MainActor (Event) -> Void) async throws(Refusal) {
        guard engine == nil, !isCancelled else { return }
        guard let recognizer = Self.recognizer(for: locale), recognizer.isAvailable else {
            // A local, because swiftformat strips the `self.` the log's autoclosure needs.
            let identifier = locale.identifier
            Self.log.notice("No recognizer available for \(identifier, privacy: .public)")
            throw .recognizerUnavailable
        }
        try MediaAudioSession.shared.dictationWillStart { [weak self] in self?.preempt() }
        holdsSession = true
        self.events = events

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ["Reachy"]
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        #if os(macOS)
            // The Mac has no session to stand WebRTC's audio down with, so the robot's
            // voice may be playing through its speakers. Voice processing cancels what
            // this Mac itself plays. A device measurement, not a guarantee.
            try? input.setVoiceProcessingEnabled(true)
        #endif
        // Its own format: a tap in any other sample rate than the hardware's fails.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            teardown()
            throw .microphoneUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tap(appendingTo: RequestBox(request), reporting: continuation)
        )
        engine.prepare()
        guard await Self.startWithRetry(engine), !isCancelled, self.engine === engine else {
            teardown()
            throw .microphoneUnavailable
        }

        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(into: continuation))
        consumer = Task { [weak self] in
            for await update in stream {
                self?.handle(update)
            }
            self?.streamFinished()
        }
        observeConfigurationChanges(of: engine)
        Self.log.notice("Take started, on device: \(request.requiresOnDeviceRecognition, privacy: .public)")
    }

    /// Stops listening and returns what was heard.
    ///
    /// The microphone goes **first**, so the robot's audio is back before any wait —
    /// then the recognizer is told the audio has ended and given `timeout` to say its
    /// last word. What it said before the deadline stands.
    public func finish(timeout: Duration) async -> Outcome {
        guard engine != nil || request != nil else { return .nothing }
        releaseMicrophone()
        request?.endAudio()
        if !isFinal, failure == nil, !isStreamFinished {
            await waitForTheLastWord(timeout: timeout)
        }
        task?.cancel()
        task = nil
        request = nil
        consumer?.cancel()
        consumer = nil
        events = nil
        return outcome
    }

    /// Ends the take and discards it. Idempotent.
    public func cancel() {
        isCancelled = true
        teardown()
    }

    // MARK: -

    /// A call, an interruption or a route change took the microphone.
    private func preempt() {
        let events = events
        cancel()
        Self.log.notice("Take preempted")
        events?(.preempted)
    }

    private func teardown() {
        releaseMicrophone()
        task?.cancel()
        task = nil
        request = nil
        consumer?.cancel()
        consumer = nil
        events = nil
        resumeWaiter()
    }

    private func releaseMicrophone() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if holdsSession {
            holdsSession = false
            MediaAudioSession.shared.dictationDidEnd()
        }
    }

    private var outcome: Outcome {
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return .heard(text)
        }
        guard let failure, !failure.meansNothingWasSaid else { return .nothing }
        Self.log.notice("Recognition failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        return .failed
    }

    // MARK: Results

    private func handle(_ update: Update) {
        switch update {
        case let .text(text, final):
            latest = text
            if final {
                isFinal = true
                resumeWaiter()
            }
            if !text.isEmpty {
                events?(.heard(text))
            }
        case let .failed(domain, code):
            failure = Failure(domain: domain, code: code)
            resumeWaiter()
        case let .level(value):
            let now = ContinuousClock.now
            guard now - lastLevel >= .milliseconds(66) else { return }
            lastLevel = now
            events?(.level(value))
        }
    }

    private func streamFinished() {
        isStreamFinished = true
        resumeWaiter()
    }

    /// A once-only waiter, resumed by the last word, a failure, the stream ending or the
    /// deadline — whichever comes first. Not a task group: a child awaiting a
    /// continuation nobody resumes keeps the whole group alive.
    private func waitForTheLastWord(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            waiterDeadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiter()
            }
        }
    }

    private func resumeWaiter() {
        waiterDeadline?.cancel()
        waiterDeadline = nil
        waiter?.resume()
        waiter = nil
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        // AirPods connecting, a route change: the engine has stopped under the take.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { @Sendable [weak self] _ in
            // `queue: .main` is what makes this assumption true.
            MainActor.assumeIsolated { self?.preempt() }
        }
    }

    /// WebRTC winds its audio unit down on a background thread after the flag goes
    /// false, so a first start can find the hardware still busy — the retry shape
    /// `MediaAudioSession` already uses for the session itself.
    private static func startWithRetry(_ engine: AVAudioEngine) async -> Bool {
        for attempt in 0 ..< 5 {
            do {
                try engine.start()
                return true
            } catch {
                guard attempt < 4, await (try? Task.sleep(for: .milliseconds(200))) != nil else { break }
            }
        }
        log.notice("Engine would not start")
        return false
    }

    /// The device's own locale first, then any supported locale in the same language —
    /// a phone set to `ru_KZ` should transcribe Russian rather than refuse.
    private static func recognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let exact = SFSpeechRecognizer(locale: locale) {
            return exact
        }
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let candidates = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == language }
            .sorted { $0.identifier < $1.identifier }
        return candidates.first.flatMap(SFSpeechRecognizer.init(locale:))
    }
}
