import AVFoundation
import Foundation
import Observation
import Speech

/// Transcribes speech to text **on the device**.
///
/// `requiresOnDeviceRecognition = true` is the point of this type, not an optimisation. Left off,
/// `SFSpeechRecognizer` uploads audio to Apple's servers for transcription — which would quietly
/// break the app's promise that the only thing leaving the device is the text you chose to send
/// to your own LLM key. On-device recognition is somewhat less accurate; that is the right trade
/// here, and the text is editable before it is logged anyway.
@Observable
@MainActor
final class SpeechTranscriber {
    /// Live transcript, updated as the user speaks.
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// False when the device or locale has no on-device model, so the UI can hide voice input
    /// rather than offering a button that fails.
    var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Requests both permissions this needs: speech recognition and the microphone.
    ///
    /// Both, because they are genuinely separate grants and being denied either one makes voice
    /// logging impossible — asking for one and discovering the other at record time would show
    /// the user a failure instead of a prompt.
    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else {
            errorMessage = "Speech recognition permission was declined. You can enable it in Settings."
            return false
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        if !micGranted {
            errorMessage = "Microphone access was declined. You can enable it in Settings."
        }
        return micGranted
    }

    func start() async {
        guard !isRecording else { return }

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        guard await requestAuthorization() else { return }

        transcript = ""
        errorMessage = nil

        do {
            try configureAudioSession()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // The load-bearing line — see the type's documentation.
            request.requiresOnDeviceRecognition = true
            self.request = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    // Any error, or a final result, means this session is over.
                    if error != nil || result?.isFinal == true {
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            stop()
        }
    }

    /// Stops recording and leaves ``transcript`` holding whatever was heard.
    func stop() {
        guard isRecording || task != nil else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }

        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false

        // Hand the audio session back so other audio — music, a podcast the user paused —
        // can resume.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.record` rather than `.playAndRecord`: Tally plays nothing, and the narrower category
        // is less disruptive to whatever else is making sound.
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
