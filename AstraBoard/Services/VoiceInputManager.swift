import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class VoiceInputManager: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""

    private let speechRecognizer = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptPrefix = ""
    private var didFinalize = false
    private var finalHandler: ((String) -> Void)?

    func startTranscribing(initialText: String) async -> Bool {
        guard !isRecording else { return true }
        guard await requestAuthorization() else { return false }
        guard let speechRecognizer, speechRecognizer.isAvailable else { return false }

        didFinalize = false
        finalHandler = nil
        transcriptPrefix = normalizedPrefix(from: initialText)
        transcript = transcriptPrefix

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            engine.prepare()
            try engine.start()
        } catch {
            cleanup()
            return false
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let combined = self.combinedTranscript(prefix: self.transcriptPrefix,
                                                           transcription: result.bestTranscription.formattedString)
                    self.transcript = combined
                    if result.isFinal {
                        self.finalizeIfNeeded(text: combined)
                    }
                }
                if error != nil {
                    self.finalizeIfNeeded(text: self.transcript)
                }
            }
        }

        isRecording = true
        return true
    }

    func stopTranscribing(onFinal: @escaping (String) -> Void) {
        guard isRecording else { return }
        finalHandler = onFinal
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor in
                self?.finalizeIfNeeded(text: self?.transcript ?? "")
            }
        }
    }

    func cancelTranscribing() {
        guard isRecording else { return }
        finalHandler = nil
        didFinalize = true
        cleanup()
        isRecording = false
    }

    private func finalizeIfNeeded(text: String) {
        guard !didFinalize else { return }
        didFinalize = true
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        finalHandler?(finalText)
        finalHandler = nil
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func normalizedPrefix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if text.hasSuffix(" ") || text.hasSuffix("\n") {
            return text
        }
        return text + " "
    }

    private func combinedTranscript(prefix: String, transcription: String) -> String {
        if prefix.isEmpty { return transcription }
        if transcription.isEmpty { return prefix }
        return prefix + transcription
    }

    private func requestAuthorization() async -> Bool {
        let speechOK = await requestSpeechAuthorization()
        guard speechOK else { return false }
        return await requestMicrophoneAuthorization()
    }

    private func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            return true
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
}
