import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

private let panelMinSize = CGSize(width: 220, height: 180)

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

struct HUDView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var chatInput: String
    var onSend: () -> Void
    
    @State private var dragOffset: CGSize = .zero
    @State private var inputHeight: CGFloat = 56
    @State private var isMultiLineInput = false
    @State private var textFieldKey: UUID = UUID() // Add this to force refresh

    private let baseInputHeight: CGFloat = 56
    private let inputVerticalPadding: CGFloat = 20

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
    private var minimizedButtonBackground: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.9 : 0.85)
    }

    var body: some View {
        if store.doc.ui.hud.isVisible {
            let size = hudSize()
            Capsule()
                .fill(barColor)
                .shadow(color: hudShadowColor, radius: 10, x: 0, y: 8)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .center) {
                    HStack(alignment: .center, spacing: 6) {
                        hudButton(symbol: "bubble.left.fill",
                                  isActive: store.doc.ui.panels.chat.isOpen,
                                  isPulsing: !store.doc.ui.panels.chat.isOpen && store.pendingChatReplies > 0,
                                  showsBadge: !store.doc.ui.panels.chat.isOpen && store.chatNeedsAttention) {
                            store.togglePanel(.chat)
                        }
                        hudButton(symbol: "list.bullet.rectangle",
                                  isActive: store.doc.ui.panels.log.isOpen) {
                            store.togglePanel(.log)
                        }
                        hudButton(symbol: "brain.head.profile",
                                  isActive: store.doc.ui.panels.thoughts.isOpen) {
                            store.togglePanel(.thoughts)
                        }
                        Spacer(minLength: 4)
                        inputFieldContainer
                            .id(textFieldKey) // Add key to force recreation
                        if !store.chatDraftImages.isEmpty || !store.chatDraftFiles.isEmpty {
                            hudAttachmentStack
                        }
                        hudButton(symbol: "xmark") { store.toggleHUD() }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
            .foregroundColor(iconColor)
            .offset(x: store.doc.ui.hud.x.cg + dragOffset.width,
                    y: hudOffsetY)
            .simultaneousGesture(hudDragGesture())
            .onChange(of: chatInput) { newValue in
                let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isEmpty {
                    inputHeight = baseInputHeight
                    store.hudExtraHeight = 0
                    isMultiLineInput = false
                    textFieldKey = UUID() // Force text field to recreate
                }
            }
            .onChange(of: inputHeight) { newHeight in
                let isEmpty = chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !isEmpty {
                    let extra = max(0, newHeight - baseInputHeight)
                    store.hudExtraHeight = extra
                }
            }
        } else {
            Button(action: { store.toggleHUD() }) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(minimizedButtonBackground))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
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
                                onCommit: onSend,
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
                .padding(.horizontal, 14)
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
                store.isDraggingOverlay = true
                dragOffset = value.translation
            }
            .onEnded { value in
                store.moveHUD(by: value.translation)
                dragOffset = .zero
                store.clampHUDPosition()
                store.isDraggingOverlay = false
            }
    }

    private func hudSize() -> CGSize {
        BoardStore.hudSize
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

    private var hasChatInputText: Bool {
        !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pinChatInputText() {
        let text = chatInput
        if store.pinChatInputText(text) {
            chatInput = ""
        }
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

private struct HUDScrollCapture: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollCaptureView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
        }
    }
}

struct FloatingPanelHostView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            panelView(for: .chat)
            panelView(for: .chatArchive)
            panelView(for: .log)
            panelView(for: .thoughts)
            panelView(for: .memories)
            panelView(for: .shapeStyle)
            panelView(for: .settings)
            panelView(for: .personality)
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
        case .thoughts:
            if store.doc.ui.panels.thoughts.isOpen {
                FloatingPanelView(panelKind: .thoughts, title: "Thoughts", box: store.doc.ui.panels.thoughts, onUpdate: { frame in
                    store.updatePanel(.thoughts, frame: frame)
                }, onClose: {
                    store.togglePanel(.thoughts)
                }) {
                    ThoughtsPanelView()
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
                }) {
                    SettingsPanelView()
                }
            }
        case .personality:
            if store.doc.ui.panels.personality.isOpen {
                FloatingPanelView(panelKind: .personality, title: "Personality", box: store.doc.ui.panels.personality, onUpdate: { frame in
                    store.updatePanel(.personality, frame: frame)
                }, onClose: {
                    store.togglePanel(.personality)
                }) {
                    PersonalityPanelView()
                }
            }
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
    @ViewBuilder var content: Content
    private var headerBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.85 : 0.7)
    }
    private var panelBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0.82)
    }
    private var panelBorder: Color {
        Color(NSColor.separatorColor)
    }
    private var panelShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15)
    }

    var body: some View {
        let frame = CGRect(x: box.x.cg,
                           y: box.y.cg,
                           width: max(panelMinSize.width, box.w.cg),
                           height: max(panelMinSize.height, box.h.cg))

        return panelBody(frame: frame)
    }

    private func panelBody(frame: CGRect) -> some View {
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
            PanelResizeHandles(
                frame: frame,
                minSize: panelMinSize,
                panelKind: panelKind,
                onUpdate: onUpdate
            )
            .frame(width: frame.width, height: frame.height)
            .clipped()
        }
        .offset(x: frame.minX, y: frame.minY)
    }
}

// MARK: - Auto-scrolling Panels

struct ChatPanelView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: () -> Void

    private var canStartNewChat: Bool {
        !store.doc.chat.messages.isEmpty || store.chatWarning != nil
    }

    var body: some View {
        let lastMessageText = store.doc.chat.messages.last?.text ?? ""
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(store.doc.chat.messages.enumerated()), id: \.element.id) { index, msg in
                                let canRetry = msg.role == .model
                                    && index == store.doc.chat.messages.count - 1
                                    && store.pendingChatReplies == 0
                                let canEdit = msg.role == .user
                                    && store.pendingChatReplies == 0
                                ChatMessageRow(message: msg,
                                               showsRetry: canRetry,
                                               onRetry: { store.retryChatReply(messageId: msg.id) },
                                               showsEdit: canEdit)
                                    .id(msg.id) // Explicit ID for scrolling
                                if index != store.doc.chat.messages.count - 1 {
                                    Rectangle()
                                        .fill(Color(NSColor.separatorColor))
                                        .frame(height: 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: store.doc.chat.messages.count) { _ in
                        if let last = store.doc.chat.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: lastMessageText) { _ in
                        if let last = store.doc.chat.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = store.doc.chat.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

struct ChatArchivePanelView: View {
    @EnvironmentObject var store: BoardStore

    private var archivedChat: ChatThread? {
        guard let id = store.activeArchivedChatId else { return nil }
        return store.archivedChat(id: id)
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
                    }
                } else {
                    Text("Select a chat from the log to view it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
    }
}

private struct ChatMessageRow: View {
    @EnvironmentObject var store: BoardStore
    let message: ChatMsg
    var showsRetry: Bool = false
    var onRetry: () -> Void = {}
    var showsEdit: Bool = false

    @State private var isEditing = false
    @State private var draftText = ""

    private enum ChatTypography {
        static let senderFont = Font.system(size: 18, weight: .semibold)
        static let messageFont = Font.system(size: 17, weight: .regular)
        static let messageLineSpacing: CGFloat = 6
        static let editorMinHeight: CGFloat = 88
    }

    private var hasContent: Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.images.isEmpty
            || !message.files.isEmpty
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
                output.append(line + "  ")
            }
        }
        return output.joined(separator: "\n")
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
                    Text(message.role == .user ? "You" : "Astra")
                        .font(ChatTypography.senderFont)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    if message.role == .model && showsRetry {
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
                    if message.role == .user && showsEdit && !isEditing {
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
                } else if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // NOTE: SwiftUI's `Text(AttributedString)` + `.textSelection(.enabled)`
                    // renders links with blue styling but doesn't reliably make them clickable
                    // on macOS. Use an NSTextView-backed renderer so links open in the browser.
                    if let markdownText {
                        ChatRichTextView(
                            attributedText: NSAttributedString(markdownText),
                            baseFont: NSFont.systemFont(ofSize: 17, weight: .regular),
                            textColor: NSColor.labelColor,
                            lineSpacing: ChatTypography.messageLineSpacing
                        )
                    } else {
                        ChatRichTextView(
                            attributedText: NSAttributedString(string: message.text),
                            baseFont: NSFont.systemFont(ofSize: 17, weight: .regular),
                            textColor: NSColor.labelColor,
                            lineSpacing: ChatTypography.messageLineSpacing
                        )
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
        guard message.role == .user else { return }
        draftText = message.text
        isEditing = true
    }

    private func cancelEditing() {
        draftText = message.text
        isEditing = false
    }

    private func saveEditing() {
        guard message.role == .user else { return }
        store.editChatMessageAndResend(messageId: message.id, text: draftText)
        isEditing = false
    }
}

/// NSTextView-backed message renderer that keeps text selectable *and* makes
/// markdown links clickable on macOS.
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

        let textView = NSTextView()
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
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping

        // Make links look/behave like links.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        applyText(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: PassThroughScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = context.coordinator
        applyText(to: textView, in: nsView)
    }

    private func applyText(to textView: NSTextView, in scrollView: PassThroughScrollView) {
        let display = makeDisplayAttributedString()

        // Assign content.
        textView.textStorage?.setAttributedString(display)

        // Base style (used for any runs that don't specify their own).
        textView.font = baseFont
        textView.textColor = textColor
        textView.insertionPointColor = textColor

        // Keep the text container sized to the available width, then measure height.
        let availableWidth = max(1, scrollView.contentSize.width)
        textView.textContainer?.containerSize = NSSize(width: availableWidth,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        updateHeight(for: textView, in: scrollView)
    }

    private func makeDisplayAttributedString() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let full = NSRange(location: 0, length: mutable.length)

        // Apply paragraph style (line spacing) uniformly.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: full)

        // Ensure a base font/color exists for any runs that didn't get explicit attributes.
        mutable.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: baseFont, range: range)
            }
        }
        mutable.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
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
                let existing = mutable.attribute(.link, at: match.range.location, effectiveRange: nil)
                if existing == nil {
                    mutable.addAttribute(.link, value: url, range: match.range)
                }
            }
        }

        return mutable
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

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
        }

        override func scrollWheel(with event: NSEvent) {
            let docHeight = documentView?.bounds.height ?? 0
            let viewHeight = contentView.bounds.height
            if docHeight <= viewHeight + 1 {
                nextResponder?.scrollWheel(with: event)
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
        installHeightUpdater(context.coordinator, textView: textView, scrollView: scrollView)
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
    @State private var hudColorObserver: NSObjectProtocol?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name")
                .font(.headline)
            TextField("Name", text: userNameBinding)
                .textFieldStyle(.roundedBorder)

            Text("API Key")
                .font(.headline)
            SecureField("sk-...", text: apiKeyBinding)
                .textFieldStyle(.roundedBorder)

            Divider()

            Text("HUD")
                .font(.headline)
            hudBarColorRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            removeHUDColorObserver()
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

    private var apiKeyBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.apiKey
        }, set: { newValue in
            store.updateChatSettings { $0.apiKey = newValue }
        })
    }

    private var userNameBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.userName
        }, set: { newValue in
            store.updateChatSettings { $0.userName = newValue }
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

struct PersonalityPanelView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: personalityBinding)
                    .frame(minHeight: 140)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1))
                if personalityBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("e.g. Be concise and use bullet points.")
                        .foregroundColor(.secondary)
                        .padding(10)
                }
            }
            Text("Used as the system prompt for the model.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var personalityBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.personality
        }, set: { newValue in
            store.updateChatSettings { $0.personality = newValue }
        })
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

struct LogPanelView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.doc.log) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Date(timeIntervalSince1970: item.ts), style: .time)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(item.summary)
                            if let chatId = item.relatedChatId {
                                Button("Open chat") {
                                    store.openArchivedChat(id: chatId)
                                }
                                .buttonStyle(.borderless)
                            }
                            if let ids = item.relatedEntryIds, !ids.isEmpty {
                                let label = ids.map { $0.uuidString.prefix(4) }.joined(separator: ", ")
                                Text("Related: \(label)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .id(item.id) // Explicit ID for scrolling
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.doc.log.count) { _ in
                if let last = store.doc.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = store.doc.log.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct ThoughtsPanelView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.doc.thoughts) { thought in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(Date(timeIntervalSince1970: thought.ts), style: .time)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(thought.summary)
                                    .font(.body)
                            }
                            Spacer()
                            if let target = thought.relatedEntryIds?.first {
                                Button("View") {
                                    store.jumpToEntry(id: target)
                                }
                            }
                        }
                        .id(thought.id) // Explicit ID for scrolling
                        Divider()
                    }
                }
            }
            .onChange(of: store.doc.thoughts.count) { _ in
                if let last = store.doc.thoughts.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = store.doc.thoughts.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct MemoriesPanelView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        if store.doc.memories.isEmpty {
            Text("No memories saved yet.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.doc.memories.enumerated()), id: \.offset) { index, memory in
                        HStack(alignment: .top, spacing: 8) {
                            Text(memory)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(action: { store.deleteMemory(at: index) }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete memory")
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
