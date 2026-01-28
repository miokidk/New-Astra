import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import Supabase

private let panelMinSize = CGSize(width: 240, height: 200)

struct HUDView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String
    var onSend: () -> Void

    @State private var showingAttachmentActions = false
    @State private var showingImagePicker = false
    @State private var showingFileImporter = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 8) {
            if !store.chatDraftImages.isEmpty || !store.chatDraftFiles.isEmpty {
                chatAttachmentRow
            }

            HStack(spacing: 10) {
                Button(action: { store.togglePanel(.chat) }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        if store.pendingChatReplies > 0 || store.chatNeedsAttention {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -6)
                        }
                    }
                }

                Button(action: { showingAttachmentActions = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .confirmationDialog("Add attachment", isPresented: $showingAttachmentActions) {
                    Button("Photo") { showingImagePicker = true }
                    Button("File") { showingFileImporter = true }
                }

                TextField("Message", text: $chatInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { onSend() }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { dismissKeyboard() }
                        }
                    }

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && store.chatDraftImages.isEmpty
                          && store.chatDraftFiles.isEmpty)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .photosPicker(isPresented: $showingImagePicker, selection: $pickedPhoto, matching: .images)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
            guard let url = try? result.get() else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let ref = store.copyFile(at: url) {
                store.appendChatDraftFiles([ref])
            }
        }
        .onChange(of: pickedPhoto) { newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                await MainActor.run {
                    if let ref = store.saveImage(data: data, ext: "png") {
                        store.appendChatDraftImages([ref])
                    }
                    pickedPhoto = nil
                }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var chatAttachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.chatDraftImages, id: \.self) { ref in
                    ZStack(alignment: .topTrailing) {
                        AttachmentImageThumbnail(ref: ref)
                        Button(action: { store.removeChatDraftImage(ref) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                ForEach(store.chatDraftFiles, id: \.self) { ref in
                    ZStack(alignment: .topTrailing) {
                        AttachmentFileThumbnail(ref: ref)
                        Button(action: { store.removeChatDraftFile(ref) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 56)
    }
}

private struct AttachmentImageThumbnail: View {
    @EnvironmentObject var store: BoardStore
    let ref: ImageRef

    var body: some View {
        if let url = store.imageURL(for: ref),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipped()
                .cornerRadius(8)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.secondarySystemBackground))
                .frame(width: 44, height: 44)
                .overlay(Text("Img").font(.caption).foregroundColor(.secondary))
        }
    }
}

private struct AttachmentFileThumbnail: View {
    let ref: FileRef

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(UIColor.secondarySystemBackground))
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "doc.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.secondary)
            )
    }
}

struct FloatingPanelHostView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            panelView(for: .chat)
            panelView(for: .chatArchive)
            panelView(for: .log)
            panelView(for: .memories)
            panelView(for: .shapeStyle)
            panelView(for: .settings)
            panelView(for: .personality)
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
                    ChatPanelView(chatInput: $chatInput)
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
        case .reminder:
            ReminderPanel()
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

        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(8)
            .background(Color(UIColor.systemBackground).opacity(0.85))
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
                .fill(Color(UIColor.systemBackground).opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor.separator), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
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

private struct PanelResizeHandles: View {
    @EnvironmentObject var store: BoardStore
    var frame: CGRect
    var minSize: CGSize
    var panelKind: PanelKind
    var onUpdate: (CGRect) -> Void

    private let edgeThickness: CGFloat = 10
    private let cornerSize: CGFloat = 18

    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        let width = frame.width
        let height = frame.height
        ZStack {
            edgeHandle(.top, width: width, height: edgeThickness)
                .position(x: width / 2, y: 0)
            edgeHandle(.bottom, width: width, height: edgeThickness)
                .position(x: width / 2, y: height)
            edgeHandle(.left, width: edgeThickness, height: height)
                .position(x: 0, y: height / 2)
            edgeHandle(.right, width: edgeThickness, height: height)
                .position(x: width, y: height / 2)
            cornerHandle(.topLeft)
                .position(x: 0, y: 0)
            cornerHandle(.topRight)
                .position(x: width, y: 0)
            cornerHandle(.bottomLeft)
                .position(x: 0, y: height)
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
            .gesture(resizeGesture(for: position))
    }

    private func cornerHandle(_ position: Edge) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.001))
            .frame(width: cornerSize, height: cornerSize)
            .contentShape(Rectangle())
            .gesture(resizeGesture(for: position))
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
                    .frame(minWidth: 140)
                    .focused($fieldFocused)
                    .onSubmit { onNext() }

                Text(matchSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)

                Button(action: onPrev) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)

                Button(action: onNext) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.secondarySystemBackground).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(UIColor.separator), lineWidth: 1)
            )
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            .onChange(of: isVisible) { v in
                if v { DispatchQueue.main.async { fieldFocused = true } }
            }
        }
    }
}

private struct ChatPanelBackground: View {
    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let dotRadius: CGFloat = 1.6
                let spacing: CGFloat = 18
                let color = Color(UIColor.separator).opacity(0.35)
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

private enum ChatScrollAnchor {
    static let bottom = "CHAT_BOTTOM_ANCHOR"
}

private struct ChatViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatBottomMaxYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatPanelView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var chatInput: String

    @State private var isPinnedToBottom: Bool = true
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomMaxY: CGFloat = 0

    @State private var isFindVisible = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0

    private let pinThreshold: CGFloat = 1

    private func recomputePinnedState() {
        guard viewportHeight > 0 else { return }
        let distanceFromBottom = bottomMaxY - viewportHeight
        let pinnedNow = distanceFromBottom <= pinThreshold
        if pinnedNow != isPinnedToBottom {
            isPinnedToBottom = pinnedNow
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

    private func moveToNextMatch(proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches()
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
    }

    private func moveToPrevMatch(proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches()
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
    }

    private var canStartNewChat: Bool {
        !store.doc.chat.messages.isEmpty || store.chatWarning != nil
    }

    var body: some View {
        let lastMessageText = store.doc.chat.messages.last?.text ?? ""
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
                HStack(spacing: 8) {
                    Spacer()
                    if store.pendingChatReplies > 0 {
                        Button("Stop") {
                            store.stopChatReplies()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("New Chat") {
                        store.startNewChat()
                        chatInput = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStartNewChat)

                    Button(action: { isFindVisible.toggle() }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
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
                        onNext: { moveToNextMatch(proxy: proxy) },
                        onPrev: { moveToPrevMatch(proxy: proxy) },
                        onClose: { isFindVisible = false }
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(store.doc.chat.messages.enumerated()), id: \.element.id) { index, msg in
                                let canRetry = msg.role == .model
                                    && index == store.doc.chat.messages.count - 1
                                    && store.pendingChatReplies == 0
                                let canEdit = msg.role == .user
                                    && store.pendingChatReplies == 0
                                let isActiveReply = msg.role == .model
                                    && index == store.doc.chat.messages.count - 1
                                    && store.pendingChatReplies > 0
                                let activityText = (isActiveReply && msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    ? store.chatActivityStatus
                                    : nil

                                ChatMessageRow(
                                    message: msg,
                                    showsRetry: canRetry,
                                    onRetry: { store.retryChatReply(messageId: msg.id) },
                                    showsEdit: canEdit,
                                    activityText: activityText
                                )
                                .id(msg.id)

                                if index != store.doc.chat.messages.count - 1 {
                                    Rectangle()
                                        .fill(Color(UIColor.separator))
                                        .frame(height: 1)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(ChatScrollAnchor.bottom)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: ChatBottomMaxYKey.self,
                                            value: geo.frame(in: .named("chatScroll")).maxY
                                        )
                                    }
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ChatViewportHeightKey.self, value: geo.size.height)
                        }
                    )
                    .onPreferenceChange(ChatViewportHeightKey.self) { h in
                        viewportHeight = h
                        recomputePinnedState()
                    }
                    .onPreferenceChange(ChatBottomMaxYKey.self) { y in
                        bottomMaxY = y
                        recomputePinnedState()
                    }
                    .onAppear {
                        proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                    }
                    .onChange(of: store.doc.chat.messages.count) { _ in
                        guard isPinnedToBottom else { return }
                        withAnimation {
                            proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                        }
                    }
                    .onChange(of: lastMessageText) { _ in
                        guard isPinnedToBottom else { return }
                        proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                    }
                    .onChange(of: findQuery) { _ in
                        rebuildFindMatches()
                        scrollToCurrentMatch(proxy: proxy)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct ChatArchivePanelView: View {
    @EnvironmentObject var store: BoardStore

    @State private var isFindVisible = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0

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

    private func moveToNextMatch(chat: ChatThread, proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches(chat)
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
    }

    private func moveToPrevMatch(chat: ChatThread, proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches(chat)
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
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
                        Button(action: { isFindVisible.toggle() }) {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
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
                            onNext: { moveToNextMatch(chat: archivedChat, proxy: proxy) },
                            onPrev: { moveToPrevMatch(chat: archivedChat, proxy: proxy) },
                            onClose: { isFindVisible = false }
                        )

                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(archivedChat.messages.enumerated()), id: \.element.id) { index, msg in
                                    ChatMessageRow(message: msg)
                                        .id(msg.id)
                                    if index != archivedChat.messages.count - 1 {
                                        Rectangle()
                                            .fill(Color(UIColor.separator))
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
                            scrollToCurrentMatch(proxy: proxy)
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

private struct ChatActivityStatusView: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(UIColor.secondaryLabel).opacity(0.7))
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.0 : 0.6)
                .opacity(pulse ? 1.0 : 0.4)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(UIColor.secondaryLabel))
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

private struct ChatMessageRow: View {
    @EnvironmentObject var store: BoardStore
    let message: ChatMsg
    var showsRetry: Bool = false
    var onRetry: () -> Void = {}
    var showsEdit: Bool = false
    var activityText: String? = nil

    @State private var isEditing = false
    @State private var draftText = ""
    @State private var isWebResultsExpanded = false

    private enum ChatTypography {
        static let senderFont = Font.system(size: 16, weight: .semibold)
        static let messageFont = Font.system(size: 16, weight: .regular)
        static let messageLineSpacing: CGFloat = 6
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
        guard let web = message.webSearch, !web.items.isEmpty else { return s }

        let ns = s as NSString
        let pattern = #"\[(\d+)\]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }

        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        let mutable = NSMutableString(string: s)

        for m in matches.reversed() {
            guard m.numberOfRanges >= 2 else { continue }

            let numStr = ns.substring(with: m.range(at: 1))
            guard let n = Int(numStr), n >= 1, n <= web.items.count else { continue }

            let end = m.range.location + m.range.length
            if end < ns.length {
                let nextChar = ns.substring(with: NSRange(location: end, length: 1))
                if nextChar == "(" { continue }
            }

            let url = web.items[n - 1].url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }

            let replacement = "[\(n)](\(url))"
            mutable.replaceCharacters(in: m.range, with: replacement)
        }

        return mutable as String
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
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground).opacity(0.9)))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(UIColor.secondaryLabel))
            .disabled(!hasContent)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(message.role == .user ? "You" : "Astra")
                        .font(ChatTypography.senderFont)
                        .foregroundColor(Color(UIColor.secondaryLabel))
                    if message.role == .model && showsRetry {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color(UIColor.secondarySystemBackground).opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(UIColor.secondaryLabel))
                    }
                    if message.role == .user && showsEdit && !isEditing {
                        Button(action: startEditing) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color(UIColor.secondarySystemBackground).opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(UIColor.secondaryLabel))
                    }
                }
                if let messageDate {
                    HStack(spacing: 6) {
                        Text(messageDate, style: .date)
                        Text(messageDate, style: .time)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                if let web = message.webSearch, !web.items.isEmpty {
                    DisclosureGroup(isExpanded: $isWebResultsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Query: \"\(web.query)\"")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(web.items.enumerated()), id: \.offset) { idx, item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let url = URL(string: item.url), !item.url.isEmpty {
                                            Link("\(idx + 1). \(item.title)", destination: url)
                                                .font(.system(size: 14, weight: .semibold))
                                        } else {
                                            Text("\(idx + 1). \(item.title)")
                                                .font(.system(size: 14, weight: .semibold))
                                        }

                                        if let snippet = item.snippet,
                                           !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(snippet)
                                                .font(.system(size: 13))
                                                .foregroundColor(.secondary)
                                        }

                                        if !item.url.isEmpty {
                                            Text(item.url)
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(UIColor.secondarySystemBackground).opacity(0.6))
                                    )
                                }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    } label: {
                        Text("Web results")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(UIColor.secondaryLabel))
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
                                .fill(Color(UIColor.secondarySystemBackground).opacity(0.9))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.separator), lineWidth: 1)
                        )
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            cancelEditing()
                        }
                        .buttonStyle(.bordered)
                        Button("Send") {
                            saveEditing()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftText == message.text)
                    }
                } else if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let markdownText {
                        Text(markdownText)
                            .font(ChatTypography.messageFont)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    } else {
                        Text(message.text)
                            .font(ChatTypography.messageFont)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                } else if let activityText, !activityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ChatActivityStatusView(text: activityText)
                        .padding(.vertical, 2)
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
                                        .fill(Color(UIColor.secondarySystemBackground).opacity(0.8))
                                )
                            }
                            .buttonStyle(.plain)
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
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxSide, maxHeight: maxSide)
                .background(Color(UIColor.separator).opacity(0.35))
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

private struct LogPanelView: View {
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
                    LazyVStack(spacing: 0) {
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
                                    .foregroundColor(.accentColor)

                                    Button {
                                        store.deleteArchivedChat(id: chatId)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.red)
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

private struct MemoriesPanelView: View {
    @EnvironmentObject var store: BoardStore

    @State private var isFindVisible: Bool = false
    @State private var findQuery: String = ""
    @State private var findMatches: [Int] = []
    @State private var findIndex: Int = 0

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

    private func moveToNextMatch(memories: [Memory], proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches(memories)
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
    }

    private func moveToPrevMatch(memories: [Memory], proxy: ScrollViewProxy) {
        if !isFindVisible { isFindVisible = true }
        rebuildFindMatches(memories)
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
        scrollToCurrentMatch(proxy: proxy)
    }

    var body: some View {
        let memories = store.doc.memories
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
                    Button(action: { isFindVisible.toggle() }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }

                ScrollViewReader { proxy in
                    FindBarView(
                        isVisible: $isFindVisible,
                        query: $findQuery,
                        matchSummary: matchSummary,
                        onNext: { moveToNextMatch(memories: memories, proxy: proxy) },
                        onPrev: { moveToPrevMatch(memories: memories, proxy: proxy) },
                        onClose: { isFindVisible = false }
                    )

                    Group {
                        if memories.isEmpty {
                            Spacer()
                            Text("No Memories")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Memories saved by the model will show up here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(memories.enumerated()), id: \.element.id) { idx, mem in
                                        HStack(alignment: .top, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(mem.text)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .textSelection(.enabled)

                                                if let imageRef = mem.image, let url = store.imageURL(for: imageRef) {
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
                                                store.deleteMemory(id: mem.id)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.red)
                                            .padding(.top, 8)
                                        }
                                        .padding(.horizontal, 12)
                                        .id(idx)

                                        if idx != memories.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .onChange(of: memories.count) { _ in
                                rebuildFindMatches(memories)
                            }
                        }
                    }
                    .onAppear { rebuildFindMatches(memories) }
                    .onChange(of: findQuery) { _ in rebuildFindMatches(memories) }
                    .onChange(of: findQuery) { _ in scrollToCurrentMatch(proxy: proxy) }
                }
            }
            .padding(12)
        }
    }
}

private struct SettingsPanelView: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var syncService: BoardSyncService
    @State private var email: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.headline)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button(action: sendMagicLink) {
                HStack(spacing: 8) {
                    if authService.isSendingLink {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text("Send sign-in link")
                }
            }
            .disabled(authService.isSendingLink || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(authStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
            if let message = authService.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            TextField("Name", text: userNameBinding)
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: apiKeyBinding)
                .textFieldStyle(.roundedBorder)

            Divider()

            Text("Sync (debug)")
                .font(.headline)
            Text("Pull: \(syncService.pullStatusText)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Push: \(syncService.pushStatusText)")
                .font(.caption)
                .foregroundColor(.secondary)
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
}

private struct PersonalityPanelView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        TextEditor(text: personalityBinding)
            .font(.system(size: 14))
            .frame(minHeight: 120)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground).opacity(0.8))
            )
    }

    private var personalityBinding: Binding<String> {
        Binding(get: {
            store.doc.chatSettings.personality
        }, set: { newValue in
            store.updateChatSettings { $0.personality = newValue }
        })
    }
}

private struct StylePanelView: View {
    @EnvironmentObject var store: BoardStore

    private let fontFamilies: [String] = {
        let available = Set(UIFont.familyNames)
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
            "American Typewriter",
            "Chalkduster",
            "Marker Felt",
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
                        .tag(family)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func sizeRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func colorRow(title: String, selection: Binding<Color>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            ColorPicker("", selection: selection)
                .labelsHidden()
        }
    }

    private func opacityRow(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue))
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

private struct MarkdownText: View {
    let content: String

    var body: some View {
        if let attributed = renderMarkdown() {
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func renderMarkdown() -> AttributedString? {
        let textWithHardBreaks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\n", with: "§§PARAGRAPH§§")
            .replacingOccurrences(of: "\n", with: "  \n")
            .replacingOccurrences(of: "§§PARAGRAPH§§", with: "\n\n")

        guard var attributed = try? AttributedString(markdown: textWithHardBreaks) else {
            return nil
        }

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

private struct ReminderPanel: View {
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
                    .frame(maxHeight: 220)

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

extension ColorComponents {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    static func from(color: Color) -> ColorComponents {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorComponents(red: Double(r), green: Double(g), blue: Double(b))
    }

    /// Treat extreme grayscale colors as semantic so they stay readable in light/dark mode.
    var shouldAutoAdaptForColorScheme: Bool {
        let tol = 0.02
        let isNeutral = abs(red - green) < tol && abs(green - blue) < tol
        guard isNeutral else { return false }

        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.15 || luminance > 0.85
    }
}
