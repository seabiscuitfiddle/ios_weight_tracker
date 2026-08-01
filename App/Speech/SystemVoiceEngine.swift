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
///
/// The other uncatchable failure here is concurrency's, and every closure in this file is
/// written the way it is because of it: this type is `@MainActor`, so a closure written inside
/// it is main-actor isolated unless it says otherwise, and Swift compiles an assert into an
/// isolated closure that fires if it is ever called somewhere else. The speech, audio and TCC
/// callbacks below are all called somewhere else — that is what they are for. Each one is
/// therefore explicitly `@Sendable`, which is how a closure opts out of inheriting the
/// isolation it is written in. See ``awaitingCallback``.
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
        // Through ``awaitingCallback`` rather than a `withCheckedContinuation` written here, and
        // that indirection is the entire point: the handler must not be main-actor isolated, and
        // one written inline in this type silently would be.
        let status: SFSpeechRecognizerAuthorizationStatus = await awaitingCallback { handler in
            SFSpeechRecognizer.requestAuthorization(handler)
        }
        guard status == .authorized else { throw VoiceInputError.speechPermissionDenied }

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

        // `@Sendable`, because this one is called from the audio hardware's own realtime thread —
        // the furthest thing there is from the main actor — and an isolated closure asserts.
        //
        // `nonisolated(unsafe)` is what lets a `@Sendable` closure capture the request at all: it
        // is a main-actor value and the closure is not on the main actor. Appending buffers from
        // the audio thread is what an `SFSpeechAudioBufferRecognitionRequest` is *for*, and the
        // tap is removed in ``stop`` before the request is released, so the unsafety is the
        // compiler's word for "the SDK guarantees this", not a race.
        nonisolated(unsafe) let audioSink = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable (buffer, _) in
            audioSink.append(buffer)
        }

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
        // and reaching back into `self` from there is what the stream exists to avoid. `@Sendable`
        // says so to the compiler as well — without it the closure inherits this type's actor and
        // asserts on the recogniser's thread, which is every thread but the one it would accept.
        task = recognizer.recognitionTask(with: request) { @Sendable (result, error) in
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

/// Awaits a system API that answers by calling a handler back, on whatever thread it pleases.
///
/// Voice input crashed on launch a second time, and this is why. The shape is worth knowing
/// because it is invisible at the call site and nothing warns about it.
///
/// A closure written inside an isolated type — `SystemVoiceEngine` is `@MainActor` — and handed to
/// an SDK function whose handler is not declared `@Sendable` *inherits* that isolation. Swift then
/// compiles a check into the front of the closure asserting that it really is running on the main
/// actor. `SFSpeechRecognizer.requestAuthorization` answers from TCC's XPC reply queue, so the
/// assert fails, and a failed isolation assert is not something anyone can catch: it is
/// `dispatch_assert_queue` and a trap, and the process is gone. It cannot happen until someone is
/// actually asked for the permission, which is why it survived every run where the permission had
/// already been granted.
///
/// Declaring the handler `@Sendable` is what breaks the inheritance — a `@Sendable` closure is
/// never actor-isolated, so no check is compiled in and the callback may arrive wherever it
/// arrives. `ask` is `@Sendable` for exactly the same reason: as an ordinary closure it would
/// inherit its caller's isolation and then be asserted when this function, which has none, calls
/// it. And this lives at file scope rather than on the type because a member of a `@MainActor`
/// type would be back where it started.
func awaitingCallback<Value: Sendable>(
    _ ask: @Sendable (@escaping @Sendable (Value) -> Void) -> Void
) async -> Value {
    await withCheckedContinuation { continuation in
        ask { value in continuation.resume(returning: value) }
    }
}
