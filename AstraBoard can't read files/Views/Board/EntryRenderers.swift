import SwiftUI
import AppKit

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

    var body: some View {
        let rect = screenRect(for: entry)
        
        // 1. Define the content with its specific frame
        ZStack(alignment: .topLeading) {
            EntryContentView(entry: entry, activeTextEdit: $activeTextEdit)
                .frame(width: rect.width, height: rect.height)
                .overlay(selectionOverlay(rect: rect))
                .overlay(highlightOverlay(rect: rect))
        }
        // 2. Apply effects and gestures to the specific frame content strictly BEFORE positioning
        .shadow(color: entryShadowColor, radius: 9, x: 0, y: 4)
        .modifier(EntryHitShape(isCircle: isCircleEntry(entry)))
        .gesture(entryDrag())
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
            if entry.type == .image {
                Button("Copy Image") { store.copyImageToPasteboard(id: entry.id) }
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
                if store.selection.count == 1 {
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

    private func isCircleEntry(_ entry: BoardEntry) -> Bool {
        if case .shape(let kind) = entry.data {
            return kind == .circle
        }
        return false
    }

    @ViewBuilder
    private func selectionOutlineView(color: Color, lineWidth: CGFloat) -> some View {
        switch entry.data {
        case .shape(let kind):
            if kind == .circle {
                outsideStrokeCircle(lineWidth: lineWidth, color: color)
            } else {
                outsideStrokeRoundedRect(cornerRadius: 8, lineWidth: lineWidth, color: color)
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
        RoundedRectangle(cornerRadius: cornerRadius + lineWidth / 2)
            .inset(by: -lineWidth / 2)
            .stroke(color, lineWidth: lineWidth)
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
                if let url = store.imageURL(for: ref), let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        // Changed from scaledToFit to allow free resizing
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
                if kind == .rect {
                    let cornerRadius: CGFloat = 8
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fill)
                        .overlay(outsideStrokeRoundedRect(cornerRadius: cornerRadius,
                                                          lineWidth: lineWidth,
                                                          color: stroke))
                } else {
                    Circle()
                        .fill(fill)
                        .overlay(outsideStrokeCircle(lineWidth: lineWidth, color: stroke))
                }
            case .line(let data):
                let zoom = store.doc.viewport.zoom.cg
                LineEntryShape(data: data, entry: entry)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2 * zoom))
            }
        }
        .background(entryBackground)
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
        .gesture(lineEndpointDragGesture(endpoint))
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
                var newRect = calculateStandardResize(startFrame: startFrame, delta: delta, position: position)
                
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
            }
    }

    private func lineEndpointDragGesture(_ endpoint: LineEndpoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                guard let currentEntry = store.doc.entries[entry.id],
                      case .line = currentEntry.data else { return }
                let worldPoint = store.worldPoint(from: value.location)
                switch endpoint {
                case .start:
                    store.updateLine(id: entry.id, start: worldPoint)
                case .end:
                    store.updateLine(id: entry.id, end: worldPoint)
                }
            }
    }
    
    private func calculateStandardResize(startFrame: CGRect, delta: CGSize, position: Edge) -> CGRect {
        var frame = startFrame
        let minSize: CGFloat = 10
        
        switch position {
        case .top:
            frame.origin.y += delta.height
            frame.size.height -= delta.height
        case .bottom:
            frame.size.height += delta.height
        case .left:
            frame.origin.x += delta.width
            frame.size.width -= delta.width
        case .right:
            frame.size.width += delta.width
        case .topLeft:
            frame.origin.x += delta.width
            frame.origin.y += delta.height
            frame.size.width -= delta.width
            frame.size.height -= delta.height
        case .topRight:
            frame.origin.y += delta.height
            frame.size.width += delta.width
            frame.size.height -= delta.height
        case .bottomLeft:
            frame.origin.x += delta.width
            frame.size.width -= delta.width
            frame.size.height += delta.height
        case .bottomRight:
            frame.size.width += delta.width
            frame.size.height += delta.height
        }
        
        if frame.width < minSize { frame.size.width = minSize }
        if frame.height < minSize { frame.size.height = minSize }
        
        return frame
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
        let minSize: CGFloat = 10
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
    let isCircle: Bool

    func body(content: Content) -> some View {
        if isCircle {
            content.contentShape(Circle())
        } else {
            content.contentShape(Rectangle())
        }
    }
}
