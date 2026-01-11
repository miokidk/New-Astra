import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

private let panelMinSize = CGSize(width: 220, height: 180)

struct HUDView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: () -> Void
    
    @State private var dragOffset: CGSize = .zero
    @State private var inputHeight: CGFloat = 56
    @State private var isMultiLineInput = false
    @State private var textFieldKey: UUID = UUID() // Add this to force refresh

    private let baseInputHeight: CGFloat = 56
    private let inputVerticalPadding: CGFloat = 20

    private let bubbleColor = Color.white.opacity(0.42)
    private let iconColor = Color.gray.opacity(0.65)
    private let accentBorder = Color.gray.opacity(0.35)
    private let activeBorder = Color.black.opacity(0.45)
    private let pulseBorder = Color.black.opacity(0.65)

    var body: some View {
        if store.doc.ui.hud.isVisible {
            let size = hudSize()
            Capsule()
                .fill(barColor)
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 8)
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
                        if store.chatDraftImage != nil {
                            hudAttachmentPreview
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
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.85)))
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
                                onPasteImage: { store.attachChatImageFromPasteboard() },
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

    private var hudAttachmentPreview: some View {
        ChatAttachmentThumbnail(size: 40, cornerRadius: 8)
            .overlay(alignment: .topTrailing) {
                Button(action: { store.clearChatDraftImage() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.black.opacity(0.6))
                        .background(Circle().fill(bubbleColor))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Remove attachment")
            }
    }

    private func hudDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                store.isDraggingOverlay = true
                dragOffset = value.translation
            }
            .onEnded { value in
                store.doc.ui.hud.x += value.translation.width.double
                store.doc.ui.hud.y += value.translation.height.double
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
        NSColor.gray.withAlphaComponent(0.8)
    }

    private var barColor: Color {
        store.doc.ui.hudBarColor.color.opacity(store.doc.ui.hudBarOpacity)
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
    var panelKind: PanelKind
    var title: String
    var box: PanelBox
    var onUpdate: (CGRect) -> Void
    var onClose: () -> Void
    @ViewBuilder var content: Content

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
            .background(Color.white.opacity(0.7))
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
                .fill(Color.white.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
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
                                ChatMessageRow(message: msg)
                                    .id(msg.id) // Explicit ID for scrolling
                                if index != store.doc.chat.messages.count - 1 {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.28))
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
                                            .fill(Color.gray.opacity(0.28))
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

    private var hasContent: Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.image != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: { store.pinChatMessage(message) }) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.gray.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color.gray.opacity(0.7))
            .disabled(!hasContent)
            .help("Pin to board")
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "You" : "Astra")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color.gray.opacity(0.65))
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.text)
                        .font(.system(size: 18))
                        .lineSpacing(4)
                        .foregroundColor(.primary)
                }
                if let imageRef = message.image {
                    if let url = store.imageURL(for: imageRef),
                       let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(8)
                    } else {
                        Text("Image missing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ChatPanelBackground: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let dotRadius: CGFloat = 1.6
                let spacing: CGFloat = 18
                let color = Color.gray.opacity(0.18)
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
        HStack(spacing: 8) {
            ChatAttachmentThumbnail(size: 44, cornerRadius: 6)
            Text("Image attached")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button(action: { store.clearChatDraftImage() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.gray.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }
}

private struct ChatAttachmentThumbnail: View {
    @EnvironmentObject var store: BoardStore
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if let imageRef = store.chatDraftImage,
           let url = store.imageURL(for: imageRef),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.05))
                .cornerRadius(cornerRadius)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.15))
                Image(systemName: "photo")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(Color.gray.opacity(0.6))
            }
            .frame(width: size, height: size)
        }
    }
}

struct PasteAwareTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onPasteImage: () -> Bool
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
        textView.onPasteImage = onPasteImage
        textView.placeholder = placeholder
        textView.string = text
        configure(textView: textView)
        applyStyle(to: textView)
        applyContainerStyle(to: scrollView, textView: textView)
        updateHeight(for: textView, in: scrollView)

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
        textView.onPasteImage = onPasteImage
        textView.delegate = context.coordinator
        configure(textView: textView)
        applyStyle(to: textView)
        applyContainerStyle(to: nsView, textView: textView)
        updateHeight(for: textView, in: nsView)
        installHeightUpdater(context.coordinator, textView: textView, scrollView: nsView)
        context.coordinator.onCommit = onCommit
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
        var onPasteImage: (() -> Bool)?
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
            if onPasteImage?() == true { return }

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

    private let models = [
        "gpt-5.2",
        "gpt-5-nano"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model")
                .font(.headline)
            Picker("", selection: modelBinding) {
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

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
                            .stroke(Color.black.opacity(0.15), lineWidth: 1))
                    Text("Choose...")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var hudBarColorPreview: Color {
        store.doc.ui.hudBarColor.color.opacity(store.doc.ui.hudBarOpacity)
    }

    private var modelBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.model
        }, set: { newValue in
            store.updateChatSettings { $0.model = newValue }
        })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.apiKey
        }, set: { newValue in
            store.updateChatSettings { $0.apiKey = newValue }
        })
    }

    private var availableModels: [String] {
        let current = store.doc.chatSettings.model
        if current.isEmpty || models.contains(current) {
            return models
        }
        return [current] + models
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
                store.updateHUDBarStyle(color: panel.color)
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
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1))
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
            if !store.liveReasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live reasoning summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.liveReasoningSummary)
                        .font(.caption)
                        .textSelection(.enabled)
                    if let t = store.liveReasoningTokens {
                        Text("Reasoning tokens: \(t)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
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
                            if let t = thought.reasoningTokens {
                                Text("Reasoning tokens: \(t)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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
