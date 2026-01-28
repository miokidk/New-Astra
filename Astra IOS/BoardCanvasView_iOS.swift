import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

struct BoardCanvasView_iOS: View {
    @ObservedObject var store: BoardStore

    @State private var chatInput: String = ""
    @State private var toolPaletteFrame: CGRect = .zero
    @State private var toolPaletteSize: CGSize = .zero
    @State private var toolPaletteWorldPoint: CGPoint = .zero
    @State private var pendingImageInsertPoint: CGPoint?
    @State private var pendingFileInsertPoint: CGPoint?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingImagePicker = false
    @State private var showingFileImporter = false
    @State private var showingBoardsSheet = false
    @State private var previousEditingEntryID: UUID?
    @State private var showingCameraCapture = false
    @State private var pendingCameraMessage: String?

    private struct ToolPaletteFrameKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    private struct ToolPaletteSizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(UIColor.systemBackground).ignoresSafeArea()

                DottedGridView(size: geo.size, pan: store.pan, zoom: store.zoom)
                    .allowsHitTesting(false)

                ZStack(alignment: .topLeading) {
                    ForEach(store.doc.zOrder, id: \.self) { id in
                        if let entry = store.doc.entries[id] {
                            EntryContainerView(entry: entry)
                        }
                    }

                    ForEach(store.doc.zOrder, id: \.self) { id in
                        if let entry = store.doc.entries[id],
                           store.selection.contains(id),
                           (entry.type == .shape || entry.type == .text) {
                            styleButtonOverlay(for: entry)
                        }
                    }
                }
                .coordinateSpace(name: "board")

                CanvasGestureOverlay(
                    onPan: { delta, _ in handlePan(delta: delta) },
                    onPinch: { scaleDelta, center, _ in handlePinch(scaleDelta: scaleDelta, center: center) },
                    onTap: { point in handleTap(screenPoint: point) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.isToolMenuVisible {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { store.hideToolMenu() }
                }

                if store.isToolMenuVisible {
                    let clampedPoint = clampedPalettePoint(store.toolMenuScreenPosition,
                                                           size: toolPaletteSize,
                                                           in: geo.size)
                    ToolPalettePopover(
                        screenPoint: clampedPoint,
                        onSelectTool: { tool in
                            if store.currentTool == tool {
                                store.currentTool = .select
                            } else {
                                store.currentTool = tool
                            }
                            store.hideToolMenu()
                        },
                        onAddFile: {
                            pendingFileInsertPoint = toolPaletteWorldPoint
                            showingFileImporter = true
                            store.hideToolMenu()
                        },
                        onOpenPanel: { panel in
                            store.togglePanel(panel)
                            store.hideToolMenu()
                        },
                        onOpenBoards: {
                            showingBoardsSheet = true
                            store.hideToolMenu()
                        },
                        onClearBoard: {
                            store.clearBoard()
                            store.hideToolMenu()
                        }
                    )
                    .zIndex(5)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ToolPaletteFrameKey.self,
                                value: proxy.frame(in: .named("BoardSpace"))
                            )
                        }
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ToolPaletteSizeKey.self,
                                value: proxy.size
                            )
                        }
                    )
                }

                FloatingPanelHostView(chatInput: $chatInput)
                    .zIndex(10)

                HUDView(chatInput: $chatInput, onSend: submitChat)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(20)
            }
            .contentShape(Rectangle())
            .onAppear { store.viewportSize = geo.size }
            .onChange(of: geo.size) { store.viewportSize = $0 }
            .onChange(of: pickedPhoto) { newItem in
                guard let newItem else { return }
                Task {
                    guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                    guard let image = UIImage(data: data) else { return }
                    await MainActor.run {
                        defer {
                            pickedPhoto = nil
                            pendingImageInsertPoint = nil
                            store.currentTool = .select
                        }
                        guard let ref = store.saveImage(data: data, ext: "png") else { return }
                        let point = pendingImageInsertPoint ?? toolPaletteWorldPoint
                        let rect = imageRect(for: image, centeredAt: point, maxSide: 320)
                        let id = store.createEntry(type: .image, frame: rect, data: .image(ref))
                        store.select(id)
                    }
                }
            }
            .photosPicker(isPresented: $showingImagePicker, selection: $pickedPhoto, matching: .images)
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
                guard let url = try? result.get() else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let ref = store.copyFile(at: url) else { return }
                let point = pendingFileInsertPoint ?? toolPaletteWorldPoint
                let rect = CGRect(x: point.x - 130, y: point.y - 60, width: 260, height: 120)
                let id = store.createEntry(type: .file, frame: rect, data: .file(ref))
                store.select(id)
                pendingFileInsertPoint = nil
            }
            .sheet(isPresented: $showingBoardsSheet) {
                BoardsSheetView(
                    onSelectBoard: { boardId in
                        store.switchBoard(id: boardId)
                        chatInput = ""
                    },
                    onCreateBoard: {
                        store.createBoard()
                        chatInput = ""
                    },
                    onDeleteBoard: { boardId in
                        store.deleteBoard(id: boardId)
                        chatInput = ""
                    }
                )
                .environmentObject(store)
            }
            .fullScreenCover(isPresented: $showingCameraCapture) {
                CameraCaptureView(
                    onCapture: { image in
                        handleCameraCapture(image)
                    },
                    onCancel: {
                        handleCameraCancel()
                    }
                )
                .ignoresSafeArea()
            }
        }
        .coordinateSpace(name: "BoardSpace")
        .onPreferenceChange(ToolPaletteFrameKey.self) { toolPaletteFrame = $0 }
        .onPreferenceChange(ToolPaletteSizeKey.self) { toolPaletteSize = $0 }
        .onChange(of: store.selection) { newSelection in
            if let editing = store.editingEntryID, !newSelection.contains(editing) {
                store.endEditing()
            }
        }
        .onChange(of: store.editingEntryID) { newValue in
            if let previous = previousEditingEntryID,
               previous != newValue,
               let entry = store.doc.entries[previous],
               case .text(let text) = entry.data,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.deleteEntry(id: previous)
            }
            previousEditingEntryID = newValue
        }
    }

    private func handleTap(screenPoint: CGPoint) {
        dismissKeyboard()
        let wasToolMenuVisible = store.isToolMenuVisible
        if wasToolMenuVisible {
            if toolPaletteFrame.contains(screenPoint) {
                return
            }
            store.hideToolMenu()
            return
        }

        let worldPoint = store.worldPoint(from: screenPoint)

        switch store.currentTool {
        case .select:
            if let hit = store.topEntryAtScreenPoint(screenPoint) {
                if store.editingEntryID != hit {
                    store.endEditing()
                }
                store.select(hit)
            } else {
                store.endEditing()
                store.select(nil)
                if !wasToolMenuVisible {
                    store.showToolMenu(at: screenPoint)
                    toolPaletteWorldPoint = worldPoint
                }
            }
        case .text:
            let rect = CGRect(x: worldPoint.x - 120, y: worldPoint.y - 80, width: 240, height: 160)
            let id = store.createEntry(type: .text, frame: rect, data: .text(""))
            store.select(id)
            store.beginEditing(id)
            store.currentTool = .select
        case .image:
            pendingImageInsertPoint = worldPoint
            showingImagePicker = true
        case .rect:
            let rect = CGRect(x: worldPoint.x - 120, y: worldPoint.y - 80, width: 240, height: 160)
            let id = store.createEntry(type: .shape, frame: rect, data: .shape(.rect))
            store.select(id)
            store.currentTool = .select
        case .circle:
            let rect = CGRect(x: worldPoint.x - 100, y: worldPoint.y - 100, width: 200, height: 200)
            let id = store.createEntry(type: .shape, frame: rect, data: .shape(.circle))
            store.select(id)
            store.currentTool = .select
        case .line:
            let defaultLength: CGFloat = 140 / max(store.zoom, 0.001)
            let end = CGPoint(x: worldPoint.x + defaultLength, y: worldPoint.y)
            let id = store.createLineEntry(start: worldPoint, end: end)
            store.select(id)
            store.currentTool = .select
        }
    }

    private func handlePan(delta: CGPoint) {
        guard !store.isDraggingOverlay else { return }
        dismissKeyboard()
        store.applyPan(translation: CGSize(width: delta.x, height: delta.y))
    }

    private func handlePinch(scaleDelta: CGFloat, center: CGPoint) {
        guard !store.isDraggingOverlay else { return }
        store.applyZoom(delta: scaleDelta, focus: center)
    }

    private func submitChat() {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = store.chatDraftImages
        let fileAttachments = store.chatDraftFiles
        guard !trimmed.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty else { return }
        if shouldTriggerCameraCapture(for: trimmed,
                                      imageAttachments: imageAttachments,
                                      fileAttachments: fileAttachments) {
            beginCameraCapture(for: chatInput)
            return
        }

        let text = chatInput
        let didSend = store.sendChat(text: text, images: imageAttachments, files: fileAttachments)
        if didSend {
            chatInput = ""
            store.clearChatDraftImages()
            store.clearChatDraftFiles()
        }
    }

    private func shouldTriggerCameraCapture(for text: String,
                                            imageAttachments: [ImageRef],
                                            fileAttachments: [FileRef]) -> Bool {
        guard store.doc.pendingClarification == nil else { return false }
        guard imageAttachments.isEmpty, fileAttachments.isEmpty else { return false }
        guard store.doc.entries.isEmpty else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizedCameraPrompt(trimmed)
        guard !normalized.isEmpty else { return false }

        let exactTriggers: Set<String> = [
            "look at this",
            "look at that",
            "what is this",
            "whats this",
            "what is that",
            "whats that",
            "what am i looking at",
            "what am i seeing",
            "do you see this",
            "do you see that",
            "can you see this",
            "can you see that",
            "identify this",
            "identify that",
            "check this out",
            "tell me what this is",
            "any idea what this is",
            "what do you see",
            "what do you see here"
        ]
        if exactTriggers.contains(normalized) {
            return true
        }

        let prefixTriggers = [
            "what is this",
            "whats this",
            "what is that",
            "whats that",
            "look at this",
            "look at that"
        ]
        let wordCount = normalized.split(separator: " ").count
        if wordCount <= 6, prefixTriggers.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        return false
    }

    private func normalizedCameraPrompt(_ text: String) -> String {
        var normalized = text.lowercased()
        normalized = normalized.replacingOccurrences(of: "'", with: "")
        normalized = normalized.replacingOccurrences(of: "[^a-z0-9\\s]", with: " ",
                                                     options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ",
                                                     options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginCameraCapture(for text: String) {
        guard pendingCameraMessage == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            store.chatWarning = "Camera not available on this device."
            return
        }

        pendingCameraMessage = text
        store.chatWarning = nil

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showingCameraCapture = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showingCameraCapture = true
                    } else {
                        pendingCameraMessage = nil
                        store.chatWarning = "Camera access denied. Enable it in Settings to use visual questions."
                    }
                }
            }
        case .denied, .restricted:
            pendingCameraMessage = nil
            store.chatWarning = "Camera access denied. Enable it in Settings to use visual questions."
        @unknown default:
            pendingCameraMessage = nil
            store.chatWarning = "Camera access unavailable."
        }
    }

    private func handleCameraCapture(_ image: UIImage) {
        showingCameraCapture = false
        guard let text = pendingCameraMessage else { return }
        pendingCameraMessage = nil

        let data: Data
        let ext: String
        if let jpg = image.jpegData(compressionQuality: 0.85) {
            data = jpg
            ext = "jpg"
        } else if let png = image.pngData() {
            data = png
            ext = "png"
        } else {
            store.chatWarning = "Failed to capture the camera image."
            return
        }

        guard let ref = store.saveImage(data: data, ext: ext) else {
            store.chatWarning = "Failed to save the camera image."
            return
        }

        let didSend = store.sendChat(text: text, images: [ref], files: [])
        if didSend {
            chatInput = ""
            store.clearChatDraftImages()
            store.clearChatDraftFiles()
        }
    }

    private func handleCameraCancel() {
        showingCameraCapture = false
        pendingCameraMessage = nil
    }

    private func clampedPalettePoint(_ point: CGPoint, size: CGSize, in bounds: CGSize) -> CGPoint {
        let padding: CGFloat = 12
        let fallback = CGSize(width: 56, height: 360)
        let actualSize = size == .zero ? fallback : size
        let halfW = actualSize.width / 2
        let halfH = actualSize.height / 2
        let minX = halfW + padding
        let maxX = max(minX, bounds.width - halfW - padding)
        let minY = halfH + padding
        let maxY = max(minY, bounds.height - halfH - padding)
        let clampedX = min(max(point.x, minX), maxX)
        let clampedY = min(max(point.y, minY), maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func imageRect(for image: UIImage, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return CGRect(x: point.x - maxSide / 2, y: point.y - maxSide / 2, width: maxSide, height: maxSide)
        }
        let aspect = size.width / size.height
        let width: CGFloat
        let height: CGFloat
        if aspect >= 1 {
            width = maxSide
            height = maxSide / aspect
        } else {
            height = maxSide
            width = maxSide * aspect
        }
        return CGRect(x: point.x - width / 2,
                      y: point.y - height / 2,
                      width: width,
                      height: height)
    }

    private func styleButtonOverlay(for entry: BoardEntry) -> some View {
        let rect = store.screenRect(for: entry)
        let offset: CGFloat = 8
        return ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            Button(action: {
                store.togglePanel(.shapeStyle)
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.systemBackground).opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(UIColor.separator), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .offset(x: offset, y: -offset)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct DottedGridView: View {
    let size: CGSize
    let pan: CGPoint
    let zoom: CGFloat

    private let baseSpacing: CGFloat = 80
    private let dotRadius: CGFloat = 1.5

    var body: some View {
        Canvas { context, canvasSize in
            var spacing = baseSpacing * zoom
            while spacing < 24 { spacing *= 2 }
            while spacing > 160 { spacing /= 2 }

            let startX = positiveRemainder(pan.x, spacing) - spacing
            let startY = positiveRemainder(pan.y, spacing) - spacing

            var path = Path()

            var y = startY
            while y <= canvasSize.height + spacing {
                var x = startX
                while x <= canvasSize.width + spacing {
                    path.addEllipse(in: CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                    x += spacing
                }
                y += spacing
            }

            let opacity = min(0.5, max(0.1, zoom * 0.4))
            context.fill(path, with: .color(Color.secondary.opacity(opacity)))
        }
        .allowsHitTesting(false)
    }

    private func positiveRemainder(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let r = value.truncatingRemainder(dividingBy: modulus)
        return r >= 0 ? r : (r + modulus)
    }
}

private struct ToolPalettePopover: View {
    @EnvironmentObject var store: BoardStore
    let screenPoint: CGPoint
    let onSelectTool: (BoardTool) -> Void
    let onAddFile: () -> Void
    let onOpenPanel: (PanelKind) -> Void
    let onOpenBoards: () -> Void
    let onClearBoard: () -> Void

    private var undoRedoButtons: [(id: String, symbol: String, isEnabled: Bool, action: () -> Void)] {
        [
            ("undo", "arrow.uturn.backward", store.canUndo, { _ = store.undo() }),
            ("redo", "arrow.uturn.forward", store.canRedo, { _ = store.redo() })
        ]
    }

    private var toolButtons: [(id: String, symbol: String, isEnabled: Bool, action: () -> Void)] {
        [
            ("text", "textformat", true, { onSelectTool(.text) }),
            ("image", "photo", true, { onSelectTool(.image) }),
            ("rect", "square.on.square", true, { onSelectTool(.rect) }),
            ("circle", "circle", true, { onSelectTool(.circle) }),
            ("line", "pencil.and.outline", true, { onSelectTool(.line) }),
            ("file", "doc.fill", true, { onAddFile() })
        ]
    }

    private var panelButtons: [(id: String, symbol: String, isEnabled: Bool, action: () -> Void)] {
        [
            ("settings", "gearshape", true, { onOpenPanel(.settings) }),
            ("personality", "person.crop.circle", true, { onOpenPanel(.personality) }),
            ("memories", "brain", true, { onOpenPanel(.memories) }),
            ("log", "list.bullet.rectangle", true, { onOpenPanel(.log) }),
            ("boards", "square.grid.2x2", true, { onOpenBoards() })
        ]
    }

    var body: some View {
        VStack(spacing: 8) {
            iconStrip(undoRedoButtons)
            Divider().frame(width: 28).opacity(0.35)
            iconStrip(toolButtons)
            Divider().frame(width: 28).opacity(0.35)
            iconStrip(panelButtons)
            Divider().frame(width: 28).opacity(0.35)
            Button(role: .destructive, action: onClearBoard) {
                iconCapsule(symbol: "trash", tint: .red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        .position(x: screenPoint.x, y: screenPoint.y)
    }

    private func iconStrip(_ items: [(id: String, symbol: String, isEnabled: Bool, action: () -> Void)]) -> some View {
        VStack(spacing: 6) {
            ForEach(items, id: \.id) { item in
                Button(action: item.action) {
                    iconCapsule(symbol: item.symbol, tint: .primary)
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }
        }
    }

private func iconCapsule(symbol: String, tint: Color) -> some View {
    Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(tint)
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.15))
        )
}
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
