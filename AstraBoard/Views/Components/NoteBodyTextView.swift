import SwiftUI
import AppKit

@MainActor
struct NoteBodyTextView: NSViewRepresentable {
    @Binding var text: String
    var store: BoardStore
    var font: NSFont
    var textColor: NSColor
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, store: store, font: font, textColor: textColor)
    }

    private static let debugPasteboard = true

    func makeNSView(context: Context) -> NoteTextScrollView {
        let scrollView = NoteTextScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .default

        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.handlePasteImages(in: textView)
        }
        configure(textView)
        applyStyle(textView)
        applyContainerStyle(scrollView, textView: textView)
        context.coordinator.applyText(text, to: textView)
        updateHeight(for: textView, in: scrollView)

        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NoteTextScrollView, context: Context) {
        guard let textView = nsView.documentView as? NoteTextView else { return }
        let textChanged = context.coordinator.lastAppliedText != text
        if textChanged {
            context.coordinator.applyText(text, to: textView)
        }
        textView.onPasteImages = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.handlePasteImages(in: textView)
        }
        textView.delegate = context.coordinator
        configure(textView)
        applyStyle(textView)
        applyContainerStyle(nsView, textView: textView)
        context.coordinator.updateAttachmentSizes(in: textView)
        updateHeight(for: textView, in: nsView)
    }

    private func configure(_ textView: NoteTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesRuler = false
        textView.usesFontPanel = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
    }

    private func applyStyle(_ textView: NoteTextView) {
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]
    }

    private func applyContainerStyle(_ scrollView: NoteTextScrollView, textView: NoteTextView) {
        scrollView.intrinsicHeight = intrinsicHeight(for: textView)
    }

    private func intrinsicHeight(for textView: NSTextView) -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textHeight = ceil(font.ascender - font.descender)
        let inset = textView.textContainerInset.height * 2
        return textHeight + inset
    }

    private func updateHeight(for textView: NoteTextView, in scrollView: NoteTextScrollView) {
        let minHeight = intrinsicHeight(for: textView)
        let availableWidth = max(1, scrollView.contentSize.width - textView.textContainerInset.width * 2)
        let measured = measuredHeight(for: textView, minHeight: minHeight, availableWidth: availableWidth)
        if abs(scrollView.intrinsicHeight - measured) > 0.5 {
            scrollView.intrinsicHeight = measured
            scrollView.invalidateIntrinsicContentSize()
            onHeightChange(measured)
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
        let height = ceil(used.height + inset)
        return max(minHeight, height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let store: BoardStore
        let font: NSFont
        let textColor: NSColor
        var lastAppliedText: String = ""

        init(text: Binding<String>, store: BoardStore, font: NSFont, textColor: NSColor) {
            self._text = text
            self.store = store
            self.font = font
            self.textColor = textColor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            let serialized = serialize(textView)
            lastAppliedText = serialized
            text = serialized
        }

        func handlePasteImages(in textView: NoteTextView) -> Bool {
            if NoteBodyTextView.debugPasteboard {
                dumpPasteboard()
            }
            let (refs, didHandle) = store.pasteNoteImagesFromPasteboard { [weak self, weak textView] ref in
                guard let self, let textView else { return }
                self.insertImage(ref, into: textView, store: self.store)
            }
            if !refs.isEmpty {
                insertImages(refs, into: textView)
            }
            return didHandle || !refs.isEmpty
        }

        func applyText(_ text: String, to textView: NoteTextView) {
            let selectedRange = textView.selectedRange()
            let availableWidth = max(1, textView.bounds.width - textView.textContainerInset.width * 2)
            let maxImageWidth = min(availableWidth, 720)
            let attributed = makeAttributedString(from: text, store: store, font: font, textColor: textColor, maxImageWidth: maxImageWidth)
            textView.textStorage?.setAttributedString(attributed)
            let safeLocation = min(selectedRange.location, attributed.length)
            let maxLength = max(0, attributed.length - safeLocation)
            let safeLength = min(selectedRange.length, maxLength)
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            lastAppliedText = text
        }

        func updateAttachmentSizes(in textView: NoteTextView) {
            let availableWidth = max(1, textView.bounds.width - textView.textContainerInset.width * 2)
            let maxImageWidth = min(availableWidth, 720)
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
                guard let attachment = value as? NoteImageAttachment,
                      let image = attachment.image else { return }
                let size = scaledImageSize(image, maxWidth: maxImageWidth)
                attachment.bounds = NSRect(origin: .zero, size: size)
                storage.addAttribute(.attachment, value: attachment, range: range)
            }
        }

        private func insertImages(_ refs: [ImageRef], into textView: NoteTextView) {
            for (index, ref) in refs.enumerated() {
                insertImage(ref, into: textView, store: store)
                if index != refs.count - 1 {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                }
            }
        }

        private func insertImage(_ ref: ImageRef, into textView: NoteTextView, store: BoardStore) {
            let availableWidth = max(1, textView.bounds.width - textView.textContainerInset.width * 2)
            let maxImageWidth = min(availableWidth, 720)
            guard let attachment = makeAttachment(for: ref, store: store, maxWidth: maxImageWidth) else {
                return
            }
            let insertion = NSAttributedString(attachment: attachment)
            let range = textView.selectedRange()
            textView.insertText(insertion, replacementRange: range)
            let newLocation = range.location + 1
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
        }

        private func serialize(_ textView: NoteTextView) -> String {
            guard let storage = textView.textStorage else { return "" }
            let full = NSRange(location: 0, length: storage.length)
            let nsString = storage.string as NSString
            var result = ""
            storage.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? NoteImageAttachment {
                    result += NoteImageToken.token(for: attachment.imageRef)
                } else {
                    result += nsString.substring(with: range)
                }
            }
            return result
        }

        private func dumpPasteboard() {
            let pb = NSPasteboard.general
            print("Pasteboard types:", pb.types ?? [])
            pb.pasteboardItems?.enumerated().forEach { idx, item in
                print("Item \\(idx) types:", item.types)
            }
        }
    }
}

final class NoteTextScrollView: NSScrollView {
    var intrinsicHeight: CGFloat = 22

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
    }
}

final class NoteTextView: NSTextView {
    var onPasteImages: (() -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func paste(_ sender: Any?) {
        if onPasteImages?() == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if onPasteImages?() == true { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if onPasteImages?() == true { return }
        super.pasteAsRichText(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)),
             #selector(pasteAsPlainText(_:)),
             #selector(pasteAsRichText(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

final class NoteImageAttachment: NSTextAttachment {
    let imageRef: ImageRef

    init(imageRef: ImageRef) {
        self.imageRef = imageRef
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

private enum NoteImageToken {
    static let prefix = "[[image:"
    static let suffix = "]]"
    static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\[\\[image:([^\\]]+)\\]\\]", options: [])
    }()

    static func token(for ref: ImageRef) -> String {
        prefix + ref.filename + suffix
    }
}

@MainActor
private func makeAttributedString(from text: String, store: BoardStore, font: NSFont, textColor: NSColor, maxImageWidth: CGFloat) -> NSAttributedString {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor
    ]
    guard let regex = NoteImageToken.regex else {
        return NSAttributedString(string: text, attributes: attributes)
    }
    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    let matches = regex.matches(in: text, options: [], range: fullRange)
    if matches.isEmpty {
        return NSAttributedString(string: text, attributes: attributes)
    }

    let result = NSMutableAttributedString()
    var cursor = 0
    for match in matches {
        let matchRange = match.range
        if matchRange.location > cursor {
            let range = NSRange(location: cursor, length: matchRange.location - cursor)
            result.append(NSAttributedString(string: ns.substring(with: range), attributes: attributes))
        }
        if match.numberOfRanges >= 2 {
            let filename = ns.substring(with: match.range(at: 1))
            let ref = ImageRef(filename: filename)
            if let attachment = makeAttachment(for: ref, store: store, maxWidth: maxImageWidth) {
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: "[Missing image]", attributes: attributes))
            }
        }
        cursor = matchRange.location + matchRange.length
    }
    if cursor < ns.length {
        let range = NSRange(location: cursor, length: ns.length - cursor)
        result.append(NSAttributedString(string: ns.substring(with: range), attributes: attributes))
    }

    return result
}

@MainActor
private func makeAttachment(for ref: ImageRef, store: BoardStore, maxWidth: CGFloat) -> NoteImageAttachment? {
    let image: NSImage?
    if let url = store.imageURL(for: ref),
       let loaded = NSImage(contentsOf: url) {
        image = loaded
    } else {
        image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    }
    guard let image else { return nil }
    let attachment = NoteImageAttachment(imageRef: ref)
    attachment.image = image
    let size = scaledImageSize(image, maxWidth: maxWidth)
    attachment.bounds = NSRect(origin: .zero, size: size)
    return attachment
}

private func scaledImageSize(_ image: NSImage, maxWidth: CGFloat) -> NSSize {
    let size = image.size
    guard size.width > 0 else { return NSSize(width: maxWidth, height: maxWidth) }
    let scale = min(1, maxWidth / size.width)
    return NSSize(width: size.width * scale, height: size.height * scale)
}
