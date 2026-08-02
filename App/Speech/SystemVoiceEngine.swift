import AVFoundation
import Foundation
import Speech

/// The real microphone and the real recogniser.
///
/// Every line in ``start`` is in the order it is for a reason, because AVFoundation's failure
/// mode is not an error. `installTap` with a format the hardware isn't producing, or on a bus
/// that already has a tap, raises an Objective-C exception — which Swift cannot catch, so the
/// process is simply killed. Voice input crashing rather than failing is what that looks like
/// from the outside, and it is what the checks and the teardown below exist to prevent.
@MainActor
final class SystemVoiceEngine: NSObject, VoiceEngine {
    /// Both `nonisolated`, because they are written from the recogniser's delegate callback,
    /// which the system makes on whatever thread it likes. A continuation is safe there; a
    /// main-actor property would not be.
    nonisolated let availability: AsyncStream<Bool>
    private nonisolated let availabilityUpdates: AsyncStream<Bool>.Continuation

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    /// Built per session and thrown away with it, rather than held for the life of the app.
    ///
    /// An `AVAudioEngine` reads the input hardware's format when its input node is first touched
    /// and does not go back for it. One built at launch — which is when this type used to build
    /// its own, since a `@State` transcriber is created with the screen — reads that format while
    /// the audio session is still in a playback category and the microphone has never been
    /// granted, and gets zero channels at zero hertz. Handing *that* to `installTap` is the
    /// crash.
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var updates: AsyncStream<VoiceUpdate>.Continuation?
    /// Where the microphone tap puts its buffers. One per session, outliving the several
    /// recognition requests a session is made of — see ``beginRecognition(yielding:)``.
    private var sink: AudioSink?
    /// Tells this session's callbacks from a previous session's, which can still be in flight
    /// when the next one starts. Bumped by ``stop``, which every way out of a session goes
    /// through, so a recogniser finishing an utterance for a session the user has already ended
    /// cannot restart listening underneath the next one.
    private var sessionToken = 0
    /// Whether *this* type put the audio session into a recording category. `stop` is called on
    /// paths where nothing was ever started — leaving the Log tab, a start refused for want of a
    /// permission — and handing back a session we never took would interrupt whatever else on the
    /// phone is legitimately using it.
    private var didActivateSession = false

    override init() {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        availability = stream
        availabilityUpdates = continuation
        super.init()
        recognizer?.delegate = self
    }

    /// Deliberately not also asking `supportsOnDeviceRecognition`.
    ///
    /// That property is false until the locale's model has been installed, which can happen
    /// while the app is running and, on a first launch, usually hasn't happened yet. Gating the
    /// Voice button on it therefore hid the button on exactly the run where the user was trying
    /// voice for the first time. It is checked in ``start`` instead, where it can say so.
    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization() async throws {
        let speechGranted = await withCheckedContinuation { continuation in
            // `@Sendable` is load-bearing, and its absence is not a warning.
            //
            // A plain closure written inside a `@MainActor` type inherits that isolation. This
            // one is handed to an Objective-C API whose handler is annotated with no isolation of
            // its own, so the compiler cannot check that inheritance where it is written and
            // emits a runtime assertion at the closure's first instruction instead. TCC answers
            // on its own XPC reply queue — never the main one — so the assertion failed on the
            // first tap of the Voice button and trapped the process: `EXC_BREAKPOINT`, no error,
            // nothing logged, indistinguishable from the audio crashes this file already guards
            // against.
            //
            // Marked `@Sendable`, the closure inherits nothing and no assertion is emitted.
            // Resuming a continuation is safe from any thread, and the hop back to the main actor
            // happens where it belongs — at the `await` below.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else { throw VoiceInputError.speechPermissionDenied }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceInputError.microphonePermissionDenied
        }
    }

    func start() throws -> AsyncStream<VoiceUpdate> {
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceInputError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceInputError.onDeviceModelUnavailable
        }

        do {
            try configureAudioSession()
        } catch {
            stop()
            throw VoiceInputError.audioSessionFailed(error.localizedDescription)
        }

        // After the session is active, never before — see the note on the property.
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Checked rather than trusted. A format with no rate or no channels is what a microphone
        // that isn't there looks like — the simulator, or an input route that never came up —
        // and `installTap` raises on it rather than throwing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw VoiceInputError.noAudioInput
        }

        let (stream, continuation) = AsyncStream<VoiceUpdate>.makeStream()
        updates = continuation

        // Recognition before the tap, because a buffer that arrives with nowhere to go is
        // dropped — and the ones dropped that way would be the first syllable of the log.
        let sink = AudioSink()
        self.sink = sink
        beginRecognition(yielding: continuation)

        Self.installTap(on: inputNode, format: format, appendingTo: sink)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // The microphone is already tapped by this point. Tearing down here rather than
            // leaving it to the caller is the difference between a start that failed and one
            // that kills the app on the *next* attempt, when a second tap lands on a bus that
            // still has the first.
            stop()
            throw VoiceInputError.audioSessionFailed(error.localizedDescription)
        }

        return stream
    }

    /// Starts one recognition request and reports what it hears.
    ///
    /// A session is several of these rather than one. The recogniser finalises a result as soon
    /// as the speaker stops for a moment, and there is no way to ask it not to — so a list said
    /// out loud, "two eggs … toast … and a black coffee", arrives as one request per item.
    /// Ending the session on the first of them left someone still talking to a microphone that
    /// had stopped listening, and the obvious recovery — tap the button and say the rest —
    /// replaced what had already been heard, so only the last thing said survived into the field.
    /// A final result therefore starts the next request; only ``stop`` and an outright error end
    /// the session.
    private func beginRecognition(yielding continuation: AsyncStream<VoiceUpdate>.Continuation) {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The load-bearing line — see ``SpeechTranscriber``.
        request.requiresOnDeviceRecognition = true
        self.request = request
        sink?.use(request)

        let token = sessionToken

        // Captures the continuation and a number, and reads nothing else: this runs on the
        // recogniser's own thread, and reaching back into `self` from there is what the stream
        // exists to avoid. The one thing that does need `self` — starting the next request — is
        // hopped to the main actor, where that access is honest.
        //
        // `@Sendable` for the same reason as the authorization handler above — without it this
        // closure inherits the type's main-actor isolation, and the recogniser calling it from
        // its own thread trips the isolation assertion rather than delivering a transcript. A
        // continuation is safe to yield to from anywhere, so nothing else has to change.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            if let result {
                let heard = result.bestTranscription.formattedString
                if result.isFinal {
                    // These words are settled and this request is spent. Hand them over and pick
                    // the microphone straight back up for whatever is said next.
                    continuation.yield(.finalized(heard))
                    Task { @MainActor in
                        self?.continueListening(token: token, yielding: continuation)
                    }
                } else {
                    continuation.yield(.transcript(heard))
                }
            }
            if error != nil {
                continuation.yield(.ended(failed: true))
                continuation.finish()
            }
        }
    }

    /// Hands over to a fresh recognition request without disturbing the microphone.
    ///
    /// The audio engine, its tap and the audio session all stay exactly as they are; only the
    /// request the tap is feeding changes. Tearing the audio down and building it again at every
    /// pause would lose a syllable each time, and would make `installTap` — the call this whole
    /// file is arranged around not making twice — happen once per pause.
    private func continueListening(
        token: Int,
        yielding continuation: AsyncStream<VoiceUpdate>.Continuation
    ) {
        // The user tapped stop, or the session failed, while the final result was in flight.
        guard token == sessionToken, audioEngine != nil else { return }

        task = nil
        request = nil
        beginRecognition(yielding: continuation)
    }

    func stop() {
        // Before anything is torn down, so a final result already on its way from the recogniser
        // cannot restart listening on the way out.
        sessionToken &+= 1

        if let audioEngine {
            // The tap comes off before the engine goes, and both happen even when only one of
            // them was ever set up — this runs on the failure path of `start` too.
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }
        audioEngine = nil

        // Emptied as well as released: the tap is off, but a buffer already in flight on the
        // audio thread then has nowhere to land rather than a request that is being ended.
        sink?.use(nil)
        sink = nil

        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil

        updates?.finish()
        updates = nil

        // Hand the audio session back so other audio — music, a podcast the user paused —
        // can resume.
        if didActivateSession {
            didActivateSession = false
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }

    /// Installs the microphone tap from outside this type's isolation, which is the only reason
    /// this is a separate function.
    ///
    /// A tap block written inline in ``start`` is a closure inside a `@MainActor` type, so it
    /// inherits that isolation. `installTap` takes an Objective-C block annotated with no
    /// isolation of its own, so the compiler cannot check the inheritance where the closure is
    /// written and emits a runtime assertion at its first instruction instead. AVFoundation calls
    /// a tap on its realtime audio thread — never the main one — so the assertion failed on the
    /// first buffer after the microphone came up and trapped the process: `EXC_BREAKPOINT`, no
    /// error, nothing logged. Exactly the failure the authorization handler above describes,
    /// arriving a moment later in the same session.
    ///
    /// Written here, in a `nonisolated` context, the closure inherits nothing and no assertion is
    /// emitted, and passing what it needs as a parameter to a synchronous `nonisolated` function
    /// crosses no isolation boundary — so nothing has to be asserted about at run time.
    private nonisolated static func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        appendingTo sink: AudioSink
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` rather than `.playAndRecord`: Tally plays nothing, and the narrower category
        // is less disruptive to whatever else is making sound.
        //
        // No options, where there used to be `.duckOthers`. That option is only legal with the
        // playback categories, so setting it here failed the whole call with an OSStatus -50 and
        // voice never started at all. `.record` silences other audio for the duration anyway,
        // which is what the ducking was reaching for.
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        didActivateSession = true
    }
}

/// Where the microphone's buffers go, swappable while the tap keeps running.
///
/// A box rather than the request itself, because one session is several recognition requests —
/// the recogniser finalises at every pause and the next request takes over — while the tap
/// feeding them is installed exactly once. Removing and reinstalling a tap at every pause would
/// be a lost syllable each time and would make the one call this file is arranged around not
/// making twice into a routine one.
///
/// `@unchecked Sendable` around a lock, because the two sides genuinely are different threads:
/// AVFoundation calls the tap on its realtime audio thread and the swap happens on the main
/// actor. The lock is uncontended in every ordinary moment and held across a pointer read, which
/// is far less work than the `append` it guards.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Points the microphone at `request`, or at nothing.
    func use(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}

extension SystemVoiceEngine: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(
        _ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool
    ) {
        availabilityUpdates.yield(available)
    }
}
