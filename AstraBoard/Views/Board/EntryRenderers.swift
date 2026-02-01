import SwiftUI
import AppKit
import CoreImage

struct EntryContainerView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    var entry: BoardEntry
    @Binding var activeTextEdit: UUID?
    @State private var dragStartFrames: [UUID: CGRect] = [:]
    @State private var dragStartWorld: CGPoint?
    @State private var lastMagnification: CGFloat = 1.0

    var isSelected: Bool { store.selection.contains(entry.id) }
    private var entryShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12)
    }
    
    private var isCroppingThisImage: Bool {
        store.doc.ui.activeImageCropID == entry.id
    }

    var body: some View {
        let rect = screenRect(for: entry)
        
        // 1. Define the content with its specific frame
        ZStack(alignment: .topLeading) {
            EntryContentView(entry: entry, activeTextEdit: $activeTextEdit)
                .frame(width: rect.width, height: rect.height)
                // Hit-testing + drag belongs to the entry content ONLY
                .modifier(EntryHitShape(shapeKind: shapeKind(for: entry)))
                .gesture(entryDrag(), including: .gesture)

            // Handles are separate siblings so they can receive drags
            selectionOverlay(rect: rect)
            highlightOverlay(rect: rect)
        }
        .shadow(color: entryShadowColor, radius: 9, x: 0, y: 4)
        .simultaneousGesture(magnificationGesture())
        .onTapGesture(count: 1) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return }
            store.selection = [entry.id]
        }
        .onTapGesture(count: 2) {
            if entry.type == .text {
                activeTextEdit = entry.id
            } else if case .file(let ref) = entry.data {
                store.openFile(ref)
            }
        }
        .gesture(
            TapGesture(count: 1)
                .modifiers(.shift)
                .onEnded { store.toggleSelection(entry.id) }
        )
        .contextMenu {
            if case .text = entry.data {
                Button("Edit Text") {
                    store.selection = [entry.id]
                    activeTextEdit = entry.id
                    store.beginEditing(entry.id)
                }
                Divider()
            }

            if entry.type == .shape || entry.type == .text {
                Button("Edit Style…") {
                    store.selection = [entry.id]
                    if !store.doc.ui.panels.shapeStyle.isOpen {
                        store.togglePanel(.shapeStyle)
                    }
                }
                Divider()
            }
            if entry.type == .image {
                Button("Copy Image") { store.copyImageToPasteboard(id: entry.id) }
                Button("Save Image…") { store.saveImageEntryToDisk(id: entry.id) }
                Divider()
                if store.doc.ui.activeImageCropID == entry.id {
                    Button("Done Cropping") { store.endImageCrop() }
                } else {
                    Button("Crop…") { store.beginImageCrop(entry.id) }
                }
                if entry.imageCrop != nil {
                    Button("Reset Crop") { store.resetImageCrop(entry.id) }
                }
                Divider()
            }
            if entry.type == .text {
                Button("Copy Text") { store.copyTextToPasteboard(id: entry.id) }
                Divider()
            }
            if case .file(let ref) = entry.data {
                Button("Open File") { store.openFile(ref) }
                Button("Show in Finder") { store.revealFile(ref) }
                Button("Copy File") { store.copyFileEntryToPasteboard(id: entry.id) }
                Divider()
            }
            Button("Bring to Front") { store.bringToFront(ids: [entry.id]) }
            Button("Send to Back") { store.sendToBack(ids: [entry.id]) }
            
            if store.selection.count >= 2, store.selection.contains(entry.id) {
                Divider()
                Button("Group Items") {
                    store.groupSelectedItems()
                }
            }
            
            if let gid = entry.groupID {
                Divider()
                Button("Ungroup") {
                    // If multiple selected, ungroup any groups in the selection.
                    // Otherwise, just ungroup this entry’s group.
                    if store.selection.count >= 2, store.selection.contains(entry.id) {
                        store.ungroupSelectedGroups()
                    } else {
                        store.ungroupGroup(gid)
                    }
                }
            }
            
            Button("Duplicate") { store.selection = [entry.id]; store.duplicateSelected() }
            Button("Delete") { store.selection = [entry.id]; store.deleteSelected() }
        }
        // 3. Finally, position the view within the parent coordinate space
        .position(x: rect.midX, y: rect.midY)
    }

    private func selectionOverlay(rect: CGRect) -> some View {
        return ZStack(alignment: .topLeading) {
            if isSelected {
                if entry.type == .text {
                    selectionOutlineView(color: Color(NSColor.separatorColor),
                                         lineWidth: 1 / store.doc.viewport.zoom.cg)
                }
                if isCroppingThisImage {
                    ImageCropOverlay(entryID: entry.id)
                } else if store.selection.count == 1 {
                    ResizeHandles(entry: entry, activeTextEdit: $activeTextEdit)
                }
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    }

    private func highlightOverlay(rect: CGRect) -> some View {
        Group {
            if store.highlightEntryId == entry.id {
                selectionOutlineView(color: Color.purple,
                                     lineWidth: 4 / store.doc.viewport.zoom.cg)
                    .opacity(0.7)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    }

    private func entryDrag() -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("board"))
            .onChanged { value in
                guard !store.isDraggingOverlay else { return }
                if !isSelected {
                    store.selection = [entry.id]
                }
                if dragStartFrames.isEmpty {
                    for id in store.selection {
                        if let entry = store.doc.entries[id] {
                            let rect = CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg)
                            dragStartFrames[id] = rect
                        }
                    }
                    dragStartWorld = store.worldPoint(from: value.startLocation)
                }
                guard let startWorld = dragStartWorld else { return }
                let currentWorld = store.worldPoint(from: value.location)
                let delta = CGSize(width: currentWorld.x - startWorld.x,
                                   height: currentWorld.y - startWorld.y)
                for (id, rect) in dragStartFrames {
                    let origin = CGPoint(x: rect.origin.x + delta.width, y: rect.origin.y + delta.height)
                    store.setEntryOrigin(id: id, origin: origin)
                }
                guard !isCroppingThisImage else { return }
            }
            .onEnded { _ in
                dragStartFrames = [:]
                dragStartWorld = nil
            }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let delta = scale / lastMagnification
                store.applyZoom(delta: delta, focus: nil)
                lastMagnification = scale
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }

    private func screenRect(for entry: BoardEntry) -> CGRect {
        let zoom = store.doc.viewport.zoom.cg
        let origin = CGPoint(x: entry.x.cg * zoom + store.doc.viewport.offsetX.cg,
                             y: entry.y.cg * zoom + store.doc.viewport.offsetY.cg)
        let size = CGSize(width: entry.w.cg * zoom, height: entry.h.cg * zoom)
        return CGRect(origin: origin, size: size)
    }

    private func shapeKind(for entry: BoardEntry) -> ShapeKind? {
        if case .shape(let kind) = entry.data { return kind }
        return nil
    }

    @ViewBuilder
    private func selectionOutlineView(color: Color, lineWidth: CGFloat) -> some View {
        switch entry.data {
        case .shape(let kind):
            switch kind {
            case .circle:
                outsideStrokeCircle(lineWidth: lineWidth, color: color)
            case .rect:
                let zoom = store.doc.viewport.zoom.cg
                let style = store.shapeStyle(for: entry)

                let w = entry.w.cg * zoom
                let h = entry.h.cg * zoom

                let desired = max(0, style.cornerRadius) * zoom
                let cornerRadius = min(desired, min(w, h) / 2)

                outsideStrokeRoundedRect(cornerRadius: cornerRadius, lineWidth: lineWidth, color: color)
            case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
                let zoom = store.doc.viewport.zoom.cg
                let style = store.shapeStyle(for: entry)
                let desired = max(0, style.cornerRadius) * zoom

                outsideStrokeTriangle(kind: kind, cornerRadius: desired, lineWidth: lineWidth, color: color)
            }
        case .text:
            outsideStrokeRoundedRect(cornerRadius: 12, lineWidth: lineWidth, color: color)
        case .image:
            outsideStrokeRect(lineWidth: lineWidth, color: color)
        case .file:
            outsideStrokeRoundedRect(cornerRadius: 10, lineWidth: lineWidth, color: color)
        case .line:
            outsideStrokeRoundedRect(cornerRadius: 6, lineWidth: lineWidth, color: color)
        }
    }
}

@ViewBuilder
private func outsideStrokeRoundedRect(cornerRadius: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
    if lineWidth > 0 {
        if cornerRadius <= 0.0001 {
            Rectangle()
                .inset(by: -lineWidth / 2)
                .stroke(color, lineWidth: lineWidth)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius + lineWidth / 2, style: .continuous)
                .inset(by: -lineWidth / 2)
                .stroke(color, lineWidth: lineWidth)
        }
    }
}

@ViewBuilder
private func outsideStrokeCircle(lineWidth: CGFloat, color: Color) -> some View {
    if lineWidth > 0 {
        Circle()
            .inset(by: -lineWidth / 2)
            .stroke(color, lineWidth: lineWidth)
    }
}

@ViewBuilder
private func outsideStrokeRect(lineWidth: CGFloat, color: Color) -> some View {
    if lineWidth > 0 {
        Rectangle()
            .inset(by: -lineWidth / 2)
            .stroke(color, lineWidth: lineWidth)
    }
}

struct EntryContentView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    var entry: BoardEntry
    @Binding var activeTextEdit: UUID?
    private var entryBackground: Color {
        if case .image = entry.data {
            return Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.12 : 0.06)
        }
        if case .file = entry.data {
            return Color(NSColor.controlBackgroundColor).opacity(colorScheme == .dark ? 0.3 : 0.6)
        }
        return .clear
    }
    
    var body: some View {
        ZStack {
            switch entry.data {
            case .text(let text):
                let textStyle = store.textStyle(for: entry)
                let zoom = store.doc.viewport.zoom.cg
                AutoSizingTextView(
                    text: Binding(get: {
                        activeTextEdit == entry.id ? text : text
                    }, set: { new in
                        store.updateText(id: entry.id, text: new)
                    }),
                    style: textStyle,
                    isEditable: activeTextEdit == entry.id,
                    zoom: zoom,
                    colorScheme: colorScheme
                )
                .background(Color.clear)
                .allowsHitTesting(activeTextEdit == entry.id)
                .onAppear { syncTextEntrySize(text: text, style: textStyle) }
                .onChange(of: text) { newText in
                    syncTextEntrySize(text: newText, style: textStyle)
                }
                .onChange(of: entry.w) { _ in
                    syncTextEntrySize(text: text, style: textStyle)
                }
                .onChange(of: textStyle) { _ in
                    syncTextEntrySize(text: text, style: textStyle)
                }

            case .image(let ref):
                let isCropping = (store.doc.ui.activeImageCropID == entry.id)
                if let url = store.imageURL(for: ref),
                   let nsImage = NSImage(contentsOf: url) {

                    let displayImage: NSImage = {
                        guard !isCropping, let crop = entry.imageCrop else { return nsImage }
                        return croppedImage(nsImage, crop: crop) ?? nsImage
                    }()

                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(Color(NSColor.separatorColor).opacity(0.35))
                } else {
                    ZStack {
                        Color(NSColor.controlBackgroundColor).opacity(0.8)
                        Text("Image missing").foregroundColor(.secondary)
                    }
                }

            case .file(let ref):
                FileEntryView(ref: ref)

            case .shape(let kind):
                let style = store.shapeStyle(for: entry)
                let zoom = store.doc.viewport.zoom.cg
                let fill = style.fillColor.color.opacity(style.fillOpacity)
                let stroke = style.borderColor.color.opacity(style.borderOpacity)
                let lineWidth = max(style.borderWidth, 0) * zoom

                switch kind {
                case .rect:
                    let w = entry.w.cg * zoom
                    let h = entry.h.cg * zoom
                    let desired = max(0, style.cornerRadius) * zoom
                    let cornerRadius = min(desired, min(w, h) / 2)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                        .overlay(
                            outsideStrokeRoundedRect(
                                cornerRadius: cornerRadius,
                                lineWidth: lineWidth,
                                color: stroke
                            )
                        )

                case .circle:
                    Circle()
                        .fill(fill)
                        .overlay(outsideStrokeCircle(lineWidth: lineWidth, color: stroke))

                case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
                    let desired = max(0, style.cornerRadius) * zoom
                    RoundedTriangleShape(kind: kind, cornerRadius: desired)
                        .fill(fill)
                        .overlay(
                            outsideStrokeTriangle(
                                kind: kind,
                                cornerRadius: desired,
                                lineWidth: lineWidth,
                                color: stroke
                            )
                        )
                }

            case .line(let data):
                let zoom = store.doc.viewport.zoom.cg
                let lineColor: Color = (colorScheme == .dark) ? .white : .black
                LineEntryShape(data: data, entry: entry)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round, lineJoin: .round))
            }
        }
        .background(entryBackground)
    }

    // MARK: - Cropping

    private static let cropContext = CIContext(options: nil)

    private func croppedImage(_ image: NSImage, crop: ImageCropInsets) -> NSImage? {
        let crop = crop.clamped()
        guard crop != .none else { return image }

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)

        let w = ci.extent.width
        let h = ci.extent.height
        guard w > 0, h > 0 else { return nil }

        let rect = CGRect(
            x: CGFloat(crop.left) * w,
            y: CGFloat(crop.bottom) * h,
            width: max(1, (1 - CGFloat(crop.left) - CGFloat(crop.right)) * w),
            height: max(1, (1 - CGFloat(crop.top) - CGFloat(crop.bottom)) * h)
        ).integral

        let cropped = ci.cropped(to: rect)
        guard let out = Self.cropContext.createCGImage(cropped, from: cropped.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: rect.width, height: rect.height))
    }

    private func syncTextEntrySize(text: String, style: TextStyle) {
        let width = entry.w.cg
        let font = TextEntryMetrics.font(for: style)
        let height = TextEntryMetrics.height(for: text, maxWidth: width, font: font)
        let currentSize = CGSize(width: entry.w.cg, height: entry.h.cg)
        if abs(currentSize.height - height) > 0.5 {
            let rect = CGRect(x: entry.x.cg,
                              y: entry.y.cg,
                              width: width,
                              height: height)
            store.updateEntryFrame(id: entry.id, rect: rect, recordUndo: false)
        }
    }
}

private struct FileEntryView: View {
    @EnvironmentObject var store: BoardStore
    let ref: FileRef

    private var displayName: String {
        let trimmed = ref.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ref.filename : trimmed
    }

    private var fileExtension: String {
        let ext = (displayName as NSString).pathExtension
        return ext.isEmpty ? "" : ext.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 24, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if !fileExtension.isEmpty {
                        Text(fileExtension)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(NSColor.separatorColor).opacity(0.4)))
                    }
                }
            }
            Spacer(minLength: 0)
            if store.fileURL(for: ref) == nil {
                Text("File missing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
    }
}

private struct AutoSizingTextView: NSViewRepresentable {
    @Binding var text: String
    var style: TextStyle
    var isEditable: Bool
    var zoom: CGFloat
    var colorScheme: ColorScheme
    
    private func applyStyle(_ textView: NSTextView) {
            let scale = max(zoom, 0.001)
            let baseFont = TextEntryMetrics.font(for: style)
            let font = TextEntryMetrics.scaledFont(for: style, zoom: scale)

            let textColor: NSColor = style.textColor.shouldAutoAdaptForColorScheme
                ? (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(style.textOpacity.cg)
                : NSColor(calibratedRed: style.textColor.red.cg,
                          green: style.textColor.green.cg,
                          blue: style.textColor.blue.cg,
                          alpha: style.textOpacity.cg)

            let outlineColor: NSColor = style.outlineColor.shouldAutoAdaptForColorScheme
                ? (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(style.textOpacity.cg)
                : NSColor(calibratedRed: style.outlineColor.red.cg,
                          green: style.outlineColor.green.cg,
                          blue: style.outlineColor.blue.cg,
                          alpha: style.textOpacity.cg)

            let strokeWidth: CGFloat
            if style.outlineWidth > 0, baseFont.pointSize > 0 {
                let percent = (style.outlineWidth.cg / baseFont.pointSize) * 100
                strokeWidth = -percent
            } else {
                strokeWidth = 0
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .strokeColor: outlineColor,
                .strokeWidth: strokeWidth
            ]

            textView.font = font
            textView.textColor = textColor
            textView.typingAttributes = attributes

            if let storage = textView.textStorage {
                let selectedRange = textView.selectedRange()
                let fullRange = NSRange(location: 0, length: storage.length)
                storage.beginEditing()
                storage.setAttributes(attributes, range: fullRange)
                storage.endEditing()
                textView.setSelectedRange(selectedRange)
            }

            textView.insertionPointColor = textColor
        }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = true
        let insets = TextEntryMetrics.scaledInsets(for: zoom)
        textView.textContainerInset = insets
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        let initialWidth = max(textView.bounds.width - insets.width * 2, 1)
        textView.textContainer?.containerSize = NSSize(width: initialWidth,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.string = text
        applyStyle(textView)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
        let insets = TextEntryMetrics.scaledInsets(for: zoom)
        nsView.textContainerInset = insets
        nsView.isEditable = isEditable
        nsView.isSelectable = isEditable
        let containerWidth = max(nsView.bounds.width - insets.width * 2, 1)
        nsView.textContainer?.containerSize = NSSize(width: containerWidth,
                                                     height: CGFloat.greatestFiniteMagnitude)
        applyStyle(nsView)
        if isEditable,
           let window = nsView.window,
           window.firstResponder != nsView {
            window.makeFirstResponder(nsView)
        }
        if !isEditable,
           let window = nsView.window,
           window.firstResponder == nsView {
            window.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private extension ColorComponents {
    /// If the color is basically grayscale and extremely dark or extremely bright,
    /// treat it as “semantic” so it stays readable across light/dark mode.
    var shouldAutoAdaptForColorScheme: Bool {
        let tol = 0.02
        let isNeutral = abs(red - green) < tol && abs(green - blue) < tol
        guard isNeutral else { return false }

        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.15 || luminance > 0.85
    }
}

private struct TriangleShape: InsettableShape {
    let kind: ShapeKind
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)

        let minX = r.minX, midX = r.midX, maxX = r.maxX
        let minY = r.minY, midY = r.midY, maxY = r.maxY

        var p = Path()
        switch kind {
        case .triangleUp:
            p.move(to: CGPoint(x: midX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: maxY))
        case .triangleDown:
            p.move(to: CGPoint(x: midX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: minY))
        case .triangleLeft:
            p.move(to: CGPoint(x: minX, y: midY))
            p.addLine(to: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY))
        case .triangleRight:
            p.move(to: CGPoint(x: maxX, y: midY))
            p.addLine(to: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: minX, y: maxY))
        case .rect, .circle:
            // Not used for these kinds
            p.addRect(r)
        }
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct RoundedTriangleShape: InsettableShape {
    let kind: ShapeKind
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)

        let minX = r.minX, midX = r.midX, maxX = r.maxX
        let minY = r.minY, midY = r.midY, maxY = r.maxY

        let p0: CGPoint
        let p1: CGPoint
        let p2: CGPoint

        switch kind {
        case .triangleUp:
            p0 = CGPoint(x: midX, y: minY)
            p1 = CGPoint(x: maxX, y: maxY)
            p2 = CGPoint(x: minX, y: maxY)
        case .triangleDown:
            p0 = CGPoint(x: midX, y: maxY)
            p1 = CGPoint(x: minX, y: minY)
            p2 = CGPoint(x: maxX, y: minY)
        case .triangleLeft:
            p0 = CGPoint(x: minX, y: midY)
            p1 = CGPoint(x: maxX, y: minY)
            p2 = CGPoint(x: maxX, y: maxY)
        case .triangleRight:
            p0 = CGPoint(x: maxX, y: midY)
            p1 = CGPoint(x: minX, y: minY)
            p2 = CGPoint(x: minX, y: maxY)
        case .rect, .circle:
            // Not used for these kinds
            var p = Path()
            p.addRect(r)
            return p
        }

        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        func unit(_ v: CGVector) -> CGVector {
            let m = max(0.000001, hypot(v.dx, v.dy))
            return CGVector(dx: v.dx / m, dy: v.dy / m)
        }

        func dot(_ a: CGVector, _ b: CGVector) -> CGFloat {
            a.dx * b.dx + a.dy * b.dy
        }

        func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            min(max(x, lo), hi)
        }

        func angle(prev: CGPoint, corner: CGPoint, next: CGPoint) -> CGFloat {
            // interior angle at `corner`
            let v1 = unit(CGVector(dx: prev.x - corner.x, dy: prev.y - corner.y))
            let v2 = unit(CGVector(dx: next.x - corner.x, dy: next.y - corner.y))
            return acos(clamp(dot(v1, v2), -1, 1))
        }

        func pointAlong(from a: CGPoint, to b: CGPoint, distance d: CGFloat) -> CGPoint {
            let v = unit(CGVector(dx: b.x - a.x, dy: b.y - a.y))
            return CGPoint(x: a.x + v.dx * d, y: a.y + v.dy * d)
        }

        let desired = max(0, cornerRadius)

        // If 0, draw a true sharp triangle.
        if desired <= 0.0001 {
            var p = Path()
            p.move(to: p0)
            p.addLine(to: p1)
            p.addLine(to: p2)
            p.closeSubpath()
            return p
        }

        // Interior angles
        let a0 = angle(prev: p2, corner: p0, next: p1)
        let a1 = angle(prev: p0, corner: p1, next: p2)
        let a2 = angle(prev: p1, corner: p2, next: p0)

        // Maximum legal radius at each corner: r <= min(edgeLen1, edgeLen2) * tan(angle/2)
        func maxRadiusAt(prev: CGPoint, corner: CGPoint, next: CGPoint, ang: CGFloat) -> CGFloat {
            let e1 = dist(prev, corner)
            let e2 = dist(next, corner)
            let t = tan(ang / 2)
            if t <= 0.000001 { return 0 }
            return min(e1, e2) * t
        }

        let maxR0 = maxRadiusAt(prev: p2, corner: p0, next: p1, ang: a0)
        let maxR1 = maxRadiusAt(prev: p0, corner: p1, next: p2, ang: a1)
        let maxR2 = maxRadiusAt(prev: p1, corner: p2, next: p0, ang: a2)

        let maxAllowed = max(0, min(maxR0, min(maxR1, maxR2)))
        let rr = min(desired, maxAllowed)

        if rr <= 0.0001 {
            var p = Path()
            p.move(to: p0)
            p.addLine(to: p1)
            p.addLine(to: p2)
            p.closeSubpath()
            return p
        }

        // Tangent distances along each adjacent edge
        let t0 = rr / max(0.000001, tan(a0 / 2))
        let start = pointAlong(from: p0, to: p1, distance: t0)

        // Build rounded triangle. Starting at a tangent point prevents “one side stays straight”.
        var p = Path()
        p.move(to: start)
        p.addArc(tangent1End: p1, tangent2End: p2, radius: rr)
        p.addArc(tangent1End: p2, tangent2End: p0, radius: rr)
        p.addArc(tangent1End: p0, tangent2End: p1, radius: rr)
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

@ViewBuilder
private func outsideStrokeTriangle(kind: ShapeKind, cornerRadius: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
    if lineWidth > 0 {
        if cornerRadius <= 0.0001 {
            TriangleShape(kind: kind)
                .inset(by: -lineWidth / 2)
                .stroke(color, lineWidth: lineWidth)
        } else {
            RoundedTriangleShape(kind: kind, cornerRadius: cornerRadius + lineWidth / 2)
                .inset(by: -lineWidth / 2)
                .stroke(color, lineWidth: lineWidth)
        }
    }
}

struct LineEntryShape: Shape {
    var data: LineData
    var entry: BoardEntry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = data.points.first else { return path }
        path.move(to: relativePoint(first, in: rect))
        for p in data.points.dropFirst() {
            path.addLine(to: relativePoint(p, in: rect))
        }
        if data.arrow, let last = data.points.last, data.points.count > 1 {
            let prev = data.points[data.points.count - 2]
            let tail = relativePoint(prev, in: rect)
            let head = relativePoint(last, in: rect)
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let arrowLength: CGFloat = 12
            let wing: CGFloat = 6
            let point1 = CGPoint(x: head.x - arrowLength * cos(angle) + wing * sin(angle),
                                 y: head.y - arrowLength * sin(angle) - wing * cos(angle))
            let point2 = CGPoint(x: head.x - arrowLength * cos(angle) - wing * sin(angle),
                                 y: head.y - arrowLength * sin(angle) + wing * cos(angle))
            path.move(to: head)
            path.addLine(to: point1)
            path.move(to: head)
            path.addLine(to: point2)
        }
        return path
    }

    private func relativePoint(_ p: Point, in rect: CGRect) -> CGPoint {
        let relativeX = (p.x.cg - entry.x.cg) / entry.w.cg * rect.width
        let relativeY = (p.y.cg - entry.y.cg) / entry.h.cg * rect.height
        return CGPoint(x: relativeX, y: relativeY)
    }
}

private struct ResizeHandles: View {
    @EnvironmentObject var store: BoardStore
    var entry: BoardEntry
    @Binding var activeTextEdit: UUID?
    @State private var resizeStartFrame: CGRect?
    @State private var resizeStartShapeKind: ShapeKind?
    
    var body: some View {
        let zoom = store.doc.viewport.zoom.cg
        let width = entry.w.cg * zoom
        let height = entry.h.cg * zoom
        // Use full frame for handles to allow free resizing
        let handleRect = CGRect(x: 0, y: 0, width: width, height: height)
        let isText = entry.type == .text
        let isLine = isLineEntry(entry)
        
        return ZStack {
            if isLine, let endpoints = lineEndpoints(in: handleRect) {
                lineHandle(at: endpoints.start, endpoint: .start)
                lineHandle(at: endpoints.end, endpoint: .end)
            } else {
                // Circle outer-rim drag area (specific for circles to allow dragging the "line")
                if isCircleEntry(entry) {
                    Circle()
                        .stroke(Color.white.opacity(0.001), lineWidth: 16)
                        .frame(width: width, height: height)
                        .position(x: handleRect.midX, y: handleRect.midY)
                        .gesture(circleOutlineResizeGesture())
                        .cursor(NSCursor.crosshair)
                }

                let isText: Bool = { if case .text = entry.data { return true } else { return false } }()
                let isShape: Bool = { if case .shape = entry.data { return true } else { return false } }()

                if isText {
                    edgeHandle(position: .left, width: 6, height: handleRect.height)
                        .position(x: handleRect.minX, y: handleRect.midY)
                    edgeHandle(position: .right, width: 6, height: handleRect.height)
                        .position(x: handleRect.maxX, y: handleRect.midY)
                } else {
                    // Top edge
                    edgeHandle(position: .top, width: handleRect.width, height: 6)
                        .position(x: handleRect.midX, y: handleRect.minY)
                    
                    // Bottom edge
                    edgeHandle(position: .bottom, width: handleRect.width, height: 6)
                        .position(x: handleRect.midX, y: handleRect.maxY)
                    
                    // Left edge
                    edgeHandle(position: .left, width: 6, height: handleRect.height)
                        .position(x: handleRect.minX, y: handleRect.midY)
                    
                    // Right edge
                    edgeHandle(position: .right, width: 6, height: handleRect.height)
                        .position(x: handleRect.maxX, y: handleRect.midY)
                    
                    // Corners (invisible hit targets for diagonal resize)
                    cornerHandle(position: .topLeft)
                        .position(x: handleRect.minX, y: handleRect.minY)
                    
                    cornerHandle(position: .topRight)
                        .position(x: handleRect.maxX, y: handleRect.minY)
                    
                    cornerHandle(position: .bottomLeft)
                        .position(x: handleRect.minX, y: handleRect.maxY)
                    
                    cornerHandle(position: .bottomRight)
                        .position(x: handleRect.maxX, y: handleRect.maxY)
                }
            }
        }
    }
    
    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    private func edgeHandle(position: Edge, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue.opacity(0.01))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .cursor(cursor(for: position))
            .gesture(resizeGesture(for: position))
    }

    private func cornerHandle(position: Edge) -> some View {
        Rectangle()
            .fill(Color.blue.opacity(0.01))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle())
            .cursor(cursor(for: position))
            .gesture(resizeGesture(for: position))
    }

    private enum LineEndpoint {
        case start
        case end
    }

    private func lineHandle(at point: CGPoint, endpoint: LineEndpoint) -> some View {
        ZStack {
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 24, height: 24)
        }
        .position(point)
        .contentShape(Circle())
        .cursor(NSCursor.crosshair)
        .highPriorityGesture(lineEndpointDragGesture(endpoint))
    }
    
    private func cursor(for position: Edge) -> NSCursor {
        switch position {
        case .top, .bottom: return NSCursor.resizeUpDown
        case .left, .right: return NSCursor.resizeLeftRight
        case .topLeft, .bottomRight:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage(), hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil) ?? NSImage(), hotSpot: NSPoint(x: 8, y: 8))
        }
    }
    
    private func resizeGesture(for position: Edge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                guard let currentEntry = store.doc.entries[entry.id] else { return }
                
                if resizeStartFrame == nil {
                    resizeStartFrame = CGRect(x: currentEntry.x.cg, y: currentEntry.y.cg, width: currentEntry.w.cg, height: currentEntry.h.cg)
                }

                if resizeStartShapeKind == nil, case .shape(let k) = currentEntry.data {
                    resizeStartShapeKind = k
                }
                
                guard let startFrame = resizeStartFrame else { return }
                let startWorld = store.worldPoint(from: value.startLocation)
                let currentWorld = store.worldPoint(from: value.location)
                let delta = CGSize(width: currentWorld.x - startWorld.x,
                                   height: currentWorld.y - startWorld.y)

                if isTextEntry(currentEntry) {
                    guard position == .left || position == .right else { return }
                    let newRect = calculateHorizontalResize(startFrame: startFrame,
                                                            delta: delta,
                                                            position: position,
                                                            currentHeight: currentEntry.h.cg)
                    store.updateEntryFrame(id: entry.id, rect: newRect)
                    return
                }

                // 1. Calculate standard rectangular resize (used for Image, Rect, Circle handles)
                let result = calculateStandardResize(startFrame: startFrame, delta: delta, position: position)
                var newRect = result.rect

                if let startKind = resizeStartShapeKind,
                    case .shape(let currentKind) = currentEntry.data {

                        var desired = startKind

                        // Vertical pair flips when you cross vertically
                        if startKind == .triangleUp || startKind == .triangleDown {
                            if result.invertedY {
                                desired = (startKind == .triangleUp) ? .triangleDown : .triangleUp
                            }
                        }

                        // Horizontal pair flips when you cross horizontally
                        if startKind == .triangleLeft || startKind == .triangleRight {
                            if result.invertedX {
                                desired = (startKind == .triangleLeft) ? .triangleRight : .triangleLeft
                            }
                        }

                        if desired != currentKind {
                            store.updateShapeKind(id: entry.id, kind: desired)
                        }
                    }
                
                // 2. If it's a circle, snap to 1:1 aspect to ensure the selection outline matches the shape
                if isCircleEntry(currentEntry) {
                    let side = max(newRect.width, newRect.height)
                    // Anchor center to prevent it from growing strictly down/right
                    let center = CGPoint(x: newRect.midX, y: newRect.midY)
                    newRect = CGRect(x: center.x - side/2, y: center.y - side/2, width: side, height: side)
                }

                if isImageEntry(currentEntry), let aspect = imageAspectRatio(for: currentEntry) {
                    newRect = applyAspectRatio(rect: newRect, startFrame: startFrame, aspect: aspect, position: position)
                }
                
                store.updateEntryFrame(id: entry.id, rect: newRect)
            }
            .onEnded { _ in
                resizeStartFrame = nil
                resizeStartShapeKind = nil
            }
    }

    private func lineEndpointDragGesture(_ endpoint: LineEndpoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                store.isDraggingOverlay = true
                guard let currentEntry = store.doc.entries[entry.id],
                      case .line = currentEntry.data else { return }

                let worldPoint = store.worldPoint(from: value.location)
                switch endpoint {
                case .start:
                    store.updateLine(id: entry.id, start: worldPoint, recordUndo: false)
                case .end:
                    store.updateLine(id: entry.id, end: worldPoint, recordUndo: false)
                }
            }
            .onEnded { value in
                defer { store.isDraggingOverlay = false }
                guard let currentEntry = store.doc.entries[entry.id],
                      case .line = currentEntry.data else { return }

                let worldPoint = store.worldPoint(from: value.location)
                switch endpoint {
                case .start:
                    store.updateLine(id: entry.id, start: worldPoint, recordUndo: true)
                case .end:
                    store.updateLine(id: entry.id, end: worldPoint, recordUndo: true)
                }
            }
    }
    
    private func calculateStandardResize(startFrame: CGRect, delta: CGSize, position: Edge) -> (rect: CGRect, invertedX: Bool, invertedY: Bool) {
        let minSize: CGFloat = 0.01

        var minX = startFrame.minX
        var maxX = startFrame.maxX
        var minY = startFrame.minY
        var maxY = startFrame.maxY

        var invertedX = false
        var invertedY = false

        // Helpers for one axis (anchor + moving side that can cross)
        func solveAxis(anchor: CGFloat, moving: CGFloat, initialMovingLess: Bool) -> (min: CGFloat, max: CGFloat, inverted: Bool) {
            let movingLess = moving < anchor
            var lo = min(moving, anchor)
            var hi = max(moving, anchor)

            // enforce minimum size while keeping the anchor fixed
            if (hi - lo) < minSize {
                if movingLess {
                    lo = anchor - minSize
                    hi = anchor
                } else {
                    lo = anchor
                    hi = anchor + minSize
                }
            }

            return (lo, hi, movingLess != initialMovingLess)
        }

        switch position {
            case .left:
                let anchor = startFrame.maxX
                let moving = startFrame.minX + delta.width
                let solved = solveAxis(anchor: anchor, moving: moving, initialMovingLess: true)
                minX = solved.min
                maxX = solved.max
                invertedX = solved.inverted

            case .right:
                let anchor = startFrame.minX
                let moving = startFrame.maxX + delta.width
                let solved = solveAxis(anchor: anchor, moving: moving, initialMovingLess: false)
                minX = solved.min
                maxX = solved.max
                invertedX = solved.inverted

            case .top:
                let anchor = startFrame.maxY
                let moving = startFrame.minY + delta.height
                let solved = solveAxis(anchor: anchor, moving: moving, initialMovingLess: true)
                minY = solved.min
                maxY = solved.max
                invertedY = solved.inverted

            case .bottom:
                let anchor = startFrame.minY
                let moving = startFrame.maxY + delta.height
                let solved = solveAxis(anchor: anchor, moving: moving, initialMovingLess: false)
                minY = solved.min
                maxY = solved.max
                invertedY = solved.inverted

            case .topLeft:
                let ax = startFrame.maxX
                let mx = startFrame.minX + delta.width
                let sx = solveAxis(anchor: ax, moving: mx, initialMovingLess: true)
                minX = sx.min; maxX = sx.max; invertedX = sx.inverted

                let ay = startFrame.maxY
                let my = startFrame.minY + delta.height
                let sy = solveAxis(anchor: ay, moving: my, initialMovingLess: true)
                minY = sy.min; maxY = sy.max; invertedY = sy.inverted

            case .topRight:
                let ax = startFrame.minX
                let mx = startFrame.maxX + delta.width
                let sx = solveAxis(anchor: ax, moving: mx, initialMovingLess: false)
                minX = sx.min; maxX = sx.max; invertedX = sx.inverted

                let ay = startFrame.maxY
                let my = startFrame.minY + delta.height
                let sy = solveAxis(anchor: ay, moving: my, initialMovingLess: true)
                minY = sy.min; maxY = sy.max; invertedY = sy.inverted

            case .bottomLeft:
                let ax = startFrame.maxX
                let mx = startFrame.minX + delta.width
                let sx = solveAxis(anchor: ax, moving: mx, initialMovingLess: true)
                minX = sx.min; maxX = sx.max; invertedX = sx.inverted

                let ay = startFrame.minY
                let my = startFrame.maxY + delta.height
                let sy = solveAxis(anchor: ay, moving: my, initialMovingLess: false)
                minY = sy.min; maxY = sy.max; invertedY = sy.inverted

            case .bottomRight:
                let ax = startFrame.minX
                let mx = startFrame.maxX + delta.width
                let sx = solveAxis(anchor: ax, moving: mx, initialMovingLess: false)
                minX = sx.min; maxX = sx.max; invertedX = sx.inverted

                let ay = startFrame.minY
                let my = startFrame.maxY + delta.height
                let sy = solveAxis(anchor: ay, moving: my, initialMovingLess: false)
                minY = sy.min; maxY = sy.max; invertedY = sy.inverted
            }

        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), invertedX, invertedY)
    }

    private func calculateHorizontalResize(startFrame: CGRect,
                                           delta: CGSize,
                                           position: Edge,
                                           currentHeight: CGFloat) -> CGRect {
        var frame = startFrame
        switch position {
        case .left:
            frame.origin.x += delta.width
            frame.size.width -= delta.width
        case .right:
            frame.size.width += delta.width
        default:
            break
        }
        frame.size.height = currentHeight
        return frame
    }

    private func applyAspectRatio(rect: CGRect, startFrame: CGRect, aspect: CGFloat, position: Edge) -> CGRect {
        let clampedAspect = max(aspect, 0.0001)
        let minSize: CGFloat = 0.01
        var width = rect.width
        var height = rect.height

        let widthDelta = abs(rect.width - startFrame.width)
        let heightDelta = abs(rect.height - startFrame.height)
        if widthDelta > heightDelta {
            height = width / clampedAspect
        } else {
            width = height * clampedAspect
        }

        if width < minSize {
            width = minSize
            height = width / clampedAspect
        }
        if height < minSize {
            height = minSize
            width = height * clampedAspect
        }

        switch position {
        case .top:
            return CGRect(x: startFrame.midX - width / 2,
                          y: rect.minY,
                          width: width,
                          height: height)
        case .bottom:
            return CGRect(x: startFrame.midX - width / 2,
                          y: startFrame.minY,
                          width: width,
                          height: height)
        case .left:
            return CGRect(x: rect.minX,
                          y: startFrame.midY - height / 2,
                          width: width,
                          height: height)
        case .right:
            return CGRect(x: startFrame.minX,
                          y: startFrame.midY - height / 2,
                          width: width,
                          height: height)
        case .topLeft:
            return CGRect(x: startFrame.maxX - width,
                          y: startFrame.maxY - height,
                          width: width,
                          height: height)
        case .topRight:
            return CGRect(x: startFrame.minX,
                          y: startFrame.maxY - height,
                          width: width,
                          height: height)
        case .bottomLeft:
            return CGRect(x: startFrame.maxX - width,
                          y: startFrame.minY,
                          width: width,
                          height: height)
        case .bottomRight:
            return CGRect(x: startFrame.minX,
                          y: startFrame.minY,
                          width: width,
                          height: height)
        }
    }

    private func imageAspectRatio(for entry: BoardEntry) -> CGFloat? {
        guard case .image(let ref) = entry.data,
              let url = store.imageURL(for: ref),
              let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        let size = nsImage.size
        guard size.width > 0 && size.height > 0 else { return nil }
        return size.width / size.height
    }

    private func isImageEntry(_ entry: BoardEntry) -> Bool {
        if case .image = entry.data {
            return true
        }
        return false
    }

    private func isTextEntry(_ entry: BoardEntry) -> Bool {
        entry.type == .text
    }

    private func lineEndpoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint)? {
        guard case .line(let data) = entry.data,
              let first = data.points.first,
              let last = data.points.last else {
            return nil
        }
        let start = lineRelativePoint(first, in: rect)
        let end = lineRelativePoint(last, in: rect)
        return (start, end)
    }

    private func lineRelativePoint(_ p: Point, in rect: CGRect) -> CGPoint {
        let safeWidth = max(entry.w.cg, 0.001)
        let safeHeight = max(entry.h.cg, 0.001)
        let relativeX = (p.x.cg - entry.x.cg) / safeWidth * rect.width
        let relativeY = (p.y.cg - entry.y.cg) / safeHeight * rect.height
        return CGPoint(x: relativeX, y: relativeY)
    }

    private func circleOutlineResizeGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                guard let currentEntry = store.doc.entries[entry.id] else { return }
                
                // Calculate size based on distance from center (radial resize)
                // This allows dragging "any part of the outer line" intuitively.
                let center = CGPoint(
                    x: currentEntry.x.cg + currentEntry.w.cg / 2,
                    y: currentEntry.y.cg + currentEntry.h.cg / 2
                )
                
                let worldLocation = store.worldPoint(from: value.location)
                let dist = hypot(worldLocation.x - center.x, worldLocation.y - center.y)
                
                let newSize = max(dist * 2, 10)
                let newOrigin = CGPoint(x: center.x - newSize / 2, y: center.y - newSize / 2)
                
                let rect = CGRect(origin: newOrigin, size: CGSize(width: newSize, height: newSize))
                store.updateEntryFrame(id: entry.id, rect: rect)
            }
    }

    private func isCircleEntry(_ entry: BoardEntry) -> Bool {
        if case .shape(let kind) = entry.data {
            return kind == .circle
        }
        return false
    }

    private func isLineEntry(_ entry: BoardEntry) -> Bool {
        if case .line = entry.data {
            return true
        }
        return false
    }
}

// MARK: - Image Crop Overlay

private struct ImageCropOverlay: View {
    @EnvironmentObject var store: BoardStore
    let entryID: UUID

    @State private var startCrop: ImageCropInsets?
    @State private var activeEdge: Edge?

    private enum Edge { case left, right, top, bottom }

    private var crop: ImageCropInsets {
        store.doc.entries[entryID]?.imageCrop ?? .none
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let c = crop.clamped()
            let cropRect = rect(for: c, in: size)

            ZStack {
                // Dim outside crop
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(cropRect)
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))

                // Border
                Rectangle()
                    .path(in: cropRect)
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
            }
            .contentShape(Rectangle()) // whole overlay receives the drag
            .gesture(cropGesture(in: size))
        }
        .allowsHitTesting(true)
    }

    private func rect(for c: ImageCropInsets, in size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(c.left) * size.width,
            y: CGFloat(c.top) * size.height,
            width: max(1, (1 - CGFloat(c.left) - CGFloat(c.right)) * size.width),
            height: max(1, (1 - CGFloat(c.top) - CGFloat(c.bottom)) * size.height)
        )
    }

    private func closestEdge(start: CGPoint, cropRect: CGRect) -> Edge? {
        let threshold: CGFloat = 18

        let dLeft = abs(start.x - cropRect.minX)
        let dRight = abs(start.x - cropRect.maxX)
        let dTop = abs(start.y - cropRect.minY)
        let dBottom = abs(start.y - cropRect.maxY)

        let best = [
            (Edge.left, dLeft),
            (Edge.right, dRight),
            (Edge.top, dTop),
            (Edge.bottom, dBottom)
        ].min(by: { $0.1 < $1.1 })

        guard let pick = best, pick.1 <= threshold else { return nil }
        return pick.0
    }

    private func cropGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startCrop == nil {
                    startCrop = crop
                }
                guard let start = startCrop else { return }

                // Choose edge ONCE from the start location.
                if activeEdge == nil {
                    let startRect = rect(for: start.clamped(), in: canvasSize)
                    activeEdge = closestEdge(start: value.startLocation, cropRect: startRect)
                }
                guard let edge = activeEdge else { return }

                let dx = Double(value.translation.width / max(canvasSize.width, 1))
                let dy = Double(value.translation.height / max(canvasSize.height, 1))

                var next = start

                switch edge {
                case .left:
                    next.left = start.left + dx
                case .right:
                    next.right = start.right - dx
                case .top:
                    next.top = start.top + dy
                case .bottom:
                    next.bottom = start.bottom - dy
                }

                store.setImageCrop(entryID, crop: next.clamped(), recordUndo: false)
            }
            .onEnded { _ in
                // Commit
                store.setImageCrop(entryID, crop: crop.clamped(), recordUndo: true, fallbackUndoFrom: startCrop)
                startCrop = nil
                activeEdge = nil
            }
    }
}

// MARK: - BoardStore helpers (Image Crop)

extension BoardStore {
    func beginImageCrop(_ id: UUID) {
        select(id)
        doc.ui.activeImageCropID = id
    }

    func endImageCrop() {
        doc.ui.activeImageCropID = nil
    }

    func resetImageCrop(_ id: UUID) {
        guard var e = doc.entries[id] else { return }
        e.imageCrop = nil
        doc.entries[id] = e
    }

    /// Updates the crop for an image entry. `recordUndo` is accepted for API consistency,
    /// but this implementation simply mutates the doc.
    func setImageCrop(_ id: UUID,
                      crop: ImageCropInsets,
                      recordUndo: Bool,
                      fallbackUndoFrom: ImageCropInsets? = nil) {
        guard var e = doc.entries[id] else { return }
        e.imageCrop = crop.clamped()
        doc.entries[id] = e
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct EntryHitShape: ViewModifier {
    let shapeKind: ShapeKind?

    func body(content: Content) -> some View {
        guard let kind = shapeKind else {
            return AnyView(content.contentShape(Rectangle()))
        }
        switch kind {
        case .circle:
            return AnyView(content.contentShape(Circle()))
        case .rect:
            return AnyView(content.contentShape(Rectangle()))
        case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
            return AnyView(content.contentShape(TriangleShape(kind: kind)))
        }
    }
}
