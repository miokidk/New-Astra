import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class VoiceWakeListener: NSObject, ObservableObject {
    @Published private(set) var isListening = false

    var onWake: (() -> Void)?

    private let speechRecognizer = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var shouldListen = false
    private var didTrigger = false

    func startListening() async -> Bool {
        if isListening {
            shouldListen = true
            return true
        }
        shouldListen = true
        return await startEngine()
    }

    func stopListening() {
        shouldListen = false
        restartWorkItem?.cancel()
        cleanup()
        isListening = false
    }

    private func startEngine() async -> Bool {
        guard await requestAuthorization() else { return false }
        guard let speechRecognizer, speechRecognizer.isAvailable else { return false }

        didTrigger = false
        cleanup()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = ["Astra"]
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
                    self.handleTranscript(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.restartIfNeeded()
                    }
                }
                if error != nil {
                    self.restartIfNeeded()
                }
            }
        }

        isListening = true
        return true
    }

    private func handleTranscript(_ text: String) {
        guard !didTrigger else { return }
        guard containsWakeWord(in: text) else { return }
        didTrigger = true
        stopListening()
        onWake?()
    }

    private func restartIfNeeded() {
        guard shouldListen else { return }
        cleanup()
        isListening = false
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.startEngine()
            }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
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

    private func containsWakeWord(in text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter }
        for token in tokens {
            if token == "astra" { return true }
            if token.hasPrefix("astra"), token.count <= 6 { return true }
        }
        return false
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
