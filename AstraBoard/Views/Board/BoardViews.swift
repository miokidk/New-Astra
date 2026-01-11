import SwiftUI
import AppKit

struct BoardGridView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let zoom = store.doc.viewport.zoom.cg
                let offsetX = store.doc.viewport.offsetX.cg
                let offsetY = store.doc.viewport.offsetY.cg
                
                // Grid spacing is constant in world coordinates.
                let step: CGFloat = 32
                
                // Spacing in screen coordinates.
                let spacing = step * zoom
                
                // Dot size scales with zoom, but is clamped to a reasonable range.
                let dotSize: CGFloat = min(max(1.5, 3.0 * zoom), 8.0)

                // Calculate visual offset based on pan.
                let offset = CGPoint(
                    x: offsetX.truncatingRemainder(dividingBy: spacing),
                    y: offsetY.truncatingRemainder(dividingBy: spacing)
                )

                // Draw dots
                var path = Path()
                // Don't draw if dots are too dense to avoid performance issues and visual noise.
                if spacing > 3.0 {
                    // Expand the drawing loop slightly outside bounds to ensure edges are covered during rapid pan.
                    for x in stride(from: offset.x - spacing, through: size.width + spacing, by: spacing) {
                        for y in stride(from: offset.y - spacing, through: size.height + spacing, by: spacing) {
                            // Center the dot on the grid point.
                            let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                            path.addEllipse(in: rect)
                        }
                    }
                }
                
                // Fade opacity smoothly when zooming very far out to reduce visual noise.
                let opacity = min(0.5, max(0.1, zoom * 0.4))
                ctx.fill(path, with: .color(Color.secondary.opacity(opacity)))
            }
            .background(ScrollZoomView { dx, dy, location, modifiers in
                store.notePointerLocation(location)
                if modifiers.contains(.option) || modifiers.contains(.command) {
                    // Zoom
                    // Scale factor: dy is usually small (e.g. 0.1 to 5.0).
                    // We map scrolling up (positive) to zoom in (>1) and down to zoom out (<1).
                    let sensitivity: CGFloat = 0.005
                    let scale = 1.0 + (dy * sensitivity)
                    store.applyZoom(delta: scale, focus: location)
                } else {
                    // Pan
                    store.applyPan(translation: CGSize(width: dx, height: dy))
                }
            })
        }
        .allowsHitTesting(true) // Ensure background takes hits
    }
}

struct BoardWorldView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var activeTextEdit: UUID?
    @State private var marqueeStart: CGPoint?
    @State private var lineDraftId: UUID?
    @State private var lineDragStart: CGPoint?
    @State private var lastPan: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeOrShapeDrag())
                    .simultaneousGesture(panGesture())
                    .simultaneousGesture(magnificationGesture())
                    .simultaneousGesture(clickGesture())

                ForEach(store.doc.zOrder, id: \.self) { id in
                    if let entry = store.doc.entries[id] {
                        EntryContainerView(entry: entry,
                                           activeTextEdit: $activeTextEdit)
                    }
                }

                ForEach(store.doc.zOrder, id: \.self) { id in
                    if let entry = store.doc.entries[id],
                       store.selection.contains(id),
                       entry.type == .shape || entry.type == .text {
                        styleButtonOverlay(for: entry)
                    }
                }

                if let marquee = store.marqueeRect {
                    let zoom = store.doc.viewport.zoom.cg
                    let size = CGSize(width: marquee.size.width * zoom,
                                      height: marquee.size.height * zoom)
                    let center = screenPoint(for: marquee.origin + CGSize(width: marquee.width / 2,
                                                                          height: marquee.height / 2))
                    if store.currentTool == .circle {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .background(Circle().fill(Color.accentColor.opacity(0.1)))
                            .frame(width: size.width, height: size.height)
                            .position(center)
                    } else {
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .background(Rectangle().fill(Color.accentColor.opacity(0.1)))
                            .frame(width: size.width, height: size.height)
                            .position(center)
                    }
                }
            }
            .background(Color.clear)
            .onChange(of: geo.size) { store.viewportSize = $0 }
            .onChange(of: store.currentTool) { tool in
                if tool != .line {
                    lineDraftId = nil
                    lineDragStart = nil
                }
            }
            .coordinateSpace(name: "board")
        }
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !store.isDraggingOverlay else { return }
                guard store.currentTool.allowsPanGesture else { return }
                guard store.marqueeRect == nil else { return }
                let delta = CGSize(width: value.translation.width - lastPan.width,
                                   height: value.translation.height - lastPan.height)
                store.applyPan(translation: delta)
                store.notePointerLocation(value.location)
                lastPan = value.translation
            }
            .onEnded { _ in lastPan = .zero }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let delta = scale / lastMagnification
                store.applyZoom(delta: delta, focus: store.lastPointerLocationInViewport)
                lastMagnification = scale
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }

    private func clickGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard store.currentTool == .line else { return }
                guard !store.isDraggingOverlay else { return }
                let startWorld = worldPoint(from: value.startLocation)
                let currentWorld = worldPoint(from: value.location)
                if lineDraftId == nil {
                    lineDragStart = startWorld
                    let id = store.createLineEntry(start: startWorld, end: currentWorld)
                    lineDraftId = id
                    store.selection = [id]
                } else if let id = lineDraftId {
                    store.updateLine(id: id, start: lineDragStart, end: currentWorld, recordUndo: false)
                }
                store.notePointerLocation(value.location)
            }
            .onEnded { value in
                guard !store.isDraggingOverlay else { return }
                dismissFocus()

                let screenPoint = value.location
                store.marqueeRect = nil
                marqueeStart = nil

                switch store.currentTool {
                case .line:
                    let zoom = max(store.doc.viewport.zoom.cg, 0.001)
                    let defaultLength: CGFloat = 140 / zoom
                    let fallbackStart = worldPoint(from: screenPoint)
                    let fallbackEnd = CGPoint(x: fallbackStart.x + defaultLength, y: fallbackStart.y)

                    let id = lineDraftId ?? store.createLineEntry(start: fallbackStart, end: fallbackEnd)
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance < 4, let start = lineDragStart {
                        let end = CGPoint(x: start.x + defaultLength, y: start.y)
                        store.updateLine(id: id, start: start, end: end, recordUndo: false)
                    }
                    store.selection = [id]
                    store.currentTool = .select
                    lineDraftId = nil
                    lineDragStart = nil

                default:
                    let distance = hypot(value.translation.width, value.translation.height)
                    guard distance < 3 else { return }

                    switch store.currentTool {
                    case .select:
                        if let hit = store.topEntryAtScreenPoint(screenPoint) {
                            store.selection = [hit]
                            withAnimation(.easeOut(duration: 0.12)) {
                                store.hideToolMenu()
                            }
                        } else {
                            // clicked empty board
                            if store.isToolMenuVisible {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    store.hideToolMenu()
                                }
                            } else {
                                store.selection.removeAll()
                                activeTextEdit = nil
                                withAnimation(.easeOut(duration: 0.12)) {
                                    store.showToolMenu(at: screenPoint)
                                }
                            }
                        }

                    case .text:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeText(at: worldPoint(from: screenPoint))

                    case .image:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        promptImage(at: worldPoint(from: screenPoint))

                    case .rect:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeShape(kind: .rect, at: worldPoint(from: screenPoint))

                    case .circle:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeShape(kind: .circle, at: worldPoint(from: screenPoint))

                    case .line:
                        break
                    }
                }
            }
    }

    private func marqueeOrShapeDrag() -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = worldPoint(from: value.startLocation)
                let current = worldPoint(from: value.location)
                marqueeStart = start
                let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: current, size: .zero))
                let marqueeRect = store.currentTool == .circle
                    ? squareRect(from: start, to: current)
                    : rect
                switch store.currentTool {
                case .select, .rect, .circle:
                    store.marqueeRect = marqueeRect
                default:
                    break
                }
                store.notePointerLocation(value.location)
            }
            .onEnded { value in
                let start = worldPoint(from: value.startLocation)
                let end = worldPoint(from: value.location)
                defer {
                    store.marqueeRect = nil
                    marqueeStart = nil
                }
                switch store.currentTool {
                case .select:
                    let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))
                    selectEntries(in: rect)
                case .rect:
                    let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))
                    let kind: ShapeKind = .rect
                    let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
                    store.selection = [id]
                    store.currentTool = .select
                case .circle:
                    let rect = squareRect(from: start, to: end)
                    let kind: ShapeKind = .circle
                    let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
                    store.selection = [id]
                    store.currentTool = .select
                default:
                    break
                }
            }
    }

    private func worldPoint(from screen: CGPoint) -> CGPoint {
        store.worldPoint(from: screen)
    }

    private func screenPoint(for world: CGPoint) -> CGPoint {
        store.screenPoint(fromWorld: world)
    }

    private func screenRect(for entry: BoardEntry) -> CGRect {
        let zoom = store.doc.viewport.zoom.cg
        let origin = CGPoint(x: entry.x.cg * zoom + store.doc.viewport.offsetX.cg,
                             y: entry.y.cg * zoom + store.doc.viewport.offsetY.cg)
        let size = CGSize(width: entry.w.cg * zoom, height: entry.h.cg * zoom)
        return CGRect(origin: origin, size: size)
    }

    private func styleButtonOverlay(for entry: BoardEntry) -> some View {
        let rect = screenRect(for: entry)
        let offset: CGFloat = 8
        return ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            Button(action: {
                store.togglePanel(.shapeStyle)
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Edit Style")
            .offset(x: offset, y: -offset)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func dismissFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func placeText(at point: CGPoint) {
        let rect = CGRect(x: point.x - 120, y: point.y - 80, width: 240, height: 160)
        let id = store.createEntry(type: .text, frame: rect, data: .text(""))
        store.selection = [id]
        activeTextEdit = id
        store.currentTool = .select
    }

    private func placeShape(kind: ShapeKind, at point: CGPoint) {
        let rect: CGRect
        switch kind {
        case .rect:
            rect = CGRect(x: point.x - 120, y: point.y - 80, width: 240, height: 160)
        case .circle:
            rect = CGRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
        }
        let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
        store.selection = [id]
        store.currentTool = .select
    }

    private func promptImage(at point: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "gif"]
        panel.allowsMultipleSelection = false
        defer { store.currentTool = .select }
        if panel.runModal() == .OK, let url = panel.url, let ref = store.copyImage(at: url) {
            let rect = imageRect(for: url, centeredAt: point, maxSide: 320)
            let id = store.createEntry(type: .image, frame: rect, data: .image(ref))
            store.selection = [id]
        }
    }

    private func imageRect(for url: URL, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        if let nsImage = NSImage(contentsOf: url) {
            let size = nsImage.size
            if size.width > 0 && size.height > 0 {
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
        }
        return CGRect(x: point.x - maxSide / 2,
                      y: point.y - maxSide / 2,
                      width: maxSide,
                      height: maxSide)
    }

    private func squareRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        guard side > 0 else {
            return CGRect(origin: start, size: .zero)
        }
        let originX = dx < 0 ? start.x - side : start.x
        let originY = dy < 0 ? start.y - side : start.y
        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func selectEntries(in rect: CGRect) {
        var hits: Set<UUID> = []
        for (id, entry) in store.doc.entries {
            let entryRect = CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg)
            if rect.intersects(entryRect) {
                hits.insert(id)
            }
        }
        store.selection = hits
    }
}

private struct LineBuilderView: View {
    var points: [CGPoint]
    var viewport: Viewport

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() {
                path.addLine(to: p)
            }
        }
        .stroke(Color.purple, lineWidth: 2)
        .scaleEffect(viewport.zoom.cg, anchor: .topLeading)
        .offset(x: viewport.offsetX.cg, y: viewport.offsetY.cg)
    }
}

struct ScrollZoomView: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollCaptureView: NSView {
            var onScroll: ((CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void)?
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                guard window != nil else {
                    monitor = nil
                    return
                }
                // Capture scroll events globally at the window level
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window else { return event }

                    // Check for zoom modifiers (Option or Command)
                    let isZoom = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)

                    // If NOT zooming, allow native scrolling for text views and scroll views
                    if !isZoom {
                        let hitView = window.contentView?.hitTest(event.locationInWindow)
                        if let textView = hitView as? NSTextView, textView.isEditable {
                            return event
                        }
                        if hitView?.enclosingScrollView != nil {
                            return event
                        }
                        if let responder = window.firstResponder as? NSView {
                            if let textView = responder as? NSTextView, textView.isEditable {
                                return event
                            }
                            if responder.enclosingScrollView != nil {
                                return event
                            }
                        }
                    }

                    // If we're zooming, process the event regardless of where the mouse is
                    // Convert the window location to our view's coordinate space
                    let location = self.convert(event.locationInWindow, from: nil)
                    self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, location, event.modifierFlags)
                    
                    // Consume the event when zooming to prevent it from being processed elsewhere
                    return nil
                }
            }

            deinit {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
            
            override func scrollWheel(with event: NSEvent) {
                // Fallback handler - but the monitor above should catch most events
                let location = convert(event.locationInWindow, from: nil)
                onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, location, event.modifierFlags)
            }
        }
}
