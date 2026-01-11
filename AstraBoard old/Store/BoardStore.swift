import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PanelKind {
    case chat, chatArchive, log, thoughts, shapeStyle, settings, personality

    static let defaultZOrder: [PanelKind] = [
        .chat,
        .chatArchive,
        .log,
        .thoughts,
        .shapeStyle,
        .settings,
        .personality
    ]
}

final class BoardStore: ObservableObject {
    static let hudSize = CGSize(width: 780, height: 92)

    @Published var doc: BoardDoc {
        didSet { scheduleAutosave() }
    }
    @Published var selection: Set<UUID> = [] {
        didSet {
            closeStylePanelIfNeeded()
        }
    }
    @Published var currentTool: BoardTool = .select
    @Published var marqueeRect: CGRect?
    @Published var highlightEntryId: UUID?
    @Published var viewportSize: CGSize = .zero {
        didSet { clampHUDPosition() }
    }
    @Published var lineBuilder: [CGPoint] = []
    @Published var isDraggingOverlay: Bool = false
    @Published var chatWarning: String?
    @Published var chatDraftImage: ImageRef?
    @Published var pendingChatReplies: Int = 0
    @Published var chatNeedsAttention: Bool = false
    @Published var hudExtraHeight: CGFloat = 0 {
        didSet { clampHUDPosition() }
    }
    @Published var activeArchivedChatId: UUID?
    @Published private(set) var panelZOrder: [PanelKind] = PanelKind.defaultZOrder

    private let persistence: PersistenceService
    private let aiService: AIService
    private let imageModelName = "gpt-image-1.5"
    private var autosaveWorkItem: DispatchWorkItem?
    private let autosaveInterval: TimeInterval = 0.5

    init(persistence: PersistenceService, aiService: AIService) {
        self.persistence = persistence
        self.aiService = aiService
        if let loaded = persistence.load() {
            self.doc = loaded
        } else {
            self.doc = BoardDoc.defaultDoc()
            scheduleAutosave()
        }
    }

    private func closeStylePanelIfNeeded() {
        guard doc.ui.panels.shapeStyle.isOpen else { return }
        guard !hasStyleSelection else { return }
        doc.ui.panels.shapeStyle.isOpen = false
        touch()
    }
}

// MARK: - Persistence helpers
extension BoardStore {
    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            persistence.save(doc: doc)
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveInterval, execute: work)
    }

    func exportDocument() {
        persistence.export(doc: doc)
    }

    func importDocument() {
        guard let newDoc = persistence.importDoc() else { return }
        DispatchQueue.main.async {
            self.doc = newDoc
            self.selection.removeAll()
        }
    }

    func copyImage(at url: URL) -> ImageRef? {
        persistence.copyImage(url: url)
    }

    func saveImage(data: Data, ext: String = "png") -> ImageRef? {
        persistence.saveImage(data: data, ext: ext)
    }

    func imageURL(for ref: ImageRef) -> URL? {
        persistence.imageURL(for: ref)
    }
}

// MARK: - Doc + logging helpers
extension BoardStore {
    private func touch() {
        doc.updatedAt = Date().timeIntervalSince1970
    }

    func addLog(_ summary: String, actor: Actor = .user, related: [UUID]? = nil, relatedChatId: UUID? = nil) {
        let item = LogItem(id: UUID(),
                           ts: Date().timeIntervalSince1970,
                           actor: actor,
                           summary: summary,
                           relatedEntryIds: related,
                           relatedChatId: relatedChatId)
        doc.log.append(item)
        doc.log.sort { $0.ts < $1.ts }
    }

    func addThought(_ summary: String, related: [UUID]? = nil) {
        let thought = ThoughtItem(id: UUID(),
                                  ts: Date().timeIntervalSince1970,
                                  summary: summary,
                                  relatedEntryIds: related)
        doc.thoughts.append(thought)
        doc.thoughts.sort { $0.ts < $1.ts }
    }
}

// MARK: - Viewport
extension BoardStore {
    func applyPan(translation: CGSize) {
        // Direct 1:1 pan (screen pixels to viewport offset)
        doc.viewport.offsetX += translation.width.double
        doc.viewport.offsetY += translation.height.double
        touch()
    }

    func applyZoom(delta: CGFloat, focus: CGPoint?) {
        let oldZoom = doc.viewport.zoom
        
        // Revised limits: 0.02 (very far out) to 25.0 (microscope)
        let newZoom = max(0.02, min(25.0, oldZoom * delta.double))
        
        guard newZoom != oldZoom else { return }

        // If a focus point (mouse location) is provided, anchor the zoom to it.
        // This ensures the point under the cursor stays under the cursor.
        let focusPoint = focus ?? currentMouseLocationInViewport()
        if let focusPoint {
            let worldBefore = worldPoint(from: focusPoint, zoom: oldZoom)
            let screenAfter = screenPoint(fromWorld: worldBefore, zoom: newZoom)
            
            // Calculate how much the screen shifted due to zoom, and compensate the offset
            let offsetDelta = CGSize(width: (focusPoint.x - screenAfter.x), height: (focusPoint.y - screenAfter.y))
            doc.viewport.offsetX += offsetDelta.width.double
            doc.viewport.offsetY += offsetDelta.height.double
        } else {
            // Fallback to center zoom if no mouse point
            let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldBefore = worldPoint(from: center, zoom: oldZoom)
            let screenAfter = screenPoint(fromWorld: worldBefore, zoom: newZoom)
            let offsetDelta = CGSize(width: (center.x - screenAfter.x), height: (center.y - screenAfter.y))
            doc.viewport.offsetX += offsetDelta.width.double
            doc.viewport.offsetY += offsetDelta.height.double
        }
        
        doc.viewport.zoom = newZoom
        touch()
    }

    private func currentMouseLocationInViewport() -> CGPoint? {
        guard viewportSize != .zero else { return nil }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = contentView.convert(windowPoint, from: nil)
        guard localPoint.x >= 0,
              localPoint.y >= 0,
              localPoint.x <= viewportSize.width,
              localPoint.y <= viewportSize.height else {
            return nil
        }
        return localPoint
    }

    func worldPoint(from screen: CGPoint, zoom: Double? = nil) -> CGPoint {
        let z = zoom ?? doc.viewport.zoom
        let x = (screen.x - doc.viewport.offsetX.cg) / z.cg
        let y = (screen.y - doc.viewport.offsetY.cg) / z.cg
        return CGPoint(x: x, y: y)
    }

    func screenPoint(fromWorld point: Point, zoom: Double? = nil) -> CGPoint {
        let cgPoint = CGPoint(x: point.x.cg, y: point.y.cg)
        return screenPoint(fromWorld: cgPoint, zoom: zoom)
    }

    func screenPoint(fromWorld point: CGPoint, zoom: Double? = nil) -> CGPoint {
        let z = zoom ?? doc.viewport.zoom
        let x = point.x * z.cg + doc.viewport.offsetX.cg
        let y = point.y * z.cg + doc.viewport.offsetY.cg
        return CGPoint(x: x, y: y)
    }

    func jumpToEntry(id: UUID) {
        guard let entry = doc.entries[id] else { return }
        let center = CGPoint(x: (entry.x + entry.w / 2).cg, y: (entry.y + entry.h / 2).cg)
        let zoomTarget: Double = min(max(doc.viewport.zoom, 0.6), 1.5)
        doc.viewport.zoom = zoomTarget
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let offset = CGSize(width: screenCenter.x - center.x * zoomTarget.cg,
                            height: screenCenter.y - center.y * zoomTarget.cg)
        doc.viewport.offsetX = offset.width.double
        doc.viewport.offsetY = offset.height.double
        touch()
        pulseHighlight(id: id)
    }

    private func pulseHighlight(id: UUID) {
        highlightEntryId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.highlightEntryId == id else { return }
            self?.highlightEntryId = nil
        }
    }
}

// MARK: - Entry operations
extension BoardStore {
    func setSelection(_ ids: Set<UUID>) {
        selection = ids
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    @discardableResult
    func createEntry(type: EntryType, frame: CGRect, data: EntryData, createdBy: Actor = .user) -> UUID {
        let now = Date().timeIntervalSince1970
        let shapeStyle: ShapeStyle?
        let textStyle: TextStyle?
        switch data {
        case .shape(let kind):
            shapeStyle = ShapeStyle.default(for: kind)
            textStyle = nil
        case .text:
            shapeStyle = nil
            textStyle = TextStyle.default()
        default:
            shapeStyle = nil
            textStyle = nil
        }
        let entry = BoardEntry(id: UUID(),
                               type: type,
                               x: frame.origin.x.double,
                               y: frame.origin.y.double,
                               w: frame.size.width.double,
                               h: frame.size.height.double,
                               locked: false,
                               createdBy: createdBy,
                               createdAt: now,
                               updatedAt: now,
                               data: data,
                               shapeStyle: shapeStyle,
                               textStyle: textStyle)
        doc.entries[entry.id] = entry
        doc.zOrder.append(entry.id)
        touch()
        addLog("Created \(typeDisplay(type)) entry", related: [entry.id])
        return entry.id
    }

    func updateEntryFrame(id: UUID, rect: CGRect) {
        guard var entry = doc.entries[id] else { return }
        let clamped: CGRect
        if case .text(let text) = entry.data {
            let minWidth = TextEntryMetrics.minWidth
            let width = max(rect.size.width, minWidth)
            let font = TextEntryMetrics.font(for: textStyle(for: entry))
            let minHeight = TextEntryMetrics.height(for: text, maxWidth: width, font: font)
            let height = max(rect.size.height, minHeight)
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: width,
                             height: height)
        } else {
            let minSize = CGSize(width: 80, height: 60)
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: max(rect.size.width, minSize.width),
                             height: max(rect.size.height, minSize.height))
        }
        entry.x = clamped.origin.x.double
        entry.y = clamped.origin.y.double
        entry.w = clamped.size.width.double
        entry.h = clamped.size.height.double
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        touch()
    }

    func moveSelected(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        for id in selection {
            if var entry = doc.entries[id] {
                translateEntry(&entry, delta: delta)
                doc.entries[id] = entry
            }
        }
        touch()
    }

    func setEntryOrigin(id: UUID, origin: CGPoint) {
        guard var entry = doc.entries[id] else { return }
        let delta = CGSize(width: origin.x - entry.x.cg, height: origin.y - entry.y.cg)
        translateEntry(&entry, delta: delta)
        doc.entries[id] = entry
        touch()
    }

    private func translateEntry(_ entry: inout BoardEntry, delta: CGSize) {
        if case .line(let data) = entry.data {
            let shiftedPoints = data.points.map {
                Point(x: $0.x + delta.width.double, y: $0.y + delta.height.double)
            }
            let rect = boundingRect(for: shiftedPoints.map { CGPoint(x: $0.x.cg, y: $0.y.cg) })
                .insetBy(dx: -2, dy: -2)
            entry.x = rect.origin.x.double
            entry.y = rect.origin.y.double
            entry.w = rect.size.width.double
            entry.h = rect.size.height.double
            entry.data = .line(LineData(points: shiftedPoints, arrow: data.arrow))
        } else {
            entry.x += delta.width.double
            entry.y += delta.height.double
        }
        entry.updatedAt = Date().timeIntervalSince1970
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let ids = selection
        for id in ids {
            doc.entries.removeValue(forKey: id)
            doc.zOrder.removeAll { $0 == id }
        }
        addLog("Deleted \(ids.count) entr\(ids.count == 1 ? "y" : "ies")")
        selection.removeAll()
        touch()
    }

    func duplicateSelected() {
        let ids = selection
        var newIds: [UUID] = []
        for id in ids {
            guard let entry = doc.entries[id] else { continue }
            var frame = CGRect(x: entry.x.cg + 20, y: entry.y.cg + 20, width: entry.w.cg, height: entry.h.cg)
            frame = frame.integral
            let newId = createEntry(type: entry.type, frame: frame, data: entry.data, createdBy: entry.createdBy)
            if var newEntry = doc.entries[newId] {
                newEntry.data = entry.data
                newEntry.shapeStyle = entry.shapeStyle
                newEntry.textStyle = entry.textStyle
                doc.entries[newId] = newEntry
            }
            newIds.append(newId)
        }
        selection = Set(newIds)
        addLog("Duplicated \(ids.count) entr\(ids.count == 1 ? "y" : "ies")", related: Array(ids))
    }

    func clearBoard() {
        guard !doc.entries.isEmpty else { return }
        doc.entries.removeAll()
        doc.zOrder.removeAll()
        selection.removeAll()
        lineBuilder.removeAll()
        marqueeRect = nil
        highlightEntryId = nil
        addLog("Cleared board")
        touch()
    }

    func bringToFront(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        doc.zOrder.removeAll { ids.contains($0) }
        doc.zOrder.append(contentsOf: ids)
        touch()
    }

    func sendToBack(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        doc.zOrder.removeAll { ids.contains($0) }
        doc.zOrder.insert(contentsOf: ids, at: 0)
        touch()
    }

    func updateText(id: UUID, text: String) {
        guard var entry = doc.entries[id] else { return }
        entry.data = .text(text)
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        addLog("Edited text entry", related: [id])
        touch()
    }
}

// MARK: - Clipboard
extension BoardStore {
    @discardableResult
    func copyImageToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id] else { return false }
        return copyImagesToPasteboard(entries: [entry])
    }

    @discardableResult
    func copySelectedImagesToPasteboard() -> Bool {
        let orderedIds = doc.zOrder.filter { selection.contains($0) }
        let entries = orderedIds.compactMap { doc.entries[$0] }
        return copyImagesToPasteboard(entries: entries)
    }

    @discardableResult
    func pasteFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteImages(from: pasteboard) {
            return true
        }
        if let text = pasteText(from: pasteboard) {
            return pasteText(text)
        }
        return false
    }

    @discardableResult
    func attachChatImageFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general

        // 1) Normal cases (Finder file URLs, raw image data, NSImage, etc.)
        if let ref = chatImageRef(from: pasteboard) {
            chatDraftImage = ref
            return true
        }

        // 2) Promised files (screenshots "copy & delete", some browsers, etc.)
        if let receiver = firstImageFilePromiseReceiver(from: pasteboard) {
            receivePromisedImage(receiver)
            return true // swallow paste; we'll attach when the promise delivers
        }

        return false
    }
    
    private func firstImageFilePromiseReceiver(from pasteboard: NSPasteboard) -> NSFilePromiseReceiver? {
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]

        guard let receiver = receivers?.first else { return nil }

        // Only accept promises that look like images
        for type in receiver.fileTypes {
            let ut = UTType(type) ?? UTType(filenameExtension: type)
            if ut?.conforms(to: .image) == true {
                return receiver
            }
        }

        return nil
    }
    
    private func imageRefFromHTMLPasteboard(_ pasteboard: NSPasteboard) -> ImageRef? {
        guard let html = htmlString(from: pasteboard) else { return nil }

        // data:image/png;base64,...
        let pattern = "src=\\\"data:image/([^;\\\"]+);base64,([^\\\"]+)\\\""
        if let (mimeSub, b64) = firstRegexGroups(pattern: pattern, in: html),
           let data = Data(base64Encoded: b64) {
            let ext = mimeSub.lowercased() == "jpeg" ? "jpg" : mimeSub.lowercased()
            return persistence.saveImage(data: data, ext: ext)
        }
        return nil
    }

    private func remoteURLFromHTMLPasteboard(_ pasteboard: NSPasteboard) -> URL? {
        guard let html = htmlString(from: pasteboard) else { return nil }
        let pattern = "src=\\\"(https?://[^\\\"]+)\\\""
        if let (urlStr, _) = firstRegexGroups(pattern: pattern, in: html),
           let url = URL(string: urlStr) {
            return url
        }
        return nil
    }

    private func htmlString(from pasteboard: NSPasteboard) -> String? {
        let types: [NSPasteboard.PasteboardType] = [.html, NSPasteboard.PasteboardType("public.html")]
        for t in types {
            if let data = pasteboard.data(forType: t),
               let s = String(data: data, encoding: .utf8),
               !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Returns up to 2 capture groups from the first match.
    private func firstRegexGroups(pattern: String, in text: String) -> (String, String)? {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
            guard m.numberOfRanges >= 3 else { return nil }
            let g1 = ns.substring(with: m.range(at: 1))
            let g2 = ns.substring(with: m.range(at: 2))
            return (g1, g2)
        } catch {
            return nil
        }
    }

    private func downloadAndAttachRemoteImage(from url: URL) {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { return }
            let mime = response?.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("image/") else { return }

            let ext = fileExtension(fromMimeType: mime, fallbackURL: url)
            DispatchQueue.main.async {
                if let ref = self.persistence.saveImage(data: data, ext: ext) {
                    self.chatDraftImage = ref
                }
            }
        }.resume()
    }

    private func fileExtension(fromMimeType mime: String, fallbackURL: URL) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        default:
            let ext = fallbackURL.pathExtension
            return ext.isEmpty ? "png" : ext
        }
    }

    private func receivePromisedImage(_ receiver: NSFilePromiseReceiver) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AstraPaste-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: .main) { [weak self] fileURL, error in
            guard let self else { return }
            guard error == nil else {
                return
            }

            if let ref = self.copyImage(at: fileURL) {
                self.chatDraftImage = ref
            } else if let image = NSImage(contentsOf: fileURL),
                      let ref = self.savePasteboardImage(image) {
                self.chatDraftImage = ref
            }

            // Cleanup
            try? fm.removeItem(at: tempDir)
        }
    }

    func clearChatDraftImage() {
        chatDraftImage = nil
    }

    private func copyImagesToPasteboard(entries: [BoardEntry]) -> Bool {
        let images = entries.compactMap { entry -> NSImage? in
            guard case .image(let ref) = entry.data,
                  let url = imageURL(for: ref) else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
        guard !images.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(images)
    }

    private func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = imageFileURLs(from: pasteboard)
        var refs: [ImageRef] = []
        for url in urls {
            if let ref = copyImage(at: url) {
                refs.append(ref)
                continue
            }
            if let image = NSImage(contentsOf: url),
               let ref = savePasteboardImage(image) {
                refs.append(ref)
            }
        }
        if refs.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                if let ref = savePasteboardImage(image) {
                    refs.append(ref)
                }
            }
        }
        guard !refs.isEmpty else { return false }
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)
        var ids: [UUID] = []
        let offsetStep: CGFloat = 20
        for (index, ref) in refs.enumerated() {
            let offset = CGFloat(index) * offsetStep
            let center = CGPoint(x: worldCenter.x + offset, y: worldCenter.y + offset)
            let rect = imageRect(for: ref, centeredAt: center, maxSide: 320)
            let id = createEntry(type: .image, frame: rect, data: .image(ref))
            ids.append(id)
        }
        selection = Set(ids)
        return !ids.isEmpty
    }

    private func chatImageRef(from pasteboard: NSPasteboard) -> ImageRef? {
            // Try file URLs first
            let urls = imageFileURLs(from: pasteboard)
            for url in urls {
                if let ref = copyImage(at: url) {
                    return ref
                }
                if let image = NSImage(contentsOf: url),
                   let ref = savePasteboardImage(image) {
                    return ref
                }
            }
            
            // Try NSImage objects
            if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
               let image = images.first {
                return savePasteboardImage(image)
            }
            
            // Try common image data types
            let dataTypes: [NSPasteboard.PasteboardType] = [
                .tiff,
                .png,
                NSPasteboard.PasteboardType("public.png"),
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.jpg"),
                NSPasteboard.PasteboardType("public.heic"),
                NSPasteboard.PasteboardType("public.heif"),
                NSPasteboard.PasteboardType("public.gif"),
                NSPasteboard.PasteboardType("public.bmp"),
                NSPasteboard.PasteboardType("com.apple.icns")
            ]
            for type in dataTypes {
                if let data = pasteboard.data(forType: type),
                   let image = NSImage(data: data) {
                    return savePasteboardImage(image)
                }
            }
            
            // Try all pasteboard items and check if they conform to image types
            if let items = pasteboard.pasteboardItems {
                for item in items {
                    for type in item.types {
                        if let data = item.data(forType: type),
                           let image = NSImage(data: data) {
                            return savePasteboardImage(image)
                        }
                    }
                }
            }
            
            // Final fallback: try NSImage's pasteboard initializer
            if let image = NSImage(pasteboard: pasteboard) {
                return savePasteboardImage(image)
            }
            
            return nil
        }

    private func pasteText(from pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string) {
            return text
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    private func pasteText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let width = min(max(contentSize.width, minWidth), maxWidth)
        let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)
        let rect = CGRect(x: worldCenter.x - width / 2,
                          y: worldCenter.y - height / 2,
                          width: width,
                          height: height)
        let id = createEntry(type: .text, frame: rect, data: .text(trimmed))
        selection = [id]
        return true
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let data = item.data(forType: .fileURL),
                   let url = fileURL(fromPasteboardData: data) {
                    urls.append(url)
                }
                if let data = item.data(forType: .URL),
                   let url = fileURL(fromPasteboardData: data),
                   url.isFileURL {
                    urls.append(url)
                }
                if let urlString = item.string(forType: .fileURL),
                   let url = fileURL(fromPasteboardString: urlString) {
                    urls.append(url)
                }
                if let urlString = item.string(forType: .URL),
                   let url = fileURL(fromPasteboardString: urlString),
                   url.isFileURL {
                    urls.append(url)
                }
            }
        }
        if let fileList = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls.append(contentsOf: fileList.map { URL(fileURLWithPath: $0) })
        }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        return unique.filter { isLikelyImageURL($0) }
    }

    private func fileURL(fromPasteboardString string: String) -> URL? {
        if string.hasPrefix("file://") {
            return URL(string: string)
        }
        if string.hasPrefix("/") || string.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: string).expandingTildeInPath)
        }
        return nil
    }

    private func fileURL(fromPasteboardData data: Data) -> URL? {
        if let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = String(data: data, encoding: .utf8) {
            return fileURL(fromPasteboardString: string)
        }
        return nil
    }

    private func isLikelyImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"]
        if imageExts.contains(ext) {
            return true
        }
        guard let typeId = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
              let type = UTType(typeId) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private func savePasteboardImage(_ image: NSImage) -> ImageRef? {
        guard let data = pngData(from: image) else { return nil }
        return saveImage(data: data, ext: "png")
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - HUD / Panels
extension BoardStore {
    func toggleHUD() {
        doc.ui.hud.isVisible.toggle()
        clampHUDPosition()
        touch()
    }

    func moveHUD(by delta: CGSize) {
        doc.ui.hud.x += delta.width.double
        doc.ui.hud.y += delta.height.double
        touch()
    }

    func clampHUDPosition() {
        let size = Self.hudSize
        let maxX = max(0, viewportSize.width - size.width)
        let maxY = max(0, viewportSize.height - size.height)
        let clampedX = min(max(doc.ui.hud.x, 0), maxX.double)
        let clampedY = min(max(doc.ui.hud.y, 0), maxY.double)
        if clampedX != doc.ui.hud.x {
            doc.ui.hud.x = clampedX
        }
        if clampedY != doc.ui.hud.y {
            doc.ui.hud.y = clampedY
        }
    }

    func togglePanel(_ kind: PanelKind) {
        switch kind {
        case .chat:
            doc.ui.panels.chat.isOpen.toggle()
            if doc.ui.panels.chat.isOpen {
                chatNeedsAttention = false
            }
        case .chatArchive:
            doc.ui.panels.chatArchive.isOpen.toggle()
        case .log:
            doc.ui.panels.log.isOpen.toggle()
        case .thoughts:
            doc.ui.panels.thoughts.isOpen.toggle()
        case .shapeStyle:
            doc.ui.panels.shapeStyle.isOpen.toggle()
        case .settings:
            doc.ui.panels.settings.isOpen.toggle()
        case .personality:
            doc.ui.panels.personality.isOpen.toggle()
        }
        touch()
    }

    func updatePanel(_ kind: PanelKind, frame: CGRect) {
        switch kind {
        case .chat:
            doc.ui.panels.chat.x = frame.origin.x.double
            doc.ui.panels.chat.y = frame.origin.y.double
            doc.ui.panels.chat.w = frame.size.width.double
            doc.ui.panels.chat.h = frame.size.height.double
        case .chatArchive:
            doc.ui.panels.chatArchive.x = frame.origin.x.double
            doc.ui.panels.chatArchive.y = frame.origin.y.double
            doc.ui.panels.chatArchive.w = frame.size.width.double
            doc.ui.panels.chatArchive.h = frame.size.height.double
        case .log:
            doc.ui.panels.log.x = frame.origin.x.double
            doc.ui.panels.log.y = frame.origin.y.double
            doc.ui.panels.log.w = frame.size.width.double
            doc.ui.panels.log.h = frame.size.height.double
        case .thoughts:
            doc.ui.panels.thoughts.x = frame.origin.x.double
            doc.ui.panels.thoughts.y = frame.origin.y.double
            doc.ui.panels.thoughts.w = frame.size.width.double
            doc.ui.panels.thoughts.h = frame.size.height.double
        case .shapeStyle:
            doc.ui.panels.shapeStyle.x = frame.origin.x.double
            doc.ui.panels.shapeStyle.y = frame.origin.y.double
            doc.ui.panels.shapeStyle.w = frame.size.width.double
            doc.ui.panels.shapeStyle.h = frame.size.height.double
        case .settings:
            doc.ui.panels.settings.x = frame.origin.x.double
            doc.ui.panels.settings.y = frame.origin.y.double
            doc.ui.panels.settings.w = frame.size.width.double
            doc.ui.panels.settings.h = frame.size.height.double
        case .personality:
            doc.ui.panels.personality.x = frame.origin.x.double
            doc.ui.panels.personality.y = frame.origin.y.double
            doc.ui.panels.personality.w = frame.size.width.double
            doc.ui.panels.personality.h = frame.size.height.double
        }
        touch()
    }
}

// MARK: - Styles
extension BoardStore {
    var hasStyleSelection: Bool {
        selection.contains { id in
            guard let entry = doc.entries[id] else { return false }
            return entry.type == .shape || entry.type == .text
        }
    }

    func selectedShapeEntry() -> BoardEntry? {
        for id in selection {
            if let entry = doc.entries[id], entry.type == .shape {
                return entry
            }
        }
        return nil
    }

    func selectedTextEntry() -> BoardEntry? {
        for id in selection {
            if let entry = doc.entries[id], entry.type == .text {
                return entry
            }
        }
        return nil
    }

    func syncStylePanelVisibility() {
        if doc.ui.panels.shapeStyle.isOpen != hasStyleSelection {
            doc.ui.panels.shapeStyle.isOpen = hasStyleSelection
            touch()
        }
    }

    func shapeStyle(for entry: BoardEntry) -> ShapeStyle {
        if let style = entry.shapeStyle {
            return style
        }
        if case .shape(let kind) = entry.data {
            return ShapeStyle.default(for: kind)
        }
        return ShapeStyle.default(for: .rect)
    }

    func updateSelectedShapeStyles(_ update: (inout ShapeStyle) -> Void) {
        let now = Date().timeIntervalSince1970
        var didChange = false
        for id in selection {
            guard var entry = doc.entries[id], entry.type == .shape else { continue }
            var style = shapeStyle(for: entry)
            update(&style)
            entry.shapeStyle = style
            entry.updatedAt = now
            doc.entries[id] = entry
            didChange = true
        }
        if didChange {
            touch()
        }
    }

    func textStyle(for entry: BoardEntry) -> TextStyle {
        if let style = entry.textStyle {
            return style
        }
        return TextStyle.default()
    }

    func updateSelectedTextStyles(_ update: (inout TextStyle) -> Void) {
        let now = Date().timeIntervalSince1970
        var didChange = false
        for id in selection {
            guard var entry = doc.entries[id], entry.type == .text else { continue }
            var style = textStyle(for: entry)
            update(&style)
            entry.textStyle = style
            entry.updatedAt = now
            doc.entries[id] = entry
            didChange = true
        }
        if didChange {
            touch()
        }
    }
}

// MARK: - Chat Settings
extension BoardStore {
    var hasAPIKey: Bool {
        !doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ChatSettings.defaultModel : trimmed
    }

    @MainActor
    func updateChatSettings(_ update: (inout ChatSettings) -> Void) {
        let previousModel = normalizedModelName(doc.chatSettings.model)
        var next = doc.chatSettings
        let wasEmpty = next.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        update(&next)
        doc.chatSettings = next
        let isEmpty = next.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wasEmpty && !isEmpty {
            chatWarning = nil
        }
        let nextModel = normalizedModelName(next.model)
        if previousModel != nextModel {
            startNewChat(reason: "Started new chat after model switch")
        }
        touch()
    }
}

// MARK: - HUD Settings
extension BoardStore {
    @MainActor
    func updateHUDBarStyle(color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        doc.ui.hudBarColor = ColorComponents(red: Double(rgb.redComponent),
                                             green: Double(rgb.greenComponent),
                                             blue: Double(rgb.blueComponent))
        doc.ui.hudBarOpacity = max(0, min(1, Double(rgb.alphaComponent)))
        touch()
    }
}

// MARK: - Chat
extension BoardStore {
    @MainActor
    func startNewChat(reason: String? = nil) {
        guard !doc.chat.messages.isEmpty || chatWarning != nil else { return }
        var archivedChatId: UUID?
        if !doc.chat.messages.isEmpty {
            archivedChatId = doc.chat.id
            doc.chatHistory.append(doc.chat)
        }
        doc.chat = ChatThread(id: UUID(), messages: [])
        chatWarning = nil
        chatDraftImage = nil
        if let reason {
            addLog(reason, relatedChatId: archivedChatId)
        } else {
            addLog("Started new chat", relatedChatId: archivedChatId)
        }
        touch()
    }

    func archivedChat(id: UUID) -> ChatThread? {
        doc.chatHistory.first { $0.id == id }
    }

    func openArchivedChat(id: UUID) {
        guard archivedChat(id: id) != nil else { return }
        activeArchivedChatId = id
        doc.ui.panels.chatArchive.isOpen = true
        touch()
    }

    @MainActor
    func sendChat(text: String, image: ImageRef? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return false }
        let apiKey = doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            chatWarning = "Add your OpenAI API key in Settings to send messages."
            if !doc.ui.panels.settings.isOpen {
                doc.ui.panels.settings.isOpen = true
            }
            touch()
            return false
        }

        chatWarning = nil
        let now = Date().timeIntervalSince1970
        let messageText = trimmed.isEmpty ? "" : text
        let userMsg = ChatMsg(id: UUID(), role: .user, text: messageText, image: image, ts: now)
        doc.chat.messages.append(userMsg)
        addLog("User sent message")
        let prompt = image == nil ? imagePrompt(from: text) : nil
        let messagesForAPI: [AIService.Message]?
        if prompt == nil {
            messagesForAPI = openAIMessages(from: doc.chat.messages,
                                            personality: doc.chatSettings.personality)
        } else {
            messagesForAPI = nil
        }
        let replyId = UUID()
        let replyText = prompt == nil ? "" : "Generating image..."
        let reply = ChatMsg(id: replyId,
                            role: .model,
                            text: replyText,
                            image: nil,
                            ts: Date().timeIntervalSince1970)
        doc.chat.messages.append(reply)
        pendingChatReplies += 1
        touch()

        if let prompt {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.aiService.generateImage(model: self.imageModelName,
                                                                       apiKey: apiKey,
                                                                       prompt: prompt)
                    guard let imageRef = self.saveImage(data: result.data) else {
                        throw AIService.AIServiceError.invalidResponse
                    }
                    await MainActor.run {
                        self.finishImageReply(replyId: replyId,
                                              prompt: prompt,
                                              revisedPrompt: result.revisedPrompt,
                                              imageRef: imageRef)
                    }
                } catch {
                    await MainActor.run {
                        self.failChatReply(replyId: replyId, error: error)
                    }
                }
            }
            return true
        }

        guard let messagesForAPI else {
            pendingChatReplies = max(0, pendingChatReplies - 1)
            return true
        }
        let model = doc.chatSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.isEmpty ? ChatSettings.defaultModel : model

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.aiService.streamChat(model: modelName,
                                                    apiKey: apiKey,
                                                    messages: messagesForAPI) { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        self.appendChatDelta(replyId: replyId, delta: delta)
                    }
                }
                await MainActor.run {
                    self.finishChatReply(replyId: replyId)
                }
            } catch {
                await MainActor.run {
                    self.failChatReply(replyId: replyId, error: error)
                }
            }
        }
        return true
    }

    private func imagePrompt(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        let directPrefixes = ["/image", "/img", "image:", "img:"]
        for prefix in directPrefixes {
            if lowered.hasPrefix(prefix) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                var remainder = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix(":") {
                    remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        let phrasePrefixes = [
            "draw ", "draw:",
            "sketch ", "sketch:",
            "illustrate ", "illustrate:",
            "paint ", "paint:",
            "generate image of ", "generate an image of ",
            "generate image ", "generate an image ",
            "create image of ", "create an image of ",
            "create image ", "create an image ",
            "make image of ", "make an image of ",
            "make image ", "make an image ",
            "image of ", "picture of ", "photo of "
        ]
        for prefix in phrasePrefixes {
            if lowered.hasPrefix(prefix) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                let remainder = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        return nil
    }

    private func openAIMessages(from history: [ChatMsg], personality: String) -> [AIService.Message] {
        var messages: [AIService.Message] = []
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonality.isEmpty {
            messages.append(AIService.Message(role: "system", content: .text(trimmedPersonality)))
        }
        let previousImage = history.dropLast().last?.image
        let lastMessageId = history.last?.id
        for msg in history {
            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImage = msg.image != nil
            if trimmed.isEmpty && !hasImage { continue }
            let role = msg.role == .user ? "user" : "assistant"
            if msg.role == .user {
                var parts: [AIService.Message.ContentPart] = []
                var includesImage = false
                if let imageRef = msg.image,
                   let dataURL = imageDataURL(for: imageRef) {
                    parts.append(.image(url: dataURL))
                    includesImage = true
                }
                if msg.id == lastMessageId,
                   msg.image == nil,
                   let imageRef = previousImage,
                   let dataURL = imageDataURL(for: imageRef) {
                    parts.append(.image(url: dataURL))
                    includesImage = true
                }
                if !trimmed.isEmpty {
                    parts.append(.text(trimmed))
                }
                if includesImage {
                    messages.append(AIService.Message(role: role, content: .parts(parts)))
                } else if !trimmed.isEmpty {
                    messages.append(AIService.Message(role: role, content: .text(trimmed)))
                }
            } else if !trimmed.isEmpty {
                messages.append(AIService.Message(role: role, content: .text(trimmed)))
            }
        }
        return messages
    }

    private func imageDataURL(for ref: ImageRef) -> String? {
        guard let url = imageURL(for: ref),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "gif":
            mimeType = "image/gif"
        case "heic":
            mimeType = "image/heic"
        case "heif":
            mimeType = "image/heif"
        default:
            mimeType = "application/octet-stream"
        }
        let base64 = data.base64EncodedString()
        return "data:\(mimeType);base64,\(base64)"
    }

    @MainActor
    private func appendChatDelta(replyId: UUID, delta: String) {
        guard !delta.isEmpty else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return }
        doc.chat.messages[index].text += delta
    }

    @MainActor
    private func finishChatReply(replyId: UUID) {
        pendingChatReplies = max(0, pendingChatReplies - 1)
        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }
        if let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) {
            doc.chat.messages[index].ts = Date().timeIntervalSince1970
            if doc.chat.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                doc.chat.messages[index].text = "No response from the model."
            }
        }
        addLog("Astra replied")
        addModelThought()
        touch()
    }

    @MainActor
    private func finishImageReply(replyId: UUID,
                                  prompt: String,
                                  revisedPrompt: String?,
                                  imageRef: ImageRef) {
        pendingChatReplies = max(0, pendingChatReplies - 1)
        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }
        if let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) {
            let cleanPrompt = (revisedPrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            doc.chat.messages[index].ts = Date().timeIntervalSince1970
            doc.chat.messages[index].image = imageRef
            if cleanPrompt.isEmpty {
                doc.chat.messages[index].text = "Generated an image."
            } else {
                doc.chat.messages[index].text = "Generated image for: \(cleanPrompt)"
            }
        }
        addLog("Astra generated an image")
        addModelThought()
        touch()
    }

    @MainActor
    private func failChatReply(replyId: UUID, error: Error) {
        pendingChatReplies = max(0, pendingChatReplies - 1)
        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        chatWarning = "Model request failed: \(message)"
        if let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) {
            let fallback = "Request failed: \(message)"
            if doc.chat.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                doc.chat.messages[index].text = fallback
            } else {
                doc.chat.messages[index].text += "\n\n\(fallback)"
            }
        }
        addLog("Model request failed")
        touch()
    }

    private func addModelThought() {
        if let firstSelection = selection.first {
            addThought("Model commented on a selection", related: [firstSelection])
        } else if let latest = doc.zOrder.last {
            addThought("Model added a thought about a recent entry", related: [latest])
        } else {
            addThought("Model left a thought")
        }
    }

    @MainActor
    func pinChatMessage(_ message: ChatMsg) {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = message.image != nil
        guard !trimmed.isEmpty || hasImage else { return }
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)

        if let imageRef = message.image {
            let rect = imageRect(for: imageRef, centeredAt: worldCenter, maxSide: 320)
            let id = createEntry(type: .image, frame: rect, data: .image(imageRef), createdBy: message.role)
            selection = [id]
            return
        }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let width = min(max(contentSize.width, minWidth), maxWidth)
        let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
        let rect = CGRect(x: worldCenter.x - width / 2,
                          y: worldCenter.y - height / 2,
                          width: width,
                          height: height)
        let id = createEntry(type: .text, frame: rect, data: .text(trimmed), createdBy: message.role)
        selection = [id]
    }

    @MainActor
    @discardableResult
    func pinChatInputText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let width = min(max(contentSize.width, minWidth), maxWidth)
        let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)
        let rect = CGRect(x: worldCenter.x - width / 2,
                          y: worldCenter.y - height / 2,
                          width: width,
                          height: height)
        let id = createEntry(type: .text, frame: rect, data: .text(trimmed), createdBy: .user)
        selection = [id]
        return true
    }

    private func imageRect(for ref: ImageRef, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        if let url = imageURL(for: ref), let nsImage = NSImage(contentsOf: url) {
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
}

// MARK: - Line builder
extension BoardStore {
    func appendLinePoint(_ point: CGPoint) {
        lineBuilder.append(point)
    }

    func finishLine(arrow: Bool = true) {
        guard lineBuilder.count > 1 else {
            lineBuilder.removeAll()
            currentTool = .select
            return
        }
        let points = lineBuilder.map { Point(x: $0.x.double, y: $0.y.double) }
        let rect = boundingRect(for: lineBuilder)
        let data = LineData(points: points, arrow: arrow)
        let id = createEntry(type: .line, frame: rect.insetBy(dx: -2, dy: -2), data: .line(data))
        selection = [id]
        lineBuilder.removeAll()
        currentTool = .select
    }

    fileprivate func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func topEntry(at worldPoint: CGPoint) -> UUID? {
        for id in doc.zOrder.reversed() {
            guard let entry = doc.entries[id] else { continue }
            if entryContainsPoint(entry, worldPoint: worldPoint) {
                return id
            }
        }
        return nil
    }

    func topEntryAtScreenPoint(_ screenPoint: CGPoint) -> UUID? {
        let worldPoint = worldPoint(from: screenPoint)
        for id in doc.zOrder.reversed() {
            guard let entry = doc.entries[id] else { continue }
            if entryContainsPoint(entry, worldPoint: worldPoint) {
                return id
            }
        }
        return nil
    }

    private func entryContainsPoint(_ entry: BoardEntry, worldPoint: CGPoint) -> Bool {
        let rect = CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg)
        if case .shape(let kind) = entry.data, kind == .circle {
            let rx = rect.width / 2
            let ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = (worldPoint.x - center.x) / rx
            let dy = (worldPoint.y - center.y) / ry
            return (dx * dx + dy * dy) <= 1.0
        }
        return rect.contains(worldPoint)
    }
}

private func typeDisplay(_ type: EntryType) -> String {
    switch type {
    case .text: return "text"
    case .image: return "image"
    case .shape: return "shape"
    case .line: return "line"
    }
}
