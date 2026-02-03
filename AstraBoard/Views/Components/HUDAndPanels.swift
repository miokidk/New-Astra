import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import Supabase

extension NSAttributedString.Key {
    static let codeBlockMarker = NSAttributedString.Key("codeBlockMarker")
}

final class ChatInputFocusBridge {
    static let shared = ChatInputFocusBridge()
    weak var textView: PasteAwareTextField.PasteAwareTextView?
    private var pendingCaretToEnd = false

    func register(_ textView: PasteAwareTextField.PasteAwareTextView) {
        self.textView = textView
    }

    func requestFocus(moveCaretToEnd: Bool) {
        if moveCaretToEnd {
            pendingCaretToEnd = true
        }
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if moveCaretToEnd {
            moveCaretToEndIfPossible()
        }
    }

    func syncCaretToEndIfNeeded() {
        guard pendingCaretToEnd, textView != nil else { return }
        moveCaretToEndIfPossible()
        pendingCaretToEnd = false
    }

    private func moveCaretToEndIfPossible() {
        guard let textView else { return }
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }
}


// MARK: - Find Bar (Cmd+F / Cmd+G)

private struct FindBarView: View {
    @Binding var isVisible: Bool
    @Binding var query: String
    var matchSummary: String
    var onNext: () -> Void
    var onPrev: () -> Void
    var onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .focused($fieldFocused)
                    .onSubmit { onNext() }

                Text(matchSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: onPrev) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .help("Find Previous (⇧⌘G)")

                Button(action: onNext) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .help("Find Next (⌘G)")

                Button(action: {
                    onClose()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            .onChange(of: isVisible) { v in
                if v { DispatchQueue.main.async { fieldFocused = true } }
            }
#if os(macOS)
            .onExitCommand { onClose() }
#endif
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var appModel: AstraAppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var chatInput: String
    var onSend: (Bool) -> Void
    
    @State private var dragOffset: CGSize = .zero
    @State private var inputHeight: CGFloat = 56
    @State private var chatPanelHeight: CGFloat = ChatDockedPanelView.collapsedHeight()
    @State private var isMultiLineInput = false
    @State private var textFieldKey: UUID = UUID() // Add this to force refresh
    @State private var suppressToggleAfterDrag = false
    @StateObject private var voiceInput = VoiceInputManager()
    @State private var resumeWakeListeningAfterVoice = false
    @State private var voiceSilenceWorkItem: DispatchWorkItem?
    @State private var lastVoiceTranscript: String = ""

    private let baseInputHeight: CGFloat = 56
    private let inputVerticalPadding: CGFloat = 20
    private let voiceSilenceTimeout: TimeInterval = 2.0
    private let chatPanelSpacing: CGFloat = 4
    private let chatPanelOverlap: CGFloat = 18
    private var chatPanelHorizontalInset: CGFloat { baseInputHeight / 2 }

    private var bubbleColor: Color {
        Color(NSColor.controlBackgroundColor).opacity(colorScheme == .dark ? 0.65 : 0.42)
    }
    private var iconColor: Color {
        Color(NSColor.secondaryLabelColor)
    }
    private var accentBorder: Color {
        Color(NSColor.separatorColor)
    }
    private var activeBorder: Color {
        Color(NSColor.labelColor).opacity(colorScheme == .dark ? 0.6 : 0.45)
    }
    private var pulseBorder: Color {
        Color(NSColor.labelColor).opacity(colorScheme == .dark ? 0.75 : 0.65)
    }
    private var hudShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08)
    }

    var body: some View {
        if store.doc.ui.hud.isVisible {
            let size = hudSize()
            ZStack(alignment: .bottom) {
                ChatDockedPanelView(isCollapsed: !store.doc.ui.panels.chat.isOpen,
                                    chatInput: $chatInput,
                                    onSend: onSend,
                                    maxHeight: chatPanelMaxHeight,
                                    onHeightChange: { height in
                                        chatPanelHeight = height
                                    })
                    .frame(width: max(0, size.width - chatPanelHorizontalInset * 2))
                    .padding(.bottom, panelBottomPadding(for: size.height))
                hudBar(size: size)
            }
            .frame(width: size.width)
            .offset(x: store.doc.ui.hud.x.cg + dragOffset.width,
                    y: hudStackOffsetY)
            .onChange(of: store.doc.ui.panels.chat.isOpen) { isOpen in
                // Ensure the bar stays anchored during expand/collapse even before the panel reports its height.
                withAnimation(.easeInOut(duration: 0.18)) {
                    chatPanelHeight = isOpen
                        ? ChatDockedPanelView.expandedMinimumHeight(maxHeight: chatPanelMaxHeight)
                        : ChatDockedPanelView.collapsedHeight()
                }
                updateHudExtraHeight()
            }
            .onChange(of: chatInput) { newValue in
                let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isEmpty {
                    inputHeight = baseInputHeight
                    isMultiLineInput = false
                    textFieldKey = UUID() // Force text field to recreate
                    updateHudExtraHeight()
                }
            }
            .onChange(of: inputHeight) { _ in
                updateHudExtraHeight()
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
            .onAppear {
                handlePendingWakeWord()
                // Keep the bar anchored if the chat panel is persisted open.
                chatPanelHeight = store.doc.ui.panels.chat.isOpen
                    ? ChatDockedPanelView.expandedMinimumHeight(maxHeight: chatPanelMaxHeight)
                    : ChatDockedPanelView.collapsedHeight()
                updateHudExtraHeight()
            }
            .onChange(of: appModel.pendingWakeWord) { _ in
                handlePendingWakeWord()
            }
        } else {
            // Collapsed HUD: show a draggable button at the HUD's last position.
            HUDIconButton(symbol: "rectangle.on.rectangle.angled",
                          size: baseInputHeight,
                          isActive: false,
                          isPulsing: false,
                          showsBadge: false,
                          bubbleColor: bubbleColor,
                          iconColor: iconColor,
                          accentBorder: accentBorder,
                          activeBorder: activeBorder,
                          pulseBorder: pulseBorder) {
                if suppressToggleAfterDrag { return }
                store.toggleHUD()
            }
            .offset(x: store.doc.ui.hud.x.cg + dragOffset.width,
                    y: hudOffsetY)
            .simultaneousGesture(hudDragGesture())
        }
    }

    private func hudButton(symbol: String,
                           isActive: Bool = false,
                           isPulsing: Bool = false,
                           showsBadge: Bool = false,
                           action: @escaping () -> Void) -> some View {
        HUDIconButton(symbol: symbol,
                      size: baseInputHeight,
                      isActive: isActive,
                      isPulsing: isPulsing,
                      showsBadge: showsBadge,
                      bubbleColor: bubbleColor,
                      iconColor: iconColor,
                      accentBorder: accentBorder,
                      activeBorder: activeBorder,
                      pulseBorder: pulseBorder,
                      action: action)
    }

    private func hudBar(size: CGSize) -> some View {
        Capsule()
            .fill(barColor)
            .shadow(color: hudShadowColor, radius: 10, x: 0, y: 8)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .center) {
                HStack(alignment: .center, spacing: 6) {
                    hudButton(symbol: "xmark") { store.toggleHUD() }

                    inputFieldContainer
                        .id(textFieldKey) // Add key to force recreation
                    if !store.chatDraftImages.isEmpty || !store.chatDraftFiles.isEmpty {
                        hudAttachmentStack
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .foregroundColor(iconColor)
            .simultaneousGesture(hudDragGesture())
    }

    private var inputField: some View {
        ZStack {
            if isMultiLineInput {
                RoundedRectangle(cornerRadius: 18)
                    .fill(bubbleColor)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(accentBorder, lineWidth: 1))
            } else {
                Capsule()
                    .fill(bubbleColor)
                    .overlay(Capsule().stroke(accentBorder, lineWidth: 1))
            }
            PasteAwareTextField(text: $chatInput,
                                placeholder: "Hm?",
                                onCommit: { onSend(false) },
                                onPasteAttachment: { store.attachChatAttachmentsFromPasteboard() },
                                font: hudInputFont,
                                textColor: hudInputColor,
                                onHeightChange: { newHeight in
                                    let isEmpty = chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    let singleLineThreshold = baseInputHeight - inputVerticalPadding + 2
                                    let multiLine = newHeight > singleLineThreshold
                                    if isMultiLineInput != multiLine {
                                        isMultiLineInput = multiLine
                                    }
                                    if !isEmpty {
                                        let paddedHeight = newHeight + inputVerticalPadding
                                        let clampedHeight = max(baseInputHeight, paddedHeight)
                                        if abs(clampedHeight - inputHeight) > 0.5 {
                                            inputHeight = clampedHeight
                                        }
                                    }
                                },
                                isBordered: false,
                                drawsBackground: false,
                                focusRingType: .none,
                                bezelStyle: .squareBezel)
                .padding(.leading, 14)
                .padding(.trailing, 44)
                .padding(.vertical, 10)
        }
        .overlay(alignment: .topLeading) {
            if hasChatInputText {
                Button(action: pinChatInputText) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(bubbleColor)
                                .overlay(Circle().stroke(accentBorder, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .foregroundColor(iconColor)
                .padding(.leading, 2)
                .padding(.top, 2)
                .help("Pin to board")
            }
        }
        .overlay(alignment: .trailing) {
            voiceButton
                .padding(.trailing, 10)
        }
        .frame(height: inputHeight)
    }

    private var inputFieldContainer: some View {
        Color.clear
            .frame(height: baseInputHeight)
            .overlay(alignment: .bottom) {
                inputField
            }
    }

    private var hudAttachmentStack: some View {
        HStack(spacing: 6) {
            if !store.chatDraftImages.isEmpty {
                hudImageStack
            }
            if !store.chatDraftFiles.isEmpty {
                hudFileStack
            }
        }
    }

    private var hudImageStack: some View {
        let stackSpacing: CGFloat = 6
        let count = store.chatDraftImages.count
        let stackSize = 40 + CGFloat(max(0, count - 1)) * stackSpacing
        return ZStack(alignment: .topTrailing) {
            ForEach(Array(store.chatDraftImages.enumerated()), id: \.element) { index, imageRef in
                let depthOffset = CGFloat(max(0, count - 1 - index)) * stackSpacing
                ChatAttachmentThumbnail(imageRef: imageRef, size: 40, cornerRadius: 8)
                    .offset(x: depthOffset, y: depthOffset)
            }
            if let topRef = store.chatDraftImages.last {
                Button(action: { store.removeChatDraftImage(topRef) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .background(Circle().fill(bubbleColor))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove top attachment")
            }
        }
        .frame(width: stackSize, height: stackSize)
    }

    private var hudFileStack: some View {
        let stackSpacing: CGFloat = 6
        let count = store.chatDraftFiles.count
        let stackSize = 40 + CGFloat(max(0, count - 1)) * stackSpacing
        return ZStack(alignment: .topTrailing) {
            ForEach(Array(store.chatDraftFiles.enumerated()), id: \.element) { index, fileRef in
                let depthOffset = CGFloat(max(0, count - 1 - index)) * stackSpacing
                ChatFileThumbnail(fileRef: fileRef, size: 40, cornerRadius: 8)
                    .offset(x: depthOffset, y: depthOffset)
            }
            if let topRef = store.chatDraftFiles.last {
                Button(action: { store.removeChatDraftFile(topRef) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .background(Circle().fill(bubbleColor))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove top attachment")
            }
        }
        .frame(width: stackSize, height: stackSize)
    }

    private func hudDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                suppressToggleAfterDrag = true
                store.isDraggingOverlay = true
                dragOffset = value.translation
            }
            .onEnded { value in
                store.moveHUD(by: value.translation)
                dragOffset = .zero
                store.clampHUDPosition()
                store.isDraggingOverlay = false

                // give the system a beat so the drag end doesn't count as a tap
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    suppressToggleAfterDrag = false
                }
            }
    }

    private func hudSize() -> CGSize {
        BoardStore.hudSize
    }

    private var chatPanelMaxHeight: CGFloat {
        let fallback: CGFloat = 360
        guard store.viewportSize.height > 0 else { return fallback }
        let viewportCap = min(fallback, max(200, store.viewportSize.height * 0.45))
        return viewportCap
    }

    private var inputExtraHeight: CGFloat {
        max(0, inputHeight - baseInputHeight)
    }

    private func updateHudExtraHeight() {
        let next = inputExtraHeight
        if abs(store.hudExtraHeight - next) > 0.5 {
            store.hudExtraHeight = next
        }
    }

    private var panelAboveBar: CGFloat {
        max(0, chatPanelHeight - actualChatPanelOverlap)
    }

    private func panelBottomPadding(for barHeight: CGFloat) -> CGFloat {
        max(0, barHeight - actualChatPanelOverlap)
    }

    private var actualChatPanelOverlap: CGFloat {
        max(0, chatPanelOverlap - chatPanelSpacing)
    }

    private var hudInputFont: NSFont {
        let base = NSFont.systemFont(ofSize: 22, weight: .medium)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: 22) {
            return rounded
        }
        return base
    }

    private var hudInputColor: NSColor {
        NSColor.labelColor
    }

    private var barColor: Color {
        let baseColor = store.doc.ui.hudBarColor
        let adjustedColor = colorScheme == .dark ? baseColor.darkened(by: 0.55) : baseColor
        return adjustedColor.color.opacity(store.doc.ui.hudBarOpacity)
    }

    private var hudOffsetY: CGFloat {
        let baseY = store.doc.ui.hud.y.cg + dragOffset.height
        if store.isDraggingOverlay {
            return baseY
        }
        let minY = max(0, store.hudExtraHeight)
        return max(baseY, minY)
    }

    private var hudStackOffsetY: CGFloat {
        hudOffsetY - panelAboveBar
    }

    private var hasChatInputText: Bool {
        !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var voiceButton: some View {
        let isEndingConversation = store.isVoiceConversationActive && !voiceInput.isRecording
        return Button(action: toggleVoiceInput) {
            let symbol = isEndingConversation ? "mic.slash" : (voiceInput.isRecording ? "mic.fill" : "mic")
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(bubbleColor)
                        .overlay(
                            Circle().stroke(voiceInput.isRecording ? Color.red.opacity(0.7) : accentBorder,
                                            lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundColor((voiceInput.isRecording || isEndingConversation) ? Color.red : iconColor)
        .help(isEndingConversation ? "End voice conversation"
              : (voiceInput.isRecording ? "Stop voice input" : "Start voice input"))
    }

    private func pinChatInputText() {
        let text = chatInput
        if store.pinChatInputText(text) {
            chatInput = ""
        }
    }

    private func toggleVoiceInput() {
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
        if triggeredByWakeWord {
            if !store.doc.ui.hud.isVisible {
                store.toggleHUD()
            }
            if !store.doc.ui.panels.chat.isOpen {
                store.togglePanel(.chat)
            }
        }
        Task {
            let started = await voiceInput.startTranscribing(initialText: chatInput)
            if started {
                store.beginVoiceConversation()
                lastVoiceTranscript = voiceInput.transcript
                resetVoiceSilenceTimer()
                ChatInputFocusBridge.shared.requestFocus(moveCaretToEnd: true)
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
        voiceInput.stopTranscribing { finalText in
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            chatInput = trimmed
            if !trimmed.isEmpty {
                onSend(true)
            } else {
                store.endVoiceConversation()
                resumeWakeListeningIfNeeded()
            }
            lastVoiceTranscript = ""
        }
    }

    private func endVoiceConversation() {
        voiceSilenceWorkItem?.cancel()
        voiceSilenceWorkItem = nil
        lastVoiceTranscript = ""
        if voiceInput.isRecording {
            voiceInput.cancelTranscribing()
        }
        store.stopSpeechPlayback()
        resumeWakeListeningIfNeeded()
    }

    private func resetVoiceSilenceTimer() {
        guard voiceInput.isRecording else { return }
        voiceSilenceWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard voiceInput.isRecording else { return }
            stopVoiceInputAndSend()
        }
        voiceSilenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + voiceSilenceTimeout, execute: work)
    }

    private func handlePendingWakeWord() {
        guard appModel.pendingWakeWord else { return }
        appModel.markWakeWordHandled()
        guard store.doc.chatSettings.alwaysListening else { return }
        if voiceInput.isRecording || store.isVoiceConversationActive {
            return
        }
        startVoiceInput(triggeredByWakeWord: true)
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
}

private struct HUDIconButton: View {
    let symbol: String
    let size: CGFloat
    let isActive: Bool
    let isPulsing: Bool
    let showsBadge: Bool
    let bubbleColor: Color
    let iconColor: Color
    let accentBorder: Color
    let activeBorder: Color
    let pulseBorder: Color
    let action: () -> Void

    @State private var pulsePhase = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(bubbleColor)
                        .overlay(
                            Circle().stroke(isActive ? activeBorder : accentBorder,
                                            lineWidth: 1.5)
                        )
                        .overlay(
                            Circle().stroke(pulseBorder, lineWidth: 2)
                                .opacity(isPulsing ? (pulsePhase ? 1 : 0.2) : 0)
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if showsBadge {
                        Text("!")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.red.opacity(0.85)))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundColor(iconColor)
        .onAppear {
            updatePulse(isPulsing)
        }
        .onChange(of: isPulsing) { value in
            updatePulse(value)
        }
    }

    private func updatePulse(_ shouldPulse: Bool) {
        if shouldPulse {
            pulsePhase = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        } else {
            pulsePhase = false
        }
    }
}

struct FloatingPanelHostView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            panelView(for: .chatArchive)
            panelView(for: .log)
            panelView(for: .memories)
            panelView(for: .shapeStyle)
            panelView(for: .settings)
            panelView(for: .reminder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func panelView(for kind: PanelKind) -> some View {
        switch kind {
        case .chat:
            if store.doc.ui.panels.chat.isOpen {
                FloatingPanelView(panelKind: .chat, title: "Chat", box: store.doc.ui.panels.chat, onUpdate: { frame in
                    store.updatePanel(.chat, frame: frame)
                }, onClose: {
                    store.togglePanel(.chat)
                }) {
                    ChatPanelView(chatInput: $chatInput, onSend: onSend)
                }
            }
        case .chatArchive:
            if store.doc.ui.panels.chatArchive.isOpen {
                FloatingPanelView(panelKind: .chatArchive, title: "Chat Archive", box: store.doc.ui.panels.chatArchive, onUpdate: { frame in
                    store.updatePanel(.chatArchive, frame: frame)
                }, onClose: {
                    store.togglePanel(.chatArchive)
                }) {
                    ChatArchivePanelView()
                }
            }
        case .log:
            if store.doc.ui.panels.log.isOpen {
                FloatingPanelView(panelKind: .log, title: "Log", box: store.doc.ui.panels.log, onUpdate: { frame in
                    store.updatePanel(.log, frame: frame)
                }, onClose: {
                    store.togglePanel(.log)
                }) {
                    LogPanelView()
                }
            }

        case .memories:
            if store.doc.ui.panels.memories.isOpen {
                FloatingPanelView(panelKind: .memories, title: "Memories", box: store.doc.ui.panels.memories, onUpdate: { frame in
                    store.updatePanel(.memories, frame: frame)
                }, onClose: {
                    store.togglePanel(.memories)
                }) {
                    MemoriesPanelView()
                }
            }
        case .shapeStyle:
            if store.doc.ui.panels.shapeStyle.isOpen, store.hasStyleSelection {
                FloatingPanelView(panelKind: .shapeStyle, title: "Style", box: store.doc.ui.panels.shapeStyle, onUpdate: { frame in
                    store.updatePanel(.shapeStyle, frame: frame)
                }, onClose: {
                    store.togglePanel(.shapeStyle)
                }) {
                    StylePanelView()
                }
            }
        case .settings:
            if store.doc.ui.panels.settings.isOpen {
                FloatingPanelView(panelKind: .settings, title: "Settings", box: store.doc.ui.panels.settings, onUpdate: { frame in
                    store.updatePanel(.settings, frame: frame)
                }, onClose: {
                    store.togglePanel(.settings)
                }, isResizable: false) {
                    SettingsPanelView()
                }
            }
        case .reminder:
            ReminderPanel()
        }
    }
}

struct FloatingPanelView<Content: View>: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    var panelKind: PanelKind
    var title: String
    var box: PanelBox
    var onUpdate: (CGRect) -> Void
    var onClose: () -> Void
    var isResizable: Bool = true
    @ViewBuilder var content: Content
    private var headerBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.85 : 0.7)
    }
    private var panelBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0.82)
    }
    private var panelBorder: Color {
        Color.clear
    }
    private var panelShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15)
    }

    var body: some View {
        let minSize = BoardStore.panelMinSize(for: panelKind)
        let frame = CGRect(x: box.x.cg,
                           y: box.y.cg,
                           width: max(minSize.width, box.w.cg),
                           height: max(minSize.height, box.h.cg))

        return panelBody(frame: frame, minSize: minSize)
    }

    private func panelBody(frame: CGRect, minSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Text(title).font(.headline)
                Spacer()
            }
            .padding(8)
            .background(headerBackground)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        store.isDraggingOverlay = true
                        let next = frame.offsetBy(dx: value.translation.width,
                                                  dy: value.translation.height)
                        onUpdate(next)
                    }
                    .onEnded { _ in
                        store.isDraggingOverlay = false
                    }
            )

            Divider()
            content
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: frame.width, height: frame.height)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(panelBorder, lineWidth: 1))
                .shadow(color: panelShadow, radius: 10, x: 0, y: 4)
        )
        .overlay(alignment: .topLeading) {
            if isResizable {
                PanelResizeHandles(
                    frame: frame,
                    minSize: minSize,
                    panelKind: panelKind,
                    onUpdate: onUpdate
                )
                .frame(width: frame.width, height: frame.height)
                .clipped()
            }
        }
        .offset(x: frame.minX, y: frame.minY)
    }
}

// MARK: - Auto-scrolling Panels

private enum ChatScrollAnchor {
    static let bottom = "CHAT_BOTTOM_ANCHOR"
}

private final class ChatScrollState {
    var isPinnedToBottom: Bool = true
    var autoScrollWorkItem: DispatchWorkItem?
    weak var scrollView: NSScrollView?
    var lastContentHeight: CGFloat = 0
}

private struct ChatScrollObserver: NSViewRepresentable {
    var onScroll: (NSScrollView) -> Void
    var onContentSizeChange: (NSScrollView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onContentSizeChange: onContentSizeChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onContentSizeChange = onContentSizeChange
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator: NSObject {
        var onScroll: (NSScrollView) -> Void
        var onContentSizeChange: (NSScrollView) -> Void
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var pendingAttach = false

        init(onScroll: @escaping (NSScrollView) -> Void,
             onContentSizeChange: @escaping (NSScrollView) -> Void) {
            self.onScroll = onScroll
            self.onContentSizeChange = onContentSizeChange
        }

        func attach(to view: NSView) {
            guard scrollView == nil else { return }
            if let sv = findEnclosingScrollView(from: view) {
                attach(scrollView: sv)
            } else if !pendingAttach {
                pendingAttach = true
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.pendingAttach = false
                    self.attach(to: view)
                }
            }
        }

        private func findEnclosingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let node = current {
                if let sv = node as? NSScrollView {
                    return sv
                }
                if let sv = node.enclosingScrollView {
                    return sv
                }
                current = node.superview
            }
            return nil
        }

        private func attach(scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let sv = self.scrollView else { return }
                self.onScroll(sv)
            }
            if let docView = scrollView.documentView {
                docView.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: docView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, let sv = self.scrollView else { return }
                    self.onContentSizeChange(sv)
                }
            }
            onScroll(scrollView)
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }
    }
}

private struct ChatDockedPanelView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    let isCollapsed: Bool
    @Binding var chatInput: String
    var onSend: (Bool) -> Void
    let maxHeight: CGFloat
    var onHeightChange: ((CGFloat) -> Void)? = nil

    @State private var scrollState = ChatScrollState()
    @State private var contentHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0
    @FocusState private var panelFocused: Bool

    @State private var isFindVisible: Bool = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0
    @State private var pendingFindCommand: FindCommand?

    private enum Layout {
        static let cornerRadius: CGFloat = 18
        static let contentPadding: CGFloat = 12
        static let headerHeight: CGFloat = 30
        static let dividerHeight: CGFloat = 1
        static let pinThreshold: CGFloat = 12
        static let minContentHeight: CGFloat = 140
    }

    static func collapsedHeight() -> CGFloat {
        Layout.headerHeight + Layout.contentPadding * 2
    }

    static func expandedMinimumHeight(maxHeight: CGFloat) -> CGFloat {
        Layout.headerHeight + Layout.dividerHeight + min(maxHeight, Layout.minContentHeight) + Layout.contentPadding * 2
    }

    private var panelBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0.9)
    }

    private var panelBorder: Color {
        Color(NSColor.separatorColor).opacity(colorScheme == .dark ? 0.7 : 0.55)
    }

    private var panelShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12)
    }

    private var headerIconColor: Color {
        Color(NSColor.secondaryLabelColor)
    }

    private var scrollHeight: CGFloat {
        min(maxHeight, max(contentHeight, Layout.minContentHeight))
    }

    private var totalPanelHeight: CGFloat {
        if isCollapsed {
            return Self.collapsedHeight()
        }
        return Layout.headerHeight + Layout.dividerHeight + scrollHeight + Layout.contentPadding * 2
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scrollState.autoScrollWorkItem?.cancel()

        let item = DispatchWorkItem {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                }
            } else {
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                }
            }
        }

        scrollState.autoScrollWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private enum FindCommand: Equatable {
        case open
        case next
        case prev
        case close
    }

    private func updatePinnedState(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        scrollState.scrollView = scrollView
        let docHeight = docView.bounds.height
        if abs(contentHeight - docHeight) > 0.5 {
            contentHeight = docHeight
        }
        if scrollState.lastContentHeight <= 0 {
            scrollState.lastContentHeight = docHeight
        }
        let maxOffset = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        let currentOffset = scrollView.contentView.bounds.origin.y
        let distanceFromBottom: CGFloat
        if docView.isFlipped {
            distanceFromBottom = max(0, maxOffset - currentOffset)
        } else {
            distanceFromBottom = max(0, currentOffset)
        }
        let pinnedNow = distanceFromBottom <= Layout.pinThreshold
        if pinnedNow != scrollState.isPinnedToBottom {
            scrollState.isPinnedToBottom = pinnedNow
            if !pinnedNow {
                scrollState.autoScrollWorkItem?.cancel()
            }
        }
    }

    private func scrollToBottom(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        let maxOffset = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        let targetOffset = docView.isFlipped ? maxOffset : 0
        let currentOffset = scrollView.contentView.bounds.origin.y
        if abs(currentOffset - targetOffset) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func handleContentSizeChange(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        scrollState.scrollView = scrollView
        let newHeight = docView.bounds.height
        let oldHeight = scrollState.lastContentHeight
        scrollState.lastContentHeight = newHeight
        if abs(contentHeight - newHeight) > 0.5 {
            contentHeight = newHeight
        }

        guard scrollState.isPinnedToBottom else { return }
        guard oldHeight > 0 else {
            scrollToBottom(using: scrollView)
            return
        }

        if docView.isFlipped {
            let delta = newHeight - oldHeight
            if abs(delta) > 0.5 {
                let maxOffset = max(0, newHeight - scrollView.contentView.bounds.height)
                let currentOffset = scrollView.contentView.bounds.origin.y
                let targetOffset = min(max(0, currentOffset + delta), maxOffset)
                if abs(currentOffset - targetOffset) > 0.5 {
                    scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetOffset))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            scrollToBottom(using: scrollView)
        }
    }

    private var warningView: some View {
        Group {
            if let warning = store.chatWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }
        }
    }

    private func rebuildFindMatches() {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }

        let ids = store.doc.chat.messages
            .filter { $0.text.localizedCaseInsensitiveContains(q) }
            .map { $0.id }

        findMatches = ids
        if findIndex >= ids.count { findIndex = 0 }
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard isFindVisible, !findMatches.isEmpty else { return }
        let id = findMatches[findIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func applyFindCommand(_ cmd: FindCommand, proxy: ScrollViewProxy) {
        switch cmd {
        case .open:
            isFindVisible = true
            rebuildFindMatches()
            scrollToCurrentMatch(proxy: proxy)
        case .next:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches()
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + 1) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .prev:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches()
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .close:
            isFindVisible = false
        }
    }

    private var canStartNewChat: Bool {
        !store.doc.chat.messages.isEmpty || store.chatWarning != nil
    }

    private var findTarget: FindTarget {
        FindTarget(
            presentFind: { pendingFindCommand = .open },
            findNext: { pendingFindCommand = .next },
            findPrev: { pendingFindCommand = .prev },
            closeFind: { pendingFindCommand = .close }
        )
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.togglePanel(.chat)
                }
            }) {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(headerIconColor)
            .help(isCollapsed ? "Expand chat" : "Collapse chat")

            if store.pendingChatReplies > 0 {
                headerIconButton(symbol: "stop.fill", help: "Stop response") {
                    store.stopChatReplies()
                }
            }
            if store.isSpeaking {
                headerIconButton(symbol: "speaker.slash.fill", help: "Stop voice") {
                    store.stopSpeechPlayback()
                }
            }

            Spacer()

            Button("New Chat") {
                store.startNewChat()
                chatInput = ""
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(headerIconColor)
            .disabled(!canStartNewChat)
        }
        .padding(.horizontal, 8)
    }

    private func headerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(4)
        }
        .buttonStyle(.plain)
        .foregroundColor(headerIconColor)
        .help(help)
    }

    var body: some View {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchSummary: String = {
            if q.isEmpty { return "Type to search" }
            if findMatches.isEmpty { return "No matches" }
            return "\(findIndex + 1) of \(findMatches.count)"
        }()

        ZStack {
            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                .fill(panelBackground)
            ChatPanelBackground()
                .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                headerRow
                    .frame(height: Layout.headerHeight)

                if !isCollapsed {
                    Divider()

                    ScrollViewReader { proxy in
                        ZStack(alignment: .top) {
                            ScrollView(showsIndicators: contentHeight > maxHeight) {
                                VStack(alignment: .leading, spacing: 14) {
                                    warningView

                                    ForEach(Array(store.doc.chat.messages.enumerated()), id: \.element.id) { index, msg in
                                        let canRetry = false
                                        let canEdit = store.pendingChatReplies == 0 && msg.role == .user
                                        let isStreamingAssistant = store.pendingChatReplies > 0 &&
                                            index == store.doc.chat.messages.count - 1 &&
                                            msg.role == .assistant
                                        let isLastAssistant = index == store.doc.chat.messages.count - 1 && msg.role == .assistant
                                        let activityText: String? = isStreamingAssistant ? store.chatActivityStatus : nil
                                        let thinkingText: String? = isLastAssistant ? store.chatThinkingText : nil

                                        ChatMessageRow(
                                            message: msg,
                                            showsRetry: canRetry,
                                            onRetry: { store.retryChatReply(messageId: msg.id) },
                                            showsEdit: canEdit,
                                            activityText: activityText,
                                            thinkingText: thinkingText,
                                            thinkingExpanded: isLastAssistant ? store.chatThinkingExpanded : false,
                                            onToggleThinking: { store.chatThinkingExpanded.toggle() }
                                        )
                                        .id(msg.id)
                                    }

                                    Color.clear
                                        .frame(height: 1)
                                        .id(ChatScrollAnchor.bottom)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(
                                    ChatScrollObserver(
                                        onScroll: { scrollView in
                                            updatePinnedState(using: scrollView)
                                        },
                                        onContentSizeChange: { scrollView in
                                            handleContentSizeChange(using: scrollView)
                                        }
                                    )
                                    .allowsHitTesting(false)
                                )
                            }

                            FindBarView(
                                isVisible: $isFindVisible,
                                query: $findQuery,
                                matchSummary: matchSummary,
                                onNext: { pendingFindCommand = .next },
                                onPrev: { pendingFindCommand = .prev },
                                onClose: { pendingFindCommand = .close }
                            )
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                        }
                        .frame(height: scrollHeight)
                        .onAppear {
                            DispatchQueue.main.async {
                                scheduleScrollToBottom(proxy, animated: false)
                            }
                        }
                        .onChange(of: findQuery) { _ in
                            rebuildFindMatches()
                        }
                        .onChange(of: pendingFindCommand) { cmd in
                            guard let cmd else { return }
                            applyFindCommand(cmd, proxy: proxy)
                            pendingFindCommand = nil
                        }
                    }
                }
            }
            .padding(Layout.contentPadding)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                .stroke(panelBorder, lineWidth: 1)
        )
        .shadow(color: panelShadow, radius: 8, x: 0, y: 4)
        .frame(height: totalPanelHeight)
        .onAppear { reportHeight() }
        .onChange(of: totalPanelHeight) { _ in reportHeight() }
        .onChange(of: isCollapsed) { _ in
            isFindVisible = false
            reportHeight()
        }
        .contentShape(Rectangle())
#if os(macOS)
        .focusable(true)
        .hidePanelFocusRing()
        .focused($panelFocused)
        .onTapGesture { panelFocused = true }
        .onExitCommand { pendingFindCommand = .close }
#endif
    }

    private func reportHeight() {
        guard let onHeightChange else { return }
        let height = totalPanelHeight
        if abs(lastReportedHeight - height) > 0.5 {
            lastReportedHeight = height
            onHeightChange(height)
        }
    }
}

struct ChatPanelView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: (Bool) -> Void

    @State private var scrollState = ChatScrollState()
    @FocusState private var panelFocused: Bool

    @State private var isFindVisible: Bool = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0
    @State private var pendingFindCommand: FindCommand?

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scrollState.autoScrollWorkItem?.cancel()

        let item = DispatchWorkItem {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                }
            } else {
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                }
            }
        }

        scrollState.autoScrollWorkItem = item
        // small delay = lets layout settle + coalesces rapid token updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }
    
    private enum FindCommand: Equatable {
        case open
        case next
        case prev
        case close
    }

    // "As soon as the user scrolls up from bottom" => basically zero tolerance,
    // but keep 1pt to avoid float jitter.
    private let pinThreshold: CGFloat = 12

    private func updatePinnedState(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        scrollState.scrollView = scrollView
        if scrollState.lastContentHeight <= 0 {
            scrollState.lastContentHeight = docView.bounds.height
        }
        let maxOffset = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        let currentOffset = scrollView.contentView.bounds.origin.y
        let distanceFromBottom: CGFloat
        if docView.isFlipped {
            distanceFromBottom = max(0, maxOffset - currentOffset)
        } else {
            distanceFromBottom = max(0, currentOffset)
        }
        let pinnedNow = distanceFromBottom <= pinThreshold
        if pinnedNow != scrollState.isPinnedToBottom {
            scrollState.isPinnedToBottom = pinnedNow
            if !pinnedNow {
                scrollState.autoScrollWorkItem?.cancel()
            }
        }
    }

    private func scrollToBottom(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        let maxOffset = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        let targetOffset = docView.isFlipped ? maxOffset : 0
        let currentOffset = scrollView.contentView.bounds.origin.y
        if abs(currentOffset - targetOffset) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func handleContentSizeChange(using scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        scrollState.scrollView = scrollView
        let newHeight = docView.bounds.height
        let oldHeight = scrollState.lastContentHeight
        scrollState.lastContentHeight = newHeight

        guard scrollState.isPinnedToBottom else { return }
        guard oldHeight > 0 else {
            scrollToBottom(using: scrollView)
            return
        }

        if docView.isFlipped {
            let delta = newHeight - oldHeight
            if abs(delta) > 0.5 {
                let maxOffset = max(0, newHeight - scrollView.contentView.bounds.height)
                let currentOffset = scrollView.contentView.bounds.origin.y
                let targetOffset = min(max(0, currentOffset + delta), maxOffset)
                if abs(currentOffset - targetOffset) > 0.5 {
                    scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetOffset))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            scrollToBottom(using: scrollView)
        }
    }

    
    private func rebuildFindMatches() {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }

        let ids = store.doc.chat.messages
            .filter { $0.text.localizedCaseInsensitiveContains(q) }
            .map { $0.id }

        findMatches = ids
        if findIndex >= ids.count { findIndex = 0 }
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard isFindVisible, !findMatches.isEmpty else { return }
        let id = findMatches[findIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func applyFindCommand(_ cmd: FindCommand, proxy: ScrollViewProxy) {
        switch cmd {
        case .open:
            isFindVisible = true
            rebuildFindMatches()
            scrollToCurrentMatch(proxy: proxy)
        case .next:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches()
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + 1) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .prev:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches()
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .close:
            isFindVisible = false
        }
    }

    private var canStartNewChat: Bool {
        !store.doc.chat.messages.isEmpty || store.chatWarning != nil
    }

    private var findTarget: FindTarget {
        FindTarget(
            presentFind: { pendingFindCommand = .open },
            findNext: { pendingFindCommand = .next },
            findPrev: { pendingFindCommand = .prev },
            closeFind: { pendingFindCommand = .close }
        )
    }

    var body: some View {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchSummary: String = {
            if q.isEmpty { return "Type to search" }
            if findMatches.isEmpty { return "No matches" }
            return "\(findIndex + 1) of \(findMatches.count)"
        }()

        ZStack {
            ChatPanelBackground()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    if store.pendingChatReplies > 0 {
                        Button("Stop") {
                            store.stopChatReplies()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if store.isSpeaking {
                        Button("Stop Voice") {
                            store.stopSpeechPlayback()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("New Chat") {
                        store.startNewChat()
                        chatInput = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canStartNewChat)
                }

                if let warning = store.chatWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                }

                ScrollViewReader { proxy in
                    FindBarView(
                        isVisible: $isFindVisible,
                        query: $findQuery,
                        matchSummary: matchSummary,
                        onNext: { pendingFindCommand = .next },
                        onPrev: { pendingFindCommand = .prev },
                        onClose: { pendingFindCommand = .close }
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(store.doc.chat.messages.enumerated()), id: \.element.id) { index, msg in
                                let canRetry = false
                                let canEdit = store.pendingChatReplies == 0 && msg.role == .user
                                let isStreamingAssistant = store.pendingChatReplies > 0 &&
                                    index == store.doc.chat.messages.count - 1 &&
                                    msg.role == .assistant
                                let isLastAssistant = index == store.doc.chat.messages.count - 1 && msg.role == .assistant
                                let activityText: String? = isStreamingAssistant ? store.chatActivityStatus : nil
                                let thinkingText: String? = isLastAssistant ? store.chatThinkingText : nil

                                ChatMessageRow(
                                    message: msg,
                                    showsRetry: canRetry,
                                    onRetry: { store.retryChatReply(messageId: msg.id) },
                                    showsEdit: canEdit,
                                    activityText: activityText,
                                    thinkingText: thinkingText,
                                    thinkingExpanded: isLastAssistant ? store.chatThinkingExpanded : false,
                                    onToggleThinking: { store.chatThinkingExpanded.toggle() }
                                )
                                .id(msg.id)
                            }

                            // Bottom sentinel: used for both "scrollTo bottom" and "am I at bottom?"
                            Color.clear
                                .frame(height: 1)
                                .id(ChatScrollAnchor.bottom)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(
                            ChatScrollObserver(
                                onScroll: { scrollView in
                                    updatePinnedState(using: scrollView)
                                },
                                onContentSizeChange: { scrollView in
                                    handleContentSizeChange(using: scrollView)
                                }
                            )
                            .allowsHitTesting(false)
                        )
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onAppear {
                        DispatchQueue.main.async {
                            scheduleScrollToBottom(proxy, animated: false)
                        }
                    }
                    .onChange(of: findQuery) { _ in
                        rebuildFindMatches()
                    }
                    .onChange(of: pendingFindCommand) { cmd in
                        guard let cmd else { return }
                        applyFindCommand(cmd, proxy: proxy)
                        pendingFindCommand = nil
                    }
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
#if os(macOS)
        .focusable(true)
        .hidePanelFocusRing()
        .focused($panelFocused)
        .onTapGesture { panelFocused = true }
        .onExitCommand { pendingFindCommand = .close }
#endif
    }
}


struct ChatArchivePanelView: View {
    @EnvironmentObject var store: BoardStore
    @FocusState private var panelFocused: Bool

    @State private var isFindVisible: Bool = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0
    @State private var pendingFindCommand: FindCommand?

    private enum FindCommand: Equatable {
        case open, next, prev, close
    }

    private var archivedChat: ChatThread? {
        guard let id = store.activeArchivedChatId else { return nil }
        return store.archivedChat(id: id)
    }

    private func rebuildFindMatches(_ chat: ChatThread) {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }

        let ids = chat.messages
            .filter { $0.text.localizedCaseInsensitiveContains(q) }
            .map { $0.id }

        findMatches = ids
        if findIndex >= ids.count { findIndex = 0 }
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard isFindVisible, !findMatches.isEmpty else { return }
        let id = findMatches[findIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func applyFindCommand(_ cmd: FindCommand, chat: ChatThread, proxy: ScrollViewProxy) {
        switch cmd {
        case .open:
            isFindVisible = true
            rebuildFindMatches(chat)
            scrollToCurrentMatch(proxy: proxy)
        case .next:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches(chat)
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + 1) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .prev:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches(chat)
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)
        case .close:
            isFindVisible = false
        }
    }

    private var findTarget: FindTarget {
        FindTarget(
            presentFind: { pendingFindCommand = .open },
            findNext: { pendingFindCommand = .next },
            findPrev: { pendingFindCommand = .prev },
            closeFind: { pendingFindCommand = .close }
        )
    }

    var body: some View {
        ZStack {
            ChatPanelBackground()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                if let archivedChat {
                    HStack {
                        Text("Archived chat")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let last = archivedChat.messages.last {
                            Text(Date(timeIntervalSince1970: last.ts), style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ScrollViewReader { proxy in
                        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        let matchSummary: String = {
                            if q.isEmpty { return "Type to search" }
                            if findMatches.isEmpty { return "No matches" }
                            return "\(findIndex + 1) of \(findMatches.count)"
                        }()

                        FindBarView(
                            isVisible: $isFindVisible,
                            query: $findQuery,
                            matchSummary: matchSummary,
                            onNext: { pendingFindCommand = .next },
                            onPrev: { pendingFindCommand = .prev },
                            onClose: { pendingFindCommand = .close }
                        )

                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(archivedChat.messages.enumerated()), id: \.element.id) { index, msg in
                                    ChatMessageRow(message: msg)
                                        .id(msg.id)
                                    if index != archivedChat.messages.count - 1 {
                                        Rectangle()
                                            .fill(Color(NSColor.separatorColor))
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .onAppear {
                            if let last = archivedChat.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: findQuery) { _ in
                            rebuildFindMatches(archivedChat)
                        }
                        .onChange(of: pendingFindCommand) { cmd in
                            guard let cmd else { return }
                            applyFindCommand(cmd, chat: archivedChat, proxy: proxy)
                            pendingFindCommand = nil
                        }
                    }
                } else {
                    Text("Select a chat from the log to view it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
#if os(macOS)
        .focusable(true)
        .hidePanelFocusRing()
        .focused($panelFocused)
        .onTapGesture { panelFocused = true }
        .onExitCommand { pendingFindCommand = .close }
#endif
    }
}

#if os(macOS)
private struct FocusRingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            disableFocusRing(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            disableFocusRing(from: nsView)
        }
    }

    private func disableFocusRing(from view: NSView) {
        var current: NSView? = view
        while let v = current {
            v.focusRingType = .none
            current = v.superview
        }
    }
}

private extension View {
    @ViewBuilder
    func hidePanelFocusRing() -> some View {
        if #available(macOS 14, *) {
            self
                .focusEffectDisabled(true)
                .background(FocusRingDisabler())
        } else {
            self.background(FocusRingDisabler())
        }
    }
}
#else
private extension View {
    func hidePanelFocusRing() -> some View { self }
}
#endif

private struct ChatActivityStatusView: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(NSColor.secondaryLabelColor).opacity(0.7))
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.0 : 0.6)
                .opacity(pulse ? 1.0 : 0.4)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .opacity(pulse ? 1.0 : 0.7)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear { pulse = false }
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Markdown Tables

private struct ChatMarkdownTableView: View {
    let markdownTable: String
    let basePointSize: CGFloat
    let textColor: Color
    
    private let gridLineOpacity: CGFloat = 0.95
    private let gridLineWidth: CGFloat = 1
    private var gridLineColor: Color {
        Color(NSColor.separatorColor).opacity(gridLineOpacity)
    }
    
    private struct CellID: Hashable {
        let row: Int   // Grid row index (0 = header, 1... = body)
        let col: Int
    }

    private struct CellFramePrefKey: PreferenceKey {
        static var defaultValue: [CellID: CGRect] = [:]
        static func reduce(value: inout [CellID: CGRect], nextValue: () -> [CellID: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    private struct SpanGroup: Hashable {
        let col: Int
        let startBodyRow: Int   // 0-based in parsed.rows
        let endBodyRow: Int     // inclusive
        let text: String
        let align: ColAlign
    }
    
    private func computeSpanGroups(
        rows: [[String]],
        colCount: Int,
        rowSpanColumns: Set<Int>
    ) -> [SpanGroup] {

        guard !rows.isEmpty else { return [] }

        var groups: [SpanGroup] = []

        for c in 0..<colCount where rowSpanColumns.contains(c) {
            var start = 0
            while start < rows.count {
                let startText = (rows[start].count > c ? rows[start][c] : "").trimmingCharacters(in: .whitespacesAndNewlines)

                // If empty, skip until we find a non-empty anchor
                if startText.isEmpty {
                    start += 1
                    continue
                }

                var end = start
                var i = start + 1
                while i < rows.count {
                    let t = (rows[i].count > c ? rows[i][c] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty {
                        end = i
                        i += 1
                    } else {
                        break
                    }
                }

                // Only treat it as a "span" if it actually spans > 1 row
                if end > start {
                    groups.append(
                        SpanGroup(
                            col: c,
                            startBodyRow: start,
                            endBodyRow: end,
                            text: startText,
                            align: .left // will override later from parsed.alignments
                        )
                    )
                }

                start = end + 1
            }
        }

        return groups
    }

    private enum ColAlign { case left, center, right }
    
    // Which columns should visually "row-span" when cells are blank.
    // 0 = first column ("Category")
    private let rowSpanColumns: Set<Int> = [0]

    var body: some View {
        let parsed = parseMarkdownTable(markdownTable)
        let totalRows = 1 + parsed.rows.count
        let colWidths = computeColumnWidths(parsed)
        let spanAnchors = computeSpanAnchors(parsed.rows, colCount: parsed.colCount, rowSpanColumns: rowSpanColumns)

        ScrollView(.horizontal, showsIndicators: true) {
            tableGrid(
                parsed: parsed,
                totalRows: totalRows,
                colWidths: colWidths,
                spanAnchors: spanAnchors
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(gridLineColor, lineWidth: gridLineWidth)
        )
    }
    
    @ViewBuilder
    private func tableGrid(
        parsed: ParsedTable,
        totalRows: Int,
        colWidths: [CGFloat],
        spanAnchors: [[Int]]
    ) -> some View {

        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            tableHeaderRow(parsed: parsed, totalRows: totalRows, colWidths: colWidths)
            tableBodyRows(parsed: parsed, totalRows: totalRows, colWidths: colWidths, spanAnchors: spanAnchors)
        }
        .padding(8)
        .coordinateSpace(name: "mdTable")
        .overlayPreferenceValue(CellFramePrefKey.self) { frames in
            spanOverlay(frames: frames, parsed: parsed)
        }
    }

    @ViewBuilder
    private func tableHeaderRow(
        parsed: ParsedTable,
        totalRows: Int,
        colWidths: [CGFloat]
    ) -> some View {

        GridRow {
            ForEach(0..<parsed.colCount, id: \.self) { c in
                tableCell(
                    text: parsed.header[safe: c] ?? "",
                    isHeader: true,
                    rowIndex: 0,
                    colIndex: c,
                    isLastRow: totalRows == 1,
                    isLastCol: c == parsed.colCount - 1,
                    colAlign: parsed.alignments[safe: c] ?? .left,
                    width: colWidths[safe: c] ?? 120
                )
            }
        }
    }

    @ViewBuilder
    private func tableBodyRows(
        parsed: ParsedTable,
        totalRows: Int,
        colWidths: [CGFloat],
        spanAnchors: [[Int]]
    ) -> some View {

        ForEach(Array(parsed.rows.enumerated()), id: \.offset) { (r, row) in
            GridRow {
                ForEach(0..<parsed.colCount, id: \.self) { c in
                    bodyCell(
                        bodyRowIndex: r,
                        row: row,
                        col: c,
                        parsed: parsed,
                        totalRows: totalRows,
                        colWidths: colWidths,
                        spanAnchors: spanAnchors
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func bodyCell(
        bodyRowIndex: Int,
        row: [String],
        col: Int,
        parsed: ParsedTable,
        totalRows: Int,
        colWidths: [CGFloat],
        spanAnchors: [[Int]]
    ) -> some View {

        let anchor = spanAnchors[safe: bodyRowIndex]?[safe: col] ?? -1
        let hasSpan = anchor >= 0
        let isContinuation = hasSpan && anchor != bodyRowIndex
        let isLastInSpan = hasSpan && (
            bodyRowIndex == parsed.rows.count - 1 ||
            (spanAnchors[safe: bodyRowIndex + 1]?[safe: col] ?? -1) != anchor
        )

        // zebra matches anchor row
        let spanStripeRowIndex: Int? = hasSpan ? (anchor + 1) : nil // +1 because header is row 0
        let isSpanCol = rowSpanColumns.contains(col)

        // Only hide text if it's a continuation cell (empty cell extending a previous span)
        // Show normal text for cells with content, even in span columns
        let cellText = isContinuation ? "" : (row[safe: col] ?? "")

        tableCell(
            text: cellText,
            isHeader: false,
            rowIndex: bodyRowIndex + 1,
            colIndex: col,
            isLastRow: (bodyRowIndex + 1) == (totalRows - 1),
            isLastCol: col == parsed.colCount - 1,
            colAlign: parsed.alignments[safe: col] ?? .left,
            width: colWidths[safe: col] ?? 120,
            suppressBottomLine: hasSpan && !isLastInSpan,
            stripeRowOverride: spanStripeRowIndex
        )
    }

    @ViewBuilder
    private func spanOverlay(frames: [CellID: CGRect], parsed: ParsedTable) -> some View {
        let rawGroups = computeSpanGroups(
            rows: parsed.rows,
            colCount: parsed.colCount,
            rowSpanColumns: rowSpanColumns
        )

        let groups: [SpanGroup] = rawGroups.map { g in
            SpanGroup(
                col: g.col,
                startBodyRow: g.startBodyRow,
                endBodyRow: g.endBodyRow,
                text: g.text,
                align: parsed.alignments[safe: g.col] ?? .left
            )
        }

        ZStack(alignment: .topLeading) {
            ForEach(groups, id: \.self) { g in
                if let union = unionRect(for: g, frames: frames) {
                    mergedSpanLabel(text: g.text, align: g.align)
                        .frame(width: union.width, height: union.height, alignment: frameAlignment(g.align))
                        .position(x: union.midX, y: union.midY)
                }
            }
        }
    }

    private func unionRect(for g: SpanGroup, frames: [CellID: CGRect]) -> CGRect? {
        let startGridRow = g.startBodyRow + 1
        let endGridRow = g.endBodyRow + 1

        var union: CGRect?
        for r in startGridRow...endGridRow {
            if let rect = frames[CellID(row: r, col: g.col)] {
                union = union.map { $0.union(rect) } ?? rect
            }
        }
        return union
    }
    
    @ViewBuilder
    private func mergedSpanLabel(text: String, align: ColAlign) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = Font.custom("HelveticaNeue-Medium", size: basePointSize)

        if let a = try? AttributedString(
            markdown: trimmed.isEmpty ? " " : trimmed,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(a)
                .font(font)
                .foregroundColor(textColor)
                .multilineTextAlignment(textAlignment(align))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        } else {
            Text(trimmed.isEmpty ? " " : trimmed)
                .font(font)
                .foregroundColor(textColor)
                .multilineTextAlignment(textAlignment(align))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private func textAlignment(_ a: ColAlign) -> TextAlignment {
        switch a {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    // MARK: - Cell

    private func tableCell(
        text: String,
        isHeader: Bool,
        rowIndex: Int,
        colIndex: Int,
        isLastRow: Bool,
        isLastCol: Bool,
        colAlign: ColAlign,
        width: CGFloat,
        suppressBottomLine: Bool = false,
        stripeRowOverride: Int? = nil
    ) -> some View {

        let stripeIndex = stripeRowOverride ?? rowIndex

        let headerBG = Color(NSColor.controlBackgroundColor).opacity(0.35)
        let zebraBG  = (stripeIndex % 2 == 0)
            ? Color(NSColor.controlBackgroundColor).opacity(0.18)
            : Color(NSColor.controlBackgroundColor).opacity(0.10)

        return MarkdownCellText(
            raw: text,
            basePointSize: basePointSize,
            textColor: textColor,
            isHeader: isHeader,
            colAlign: colAlign
        )
        .frame(width: width, alignment: frameAlignment(colAlign))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .gridCellUnsizedAxes(.vertical)
        .background(isHeader ? headerBG : zebraBG)
        // Gridlines (draw bottom + trailing only; outer border comes from container)
        .overlay(alignment: .bottom) {
            if !isLastRow && !suppressBottomLine {
                Rectangle()
                    .fill(gridLineColor)
                    .frame(height: gridLineWidth)
            }
        }
        .overlay(alignment: .trailing) {
            if !isLastCol {
                Rectangle()
                    .fill(gridLineColor)
                    .frame(width: gridLineWidth)
            }
        }
        .background(
            GeometryReader { proxy in
                if rowSpanColumns.contains(colIndex) {
                    Color.clear
                        .preference(
                            key: CellFramePrefKey.self,
                            value: [CellID(row: rowIndex, col: colIndex): proxy.frame(in: .named("mdTable"))]
                        )
                } else {
                    Color.clear
                }
            }
        )
    }

    private struct MarkdownCellText: View {
        let raw: String
        let basePointSize: CGFloat
        let textColor: Color
        let isHeader: Bool
        let colAlign: ColAlign

        var body: some View {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let font: Font = isHeader
                ? .custom("HelveticaNeue-Medium", size: basePointSize)
                : .custom("HelveticaNeue-Light", size: basePointSize)

            if let a = markdownAttributedString(from: trimmed.isEmpty ? " " : trimmed) {
                Text(a)
                    .font(font)
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                    .multilineTextAlignment(textAlignment(colAlign))
                    .fixedSize(horizontal: false, vertical: true) // ✅ wraps instead of exploding width
            } else {
                Text(trimmed.isEmpty ? " " : trimmed)
                    .font(font)
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                    .multilineTextAlignment(textAlignment(colAlign))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func markdownAttributedString(from s: String) -> AttributedString? {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            return try? AttributedString(markdown: s, options: options)
        }

        private func textAlignment(_ a: ColAlign) -> TextAlignment {
            switch a {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }
    }

    private func frameAlignment(_ a: ColAlign) -> Alignment {
        switch a {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
    
    private func computeSpanAnchors(
        _ rows: [[String]],
        colCount: Int,
        rowSpanColumns: Set<Int>
    ) -> [[Int]] {
        guard !rows.isEmpty, colCount > 0 else { return [] }

        var anchors = Array(repeating: Array(repeating: -1, count: colCount), count: rows.count)

        for c in 0..<colCount {
            // Only apply the rowspan illusion to selected columns
            guard rowSpanColumns.contains(c) else { continue }

            var lastNonEmptyRow: Int = -1

            for r in 0..<rows.count {
                let cell = (rows[r].count > c ? rows[r][c] : "").trimmingCharacters(in: .whitespacesAndNewlines)

                if !cell.isEmpty {
                    lastNonEmptyRow = r
                    anchors[r][c] = r
                } else if lastNonEmptyRow >= 0 {
                    anchors[r][c] = lastNonEmptyRow
                } else {
                    anchors[r][c] = -1
                }
            }
        }

        return anchors
    }

    // MARK: - Parsing

    private struct ParsedTable {
        let header: [String]
        let alignments: [ColAlign]
        let rows: [[String]]
        let colCount: Int
    }

    private func parseMarkdownTable(_ block: String) -> ParsedTable {
        let lines = block
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }

        guard lines.count >= 2 else {
            return ParsedTable(header: [], alignments: [], rows: [], colCount: 0)
        }

        let header = parseRow(lines[0])
        let align = parseAlignmentRow(lines[1], expectedCols: header.count)
        let rows = lines.dropFirst(2).map(parseRow)

        let colCount = max(header.count, rows.map(\.count).max() ?? 0, align.count)

        return ParsedTable(header: header, alignments: align, rows: rows, colCount: colCount)
    }

    private func parseRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return splitOnUnescapedPipes(t).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func parseAlignmentRow(_ line: String, expectedCols: Int) -> [ColAlign] {
        let cells = parseRow(line)
        var out: [ColAlign] = []
        out.reserveCapacity(max(expectedCols, cells.count))

        for cell in cells {
            let s = cell.replacingOccurrences(of: " ", with: "")
            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            if left && right { out.append(.center) }
            else if right { out.append(.right) }
            else { out.append(.left) }
        }

        if out.count < expectedCols {
            out.append(contentsOf: Array(repeating: .left, count: expectedCols - out.count))
        }
        return out
    }

    private func splitOnUnescapedPipes(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false

        for ch in s {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" {
                escaping = true
                continue
            }
            if ch == "|" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - Column widths (keeps it table-like)

    private func computeColumnWidths(_ parsed: ParsedTable) -> [CGFloat] {
        guard parsed.colCount > 0 else { return [] }

        // Estimate width from max characters, but clamp so long cells wrap (table stays “table-y”).
        let charW = max(6.0, basePointSize * 0.55) // rough Helvetica char width
        let minW: CGFloat = 120
        let maxW: CGFloat = 420  // key: prevents the “columns drift apart” look

        var maxChars = Array(repeating: 0, count: parsed.colCount)

        func consider(_ row: [String]) {
            for c in 0..<parsed.colCount {
                let s = row[safe: c] ?? ""
                maxChars[c] = max(maxChars[c], s.count)
            }
        }

        consider(parsed.header)
        for r in parsed.rows { consider(r) }

        return maxChars.map { ch in
            let estimated = CGFloat(ch) * charW
            return min(max(minW, estimated), maxW)
        }
    }
}

// If you already added this earlier, don’t duplicate it.
private extension Array {
    subscript(safe index: Int) -> Element? {
        (indices.contains(index)) ? self[index] : nil
    }
}

private struct ChatMessageRow: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMsg
    var showsRetry: Bool = false
    var onRetry: () -> Void = {}
    var showsEdit: Bool = false
    var activityText: String? = nil
    var thinkingText: String? = nil
    var thinkingExpanded: Bool = false
    var onToggleThinking: () -> Void = {}

    @State private var isEditing = false
    @State private var draftText = ""
    
    private func markdownText(for rawText: String) -> AttributedString? {
        let source = markdownSource(for: rawText)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return nil
        }
        let sourceNewlines = source.filter { $0 == "\n" }.count
        let parsedNewlines = parsed.characters.filter { $0.isNewline }.count
        if sourceNewlines > 0, parsedNewlines < sourceNewlines {
            return markdownPreservingNewlines(rawText)
        }
        return parsed
    }

    private func markdownSource(for rawText: String) -> String {
        let lines = rawText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var output: [String] = []
        var inCodeBlock = false
        output.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                output.append(String(line))
                continue
            }
            if inCodeBlock {
                output.append(String(line))
            } else if line.isEmpty {
                output.append(String(line))
            } else {
                let processed = linkifyCitationsIfPossible(String(line))
                output.append(processed + "  ")
            }
        }
        return output.joined(separator: "\n")
    }

    private struct TableAwareBlock: Identifiable {
        enum Kind { case text, table, horizontalRule }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private func splitMarkdownIntoTableAwareBlocks(_ rawText: String) -> [TableAwareBlock] {
        let ns = rawText as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Don't treat tables inside fenced code blocks as real tables.
        let codePattern = #"```[\s\S]*?```"#
        let codeRanges: [NSRange] =
            (try? NSRegularExpression(pattern: codePattern))?
                .matches(in: rawText, range: full)
                .map(\.range)
            ?? []

        // Matches horizontal rules: --- or *** or ___ (3 or more, with optional whitespace)
        let hrPattern = #"(?m)^\s*([-*_])\1\1+\s*$"#
        let hrRanges: [NSRange] =
            (try? NSRegularExpression(pattern: hrPattern))?
                .matches(in: rawText, range: full)
                .filter { m in !codeRanges.contains { NSIntersectionRange($0, m.range).length > 0 } }
                .map(\.range)
            ?? []

        // Matches a full Markdown table block (header + separator + rows)
        let pattern = #"(?m)(^\s*\|.*\|\s*$\n^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$\n(^\s*\|.*\|\s*$\n?)*)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return [TableAwareBlock(kind: .text, text: rawText)]
        }

        let tableMatches = re.matches(in: rawText, range: full).filter { m in
            !codeRanges.contains { NSIntersectionRange($0, m.range).length > 0 }
        }

        // Combine all special ranges (tables and horizontal rules)
        struct SpecialBlock {
            let range: NSRange
            let kind: TableAwareBlock.Kind
        }
        
        var specialBlocks: [SpecialBlock] = []
        specialBlocks.append(contentsOf: tableMatches.map { SpecialBlock(range: $0.range, kind: .table) })
        specialBlocks.append(contentsOf: hrRanges.map { SpecialBlock(range: $0, kind: .horizontalRule) })
        specialBlocks.sort { $0.range.location < $1.range.location }

        guard !specialBlocks.isEmpty else {
            return [TableAwareBlock(kind: .text, text: rawText)]
        }

        var blocks: [TableAwareBlock] = []
        var cursor = 0

        for special in specialBlocks {
            if special.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: special.range.location - cursor))
                if !before.isEmpty {
                    blocks.append(TableAwareBlock(kind: .text, text: before))
                }
            }

            let content = ns.substring(with: special.range)
            if !content.isEmpty {
                blocks.append(TableAwareBlock(kind: special.kind, text: content))
            }

            cursor = NSMaxRange(special.range)
        }

        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                blocks.append(TableAwareBlock(kind: .text, text: tail))
            }
        }

        // Drop blocks that are only whitespace/newlines.
        return blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum ChatTypography {
        static let senderFont = ChatStyle.senderFont
        static let messageFont: Font = .custom("HelveticaNeue-Light", size: ChatStyle.basePointSize)
        static let messageLineSpacing: CGFloat = 0
        static let editorMinHeight: CGFloat = 88
    }

    private var hasContent: Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.images.isEmpty
            || !message.files.isEmpty
    }

    private var messageDate: Date? {
        message.ts > 0 ? Date(timeIntervalSince1970: message.ts) : nil
    }

    private func createMarkdownAttributedString() -> NSAttributedString {
        createMarkdownAttributedString(from: message.text)
    }

    private func createMarkdownAttributedString(from rawText: String) -> NSAttributedString {
        guard let md = markdownText(for: rawText) else {
            return NSAttributedString(string: rawText)
        }

        let s = String(md.characters)
        let out = NSMutableAttributedString(md)

        let baseSize: CGFloat = ChatStyle.basePointSize
        let baseFont: NSFont = ChatStyle.baseFont

        let codeBg: NSColor = {
            if colorScheme == .dark {
                return NSColor.white.withAlphaComponent(0.12)
            } else {
                return NSColor.black.withAlphaComponent(0.08)
            }
        }()

        func nsRange(for runRange: Range<AttributedString.Index>) -> NSRange {
            let lower = md.characters.distance(from: md.characters.startIndex, to: runRange.lowerBound)
            let upper = md.characters.distance(from: md.characters.startIndex, to: runRange.upperBound)
            let start = s.index(s.startIndex, offsetBy: lower)
            let end = s.index(s.startIndex, offsetBy: upper)
            return NSRange(start..<end, in: s)
        }

        // First pass: identify all code block ranges
        var codeBlockRanges: [NSRange] = []

        for run in md.runs {
            if let intent = run.attributes.presentationIntent {
                for c in intent.components {
                    if case .codeBlock(_) = c.kind {
                        let range = nsRange(for: run.range)
                        codeBlockRanges.append(range)
                    }
                }
            }
        }

        // Merge overlapping ranges
        codeBlockRanges.sort { $0.location < $1.location }
        var mergedRanges: [NSRange] = []
        for range in codeBlockRanges {
            if let last = mergedRanges.last, NSMaxRange(last) >= range.location {
                mergedRanges[mergedRanges.count - 1] = NSUnionRange(last, range)
            } else {
                mergedRanges.append(range)
            }
        }
        codeBlockRanges = mergedRanges

        // Second pass: apply styling
        for run in md.runs {
            var font = baseFont
            var isCodeBlock = false
            let range = nsRange(for: run.range)

            if let intent = run.attributes.presentationIntent {
                for c in intent.components {
                    if case .header(let level) = c.kind {
                        font = ChatStyle.headingFont(level: level)
                    }

                    if case .codeBlock(_) = c.kind {
                        isCodeBlock = true
                        font = NSFont.monospacedSystemFont(ofSize: max(12, baseSize - 2), weight: .regular)
                    }
                }
            }

            if let inline = run.attributes.inlinePresentationIntent, !isCodeBlock {
                if inline.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if inline.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                if inline.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: max(16, font.pointSize - 1), weight: .regular)
                }
            }

            out.addAttribute(.font, value: font, range: range)
        }

        // Third pass: Apply code block styling with custom marker attribute
        for codeBlockRange in codeBlockRanges {
            out.addAttribute(.codeBlockMarker, value: codeBg, range: codeBlockRange)

            let codeFont = NSFont.monospacedSystemFont(ofSize: max(12, baseSize - 2), weight: .regular)
            out.addAttribute(.font, value: codeFont, range: codeBlockRange)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacingBefore = 6
            paragraphStyle.paragraphSpacing = 6
            paragraphStyle.lineSpacing = 2

            out.addAttribute(.paragraphStyle, value: paragraphStyle, range: codeBlockRange)
        }

        return out
    }


    private var markdownText: AttributedString? {
        let source = markdownSource
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return nil
        }
        let sourceNewlines = source.filter { $0 == "\n" }.count
        let parsedNewlines = parsed.characters.filter { $0.isNewline }.count
        if sourceNewlines > 0, parsedNewlines < sourceNewlines {
            return markdownPreservingNewlines(message.text)
        }
        return parsed
    }

    private var markdownSource: String {
        let lines = message.text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var output: [String] = []
        var inCodeBlock = false
        output.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                output.append(String(line))
                continue
            }
            if inCodeBlock {
                output.append(String(line))
            } else if line.isEmpty {
                output.append(String(line))
            } else {
                let processed = linkifyCitationsIfPossible(String(line))
                output.append(processed + "  ")
            }
        }
        return output.joined(separator: "\n")
    }
    
    private func linkifyCitationsIfPossible(_ s: String) -> String {
        s
    }

    private func markdownPreservingNewlines(_ text: String) -> AttributedString {
        let inlineOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let fullOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var output = AttributedString()
        var inCodeBlock = false
        var codeLines: [String] = []

        for (index, lineSub) in lines.enumerated() {
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    codeLines.append(line)
                    let blockText = codeLines.joined(separator: "\n")
                    var block = (try? AttributedString(markdown: blockText, options: fullOptions))
                        ?? AttributedString(blockText)
                    if index < lines.count - 1, !(block.characters.last?.isNewline ?? false) {
                        block.append(AttributedString("\n"))
                    }
                    output += block
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    codeLines = [line]
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let parsedLine: AttributedString
            if isHeadingLine(trimmed) {
                parsedLine = (try? AttributedString(markdown: line, options: fullOptions))
                    ?? AttributedString(line)
            } else {
                parsedLine = (try? AttributedString(markdown: line, options: inlineOptions))
                    ?? AttributedString(line)
            }
            output += parsedLine
            if index < lines.count - 1 {
                output.append(AttributedString("\n"))
            }
        }

        if inCodeBlock, !codeLines.isEmpty {
            output += AttributedString(codeLines.joined(separator: "\n"))
        }

        return output
    }

    private func isHeadingLine(_ line: String) -> Bool {
        guard line.first == "#" else { return false }
        var count = 0
        for char in line {
            if char == "#" {
                count += 1
            } else {
                break
            }
        }
        guard count > 0, count <= 6 else { return false }
        let index = line.index(line.startIndex, offsetBy: count)
        if index == line.endIndex {
            return true
        }
        return line[index].isWhitespace
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: { store.pinChatMessage(message) }) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.9)))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .disabled(!hasContent)
            .help("Pin to board")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(message.role.chatDisplayName)
                        .font(ChatStyle.senderFont)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    if showsRetry {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .help("Retry response")
                    }
                    if showsEdit && !isEditing {
                        Button(action: startEditing) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .help("Edit message")
                    }
                }
                if let messageDate {
                    HStack(spacing: 6) {
                        Text(messageDate, style: .date)
                        Text(messageDate, style: .time)
                    }
                    .font(ChatStyle.timestampFont)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                if isEditing {
                    TextEditor(text: $draftText)
                        .font(ChatTypography.messageFont)
                        .lineSpacing(ChatTypography.messageLineSpacing)
                        .frame(minHeight: ChatTypography.editorMinHeight)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            cancelEditing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Send") {
                            saveEditing()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(draftText == message.text)
                    }
                } else {
                    // Show thinking section FIRST if we have thinking text
                    if let thinkingText, !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: onToggleThinking) {
                            HStack(spacing: 6) {
                                Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Thoughts")
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(
                            get: { thinkingExpanded },
                            set: { _ in onToggleThinking() }
                        ), arrowEdge: .leading) {
                            ScrollView {
                                Text(thinkingText)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(Color(NSColor.labelColor))
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 400, height: 300)
                            .background(Color(NSColor.controlBackgroundColor))
                        }
                    }
                    
                    // Then show the main message text
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // NOTE: SwiftUI's `Text(AttributedString)` + `.textSelection(.enabled)`
                        // renders links with blue styling but doesn't reliably make them clickable
                        // on macOS. Use an NSTextView-backed renderer so links open in the browser.
                        // Render tables as their own horizontally-scrollable blocks so they don't
                        // "break" when the chat panel is narrow.
                        let blocks = splitMarkdownIntoTableAwareBlocks(message.text)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(blocks) { block in
                                switch block.kind {
                                case .text:
                                    // NOTE: SwiftUI's `Text(AttributedString)` + `.textSelection(.enabled)`
                                    // renders links with blue styling but doesn't reliably make them clickable
                                    // on macOS. Use an NSTextView-backed renderer so links open in the browser.
                                    ChatRichTextView(
                                        attributedText: createMarkdownAttributedString(from: block.text),
                                        baseFont: ChatStyle.baseFont,
                                        textColor: ChatStyle.baseColor,
                                        lineSpacing: 0
                                    )

                                case .table:
                                    ChatMarkdownTableView(
                                        markdownTable: block.text,
                                        basePointSize: ChatStyle.basePointSize,
                                        textColor: Color(ChatStyle.baseColor)
                                    )
                                    
                                case .horizontalRule:
                                    // Render as a separator line that adapts to panel width
                                    Rectangle()
                                        .fill(Color(NSColor.separatorColor))
                                        .frame(height: 1)
                                        .padding(.vertical, 6)
                                }
                            }
                        }
                    } else if let activityText, !activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Show activity status only if no message text yet
                        ChatActivityStatusView(text: activityText)
                            .padding(.vertical, 2)
                    }
                }
                if !message.images.isEmpty {
                    let maxSide: CGFloat = message.images.count > 1 ? 200 : 260
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(message.images.enumerated()), id: \.element) { index, imageRef in
                            let offset = CGFloat(index) * 12
                            messageImageView(for: imageRef, maxSide: maxSide)
                                .offset(x: offset, y: offset)
                        }
                    }
                    .frame(width: maxSide + CGFloat(max(0, message.images.count - 1)) * 12,
                           height: maxSide + CGFloat(max(0, message.images.count - 1)) * 12,
                           alignment: .topLeading)
                }
                if !message.files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.files, id: \.self) { fileRef in
                            Button(action: { store.openFile(fileRef) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(fileDisplayName(fileRef))
                                        .font(.system(size: 14, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .frame(maxWidth: ChatStyle.maxMessageContentWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .onAppear {
            draftText = message.text
        }
        .onChange(of: message.text) { newValue in
            if !isEditing {
                draftText = newValue
            }
        }
    }

    @ViewBuilder
    private func messageImageView(for imageRef: ImageRef, maxSide: CGFloat) -> some View {
        if let url = store.imageURL(for: imageRef),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxSide, maxHeight: maxSide)
                .background(Color(NSColor.separatorColor).opacity(0.35))
                .cornerRadius(8)
        } else {
            Text("Image missing")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func fileDisplayName(_ ref: FileRef) -> String {
        let trimmed = ref.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ref.filename : trimmed
    }

    private func startEditing() {
        draftText = message.text
        isEditing = true
    }

    private func cancelEditing() {
        draftText = message.text
        isEditing = false
    }

    private func saveEditing() {
        store.editChatMessageAndResend(messageId: message.id, text: draftText)
        isEditing = false
    }
}

struct MarkdownText: View {
    let content: String

    var body: some View {
        if let attributed = renderMarkdown() {
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Fallback if parsing fails (very rare)
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func renderMarkdown() -> AttributedString? {
        // 1. NEWLINE HACK
        // Markdown swallows single newlines. We replace them with "  \n" (Hard Break).
        // We protect double newlines (\n\n) which act as paragraph breaks.
        // ALSO protect markdown tables from the hard break conversion!

        var textWithHardBreaks = content.replacingOccurrences(of: "\r\n", with: "\n") // normalize CRLF

        // Protect tables first
        let tablePattern = #"(?m)(^\s*\|.*\|\s*$\n^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$\n(^\s*\|.*\|\s*$\n?)*)"#
        var tableProtections: [String: String] = [:]
        if let tableRegex = try? NSRegularExpression(pattern: tablePattern) {
            let matches = tableRegex.matches(in: textWithHardBreaks, range: NSRange(textWithHardBreaks.startIndex..., in: textWithHardBreaks))
            for (index, match) in matches.enumerated().reversed() {
                if let range = Range(match.range, in: textWithHardBreaks) {
                    let placeholder = "§§TABLE\(index)§§"
                    let tableContent = String(textWithHardBreaks[range])
                    tableProtections[placeholder] = tableContent
                    textWithHardBreaks.replaceSubrange(range, with: placeholder)
                }
            }
        }

        // Now apply hard breaks
        textWithHardBreaks = textWithHardBreaks
            .replacingOccurrences(of: "\n\n", with: "§§PARAGRAPH§§") // protect paragraphs
            .replacingOccurrences(of: "\n", with: "  \n") // force hard break on single lines
            .replacingOccurrences(of: "§§PARAGRAPH§§", with: "\n\n") // restore paragraphs

        // Restore tables
        for (placeholder, tableContent) in tableProtections {
            textWithHardBreaks = textWithHardBreaks.replacingOccurrences(of: placeholder, with: tableContent)
        }

        // 2. PARSE MARKDOWN
        // We assume generic Markdown syntax.
        guard var attributed = try? AttributedString(markdown: textWithHardBreaks) else {
            return nil
        }

        // 3. APPLY STYLING
        // Block-level styling (headers) comes from presentationIntent.
        // Inline styling (code/bold/italic intent) comes from inlinePresentationIntent.

        for run in attributed.runs {

            if let intent = run.attributes.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        switch level {
                        case 1: attributed[run.range].font = .system(.title).bold()
                        case 2: attributed[run.range].font = .system(.title2).bold()
                        case 3: attributed[run.range].font = .system(.title3).bold()
                        default: attributed[run.range].font = .system(.headline).bold()
                        }
                    default:
                        break
                    }
                }
            }

            if let inline = run.attributes.inlinePresentationIntent,
               inline.contains(.code) {
                attributed[run.range].font = .system(.body, design: .monospaced)
                attributed[run.range].foregroundColor = .secondary
            }
        }
        return attributed
    }
}

private enum ChatStyle {
    // Chat-style defaults
    static let basePointSize: CGFloat = 16
    static let baseFont: NSFont = {
        // Prefer Helvetica Neue Light; fall back safely.
        if let f = NSFont(name: "Avenir-Next", size: basePointSize) { return f }
        if let f = NSFont(name: "Avenir", size: basePointSize) { return f }
        return NSFont.systemFont(ofSize: basePointSize, weight: .light)
    }()
    static let baseColor: NSColor = .labelColor

    // Readability (tighter than before)
    static let lineHeightMultiple: CGFloat = 1.15
    static let paragraphSpacing: CGFloat = 2
    static let paragraphSpacingBefore: CGFloat = 0
    static let maxMessageContentWidth: CGFloat = 720

    // Container feel
    static let textInset = NSSize(width: 0, height: 2)
    static let lineFragmentPadding: CGFloat = 2

    // Headings (relative, not huge)
    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: return NSFont.systemFont(ofSize: 19, weight: .bold)
        case 3: return NSFont.systemFont(ofSize: 17, weight: .semibold)
        default: return NSFont.systemFont(ofSize: 16, weight: .semibold)
        }
    }

    static let senderFont: Font = .custom("HelveticaNeue-Medium", size: 16)
    static let timestampFont: Font = .custom("HelveticaNeue-Light", size: 11)
}

private class CodeBlockTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        // DON'T draw any background - keep it transparent
        // (Remove the code that was filling with bgColor)
        
        guard let textStorage = self.textStorage else { return }
        guard let layoutManager = self.layoutManager else { return }
        guard let textContainer = self.textContainer else { return }
        
        // No background fill - just draw code block rectangles directly
        
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerOrigin = textContainerOrigin
        
        // Find all code block ranges using our custom marker attribute
        var codeBlockInfo: [(range: NSRange, color: NSColor)] = []
        
        textStorage.enumerateAttribute(.codeBlockMarker, in: fullRange, options: []) { value, range, _ in
            if let bgColor = value as? NSColor {
                codeBlockInfo.append((range: range, color: bgColor))
            }
        }
        
        // Group consecutive code block ranges
        var mergedBlocks: [(range: NSRange, color: NSColor)] = []
        for block in codeBlockInfo {
            if let last = mergedBlocks.last,
               NSMaxRange(last.range) >= block.range.location {
                let unionRange = NSUnionRange(last.range, block.range)
                mergedBlocks[mergedBlocks.count - 1] = (range: unionRange, color: block.color)
            } else {
                mergedBlocks.append(block)
            }
        }
        
        // Draw rounded rectangle for each code block
        for block in mergedBlocks {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            
            // Get all line fragment rects for this glyph range
            var rects: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, textContainer, glyphRange, stop in
                rects.append(usedRect)
            }
            
            guard !rects.isEmpty else { continue }
            
            // Calculate the union of all line rects
            var boundingRect = rects[0]
            for rect in rects.dropFirst() {
                boundingRect = boundingRect.union(rect)
            }
            
            // Adjust for container origin and add padding
            let padding: CGFloat = 12
            let verticalPadding: CGFloat = 8
            
            boundingRect.origin.x += containerOrigin.x - padding
            boundingRect.origin.y += containerOrigin.y - verticalPadding
            boundingRect.size.width += padding * 2
            boundingRect.size.height += verticalPadding * 2
            
            // Ensure the rect is within the visible area
            boundingRect = boundingRect.intersection(self.bounds)
            
            // Draw the rounded rectangle
            let path = NSBezierPath(roundedRect: boundingRect, xRadius: 8, yRadius: 8)
            block.color.setFill()
            path.fill()
        }
    }
    
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(self.visibleRect)
    }
}

private struct ChatRichTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let baseFont: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassThroughScrollView {
        let scrollView = PassThroughScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = CodeBlockTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesRuler = false
        textView.usesFontPanel = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = ChatStyle.textInset
        textView.textContainer?.lineFragmentPadding = ChatStyle.lineFragmentPadding
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.isAutomaticLinkDetectionEnabled = true

        // Make links look/behave like links.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        scrollView.documentView = textView

        scrollView.onLayout = { [weak textView] sv in
            guard let tv = textView else { return }
            syncWidthAndHeight(for: tv, in: sv)
        }

        applyText(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: PassThroughScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = context.coordinator

        nsView.onLayout = { [weak textView] sv in
            guard let tv = textView else { return }
            syncWidthAndHeight(for: tv, in: sv)
        }

        applyText(to: textView, in: nsView)
    }

    private func applyText(to textView: NSTextView, in scrollView: PassThroughScrollView) {
        let display = makeDisplayAttributedString()
        textView.textStorage?.setAttributedString(display)

        // Don't set textView.font or textView.textColor (it can flatten).
        syncWidthAndHeight(for: textView, in: scrollView)
    }

    private func makeDisplayAttributedString() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let full = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(NSAttributedString.Key.paragraphStyle, in: full, options: []) { value, range, _ in
            let p: NSMutableParagraphStyle
            if let existing = value as? NSParagraphStyle,
            let copy = existing.mutableCopy() as? NSMutableParagraphStyle {
                p = copy
            } else {
                p = NSMutableParagraphStyle()
            }

            p.lineBreakMode = .byWordWrapping
            p.lineHeightMultiple = ChatStyle.lineHeightMultiple
            p.paragraphSpacing = ChatStyle.paragraphSpacing
            p.paragraphSpacingBefore = ChatStyle.paragraphSpacingBefore

            mutable.addAttribute(.paragraphStyle, value: p, range: range)
        }

        // Ensure a base font/color exists for any runs that didn't get explicit attributes.
        mutable.enumerateAttribute(NSAttributedString.Key.font, in: full, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: baseFont, range: range)
            }
        }
        mutable.enumerateAttribute(NSAttributedString.Key.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: textColor, range: range)
            }
        }

        // If the markdown parser didn't attach link attributes (or we're rendering plain text),
        // detect raw URLs and make them clickable.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: mutable.string, options: [], range: full) { match, _, _ in
                guard let match, let url = match.url else { return }
                // Don't clobber any existing link styling.
                let existing = mutable.attribute(NSAttributedString.Key.link, at: match.range.location, effectiveRange: nil)
                if existing == nil {
                    mutable.addAttribute(NSAttributedString.Key.link, value: url, range: match.range)
                }
            }
        }

        replaceHorizontalRules(in: mutable, baseFont: baseFont, textColor: textColor)
        replaceMarkdownTables(in: mutable, baseFont: baseFont, textColor: textColor)
        replaceTaskListCheckboxes(in: mutable, baseFont: baseFont, textColor: textColor)
        styleUnorderedLists(in: mutable)
        styleOrderedLists(in: mutable)
        styleBlockquotes(in: mutable, baseFont: baseFont)
        styleCodeFences(in: mutable, baseFont: baseFont, textColor: textColor)
        styleInlineCode(in: mutable, baseFont: baseFont)

        return mutable
    }
    
    private func syncWidthAndHeight(for textView: NSTextView, in scrollView: PassThroughScrollView) {
        let w = scrollView.contentSize.width

        // If width isn't settled yet, don't do a bogus measurement that explodes row height.
        guard w > 20 else {
            if abs(scrollView.intrinsicHeight - 22) > 0.5 {
                scrollView.intrinsicHeight = 22
                scrollView.invalidateIntrinsicContentSize()
            }
            return
        }

        let availableWidth = w

        textView.textContainer?.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        // Make sure the text view itself matches that width.
        textView.setFrameSize(NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude))

        updateHeight(for: textView, in: scrollView)
    }
    
    private func updateHeight(for textView: NSTextView, in scrollView: PassThroughScrollView) {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else {
            return
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let measured = ceil(used.height + textView.textContainerInset.height * 2)
        let clamped = max(1, measured)
        if abs(scrollView.intrinsicHeight - clamped) > 0.5 {
            scrollView.intrinsicHeight = clamped
            scrollView.invalidateIntrinsicContentSize()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            return openLink(link)
        }

        func textView(_ textView: NSTextView, shouldInteractWith url: URL, in characterRange: NSRange) -> Bool {
            _ = openLink(url)
            return false
        }

        private func openLink(_ link: Any) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let url = (link as? NSURL) as URL? {
                NSWorkspace.shared.open(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }
    }

    /// A non-scrolling scroll view that sizes to its content, and passes
    /// scroll wheel events up to the parent when it has nothing to scroll.
    final class PassThroughScrollView: NSScrollView {
        var intrinsicHeight: CGFloat = 22

        // NEW: called whenever AppKit lays this view out (width becomes "real" here)
        var onLayout: ((PassThroughScrollView) -> Void)?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
        }

        override func layout() {
            super.layout()
            onLayout?(self)
        }

        override func scrollWheel(with event: NSEvent) {
            if let next = nextResponder {
                next.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}

private struct ChatPanelBackground: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let dotRadius: CGFloat = 1.6
                let spacing: CGFloat = 18
                let color = Color(NSColor.separatorColor).opacity(0.4)
                for y in stride(from: 6.0, through: size.height, by: spacing) {
                    for x in stride(from: 6.0, through: size.width, by: spacing) {
                        let rect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
        }
    }
}

private struct ChatAttachmentRow: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        let imageAttachments = store.chatDraftImages
        let fileAttachments = store.chatDraftFiles
        let totalCount = imageAttachments.count + fileAttachments.count
        let label = totalCount == 1 ? "Attachment added" : "\(totalCount) attachments added"
        HStack(spacing: 8) {
            if let imageRef = imageAttachments.first {
                ChatAttachmentThumbnail(imageRef: imageRef, size: 44, cornerRadius: 6)
            } else {
                ChatFileThumbnail(fileRef: fileAttachments.first, size: 44, cornerRadius: 6)
            }
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button(action: {
                store.clearChatDraftImages()
                store.clearChatDraftFiles()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }
}

private struct ChatAttachmentThumbnail: View {
    @EnvironmentObject var store: BoardStore
    let imageRef: ImageRef?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let imageRef,
           let url = store.imageURL(for: imageRef),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(Color(NSColor.separatorColor).opacity(0.35))
                .cornerRadius(cornerRadius)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(NSColor.controlBackgroundColor))
                Image(systemName: "photo")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .frame(width: size, height: size)
        }
    }
}

private struct ChatFileThumbnail: View {
    let fileRef: FileRef?
    let size: CGFloat
    let cornerRadius: CGFloat

    private var fileExtension: String {
        guard let name = fileRef?.originalName, !name.isEmpty else { return "" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "" : ext.uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(NSColor.controlBackgroundColor))
            VStack(spacing: 4) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                if !fileExtension.isEmpty {
                    Text(fileExtension)
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct PasteAwareTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onPasteAttachment: () -> Bool
    var font: NSFont?
    var textColor: NSColor?
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var isBordered: Bool = true
    var drawsBackground: Bool = true
    var focusRingType: NSFocusRingType = .default
    var bezelStyle: NSTextField.BezelStyle = .roundedBezel

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> PasteAwareScrollView {
        let scrollView = PasteAwareScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = PasteAwareTextView()
        textView.delegate = context.coordinator
        textView.onPasteAttachment = onPasteAttachment
        textView.placeholder = placeholder
        textView.string = text
        configure(textView: textView)
        applyStyle(to: textView)
        applyContainerStyle(to: scrollView, textView: textView)
        updateHeight(for: textView, in: scrollView)
        ChatInputFocusBridge.shared.register(textView)

        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: PasteAwareScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteAwareTextView else { return }
        let textChanged = textView.string != text
        if textChanged {
            textView.string = text
            textView.needsDisplay = true
            // Force layout update when text changes
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
        textView.placeholder = placeholder
        textView.onPasteAttachment = onPasteAttachment
        textView.delegate = context.coordinator
        configure(textView: textView)
        applyStyle(to: textView)
        applyContainerStyle(to: nsView, textView: textView)
        updateHeight(for: textView, in: nsView)
        installHeightUpdater(context.coordinator, textView: textView, scrollView: nsView)
        context.coordinator.onCommit = onCommit
        ChatInputFocusBridge.shared.register(textView)
        ChatInputFocusBridge.shared.syncCaretToEndIfNeeded()
    }

    private func installHeightUpdater(_ coordinator: Coordinator,
                                      textView: PasteAwareTextView,
                                      scrollView: PasteAwareScrollView) {
        coordinator.onHeightUpdate = { [weak scrollView, weak textView] in
            guard let scrollView, let textView else { return }
            self.updateHeight(for: textView, in: scrollView)
        }
    }

    private func configure(textView: PasteAwareTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesRuler = false
        textView.usesFontPanel = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = drawsBackground
        textView.backgroundColor = drawsBackground ? NSColor.textBackgroundColor : .clear
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.maximumNumberOfLines = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.onHeightChange = onHeightChange
    }

    private func applyContainerStyle(to scrollView: PasteAwareScrollView, textView: PasteAwareTextView) {
        scrollView.borderType = isBordered ? .bezelBorder : .noBorder
        scrollView.focusRingType = focusRingType
        scrollView.intrinsicHeight = intrinsicHeight(for: textView, bordered: isBordered)
    }

    private func intrinsicHeight(for textView: NSTextView, bordered: Bool) -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textHeight = ceil(font.ascender - font.descender)
        let inset = textView.textContainerInset.height * 2
        let borderPadding: CGFloat = bordered ? 6 : 0
        return textHeight + inset + borderPadding
    }

    private func updateHeight(for textView: PasteAwareTextView, in scrollView: PasteAwareScrollView) {
        let minHeight = intrinsicHeight(for: textView, bordered: isBordered)
        let availableWidth = max(1, scrollView.contentSize.width - textView.textContainerInset.width * 2)
        let measured = measuredHeight(for: textView, minHeight: minHeight, availableWidth: availableWidth)
        if abs(scrollView.intrinsicHeight - measured) > 0.5 {
            scrollView.intrinsicHeight = measured
            scrollView.invalidateIntrinsicContentSize()
            textView.onHeightChange?(measured)
        }
    }

    private func measuredHeight(for textView: NSTextView, minHeight: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return minHeight
        }
        textContainer.containerSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset.height * 2
        let borderPadding: CGFloat = isBordered ? 6 : 0
        let height = ceil(used.height + inset + borderPadding)
        return max(minHeight, height)
    }

    private func applyStyle(to textView: NSTextView) {
        if let font {
            textView.font = font
        }
        if let textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onCommit: () -> Void
        var onHeightUpdate: (() -> Void)?

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self._text = text
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text = editor.string
            onHeightUpdate?()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            handleCommand(commandSelector)
        }

        private func handleCommand(_ commandSelector: Selector) -> Bool {
            if isCommitCommand(commandSelector) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                onCommit()
                return true
            }
            return false
        }

        private func isCommitCommand(_ commandSelector: Selector) -> Bool {
            let name = NSStringFromSelector(commandSelector)
            return name == "insertNewline:" || name == "insertNewlineIgnoringFieldEditor:" || name == "insertLineBreak:"
        }
    }

    final class PasteAwareScrollView: NSScrollView {
        var intrinsicHeight: CGFloat = 22

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
        }
    }

    final class PasteAwareTextView: NSTextView {
        var onPasteAttachment: (() -> Bool)?
        var placeholder: String = "" {
            didSet { needsDisplay = true }
        }
        var onHeightChange: ((CGFloat) -> Void)?

        private func pasteboardLooksLikeImage(_ pasteboard: NSPasteboard) -> Bool {
            // Promised images (e.g. “copy & delete” screenshots)
            if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
               !receivers.isEmpty {
                return true
            }

            // Raw image data (screenshots, copied images)
            if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
                return true
            }

            // HTML with <img ...>
            if let data = pasteboard.data(forType: .html),
               let html = String(data: data, encoding: .utf8),
               html.lowercased().contains("<img") {
                return true
            }
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.html")),
               let html = String(data: data, encoding: .utf8),
               html.lowercased().contains("<img") {
                return true
            }

            return false
        }

        private func handlePaste(_ sender: Any?, fallback: (Any?) -> Void) {
            let pb = NSPasteboard.general

            // First try your app’s attachment handler.
            if onPasteAttachment?() == true { return }

            // If it *looks* like an image paste, swallow it so we don’t beep.
            if pasteboardLooksLikeImage(pb) { return }

            // Otherwise, normal paste (text, urls, etc.)
            fallback(sender)
        }

        override func paste(_ sender: Any?) {
            handlePaste(sender) { super.paste($0) }
        }

        override func pasteAsPlainText(_ sender: Any?) {
            handlePaste(sender) { super.pasteAsPlainText($0) }
        }

        override func pasteAsRichText(_ sender: Any?) {
            handlePaste(sender) { super.pasteAsRichText($0) }
        }

        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            switch item.action {
            case #selector(paste(_:)),
                 #selector(pasteAsPlainText(_:)),
                 #selector(pasteAsRichText(_:)):
                return true
            default:
                return super.validateUserInterfaceItem(item)
            }
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let inset = textContainerInset
            let linePadding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(x: inset.width + linePadding,
                              y: inset.height,
                              width: bounds.width - inset.width * 2 - linePadding * 2,
                              height: bounds.height - inset.height * 2)
            placeholder.draw(in: rect, withAttributes: attributes)
        }
    }
}

struct SettingsPanelView: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var syncService: BoardSyncService
    @State private var hudColorObserver: NSObjectProtocol?
    @State private var email: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                Button(action: sendMagicLink) {
                    if authService.isSendingLink {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("Send sign-in link")
                    }
                }
                .disabled(authService.isSendingLink || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(authStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
            if let message = authService.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Text("Name")
                .font(.headline)
            TextField("Name", text: userNameBinding)
                .textFieldStyle(.roundedBorder)

            Text("Voice")
                .font(.headline)
            Picker("Voice", selection: voiceBinding) {
                ForEach(ChatSettings.availableVoices, id: \.self) { voice in
                    Text(voice.capitalized).tag(voice)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            Text("Stored preference; spoken replies are disabled.")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Always listening (wake word: \"Astra\")", isOn: alwaysListeningBinding)
                .toggleStyle(.switch)
            Text("Starts voice input when Astra hears the wake word.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("Sync (debug)")
                .font(.headline)
            Text("Pull: \(syncService.pullStatusText)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Push: \(syncService.pushStatusText)")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Sync across devices", isOn: syncEnabledBinding)
                .toggleStyle(.switch)
            Text("Disables automatic pulls/pushes/persistence uploads until re-enabled.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("HUD")
                .font(.headline)
            hudBarColorRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            removeHUDColorObserver()
        }
        .onAppear {
            if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let existingEmail = authService.user?.email {
                email = existingEmail
            }
        }
    }

    private var authStatusText: String {
        if let email = authService.user?.email, !email.isEmpty {
            return "Signed in as \(email)"
        }
        return "Signed out"
    }

    private func sendMagicLink() {
        Task {
            do {
                try await authService.sendMagicLink(email: email)
            } catch {
                // AuthService already captures statusMessage.
            }
        }
    }

    private var hudBarColorRow: some View {
        HStack {
            Text("Bar Color")
                .frame(width: 90, alignment: .leading)
            Button(action: openHUDColorPanel) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hudBarColorPreview)
                        .frame(width: 34, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1))
                    Text("Choose...")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var hudBarColorPreview: Color {
        store.doc.ui.hudBarColor.color.opacity(store.doc.ui.hudBarOpacity)
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(get: {
            store.isDeviceSyncEnabled
        }, set: { newValue in
            store.setDeviceSyncEnabled(newValue)
        })
    }

    private var userNameBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.userName
        }, set: { newValue in
            store.updateChatSettings { $0.userName = newValue }
        })
    }

    private var voiceBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.voice
        }, set: { newValue in
            store.updateChatSettings { $0.voice = newValue }
        })
    }

    private var alwaysListeningBinding: Binding<Bool> {
        Binding(get: {
            store.doc.chatSettings.alwaysListening
        }, set: { newValue in
            store.updateChatSettings { $0.alwaysListening = newValue }
        })
    }

    private func openHUDColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = store.doc.ui.hudBarColor.nsColor(alpha: store.doc.ui.hudBarOpacity)
        panel.makeKeyAndOrderFront(nil)

        if hudColorObserver == nil {
            hudColorObserver = NotificationCenter.default.addObserver(
                forName: NSColorPanel.colorDidChangeNotification,
                object: panel,
                queue: .main
            ) { note in
                guard let panel = note.object as? NSColorPanel else { return }
                Task { @MainActor in
                    store.updateHUDBarStyle(color: panel.color)
                }
            }
        }
    }

    private func removeHUDColorObserver() {
        if let observer = hudColorObserver {
            NotificationCenter.default.removeObserver(observer)
            hudColorObserver = nil
        }
    }
}

private struct PanelResizeHandles: View {
    @EnvironmentObject var store: BoardStore
    var frame: CGRect
    var minSize: CGSize
    var panelKind: PanelKind
    var onUpdate: (CGRect) -> Void

    private let edgeThickness: CGFloat = 8
    private let cornerSize: CGFloat = 16

    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        let width = frame.width
        let height = frame.height
        ZStack {
            // Top edge
            edgeHandle(.top, width: width, height: edgeThickness)
                .position(x: width / 2, y: 0)

            // Bottom edge
            edgeHandle(.bottom, width: width, height: edgeThickness)
                .position(x: width / 2, y: height)

            // Left edge
            edgeHandle(.left, width: edgeThickness, height: height)
                .position(x: 0, y: height / 2)

            // Right edge
            edgeHandle(.right, width: edgeThickness, height: height)
                .position(x: width, y: height / 2)

            // Top-left corner
            cornerHandle(.topLeft)
                .position(x: 0, y: 0)

            // Top-right corner
            cornerHandle(.topRight)
                .position(x: width, y: 0)

            // Bottom-left corner
            cornerHandle(.bottomLeft)
                .position(x: 0, y: height)

            // Bottom-right corner
            cornerHandle(.bottomRight)
                .position(x: width, y: height)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func edgeHandle(_ position: Edge, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue.opacity(0.001))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .cursor(cursor(for: position))
            .gesture(resizeGesture(for: position))
    }

    private func cornerHandle(_ position: Edge) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.001))
            .frame(width: cornerSize, height: cornerSize)
            .contentShape(Rectangle())
            .cursor(cursor(for: position))
            .gesture(resizeGesture(for: position))
    }

    private func cursor(for position: Edge) -> NSCursor {
        switch position {
        case .top, .bottom:
            return NSCursor.resizeUpDown
        case .left, .right:
            return NSCursor.resizeLeftRight
        case .topLeft, .bottomRight:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage(), hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil) ?? NSImage(), hotSpot: NSPoint(x: 8, y: 8))
        }
    }

    private func resizeGesture(for position: Edge) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                store.isDraggingOverlay = true
                let next = clampedFrame(for: position, translation: value.translation)
                onUpdate(next)
            }
            .onEnded { _ in
                store.isDraggingOverlay = false
            }
    }

    private func clampedFrame(for position: Edge, translation: CGSize) -> CGRect {
        var next = frame
        switch position {
        case .top:
            next.origin.y += translation.height
            next.size.height -= translation.height
        case .bottom:
            next.size.height += translation.height
        case .left:
            next.origin.x += translation.width
            next.size.width -= translation.width
        case .right:
            next.size.width += translation.width
        case .topLeft:
            next.origin.x += translation.width
            next.origin.y += translation.height
            next.size.width -= translation.width
            next.size.height -= translation.height
        case .topRight:
            next.origin.y += translation.height
            next.size.width += translation.width
            next.size.height -= translation.height
        case .bottomLeft:
            next.origin.x += translation.width
            next.size.width -= translation.width
            next.size.height += translation.height
        case .bottomRight:
            next.size.width += translation.width
            next.size.height += translation.height
        }

        if next.size.width < minSize.width {
            let delta = minSize.width - next.size.width
            switch position {
            case .left, .topLeft, .bottomLeft:
                next.origin.x -= delta
            default:
                break
            }
            next.size.width = minSize.width
        }
        if next.size.height < minSize.height {
            let delta = minSize.height - next.size.height
            switch position {
            case .top, .topLeft, .topRight:
                next.origin.y -= delta
            default:
                break
            }
            next.size.height = minSize.height
        }

        return next
    }
}

struct MemoriesPanelView: View {
    @EnvironmentObject var store: BoardStore
    @FocusState private var panelFocused: Bool

    @State private var isFindVisible: Bool = false
    @State private var findQuery: String = ""
    @State private var findMatches: [Int] = []
    @State private var findIndex: Int = 0
    @State private var pendingFindCommand: FindCommand?
    @State private var selectedCategory: MemoryCategory = .longTerm
    @State private var hasInitializedCategory: Bool = false

    private enum FindCommand: Equatable {
        case open, next, prev, close
    }

    private func rebuildFindMatches(_ memories: [Memory]) {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }

        let hits = memories.enumerated().compactMap { idx, mem in
            mem.text.localizedCaseInsensitiveContains(q) ? idx : nil
        }

        findMatches = hits
        if findIndex >= hits.count { findIndex = 0 }
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard isFindVisible, !findMatches.isEmpty else { return }
        let idx = findMatches[findIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(idx, anchor: .center)
        }
    }

    private func applyFindCommand(_ cmd: FindCommand, memories: [Memory], proxy: ScrollViewProxy) {
        switch cmd {
        case .open:
            isFindVisible = true
            rebuildFindMatches(memories)
            scrollToCurrentMatch(proxy: proxy)

        case .next:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches(memories)
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + 1) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)

        case .prev:
            if !isFindVisible { isFindVisible = true }
            rebuildFindMatches(memories)
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
            scrollToCurrentMatch(proxy: proxy)

        case .close:
            isFindVisible = false
        }
    }

    private var findTarget: FindTarget {
        FindTarget(
            presentFind: { pendingFindCommand = .open },
            findNext: { pendingFindCommand = .next },
            findPrev: { pendingFindCommand = .prev },
            closeFind: { pendingFindCommand = .close }
        )
    }

    private var memories: [Memory] {
        store.doc.memories
    }

    private var filteredMemories: [Memory] {
        memories.filter { $0.category == selectedCategory }
    }

    private var matchSummary: String {
        let trimmed = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Type to search" }
        if findMatches.isEmpty { return "No matches" }
        return "\(findIndex + 1) of \(findMatches.count)"
    }

    @ViewBuilder
    private var emptyStateView: some View {
        Spacer()
        Text("No Memories")
            .font(.headline)
            .foregroundColor(.secondary)
        Text("Memories appear here when saved.")
            .font(.subheadline)
            .foregroundColor(.secondary)
        Spacer()
    }

    @ViewBuilder
    private func memoriesList(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FindBarView(
                isVisible: $isFindVisible,
                query: $findQuery,
                matchSummary: matchSummary,
                onNext: { pendingFindCommand = .next },
                onPrev: { pendingFindCommand = .prev },
                onClose: { pendingFindCommand = .close }
            )

            if filteredMemories.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredMemories.indices, id: \.self) { idx in
                            MemoryRowView(memory: filteredMemories[idx],
                                          rowId: idx,
                                          showsDivider: idx != filteredMemories.count - 1)
                        }
                    }
                }
                .onChange(of: filteredMemories.count) { _ in
                    rebuildFindMatches(filteredMemories)
                }
            }
        }
        // ✅ Find mechanics now attach to a REAL view (the VStack)
        .onAppear {
            if !hasInitializedCategory {
                if !memories.contains(where: { $0.category == selectedCategory }),
                   let firstCategory = MemoryCategory.allCases.first(where: { category in
                       memories.contains(where: { $0.category == category })
                   }) {
                    selectedCategory = firstCategory
                }
                hasInitializedCategory = true
            }
            rebuildFindMatches(filteredMemories)
        }
        .onChange(of: findQuery) { _ in rebuildFindMatches(filteredMemories) }
        .onChange(of: selectedCategory) { _ in rebuildFindMatches(filteredMemories) }
        .onChange(of: pendingFindCommand) { cmd in
            guard let cmd else { return }
            applyFindCommand(cmd, memories: filteredMemories, proxy: proxy)
            pendingFindCommand = nil
        }
    }

    var body: some View {
        ZStack {
            ChatPanelBackground()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Memory Category", selection: $selectedCategory) {
                    ForEach(MemoryCategory.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .pickerStyle(.segmented)

                ScrollViewReader { proxy in
                    memoriesList(proxy: proxy)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
#if os(macOS)
        .focusable(true)
        .hidePanelFocusRing()
        .focused($panelFocused)
        .onTapGesture { panelFocused = true }
        .onExitCommand { pendingFindCommand = .close }
#endif
    }
}

private struct MemoryRowView: View {
    @EnvironmentObject var store: BoardStore
    let memory: Memory
    let rowId: Int
    let showsDivider: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(memory.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let imageRef = memory.image, let url = store.imageURL(for: imageRef) {
                    AsyncImage(url: url) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(4)
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: 200, maxHeight: 200)
                }
            }
            .padding(.vertical, 10)
            Button {
                store.deleteMemory(id: memory.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .help("Delete memory")
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .id(rowId)

        if showsDivider {
            Divider()
        }
    }
}

struct LogPanelView: View {
    @EnvironmentObject var store: BoardStore

    private var chats: [ChatThread] {
        store.doc.chatHistory
            .filter { !$0.messages.isEmpty }
            .sorted { ($0.messages.last?.ts ?? 0) > ($1.messages.last?.ts ?? 0) }
    }

    private func chatPreview(for chat: ChatThread) -> String {
        if let chatTitle = chat.title, !chatTitle.isEmpty {
            return chatTitle
        }
        guard let firstUserMessage = chat.messages.first(where: { $0.role == .user && !$0.text.isEmpty }) else {
            return chat.messages.first?.text ?? "Chat"
        }
        let preview = firstUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "Chat" : preview
    }

    var body: some View {
        VStack(spacing: 0) {
            if chats.isEmpty {
                Spacer()
                Text("No Chat History")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Closed chats will appear here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(chats, id: \.id) { chat in
                            let chatId = chat.id
                            let lastTs = chat.messages.last?.ts ?? 0

                            VStack(alignment: .leading, spacing: 6) {
                                Text(chatPreview(for: chat))
                                    .font(.headline.weight(.medium))
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack {
                                    Text(Date(timeIntervalSince1970: lastTs), style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(Date(timeIntervalSince1970: lastTs), style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("Resume") {
                                        store.resumeArchivedChat(id: chatId)
                                    }
                                    .buttonStyle(.plain)
                                    .controlSize(.small)
                                    .foregroundColor(.accentColor)

                                    Button {
                                        store.deleteArchivedChat(id: chatId)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .controlSize(.small)
                                    .foregroundColor(.red)
                                    .help("Delete Chat History")
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.resumeArchivedChat(id: chatId)
                            }
                            .id(chatId)

                            if chatId != chats.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}


struct StylePanelView: View {
    @EnvironmentObject var store: BoardStore

    private let fontFamilies: [String] = {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        let preferred = [
            TextStyle.systemFontName,
            "Helvetica Neue",
            "Avenir Next",
            "Futura",
            "Didot",
            "Baskerville",
            "Georgia",
            "Gill Sans",
            "Optima",
            "Copperplate",
            "American Typewriter",
            "Chalkduster",
            "Comic Sans MS",
            "Marker Felt",
            "Papyrus",
            "Zapfino",
            "Hoefler Text",
            "Noteworthy",
            "Verdana",
            "Trebuchet MS",
            "Menlo",
            "Courier New"
        ]
        let filtered = preferred.filter { $0 == TextStyle.systemFontName || available.contains($0) }
        if filtered.contains(TextStyle.systemFontName) {
            return Array(filtered.prefix(20))
        }
        return Array(([TextStyle.systemFontName] + filtered).prefix(20))
    }()

    var body: some View {
        let shapeEntry = store.selectedShapeEntry()
        let textEntry = store.selectedTextEntry()

        if shapeEntry == nil && textEntry == nil {
            Text("Select a shape or text to edit its style.")
                .foregroundColor(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = textEntry {
                        textSection(for: entry)
                    }
                    if let entry = shapeEntry {
                        if textEntry != nil {
                            Divider()
                        }
                        shapeSection(for: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func textSection(for entry: BoardEntry) -> some View {
        let fontName = Binding<String>(
            get: { store.textStyle(for: entry).fontName },
            set: { newValue in
                store.updateSelectedTextStyles { style in
                    style.fontName = newValue
                }
            }
        )
        let fontSize = Binding<Double>(
            get: { store.textStyle(for: entry).fontSize },
            set: { newValue in
                store.updateSelectedTextStyles { style in
                    style.fontSize = min(max(newValue, 6), 96)
                }
            }
        )
        let textColor = Binding<Color>(
            get: { store.textStyle(for: entry).textColor.color },
            set: { newColor in
                store.updateSelectedTextStyles { style in
                    style.textColor = ColorComponents.from(color: newColor)
                }
            }
        )
        let textOpacity = Binding<Double>(
            get: { store.textStyle(for: entry).textOpacity },
            set: { newValue in
                store.updateSelectedTextStyles { style in
                    style.textOpacity = max(0, min(1, newValue))
                }
            }
        )
        let outlineColor = Binding<Color>(
            get: { store.textStyle(for: entry).outlineColor.color },
            set: { newColor in
                store.updateSelectedTextStyles { style in
                    style.outlineColor = ColorComponents.from(color: newColor)
                }
            }
        )
        let outlineWidth = Binding<Double>(
            get: { store.textStyle(for: entry).outlineWidth },
            set: { newValue in
                store.updateSelectedTextStyles { style in
                    style.outlineWidth = max(0, newValue)
                }
            }
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text("Text")
                .font(.headline)
            fontRow(title: "Font", selection: fontName)
            sizeRow(title: "Size", value: fontSize, range: 6...96)
            colorRow(title: "Color", selection: textColor)
            opacityRow(title: "Opacity", value: textOpacity)

            Divider()

            Text("Outline")
                .font(.headline)
            colorRow(title: "Color", selection: outlineColor)
            thicknessRow(title: "Thickness", value: outlineWidth, range: 0...12)
        }
    }

    private func shapeSection(for entry: BoardEntry) -> some View {
        let fillColor = Binding<Color>(
            get: { store.shapeStyle(for: entry).fillColor.color },
            set: { newColor in
                store.updateSelectedShapeStyles { style in
                    style.fillColor = ColorComponents.from(color: newColor)
                }
            }
        )
        let fillOpacity = Binding<Double>(
            get: { store.shapeStyle(for: entry).fillOpacity },
            set: { newValue in
                store.updateSelectedShapeStyles { style in
                    style.fillOpacity = max(0, min(1, newValue))
                }
            }
        )
        let borderColor = Binding<Color>(
            get: { store.shapeStyle(for: entry).borderColor.color },
            set: { newColor in
                store.updateSelectedShapeStyles { style in
                    style.borderColor = ColorComponents.from(color: newColor)
                }
            }
        )
        let borderOpacity = Binding<Double>(
            get: { store.shapeStyle(for: entry).borderOpacity },
            set: { newValue in
                store.updateSelectedShapeStyles { style in
                    style.borderOpacity = max(0, min(1, newValue))
                }
            }
        )
        let borderWidth = Binding<Double>(
            get: { store.shapeStyle(for: entry).borderWidth },
            set: { newValue in
                store.updateSelectedShapeStyles { style in
                    style.borderWidth = max(0, newValue)
                }
            }
        )
        
        let isTriangle: Bool = {
            guard case .shape(let kind) = entry.data else { return false }
            switch kind {
            case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
                return true
            default:
                return false
            }
        }()

        let cornerRadiusMax = isTriangle ? 50.0 : 80.0
        let cornerRadiusRange: ClosedRange<Double> = 0...cornerRadiusMax
        
        let cornerRadius = Binding<Double>(
            get: { store.shapeStyle(for: entry).cornerRadius },
            set: { newValue in
                store.updateSelectedShapeStyles { style in
                    style.cornerRadius = min(max(0, newValue), cornerRadiusMax)
                }
            }
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text("Fill")
                .font(.headline)
            colorRow(title: "Color", selection: fillColor)
            opacityRow(title: "Opacity", value: fillOpacity)

            Divider()

            Text("Outline")
                .font(.headline)
            colorRow(title: "Color", selection: borderColor)
            opacityRow(title: "Opacity", value: borderOpacity)
            thicknessRow(title: "Thickness", value: borderWidth, range: 0...20)
            
            Divider()

            Text("Corners")
                .font(.headline)
            thicknessRow(title: "Radius", value: cornerRadius, range: cornerRadiusRange)
        }
    }

    private func fontRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(fontFamilies, id: \.self) { family in
                    Text(family)
                        .font(previewFont(for: family))
                        .tag(family)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func previewFont(for family: String) -> Font {
        if family == TextStyle.systemFontName {
            return .system(size: 13)
        }
        let font = NSFontManager.shared.font(withFamily: family,
                                             traits: [],
                                             weight: 5,
                                             size: 13)
        return font.map { Font($0) } ?? .system(size: 13)
    }

    private func sizeRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func colorRow(title: String, selection: Binding<Color>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func opacityRow(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func thicknessRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

extension ColorComponents {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    func nsColor(alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: CGFloat(alpha))
    }

    func darkened(by multiplier: Double) -> ColorComponents {
        let clamped = max(0, min(1, multiplier))
        guard let rgb = nsColor().usingColorSpace(.sRGB) else {
            return ColorComponents(red: max(0, min(1, red * clamped)),
                                   green: max(0, min(1, green * clamped)),
                                   blue: max(0, min(1, blue * clamped)))
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjustedBrightness = max(0, min(1, brightness * CGFloat(clamped)))
        let adjusted = NSColor(calibratedHue: hue,
                               saturation: saturation,
                               brightness: adjustedBrightness,
                               alpha: alpha)
        let adjustedRGB = adjusted.usingColorSpace(.sRGB) ?? adjusted
        return ColorComponents(red: Double(adjustedRGB.redComponent),
                               green: Double(adjustedRGB.greenComponent),
                               blue: Double(adjustedRGB.blueComponent))
    }

    static func from(color: Color) -> ColorComponents {
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return ColorComponents(red: Double(rgb.redComponent),
                               green: Double(rgb.greenComponent),
                               blue: Double(rgb.blueComponent))
    }

    static func from(nsColor: NSColor) -> ColorComponents {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return ColorComponents(red: Double(rgb.redComponent),
                               green: Double(rgb.greenComponent),
                               blue: Double(rgb.blueComponent))
    }
}

final class HorizontalRuleAttachmentCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize {
        NSSize(width: 0, height: 14) // width ignored; text view gives us the frame width
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let y = cellFrame.midY
        let inset: CGFloat = 0

        NSColor.separatorColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: cellFrame.minX + inset, y: y))
        path.line(to: NSPoint(x: cellFrame.maxX - inset, y: y))
        path.stroke()
    }
}

private func replaceHorizontalRules(in mutable: NSMutableAttributedString,
                                    baseFont: NSFont,
                                    textColor: NSColor)
{
    let s = mutable.string as NSString
    let full = NSRange(location: 0, length: s.length)

    // A line that is ONLY --- or *** or ___ (allow whitespace)
    let pattern = #"(?m)^\s*([-*_])\1\1+\s*$"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
    let line = String(repeating: "─", count: 52) // tweak 40–80 depending on vibe
    let attrs: [NSAttributedString.Key: Any] = [
        .font: mono,
        .foregroundColor: NSColor.separatorColor
    ]

    for m in re.matches(in: mutable.string, range: full).reversed() {
        let rep = NSAttributedString(string: line + "\n", attributes: attrs)
        mutable.replaceCharacters(in: m.range, with: rep)
    }
}

private func replaceMarkdownTables(in mutable: NSMutableAttributedString,
                                   baseFont: NSFont,
                                   textColor: NSColor)
{
    let ns = mutable.string as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Matches a full Markdown table block (header + separator + rows)
    // The pattern is multiline, so we only match blocks that are not broken by hard line breaks.
    let pattern = #"(?m)(^\s*\|.*\|\s*$\n^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$\n(^\s*\|.*\|\s*$\n?)*)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    // Helper to split a row into its cells
    func parseRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // Use a slightly smaller monospaced font for tables
    let mono = NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 2), weight: .regular)

    for match in re.matches(in: mutable.string, range: full).reversed() {
        let block = ns.substring(with: match.range)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else { continue }

        let header = parseRow(lines[0])
        let bodyRows = lines.dropFirst(2).map(parseRow)
        let rows = [header] + bodyRows

        // Determine number of columns
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { continue }

        // Calculate the width of each column in *character* units
        var widths = Array(repeating: 0, count: colCount)
        let sampleChar = "M" as NSString
        let charWidth = sampleChar.size(withAttributes: [.font: mono]).width

        for row in rows {
            for c in 0..<colCount {
                let cell = (c < row.count) ? row[c] : ""
                let cellWidth = (cell as NSString).size(withAttributes: [.font: mono]).width
                let charCount = Int(ceil(cellWidth / charWidth))
                widths[c] = max(widths[c], max(charCount, 3))   // minimum 3 chars wide
            }
        }

        // Helper to pad a string to a given character count
        func pad(_ s: String, to charCount: Int) -> String {
            let str = s as NSString
            let currentChars = Int(ceil(str.size(withAttributes: [.font: mono]).width / charWidth))
            let padding = max(0, charCount - currentChars)
            return s + String(repeating: " ", count: padding)
        }

        // Helper to build a border line
        func border(left: String, mid: String, right: String, fill: String = "─") -> String {
            left + widths.map { String(repeating: fill, count: $0 + 2) }.joined(separator: mid) + right
        }

        // Helper to build a row line
        func rowLine(_ row: [String]) -> String {
            "│" + (0..<colCount).map { c in
                " " + pad(c < row.count ? row[c] : "", to: widths[c]) + " "
            }.joined(separator: "│") + "│"
        }

        // Build the final table string
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: textColor
        ]

        result.append(NSAttributedString(string: border(left: "┌", mid: "┬", right: "┐") + "\n", attributes: attrs))
        result.append(NSAttributedString(string: rowLine(header) + "\n", attributes: attrs))
        result.append(NSAttributedString(string: border(left: "├", mid: "┼", right: "┤") + "\n", attributes: attrs))
        for (index, r) in bodyRows.enumerated() {
            result.append(NSAttributedString(string: rowLine(r) + "\n", attributes: attrs))
            // Add divider between rows (but not after the last row)
            if index < bodyRows.count - 1 {
                result.append(NSAttributedString(string: border(left: "├", mid: "┼", right: "┤") + "\n", attributes: attrs))
            }
        }
        result.append(NSAttributedString(string: border(left: "└", mid: "┴", right: "┘") + "\n", attributes: attrs))

        // Replace the original Markdown table block with the nicely formatted one
        mutable.replaceCharacters(in: match.range, with: result)
    }
}

private func replaceTaskListCheckboxes(in mutable: NSMutableAttributedString,
                                      baseFont: NSFont,
                                      textColor: NSColor)
{
    let ns = mutable.string as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Matches: "- [ ] " , "* [x] ", "1. [ ] " etc
    let pattern = #"(?m)^[ \t]*((?:[-*+])|(?:\d+\.))[ \t]+\[( |x|X)\][ \t]+"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    for m in re.matches(in: mutable.string, range: full).reversed() {
        let prefix = ns.substring(with: m.range(at: 1))      // "-", "*", "1.", etc
        let checked = ns.substring(with: m.range(at: 2))     // " " or "x"
        let box = (checked.lowercased() == "x") ? "☑" : "☐"

        // Keep numbering/bullet prefix, but make it look cleaner
        // Example: "- [ ] thing" -> "• ☐ thing"
        // Example: "1. [x] thing" -> "1. ☑ thing"
        let renderedPrefix: String = {
            if prefix == "-" || prefix == "*" || prefix == "+" { return "•" }
            return prefix
        }()

        let rep = "\(renderedPrefix) \(box) "
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: textColor
        ]
        mutable.replaceCharacters(in: m.range, with: NSAttributedString(string: rep, attributes: attrs))
    }
}

private func styleBlockquotes(in mutable: NSMutableAttributedString,
                              baseFont: NSFont)
{
    var ns = mutable.string as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Match the leading "> " marker on each quoted line
    let pattern = #"(?m)^[ \t]*>[ \t]?"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    for m in re.matches(in: mutable.string, range: full).reversed() {
        let lineStart = m.range.location

        // Remove the "> " marker
        mutable.replaceCharacters(in: m.range, with: "")

        // Insert a subtle bar at the start of the line
        let barAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.separatorColor
        ]
        mutable.insert(NSAttributedString(string: "▍ ", attributes: barAttrs), at: lineStart)

        // Recompute paragraph range after edits
        ns = mutable.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: lineStart, length: 0))

        // Merge paragraph style (don’t nuke existing)
        let existing = (mutable.attribute(.paragraphStyle, at: max(0, paraRange.location), effectiveRange: nil) as? NSParagraphStyle)
        let p = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

        p.firstLineHeadIndent = 18
        p.headIndent = 18
        p.paragraphSpacingBefore = 1
        p.paragraphSpacing = 2

        mutable.addAttribute(.paragraphStyle, value: p, range: paraRange)
    }
}

private func styleCodeFences(in mutable: NSMutableAttributedString,
                             baseFont: NSFont,
                             textColor: NSColor)
{
    let s = mutable.string
    
    // Updated regex to handle code fences more robustly:
    // - Captures optional language identifier (with optional whitespace)
    // - Uses non-greedy matching for content
    // - Handles both \n and \r\n line endings
    // - Works with or without language identifier
    let pattern = #"```[ \t]*(\w+)?[ \t]*[\r\n]+(.*?)[\r\n]+```"#
    
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        print("❌ Failed to create regex for code fences")
        return
    }
    
    let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
    
    // Process matches in reverse to maintain valid indices
    for match in matches.reversed() {
        // Extract language (optional)
        let langRange = match.range(at: 1)
        let lang = (langRange.location != NSNotFound) ? (s as NSString).substring(with: langRange) : ""
        
        // Extract code content
        let contentRange = match.range(at: 2)
        guard contentRange.location != NSNotFound else { continue }
        let content = (s as NSString).substring(with: contentRange)
        
        // Create styled replacement
        let result = NSMutableAttributedString()
        
        // Add language label if present
        if !lang.isEmpty {
            let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let labelColor = NSColor.secondaryLabelColor
            let label = NSAttributedString(string: lang + "\n", attributes: [
                .font: labelFont,
                .foregroundColor: labelColor
            ])
            result.append(label)
        }
        
        // Add code content
        let codeFont = NSFont.monospacedSystemFont(ofSize: max(12, baseFont.pointSize - 2), weight: .regular)
        let codeFg = NSColor.labelColor
        let codeBg = NSColor.controlBackgroundColor.withAlphaComponent(0.85)
        
        let codeText = NSAttributedString(string: content, attributes: [
            .font: codeFont,
            .foregroundColor: codeFg,
            .backgroundColor: codeBg
        ])
        result.append(codeText)
        
        // Apply paragraph style with insets
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 12
        paragraphStyle.headIndent = 12
        paragraphStyle.tailIndent = -12
        paragraphStyle.paragraphSpacingBefore = 2
        paragraphStyle.paragraphSpacing = 2
        paragraphStyle.lineSpacing = 1
        
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        
        // Replace the entire fence (including markers) with the styled content
        mutable.replaceCharacters(in: match.range, with: result)
    }
}

private func styleInlineCode(in mutable: NSMutableAttributedString,
                             baseFont: NSFont)
{
    let s = mutable.string
    let full = NSRange(location: 0, length: mutable.length)
    
    // First, identify all ranges that have code block marker
    var codeBlockRanges: [NSRange] = []
    mutable.enumerateAttribute(.codeBlockMarker, in: full, options: []) { value, range, _ in
        if value != nil {
            codeBlockRanges.append(range)
        }
    }
    
    // Helper to check if a position is inside a code block
    func isInsideCodeBlock(_ position: Int) -> Bool {
        return codeBlockRanges.contains { range in
            position >= range.location && position < NSMaxRange(range)
        }
    }
    
    // Parse single-backtick pairs, skipping those inside code blocks
    var pairs: [(start: Int, end: Int)] = []
    var i = s.startIndex
    var open: Int? = nil

    func offset(of idx: String.Index) -> Int {
        s.distance(from: s.startIndex, to: idx)
    }

    while i < s.endIndex {
        if s[i] == "`" {
            let pos = offset(of: i)
            
            // Skip if this backtick is inside a code block
            if isInsideCodeBlock(pos) {
                i = s.index(after: i)
                open = nil
                continue
            }

            // Skip ``` fences
            let next1 = s.index(after: i)
            if next1 < s.endIndex, s[next1] == "`" {
                let next2 = s.index(after: next1)
                if next2 < s.endIndex, s[next2] == "`" {
                    i = s.index(after: next2)
                    open = nil
                    continue
                }
            }

            if let o = open {
                let startIdx = s.index(s.startIndex, offsetBy: o + 1)
                let endIdx = s.index(s.startIndex, offsetBy: pos)
                if !s[startIdx..<endIdx].contains("\n") && !isInsideCodeBlock(o) {
                    pairs.append((start: o, end: pos))
                }
                open = nil
            } else {
                open = pos
            }
        }
        i = s.index(after: i)
    }

    let mono = NSFont.monospacedSystemFont(ofSize: max(12, baseFont.pointSize - 1), weight: .regular)
    let bg = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
    let fg = NSColor.secondaryLabelColor

    for p in pairs.reversed() {
        let contentRange = NSRange(location: p.start + 1, length: p.end - p.start - 1)

        mutable.addAttributes([
            .font: mono,
            .foregroundColor: fg,
            .backgroundColor: bg
        ], range: contentRange)

        mutable.deleteCharacters(in: NSRange(location: p.end, length: 1))
        mutable.deleteCharacters(in: NSRange(location: p.start, length: 1))
    }
}

private func styleUnorderedLists(in mutable: NSMutableAttributedString) {
    var ns = mutable.string as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Matches: "  - item", "\t* item", "+ item" (but NOT task list "- [ ]")
    let pattern = #"(?m)^([ \t]*)([-*+])[ \t]+(?!\[)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    let matches = re.matches(in: mutable.string, range: full).reversed()
    for m in matches {
        let indentStr = ns.substring(with: m.range(at: 1))
        let indentSpaces = indentStr.filter { $0 == " " }.count + indentStr.filter { $0 == "\t" }.count * 2
        let level = max(0, indentSpaces / 2)

        let start = m.range.location
        mutable.replaceCharacters(in: m.range, with: "• ")

        ns = mutable.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: start, length: 0))

        let existing = mutable.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
        let p = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

        let baseIndent: CGFloat = 18
        let first = CGFloat(level) * baseIndent
        p.firstLineHeadIndent = first
        p.headIndent = first + baseIndent
        p.lineBreakMode = .byWordWrapping

        mutable.addAttribute(.paragraphStyle, value: p, range: paraRange)
    }
}

private func styleOrderedLists(in mutable: NSMutableAttributedString) {
    var ns = mutable.string as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Matches: "  1. item"
    let pattern = #"(?m)^([ \t]*)(\d+)\.[ \t]+"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return }

    let matches = re.matches(in: mutable.string, range: full).reversed()
    for m in matches {
        let indentStr = ns.substring(with: m.range(at: 1))
        let indentSpaces = indentStr.filter { $0 == " " }.count + indentStr.filter { $0 == "\t" }.count * 2
        let level = max(0, indentSpaces / 2)

        let number = ns.substring(with: m.range(at: 2))
        let start = m.range.location

        // Replace "   12. " with "12. "
        mutable.replaceCharacters(in: m.range, with: "\(number). ")

        ns = mutable.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: start, length: 0))

        let existing = mutable.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
        let p = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

        let baseIndent: CGFloat = 18
        let first = CGFloat(level) * baseIndent
        p.firstLineHeadIndent = first
        p.headIndent = first + baseIndent + 6 // a bit wider for "12."
        p.lineBreakMode = .byWordWrapping

        mutable.addAttribute(.paragraphStyle, value: p, range: paraRange)
    }
}

// MARK: - Reminder Panel

struct ReminderPanel: View {
    @EnvironmentObject var store: BoardStore

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        guard let id = store.activeReminderPanelId,
              let reminder = store.getReminder(id: id)
        else {
            return AnyView(EmptyView())
        }

        let dueDate = Date(timeIntervalSince1970: reminder.dueAt)
        let message =
            (reminder.preparedMessage?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Preparing…"

        return AnyView(
            FloatingPanelView(
                panelKind: .reminder,
                title: "Reminder",
                box: store.doc.ui.panels.reminder,
                onUpdate: { frame in
                    store.updatePanel(.reminder, frame: frame)
                },
                onClose: {
                    store.clearActiveReminderPanel()
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reminder.title)
                        .font(.headline)

                    Text(Self.dateFormatter.string(from: dueDate))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Divider()

                    ScrollView {
                        MarkdownText(content: message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 220) // tweak this height to taste

                    HStack {
                        Spacer()
                        Button("Dismiss") {
                            store.clearActiveReminderPanel()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        )
    }
}
