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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The load-bearing line — see ``SpeechTranscriber``.
        request.requiresOnDeviceRecognition = true
        self.request = request

        Self.installTap(on: inputNode, format: format, appendingTo: request)

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

        let (stream, continuation) = AsyncStream<VoiceUpdate>.makeStream()
        updates = continuation

        // Captures the continuation and nothing else: this runs on the recogniser's own thread,
        // and reaching back into `self` from there is what the stream exists to avoid.
        //
        // `@Sendable` for the same reason as the authorization handler above — without it this
        // closure inherits the type's main-actor isolation, and the recogniser calling it from
        // its own thread trips the isolation assertion rather than delivering a transcript. A
        // continuation is safe to yield to from anywhere, so nothing else has to change.
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result {
                continuation.yield(.transcript(result.bestTranscription.formattedString))
            }
            // Any error, or a final result, means this session is over.
            if error != nil || result?.isFinal == true {
                continuation.yield(.ended(failed: error != nil))
                continuation.finish()
            }
        }

        return stream
    }

    func stop() {
        if let audioEngine {
            // The tap comes off before the engine goes, and both happen even when only one of
            // them was ever set up — this runs on the failure path of `start` too.
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }
        audioEngine = nil

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
    /// emitted. Annotating it `@Sendable` in place would do the same, but a `@Sendable` closure
    /// cannot capture the request — `SFSpeechAudioBufferRecognitionRequest` is not `Sendable`, and
    /// under Swift 6 that capture is an error rather than the warning it would have been. Passing
    /// the request as a parameter to a synchronous `nonisolated` function crosses no isolation
    /// boundary, so nothing needs to be made `Sendable` or asserted about at run time.
    private nonisolated static func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        appendingTo request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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

extension SystemVoiceEngine: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(
        _ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool
    ) {
        availabilityUpdates.yield(available)
    }
}
