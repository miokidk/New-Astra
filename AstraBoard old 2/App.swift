import SwiftUI
import AppKit

@main
struct AstraBoardApp: App {
    @StateObject private var store = BoardStore(persistence: PersistenceService(), aiService: AIService())

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Board") {
                Button("Export JSON") { store.exportDocument() }
                Button("Import JSON") { store.importDocument() }
                Divider()
                Button("Delete Selected") { store.deleteSelected() }.keyboardShortcut(.delete)
                Button("Duplicate Selected") { store.duplicateSelected() }.keyboardShortcut("d", modifiers: [.command])
            }
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
        let attachment = store.chatDraftImage
        if !trimmed.isEmpty || attachment != nil {
            let text = chatInput
            let didSend = store.sendChat(text: text, image: attachment)
            if didSend {
                chatInput = ""
                store.clearChatDraftImage()
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onReturn: onReturn, onCopy: onCopy, onPaste: onPaste)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onReturn = onReturn
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
        context.coordinator.startMonitoring()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onReturn = onReturn
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
    }

    final class Coordinator {
        var onReturn: () -> Void
        var onCopy: () -> Bool
        var onPaste: () -> Bool
        private var monitor: Any?

        init(onReturn: @escaping () -> Void, onCopy: @escaping () -> Bool, onPaste: @escaping () -> Bool) {
            self.onReturn = onReturn
            self.onCopy = onCopy
            self.onPaste = onPaste
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
