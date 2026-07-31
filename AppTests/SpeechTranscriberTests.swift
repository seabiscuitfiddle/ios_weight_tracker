import Foundation
import Testing
@testable import Tally

/// A stand-in for the microphone and the on-device recogniser.
///
/// The real ones can't be tested against: a test process has no microphone, no way to grant
/// itself two privacy permissions, and — the part that matters here — AVFoundation answers a
/// request it can't satisfy by raising, which takes the whole test runner with it. That is
/// precisely the behaviour under test, so it has to be staged rather than provoked.
@MainActor
private final class FakeVoiceEngine: VoiceEngine {
    var isAvailable = true
    let availability: AsyncStream<Bool>
    private let availabilityUpdates: AsyncStream<Bool>.Continuation

    /// Thrown by the next `requestAuthorization`, if set.
    var authorizationError: VoiceInputError?
    /// Thrown by the next `start`, if set. Cleared when it fires, so a test can show the attempt
    /// *after* a failure getting through.
    var startError: VoiceInputError?
    /// Holds `requestAuthorization` open, the way the system's permission prompt does.
    var pausesAuthorization = false

    private(set) var starts = 0
    private(set) var stops = 0
    private var updates: AsyncStream<VoiceUpdate>.Continuation?
    private var authorizationGate: CheckedContinuation<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        availability = stream
        availabilityUpdates = continuation
    }

    /// True while a start is parked on the permission prompt.
    var isAwaitingAuthorization: Bool { authorizationGate != nil }

    func releaseAuthorization() {
        authorizationGate?.resume()
        authorizationGate = nil
    }

    func becomeAvailable(_ available: Bool) {
        isAvailable = available
        availabilityUpdates.yield(available)
    }

    func send(_ update: VoiceUpdate) {
        updates?.yield(update)
    }

    func requestAuthorization() async throws {
        if pausesAuthorization {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                authorizationGate = continuation
            }
        }
        if let authorizationError { throw authorizationError }
    }

    func start() throws -> AsyncStream<VoiceUpdate> {
        starts += 1
        if let startError {
            self.startError = nil
            throw startError
        }
        let (stream, continuation) = AsyncStream<VoiceUpdate>.makeStream()
        updates = continuation
        return stream
    }

    func stop() {
        stops += 1
        updates?.finish()
        updates = nil
    }
}

/// Voice input, which crashed rather than failed.
///
/// Nothing here reaches AVFoundation. What these check is the sequencing around it — what a
/// failed start leaves behind, and whether a second attempt can happen at all — because that is
/// where the crash was: an audio engine that failed after the microphone was already tapped left
/// the tap in place, and the next tap on the same bus is an uncatchable exception rather than an
/// error.
@MainActor
@Suite("Speech transcriber")
struct SpeechTranscriberTests {
    /// Lets the transcriber's update task run. Everything is on the main actor, so a yielded
    /// value only lands once the test hands control back. Bounded, so a regression fails in
    /// milliseconds rather than hanging the run.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("mirrors what is heard")
    func mirrorsTranscript() async {
        let engine = FakeVoiceEngine()
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()
        #expect(transcriber.isRecording)

        engine.send(.transcript("two eggs"))
        await settle { !transcriber.transcript.isEmpty }
        #expect(transcriber.transcript == "two eggs")

        engine.send(.transcript("two eggs and toast"))
        await settle { transcriber.transcript.contains("toast") }
        #expect(transcriber.transcript == "two eggs and toast")
    }

    /// The bug this file exists for. A start that threw part-way used to return without tearing
    /// down, because `stop` first checked whether anything was recording — and nothing was, yet.
    /// Whatever the engine had already set up stayed set up, and took the next attempt with it.
    @Test("tears the engine down when a start fails")
    func failedStartTearsDown() async {
        let engine = FakeVoiceEngine()
        engine.startError = .audioSessionFailed("engine wouldn't start")
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()

        #expect(engine.stops == 1)
        #expect(!transcriber.isRecording)
        #expect(transcriber.errorMessage?.contains("engine wouldn't start") == true)
    }

    @Test("a failed start doesn't prevent the next one")
    func recoversFromAFailedStart() async {
        let engine = FakeVoiceEngine()
        engine.startError = .noAudioInput
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()
        #expect(!transcriber.isRecording)

        await transcriber.start()
        #expect(transcriber.isRecording)
        #expect(engine.starts == 2)
        // The failure's explanation goes with it, rather than sitting under a session that is
        // now working.
        #expect(transcriber.errorMessage == nil)
    }

    @Test("stopping is safe when nothing is running")
    func stopWithoutStart() {
        let engine = FakeVoiceEngine()
        let transcriber = SpeechTranscriber(engine: engine)

        transcriber.stop()
        transcriber.stop()

        #expect(engine.stops == 2)
        #expect(!transcriber.isRecording)
    }

    @Test("explains a permission it was refused")
    func reportsDeniedPermission() async {
        let engine = FakeVoiceEngine()
        engine.authorizationError = .microphonePermissionDenied
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()

        #expect(transcriber.errorMessage == VoiceInputError.microphonePermissionDenied.userMessage)
        #expect(!transcriber.isRecording)
        #expect(engine.starts == 0)
    }

    /// The widget's Voice button is a deep link straight into recording, so it reaches this
    /// without the button — and therefore without the button's availability check — in the way.
    /// It has to say why rather than open a screen and sit there.
    @Test("explains itself when there is no recogniser to start")
    func reportsUnavailableRecognizer() async {
        let engine = FakeVoiceEngine()
        engine.isAvailable = false
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()

        #expect(transcriber.errorMessage == VoiceInputError.recognizerUnavailable.userMessage)
        #expect(!transcriber.isRecording)
        #expect(engine.starts == 0)
    }

    /// The first tap opens the permission prompt and then sits there, sometimes for as long as it
    /// takes to read it. `isRecording` is false the whole time, so a second tap used to walk
    /// straight past the guard and start a second session on top of the first.
    @Test("ignores a second tap while the permission prompt is up")
    func ignoresReentrantStart() async {
        let engine = FakeVoiceEngine()
        engine.pausesAuthorization = true
        let transcriber = SpeechTranscriber(engine: engine)

        let first = Task { await transcriber.start() }
        await settle { engine.isAwaitingAuthorization }

        await transcriber.start()
        #expect(engine.starts == 0)

        engine.releaseAuthorization()
        await first.value

        #expect(transcriber.isRecording)
        #expect(engine.starts == 1)
    }

    @Test("a session that ends having heard nothing says so")
    func silentSessionExplainsItself() async {
        let engine = FakeVoiceEngine()
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()
        engine.send(.ended(failed: true))
        await settle { !transcriber.isRecording }

        #expect(transcriber.errorMessage != nil)
        #expect(engine.stops == 1)
    }

    /// The words are already in the field and editable, which is what the user came for. Replacing
    /// them with an error would be a worse outcome than the error.
    @Test("keeps what was heard when the session ends badly")
    func keepsTranscriptOnFailure() async {
        let engine = FakeVoiceEngine()
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()
        engine.send(.transcript("a black coffee"))
        await settle { !transcriber.transcript.isEmpty }
        engine.send(.ended(failed: true))
        await settle { !transcriber.isRecording }

        #expect(transcriber.transcript == "a black coffee")
        #expect(transcriber.errorMessage == nil)
    }

    @Test("stops listening when the session finishes on its own")
    func finalResultStops() async {
        let engine = FakeVoiceEngine()
        let transcriber = SpeechTranscriber(engine: engine)

        await transcriber.start()
        engine.send(.ended(failed: false))
        await settle { !transcriber.isRecording }

        #expect(!transcriber.isRecording)
        #expect(transcriber.errorMessage == nil)
    }

    /// A recogniser that isn't ready at launch becomes ready a moment later, and the Voice button
    /// has to appear when it does — reading availability straight off `SFSpeechRecognizer`
    /// registered no dependency, so the button stayed hidden for the rest of the run.
    @Test("follows the recogniser in and out of availability")
    func tracksAvailability() async {
        let engine = FakeVoiceEngine()
        engine.isAvailable = false
        let transcriber = SpeechTranscriber(engine: engine)
        #expect(!transcriber.isAvailable)

        engine.becomeAvailable(true)
        await settle { transcriber.isAvailable }
        #expect(transcriber.isAvailable)

        engine.becomeAvailable(false)
        await settle { !transcriber.isAvailable }
        #expect(!transcriber.isAvailable)
    }

    /// Every one of these is read by someone holding a phone to their mouth wondering why nothing
    /// happened, so each has to be a sentence rather than a symptom.
    @Test("every failure to start says something a person can read")
    func everyErrorHasAMessage() {
        let errors: [VoiceInputError] = [
            .recognizerUnavailable, .onDeviceModelUnavailable, .speechPermissionDenied,
            .microphonePermissionDenied, .noAudioInput, .audioSessionFailed("no input node"),
        ]
        for error in errors {
            #expect(error.userMessage.hasSuffix("."))
            #expect(!error.userMessage.contains("Error"))
        }
    }
}
