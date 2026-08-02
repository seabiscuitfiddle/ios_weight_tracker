import Foundation
import Observation

/// Transcribes speech to text **on the device**.
///
/// On-device recognition is the point of voice input here, not an optimisation. Left off,
/// `SFSpeechRecognizer` uploads audio to Apple's servers for transcription — which would quietly
/// break the app's promise that the only thing leaving the device is the text you chose to send
/// to your own LLM key. On-device recognition is somewhat less accurate; that is the right trade
/// here, and the text is editable before it is logged anyway.
///
/// The microphone and the recogniser sit behind ``VoiceEngine`` rather than being used directly.
/// That is not for swappability: AVFoundation *raises* — an Objective-C exception, uncatchable
/// from Swift, so the app disappears rather than showing an error — when it is asked to record
/// with a microphone that isn't there, or to tap an input that is already tapped. Both are
/// reachable from an ordinary tap on the Voice button, so the order these calls happen in and
/// what a failed start leaves behind are the load-bearing parts of this feature, and the
/// protocol is what lets a test check them.
@Observable
@MainActor
final class SpeechTranscriber {
    /// Live transcript of the whole session, updated as the user speaks.
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var errorMessage: String?

    /// Whether there is a recogniser to start, so the UI can hide voice input rather than
    /// offering a button that fails.
    ///
    /// Stored rather than read through to the recogniser on demand, because availability
    /// genuinely changes while the app is up — a model finishes installing, a phone call ends —
    /// and a value computed from a type `@Observable` can't see registers no dependency at all.
    /// The button was therefore drawn once, from whatever happened to be true at launch, and a
    /// recogniser that wasn't ready yet meant no Voice button for the rest of the run.
    private(set) var isAvailable: Bool

    private let engine: any VoiceEngine
    /// Consumes one session's updates. Held so it can be cancelled: a stopped session must not
    /// keep writing into ``transcript``.
    private var session: Task<Void, Never>?
    /// True from the first tap until the session is either running or has failed. The permission
    /// prompt is a long suspension the first time round, and `isRecording` is still false
    /// throughout it, so without this a second tap starts a second session on top of the first.
    private var isStarting = false
    /// The utterances of this session that the recogniser has settled on, run together.
    ///
    /// Kept apart from ``transcript`` because the recogniser revises an utterance for as long as
    /// it is being said and stops revising it the moment the speaker pauses. Everything after
    /// that pause is a *new* utterance, reported from nothing — so mirroring the latest one
    /// straight into ``transcript`` showed only the thing said most recently, and dropped
    /// everything logged in the same breath before it. Adding them up is what makes "two eggs …
    /// toast … and a black coffee" one send with three entries in it.
    private var settledUtterances = ""

    init(engine: any VoiceEngine = SystemVoiceEngine()) {
        self.engine = engine
        self.isAvailable = engine.isAvailable

        // Runs for as long as the transcriber does — availability changes between sessions as
        // much as during one, which is the whole reason for watching it. Weakly, so this holds
        // nothing alive: the loop simply stops finding anything to update.
        let availability = engine.availability
        Task { [weak self] in
            for await available in availability { self?.isAvailable = available }
        }
    }

    /// Starts listening, or explains why it can't.
    ///
    /// Every failure ends in ``stop``, including one raised before anything was started. Tearing
    /// down what did get set up is the whole difference between a start that failed and a start
    /// that takes the *next* one down with it.
    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        transcript = ""
        settledUtterances = ""
        errorMessage = nil

        do {
            // Before the permission prompts, not after: asking someone for their microphone and
            // then telling them transcription can't run anyway is two dialogs' worth of nothing.
            guard isAvailable else { throw VoiceInputError.recognizerUnavailable }

            try await engine.requestAuthorization()
            let updates = try engine.start()
            isRecording = true
            session = Task { [weak self] in
                for await update in updates { self?.apply(update) }
            }
        } catch {
            // An error from somewhere other than the engine's own vocabulary is still shown the
            // same way, so what the user reads doesn't depend on which layer gave up.
            let failure: VoiceInputError = error as? VoiceInputError
                ?? .audioSessionFailed(error.localizedDescription)
            errorMessage = failure.userMessage
            stop()
        }
    }

    /// Stops recording and leaves ``transcript`` holding whatever was heard.
    ///
    /// Unconditional, and correct to call when nothing is running: the teardown is the same
    /// either way. A `stop` that first decided whether there was anything to stop is how a
    /// half-started session — one whose audio engine failed on the line *after* the microphone
    /// was already tapped — used to survive into the next attempt and crash it.
    func stop() {
        session?.cancel()
        session = nil
        engine.stop()
        isRecording = false
    }

    private func apply(_ update: VoiceUpdate) {
        switch update {
        case .transcript(let text):
            transcript = VoiceTranscript.joined(settledUtterances, text)
        case .finalized(let text):
            settledUtterances = VoiceTranscript.joined(settledUtterances, text)
            transcript = settledUtterances
        case .ended(let failed):
            // A failure that arrives after something was heard isn't worth saying: the words are
            // in the field, editable, which is what the user came for. One that arrives with
            // nothing heard is the case where silence would read as the button doing nothing.
            if failed, transcript.isEmpty {
                errorMessage = "Nothing was heard. Try again, closer to the microphone."
            }
            stop()
        }
    }
}

/// What a running voice session reports back.
enum VoiceUpdate: Sendable {
    /// The utterance being spoken now, as heard so far and sent again on every revision. Only
    /// this utterance — anything settled by an earlier ``finalized`` is not repeated.
    case transcript(String)
    /// The recogniser has stopped revising an utterance, because the speaker paused. The session
    /// carries on; the next ``transcript`` starts the next utterance from nothing.
    case finalized(String)
    /// The session ended on its own — recognition gave up, or the microphone went away.
    case ended(failed: Bool)
}

/// How the pieces of a spoken log are run together.
enum VoiceTranscript {
    /// Joins two things the user said into one description.
    ///
    /// With a comma, not a space. The two are separate things, said with a pause between them,
    /// and one send is split into entries by reading the words: "two eggs toast" is one odd
    /// breakfast to a parser, while "two eggs, toast" is the two entries that were actually
    /// spoken. Punctuation the speaker dictated themselves stands as it is rather than gaining a
    /// comma after it.
    static func joined(_ existing: String, _ addition: String) -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return addition }
        guard !addition.isEmpty else { return existing }

        let alreadyPunctuated = existing.last.map { ",.!?;:–—".contains($0) } ?? false
        return existing + (alreadyPunctuated ? " " : ", ") + addition
    }
}

/// The microphone and the on-device recogniser, behind one protocol.
///
/// See ``SpeechTranscriber`` for why this exists.
@MainActor
protocol VoiceEngine: AnyObject {
    /// Whether a session could be started right now.
    var isAvailable: Bool { get }

    /// Changes to ``isAvailable``. One stream, for one consumer: the transcriber that owns this.
    var availability: AsyncStream<Bool> { get }

    /// Requests both permissions this needs: speech recognition and the microphone.
    ///
    /// Both, because they are genuinely separate grants and being denied either one makes voice
    /// logging impossible — asking for one and discovering the other at record time would show
    /// the user a failure instead of a prompt.
    func requestAuthorization() async throws

    /// Starts recording. The returned stream ends when the session does.
    func start() throws -> AsyncStream<VoiceUpdate>

    /// Tears down everything ``start`` sets up. Must be idempotent, and must be correct to call
    /// after a `start` that threw part-way through.
    func stop()
}

/// Why voice input couldn't start.
///
/// Each case carries a ``userMessage`` for the same reason `NutritionParserError` does: "an error
/// occurred" tells someone holding a phone to their mouth nothing about what to do next.
enum VoiceInputError: Error, Hashable, Sendable {
    /// The recogniser exists but isn't ready — no network for its assets, or another app has it.
    case recognizerUnavailable
    /// This device or language has no on-device model, and Tally will not transcribe off-device.
    case onDeviceModelUnavailable
    case speechPermissionDenied
    case microphonePermissionDenied
    /// The audio session came up with nothing to record from: the simulator, or an input route
    /// that never arrived.
    case noAudioInput
    /// The audio session or engine refused to start, with whatever it said about why.
    case audioSessionFailed(String)

    var userMessage: String {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition isn't available right now. Try again in a moment."
        case .onDeviceModelUnavailable:
            // Says what Tally won't do as well as what's missing, because "unavailable" for a
            // feature that plainly works in other apps reads as a bug rather than a choice.
            """
            Your language has no on-device transcription on this device, and Tally won't send \
            your voice to Apple's servers. Type it instead.
            """
        case .speechPermissionDenied:
            "Speech recognition permission was declined. You can enable it in Settings."
        case .microphonePermissionDenied:
            "Microphone access was declined. You can enable it in Settings."
        case .noAudioInput:
            "No microphone is available, so there's nothing to record from."
        case .audioSessionFailed(let reason):
            Self.recordingFailure(reason)
        }
    }

    /// The audio session's own words about a failure, made into a sentence.
    ///
    /// What arrives here is a `localizedDescription` from AVFoundation, which is a fragment at
    /// least as often as a sentence — "no input node" — and a message that stops mid-thought
    /// reads as the app breaking rather than explaining itself. A reason that says nothing at
    /// all is left out entirely rather than shown as a dangling colon.
    private static func recordingFailure(_ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = reason.last else { return "Couldn't start recording. Try again." }
        let fullStop = ".!?".contains(end) ? "" : "."
        return "Couldn't start recording: \(reason)\(fullStop)"
    }
}
