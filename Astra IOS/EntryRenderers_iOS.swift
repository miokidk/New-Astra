import SwiftUI
import UIKit

struct EntryContainerView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    var entry: BoardEntry
    @State private var dragStartFrames: [UUID: CGRect] = [:]
    @State private var dragStartWorld: CGPoint?

    private var isSelected: Bool {
        store.selection.contains(entry.id)
    }

    var body: some View {
        let rect = store.screenRect(for: entry)
        ZStack(alignment: .topLeading) {
            EntryContentView(entry: entry)
                .frame(width: rect.width, height: rect.height)
                .modifier(EntryHitShape(isCircle: isCircleEntry(entry)))
                .gesture(entryDrag())

            if isSelected {
                selectionOverlay(rect: rect)
            }
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                radius: 8,
                x: 0,
                y: 4)
    .position(x: rect.midX, y: rect.midY)
    .onTapGesture { store.select(entry.id) }
    .onTapGesture(count: 2) {
        if entry.type == .text {
            store.beginEditing(entry.id)
        } else if case .file(let ref) = entry.data {
            store.openFile(ref)
        }
    }
}

    private func selectionOverlay(rect: CGRect) -> some View {
        let lineWidth = max(1, 1 / max(store.zoom, 0.001))
        return ZStack(alignment: .topLeading) {
            selectionOutlineView(color: Color(UIColor.separator), lineWidth: lineWidth)
            if store.selection.count == 1 {
                ResizeHandles(entry: entry)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    }

    private func entryDrag() -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("board"))
            .onChanged { value in
                guard !store.isDraggingOverlay else { return }
                store.isDraggingOverlay = true
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
                    let origin = CGPoint(x: rect.origin.x + delta.width,
                                         y: rect.origin.y + delta.height)
                    store.setEntryOrigin(id: id, origin: origin)
                }
            }
            .onEnded { _ in
                dragStartFrames = [:]
                dragStartWorld = nil
                store.isDraggingOverlay = false
            }
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

    var body: some View {
        ZStack {
            switch entry.data {
            case .text(let text):
                let textStyle = store.textStyle(for: entry)
                let zoom = store.zoom
                AutoSizingTextView(
                    text: Binding(get: { text }, set: { newValue in
                        store.updateText(id: entry.id, text: newValue)
                    }),
                    style: textStyle,
                    isEditable: store.editingEntryID == entry.id,
                    zoom: zoom,
                    colorScheme: colorScheme
                )
                .background(Color.clear)
                .allowsHitTesting(store.editingEntryID == entry.id)
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
                if let url = store.imageURL(for: ref),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(Color(UIColor.separator).opacity(0.2))
                } else {
                    ZStack {
                        Color(UIColor.secondarySystemBackground)
                        Text("Image missing")
                            .foregroundColor(.secondary)
                    }
                }
            case .file(let ref):
                FileEntryView(ref: ref)
            case .shape(let kind):
                let style = store.shapeStyle(for: entry)
                let zoom = store.zoom
                let fill = style.fillColor.color.opacity(style.fillOpacity)
                let stroke = style.borderColor.color.opacity(style.borderOpacity)
                let lineWidth = max(style.borderWidth, 0).cg * zoom
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
                let zoom = store.zoom
                let lineColor: Color = (colorScheme == .dark) ? .white : .black
                LineEntryShape(data: data, entry: entry)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round, lineJoin: .round))
            }
        }
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
            store.updateEntryFrame(id: entry.id, rect: rect)
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
                            .background(Capsule().fill(Color(UIColor.separator).opacity(0.4)))
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
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.8))
        )
    }
}

private struct AutoSizingTextView: UIViewRepresentable {
    @Binding var text: String
    var style: TextStyle
    var isEditable: Bool
    var zoom: CGFloat
    var colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = scaledInsets()
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.text = text
        applyStyle(textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.textContainerInset = scaledInsets()
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        applyStyle(textView)
        if isEditable, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        if !isEditable, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    private func scaledInsets() -> UIEdgeInsets {
        let insets = TextEntryMetrics.scaledInsets(for: zoom)
        return UIEdgeInsets(top: insets.height,
                            left: insets.width,
                            bottom: insets.height,
                            right: insets.width)
    }

    private func applyStyle(_ textView: UITextView) {
        let baseFont = TextEntryMetrics.font(for: style)
        let font = TextEntryMetrics.scaledFont(for: style, zoom: zoom)

        let textColor: UIColor = style.textColor.shouldAutoAdaptForColorScheme
            ? (colorScheme == .dark ? UIColor.white : UIColor.black).withAlphaComponent(style.textOpacity.cg)
            : UIColor(red: style.textColor.red.cg,
                      green: style.textColor.green.cg,
                      blue: style.textColor.blue.cg,
                      alpha: style.textOpacity.cg)
        let outlineColor: UIColor = style.outlineColor.shouldAutoAdaptForColorScheme
            ? (colorScheme == .dark ? UIColor.white : UIColor.black).withAlphaComponent(style.textOpacity.cg)
            : UIColor(red: style.outlineColor.red.cg,
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

        textView.typingAttributes = attributes
        textView.textColor = textColor
        textView.font = font

        let storage = textView.textStorage
        let selectedRange = textView.selectedRange
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(attributes, range: fullRange)
        storage.endEditing()
        textView.selectedRange = selectedRange
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text ?? ""
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
    @State private var resizeStartFrame: CGRect?

    private let edgeThickness: CGFloat = 12
    private let cornerSize: CGFloat = 20

    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum LineEndpoint {
        case start, end
    }

    var body: some View {
        let zoom = store.zoom
        let width = entry.w.cg * zoom
        let height = entry.h.cg * zoom
        let handleRect = CGRect(x: 0, y: 0, width: width, height: height)
        let isText = entry.type == .text
        let isLine = isLineEntry(entry)

        return ZStack {
            if isLine, let endpoints = lineEndpoints(in: handleRect) {
                lineHandle(at: endpoints.start, endpoint: .start)
                lineHandle(at: endpoints.end, endpoint: .end)
            } else {
                if isText {
                    edgeHandle(position: .left, width: edgeThickness, height: handleRect.height)
                        .position(x: handleRect.minX, y: handleRect.midY)
                    edgeHandle(position: .right, width: edgeThickness, height: handleRect.height)
                        .position(x: handleRect.maxX, y: handleRect.midY)
                } else {
                    edgeHandle(position: .top, width: handleRect.width, height: edgeThickness)
                        .position(x: handleRect.midX, y: handleRect.minY)
                    edgeHandle(position: .bottom, width: handleRect.width, height: edgeThickness)
                        .position(x: handleRect.midX, y: handleRect.maxY)
                    edgeHandle(position: .left, width: edgeThickness, height: handleRect.height)
                        .position(x: handleRect.minX, y: handleRect.midY)
                    edgeHandle(position: .right, width: edgeThickness, height: handleRect.height)
                        .position(x: handleRect.maxX, y: handleRect.midY)
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

    private func edgeHandle(position: Edge, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue.opacity(0.01))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(resizeGesture(for: position))
    }

    private func cornerHandle(position: Edge) -> some View {
        Rectangle()
            .fill(Color.blue.opacity(0.01))
            .frame(width: cornerSize, height: cornerSize)
            .contentShape(Rectangle())
            .gesture(resizeGesture(for: position))
    }

    private func lineHandle(at point: CGPoint, endpoint: LineEndpoint) -> some View {
        ZStack {
            Circle()
                .fill(Color(UIColor.systemBackground))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 28, height: 28)
        }
        .position(point)
        .contentShape(Circle())
        .highPriorityGesture(lineEndpointDragGesture(endpoint))
    }

    private func resizeGesture(for position: Edge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("board"))
            .onChanged { value in
                guard let currentEntry = store.doc.entries[entry.id] else { return }
                store.isDraggingOverlay = true
                if resizeStartFrame == nil {
                    resizeStartFrame = CGRect(x: currentEntry.x.cg,
                                              y: currentEntry.y.cg,
                                              width: currentEntry.w.cg,
                                              height: currentEntry.h.cg)
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

                var newRect = calculateStandardResize(startFrame: startFrame, delta: delta, position: position)

                if isCircleEntry(currentEntry) {
                    let side = max(newRect.width, newRect.height)
                    let center = CGPoint(x: newRect.midX, y: newRect.midY)
                    newRect = CGRect(x: center.x - side / 2,
                                     y: center.y - side / 2,
                                     width: side,
                                     height: side)
                }

                if isImageEntry(currentEntry),
                   let aspect = imageAspectRatio(for: currentEntry) {
                    newRect = applyAspectRatio(rect: newRect, startFrame: startFrame, aspect: aspect, position: position)
                }

                store.updateEntryFrame(id: entry.id, rect: newRect)
            }
            .onEnded { _ in
                resizeStartFrame = nil
                store.isDraggingOverlay = false
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
                    store.updateLine(id: entry.id, start: worldPoint)
                case .end:
                    store.updateLine(id: entry.id, end: worldPoint)
                }
            }
            .onEnded { _ in
                store.isDraggingOverlay = false
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
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        let size = image.size
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
