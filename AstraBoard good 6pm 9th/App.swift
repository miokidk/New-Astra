import SwiftUI
import AppKit

// MARK: - Cmd+F Find plumbing (focus-aware)

struct FindTarget {
    var presentFind: () -> Void
    var findNext: () -> Void
    var findPrev: () -> Void
    var closeFind: () -> Void
}

private struct FindTargetKey: FocusedValueKey {
    typealias Value = FindTarget
}

extension FocusedValues {
    var findTarget: FindTarget? {
        get { self[FindTargetKey.self] }
        set { self[FindTargetKey.self] = newValue }
    }
}


final class AstraAppModel: ObservableObject {
    let persistence = PersistenceService()
    let aiService = AIService()
    let webSearchService = WebSearchService()

    var defaultBoardId: UUID {
        persistence.defaultBoardId()
    }

    func createBoard() -> UUID {
        persistence.createBoard().id
    }
}

/// One SwiftUI scene (window/tab) == one board.
struct BoardRootView: View {
    @StateObject private var store: BoardStore

    init(boardID: UUID, appModel: AstraAppModel) {
        _store = StateObject(wrappedValue: BoardStore(
            boardID: boardID,
            persistence: appModel.persistence,
            aiService: appModel.aiService,
            webSearchService: appModel.webSearchService
        ))
    }

    var body: some View {
        MainView()
            .environmentObject(store)
            .focusedSceneObject(store)
    }
}

struct AstraCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var store: BoardStore?
    @FocusedValue(\.findTarget) private var findTarget

    let appModel: AstraAppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Board Tab") {
                let id = appModel.createBoard()
                openWindow(value: id)
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("New Board Window") {
                let id = appModel.createBoard()
                openWindow(value: id)
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { _ = store?.undo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!(store?.canUndo ?? false))

            Button("Redo") { _ = store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(store?.canRedo ?? false))
        }

        CommandMenu("Board") {
            Button("Export JSON") { store?.exportDocument() }
                .disabled(store == nil)
            Button("Import JSON") { store?.importDocument() }
                .disabled(store == nil)
            Divider()
            Button("Delete Selected") { store?.deleteSelected() }
                .keyboardShortcut(.delete)
                .disabled(store == nil)
            Button("Duplicate Selected") { store?.duplicateSelected() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(store == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()

            Button("Find…") { findTarget?.presentFind() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(findTarget == nil)

            Divider()

            Button("Find Next") { findTarget?.findNext() }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(findTarget == nil)

            Button("Find Previous") { findTarget?.findPrev() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(findTarget == nil)

            Divider()

            Button("Close Find") { findTarget?.closeFind() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(findTarget == nil)
        }


    }
}

@main
struct AstraBoardApp: App {
    @StateObject private var appModel = AstraAppModel()

    var body: some Scene {
        WindowGroup(for: UUID.self) { boardID in
            // boardID is Binding<UUID?>
            let resolved: UUID = {
                if let id = boardID.wrappedValue { return id }

                let id = appModel.createBoard() // or appModel.defaultBoardId if you don't want auto-new
                DispatchQueue.main.async { boardID.wrappedValue = id }
                return id
            }()

            BoardRootView(boardID: resolved, appModel: appModel)
                .environmentObject(appModel)   // ✅ View-level (works on older macOS)
        }
        .windowStyle(.titleBar)
        .commands {
            AstraCommands(appModel: appModel)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: BoardStore
    @State private var activeTextEdit: UUID?
    @State private var chatInput: String = ""
    @State private var previousActiveTextEdit: UUID?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BoardGridView()
                BoardWorldView(activeTextEdit: $activeTextEdit)
                ToolPaletteView()
                    .padding(12)
                    .zIndex(15)

                FloatingPanelHostView(chatInput: $chatInput, onSend: submitChat)
                    .zIndex(10)

                HUDView(chatInput: $chatInput, onSend: submitChat)
                    .zIndex(20)   // always clickable
            }
            .background(Color(NSColor.windowBackgroundColor))
            .background(
                KeyCommandCatcher(onReturn: {
                    handleReturnKey()
                }, onCopy: {
                    store.copySelectedImagesToPasteboard()
                }, onPaste: {
                    store.pasteFromPasteboard()
                }, onUndo: {
                    return store.undo()
                }, onRedo: {
                    return store.redo()
                }, onType: { text in
                    guard activeTextEdit == nil, store.selection.isEmpty else { return false }
                    chatInput.append(text)
                    ChatInputFocusBridge.shared.requestFocus(moveCaretToEnd: true)
                    return true
                })
            )
            .onAppear { store.viewportSize = geo.size }
            .onChange(of: geo.size) { store.viewportSize = $0 }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers, geometry: geo)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onChange(of: store.selection) { newSelection in
            if let active = activeTextEdit, !newSelection.contains(active) {
                activeTextEdit = nil
            }
        }
        .onChange(of: activeTextEdit) { newValue in
            // When text editing ends, delete if empty
            if let previousActive = previousActiveTextEdit, newValue != previousActive {
                if let entry = store.doc.entries[previousActive],
                   entry.type == .text,
                   case .text(let text) = entry.data,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.deleteEntry(id: previousActive)
                }
            }
            previousActiveTextEdit = newValue
        }
    }

    private func handleDrop(providers: [NSItemProvider], geometry: GeometryProxy) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        if let ref = store.copyImage(at: url) {
                            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let world = store.worldPoint(from: center)
                            let rect = CGRect(x: world.x - 120, y: world.y - 90, width: 240, height: 180)
                            _ = store.createEntry(type: .image, frame: rect, data: .image(ref))
                        } else if let fileRef = store.copyFile(at: url) {
                            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let world = store.worldPoint(from: center)
                            let rect = CGRect(x: world.x - 130, y: world.y - 60, width: 260, height: 120)
                            _ = store.createEntry(type: .file, frame: rect, data: .file(fileRef))
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func handleReturnKey() {
        submitChat()
    }

    private func submitChat() {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = store.chatDraftImages
        let fileAttachments = store.chatDraftFiles
        if !trimmed.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty {
            let text = chatInput
            let didSend = store.sendChat(text: text, images: imageAttachments, files: fileAttachments)
            if didSend {
                chatInput = ""
                store.clearChatDraftImages()
                store.clearChatDraftFiles()
            }
        } else if !store.selection.isEmpty {
            chatInput = ""
            store.selection.removeAll()
        } else {
            chatInput = ""
        }
    }

}

struct KeyCommandCatcher: NSViewRepresentable {
    var onReturn: () -> Void
    var onCopy: () -> Bool
    var onPaste: () -> Bool
    var onUndo: () -> Bool
    var onRedo: () -> Bool
    var onType: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onReturn: onReturn, onCopy: onCopy, onPaste: onPaste, onUndo: onUndo, onRedo: onRedo, onType: onType)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onReturn = onReturn
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
        context.coordinator.onType = onType
        context.coordinator.startMonitoring()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onReturn = onReturn
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
        context.coordinator.onType = onType
    }

    final class Coordinator {
        var onReturn: () -> Void
        var onCopy: () -> Bool
        var onPaste: () -> Bool
        var onUndo: () -> Bool
        var onRedo: () -> Bool
        var onType: (String) -> Bool
        private var monitor: Any?

        init(onReturn: @escaping () -> Void,
             onCopy: @escaping () -> Bool,
             onPaste: @escaping () -> Bool,
             onUndo: @escaping () -> Bool,
             onRedo: @escaping () -> Bool,
             onType: @escaping (String) -> Bool) {
            self.onReturn = onReturn
            self.onCopy = onCopy
            self.onPaste = onPaste
            self.onUndo = onUndo
            self.onRedo = onRedo
            self.onType = onType
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if self.handle(event: event) {
                    return nil
                }
                return event
            }
        }

        private func handle(event: NSEvent) -> Bool {
            if isCopyCommand(event) {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return false
                }
                return onCopy()
            }
            if isPasteCommand(event) {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return false
                }
                return onPaste()
            }
            if isUndoCommand(event) {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return false
                }
                return onUndo()
            }
            if isRedoCommand(event) {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return false
                }
                return onRedo()
            }
            if shouldHandleTextInput(event), let text = event.characters, !text.isEmpty {
                return onType(text)
            }
            guard event.keyCode == 36 || event.keyCode == 76 else { return false }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return false
            }
            onReturn()
            return true
        }

        private func isCopyCommand(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control) else {
                return false
            }
            let isCKey = event.charactersIgnoringModifiers?.lowercased() == "c" || event.keyCode == 8
            return isCKey
        }

        private func isPasteCommand(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control) else {
                return false
            }
            let isVKey = event.charactersIgnoringModifiers?.lowercased() == "v" || event.keyCode == 9
            return isVKey
        }

        private func isUndoCommand(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control),
                  !modifiers.contains(.shift) else {
                return false
            }
            let isZKey = event.charactersIgnoringModifiers?.lowercased() == "z" || event.keyCode == 6
            return isZKey
        }

        private func isRedoCommand(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  modifiers.contains(.shift),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control) else {
                return false
            }
            let isZKey = event.charactersIgnoringModifiers?.lowercased() == "z" || event.keyCode == 6
            return isZKey
        }

        private func shouldHandleTextInput(_ event: NSEvent) -> Bool {
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return false
            }
            if event.specialKey != nil {
                return false
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) {
                return false
            }
            guard let text = event.characters, !text.isEmpty else { return false }
            if text.contains("\n") || text.contains("\r") || text.contains("\t") {
                return false
            }
            return true
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Chat input that intercepts ⌘V for images

struct PastingChatTextView: NSViewRepresentable {
    @Binding var text: String
    var onPasteImage: () -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = ChatPastingTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.delegate = context.coordinator
        textView.string = text
        textView.onPasteImage = onPasteImage

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        (tv as? ChatPastingTextView)?.onPasteImage = onPasteImage
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }

    final class ChatPastingTextView: NSTextView {
        var onPasteImage: (() -> Bool)?

        override func paste(_ sender: Any?) {
            // If clipboard has an image, attach it (don’t paste junk into the field).
            if onPasteImage?() == true { return }
            super.paste(sender)
        }
    }
}
