import SwiftUI
import AppKit

enum VoicePillWindow {
    static let id = "voicePill"
    static let size = CGSize(width: 172, height: 56)
}

struct VoicePillRootView: View {
    let appModel: AstraAppModel

    var body: some View {
        VoicePillView()
            .environmentObject(appModel)
            .environmentObject(appModel.voiceStore)
    }
}

struct VoicePillView: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var appModel: AstraAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var voiceInput = VoiceInputManager()
    @State private var chatInput: String = ""
    @State private var resumeWakeListeningAfterVoice = false
    @State private var voiceSilenceWorkItem: DispatchWorkItem?
    @State private var voiceFallbackWorkItem: DispatchWorkItem?
    @State private var wakeStartRetryWorkItem: DispatchWorkItem?
    @State private var wakeStartRetryCount = 0
    @State private var lastVoiceTranscript: String = ""
    @State private var pillWindow: NSWindow?

    private let voiceSilenceTimeout: TimeInterval = 2.0
    private let initialSilenceTimeout: TimeInterval = 6.0
    private let wakeStartDelay: TimeInterval = 0.25
    private let wakeStartRetryDelay: TimeInterval = 1.2
    private let wakeStartRetryLimit = 1

    private var pillBackground: Color {
        Color(NSColor.controlBackgroundColor).opacity(colorScheme == .dark ? 0.7 : 0.92)
    }
    private var pillBorder: Color {
        Color(NSColor.separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.8)
    }
    private var buttonBackground: Color {
        Color(NSColor.controlBackgroundColor).opacity(colorScheme == .dark ? 0.85 : 0.78)
    }
    private var pillShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18)
    }
    private var iconColor: Color {
        Color(NSColor.secondaryLabelColor)
    }

    private var isEndingConversation: Bool {
        store.isVoiceConversationActive && !voiceInput.isRecording
    }

    private var micSymbol: String {
        if isEndingConversation { return "mic.slash" }
        return voiceInput.isRecording ? "mic.fill" : "mic"
    }

    private var micColor: Color {
        (voiceInput.isRecording || store.isVoiceConversationActive) ? .red : iconColor
    }

    private var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey && window != pillWindow
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            pillButton(symbol: micSymbol,
                       foreground: micColor,
                       help: isEndingConversation ? "End voice conversation"
                       : (voiceInput.isRecording ? "Stop voice input" : "Start voice input")) {
                toggleVoiceControl()
            }

            Divider()
                .frame(height: 20)
                .background(pillBorder)

            pillButton(symbol: "rectangle.on.rectangle",
                       foreground: iconColor,
                       help: "Open Astra window") {
                openMainWindow()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(pillBackground)
                .overlay(Capsule().stroke(pillBorder, lineWidth: 1))
                .shadow(color: pillShadow, radius: 10, x: 0, y: 6)
        )
        .frame(width: VoicePillWindow.size.width, height: VoicePillWindow.size.height)
        .background(PillWindowConfigurator())
        .background(WindowResolver { pillWindow = $0 })
        .onAppear {
            appModel.isVoicePillOpen = true
            handlePendingWakeWord()
        }
        .onDisappear {
            appModel.isVoicePillOpen = false
            endVoiceConversation()
        }
        .onChange(of: appModel.pendingWakeWord) { _ in
            handlePendingWakeWord()
        }
        .onChange(of: voiceInput.transcript) { newValue in
            guard voiceInput.isRecording else { return }
            if newValue != lastVoiceTranscript {
                lastVoiceTranscript = newValue
                resetVoiceSilenceTimer()
            }
            chatInput = newValue
        }
        .onChange(of: store.isVoiceConversationActive) { isActive in
            if !isActive {
                resumeWakeListeningIfNeeded()
            }
        }
        .onChange(of: store.voiceConversationResumeToken) { _ in
            resumeVoiceConversationInputIfNeeded()
        }
    }

    private func pillButton(symbol: String,
                            foreground: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(buttonBackground)
                        .overlay(Circle().stroke(pillBorder, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .foregroundColor(foreground)
        .help(help)
    }

    private func openMainWindow() {
        endVoiceConversation()
        openWindow(value: appModel.defaultBoardId)
        NSApp.activate(ignoringOtherApps: true)
        closeVoicePillWindow()
    }

    private func toggleVoiceControl() {
        if voiceInput.isRecording {
            stopVoiceInputAndSend()
        } else if store.isVoiceConversationActive {
            endVoiceConversation()
        } else {
            startVoiceInput(triggeredByWakeWord: false)
        }
    }

    private func startVoiceInput(triggeredByWakeWord: Bool) {
        appModel.pauseWakeListening()
        resumeWakeListeningAfterVoice = store.doc.chatSettings.alwaysListening
        syncActiveBoardIfNeeded()
        Task {
            let started = await voiceInput.startTranscribing(initialText: chatInput)
            if started {
                store.beginVoiceConversation()
                lastVoiceTranscript = voiceInput.transcript
                if triggeredByWakeWord {
                    scheduleWakeStartRetry()
                }
                scheduleFallbackStop()
                resetVoiceSilenceTimer()
            } else {
                store.endVoiceConversation()
                resumeWakeListeningIfNeeded()
            }
        }
    }

    private func stopVoiceInputAndSend() {
        guard voiceInput.isRecording else { return }
        voiceSilenceWorkItem?.cancel()
        voiceSilenceWorkItem = nil
        voiceFallbackWorkItem?.cancel()
        voiceFallbackWorkItem = nil
        wakeStartRetryWorkItem?.cancel()
        wakeStartRetryWorkItem = nil
        voiceInput.stopTranscribing { finalText in
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let textToSend = trimmed.isEmpty ? fallback : trimmed
            if !textToSend.isEmpty {
                let didSend = store.sendChat(text: textToSend, voiceInput: true)
                if didSend {
                    _ = store.persistence.save(doc: store.doc)
                    NotificationCenter.default.post(
                        name: .persistenceDidChange,
                        object: store.persistence,
                        userInfo: [PersistenceService.changeNotificationUserInfoKey: PersistenceService.ChangeEvent.board(store.currentBoardId)]
                    )
                }
            } else {
                store.endVoiceConversation()
                resumeWakeListeningIfNeeded()
            }
            chatInput = ""
            lastVoiceTranscript = ""
        }
    }

    private func endVoiceConversation() {
        voiceSilenceWorkItem?.cancel()
        voiceSilenceWorkItem = nil
        voiceFallbackWorkItem?.cancel()
        voiceFallbackWorkItem = nil
        wakeStartRetryWorkItem?.cancel()
        wakeStartRetryWorkItem = nil
        wakeStartRetryCount = 0
        lastVoiceTranscript = ""
        chatInput = ""
        if voiceInput.isRecording {
            voiceInput.cancelTranscribing()
        }
        store.stopSpeechPlayback()
        resumeWakeListeningIfNeeded()
    }

    private func resetVoiceSilenceTimer() {
        guard voiceInput.isRecording else { return }
        let trimmed = voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            scheduleFallbackStop()
            return
        }
        voiceFallbackWorkItem?.cancel()
        voiceFallbackWorkItem = nil
        wakeStartRetryWorkItem?.cancel()
        wakeStartRetryWorkItem = nil
        voiceSilenceWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard voiceInput.isRecording else { return }
            stopVoiceInputAndSend()
        }
        voiceSilenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + voiceSilenceTimeout, execute: work)
    }

    private func scheduleFallbackStop() {
        guard voiceInput.isRecording else { return }
        voiceFallbackWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard voiceInput.isRecording else { return }
            stopVoiceInputAndSend()
        }
        voiceFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + initialSilenceTimeout, execute: work)
    }

    private func handlePendingWakeWord() {
        guard appModel.pendingWakeWord else { return }
        guard !hasVisibleMainWindow else { return }
        appModel.markWakeWordHandled()
        guard store.doc.chatSettings.alwaysListening else { return }
        if voiceInput.isRecording || store.isVoiceConversationActive {
            return
        }
        syncActiveBoardIfNeeded()
        wakeStartRetryCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeStartDelay) {
            guard !voiceInput.isRecording else { return }
            guard !store.isVoiceConversationActive else { return }
            startVoiceInput(triggeredByWakeWord: true)
        }
    }

    private func resumeWakeListeningIfNeeded() {
        guard resumeWakeListeningAfterVoice else { return }
        resumeWakeListeningAfterVoice = false
        guard store.doc.chatSettings.alwaysListening else { return }
        appModel.resumeWakeListeningIfNeeded()
    }

    private func resumeVoiceConversationInputIfNeeded() {
        guard store.isVoiceConversationActive else { return }
        guard !voiceInput.isRecording else { return }
        guard !store.isSpeaking else { return }
        guard store.pendingChatReplies == 0 else { return }
        startVoiceInput(triggeredByWakeWord: false)
    }

    private func closeVoicePillWindow() {
        pillWindow?.performClose(nil)
    }

    private func syncActiveBoardIfNeeded() {
        let activeId = appModel.defaultBoardId
        guard store.currentBoardId != activeId else { return }
        store.switchBoard(id: activeId)
    }

    private func scheduleWakeStartRetry() {
        wakeStartRetryWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard voiceInput.isRecording else { return }
            let trimmed = voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty else { return }
            guard wakeStartRetryCount < wakeStartRetryLimit else { return }
            wakeStartRetryCount += 1
            voiceSilenceWorkItem?.cancel()
            voiceSilenceWorkItem = nil
            voiceFallbackWorkItem?.cancel()
            voiceFallbackWorkItem = nil
            voiceInput.cancelTranscribing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                startVoiceInput(triggeredByWakeWord: true)
            }
        }
        wakeStartRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeStartRetryDelay, execute: work)
    }
}

private struct PillWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}

private struct WindowResolver: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
