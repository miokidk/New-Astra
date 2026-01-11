import AppKit

enum TextEntryMetrics {
    static let defaultFontSize: CGFloat = 14
    static let textInsets = CGSize(width: 2, height: 2)
    static let minWidth: CGFloat = 40
    
    // Fix: Add a small vertical buffer to account for NSTextView rendering discrepancies vs boundingRect calculation.
    // Without this, the last line often gets clipped by 1-2 pixels.
    static let heightBuffer: CGFloat = 4.0

    static func font(for style: TextStyle) -> NSFont {
        let size = max(style.fontSize.cg, 1)
        if style.fontName == TextStyle.systemFontName {
            return NSFont.systemFont(ofSize: size)
        }
        if let font = NSFontManager.shared.font(withFamily: style.fontName,
                                                traits: [],
                                                weight: 5,
                                                size: size) {
            return font
        }
        if let font = NSFont(name: style.fontName, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    static func scaledFont(for style: TextStyle, zoom: CGFloat) -> NSFont {
        let base = font(for: style)
        let scale = max(zoom, 0.001)
        let size = max(base.pointSize * scale, 1)
        return base.withSize(size)
    }

    static func scaledInsets(for zoom: CGFloat) -> CGSize {
        let scale = max(zoom, 0.001)
        return CGSize(width: textInsets.width * scale, height: textInsets.height * scale)
    }

    static func height(for text: String, maxWidth: CGFloat, font: NSFont) -> CGFloat {
        let displayText: String
        if text.isEmpty {
            displayText = " "
        } else if text.hasSuffix("\n") {
            displayText = text + " "
        } else {
            displayText = text
        }
        let availableWidth = max(maxWidth - textInsets.width * 2, 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounding = (displayText as NSString).boundingRect(
            with: NSSize(width: availableWidth,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = font.ascender - font.descender + font.leading
        
        // Updated: Added heightBuffer to ensure the last line isn't clipped
        let height = ceil(max(bounding.height, lineHeight) + textInsets.height * 2 + heightBuffer)
        return max(height, 1)
    }

    static func height(for text: String, maxWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: defaultFontSize)
        return height(for: text, maxWidth: maxWidth, font: font)
    }

    static func contentSize(for text: String, font: NSFont) -> CGSize {
        let displayText: String
        if text.isEmpty {
            displayText = " "
        } else if text.hasSuffix("\n") {
            displayText = text + " "
        } else {
            displayText = text
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounding = (displayText as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = ceil(bounding.width + textInsets.width * 2)
        let lineHeight = font.ascender - font.descender + font.leading
        
        // Updated: Added heightBuffer here as well for consistency
        let height = ceil(max(bounding.height, lineHeight) + textInsets.height * 2 + heightBuffer)
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    static func contentSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: defaultFontSize)
        return contentSize(for: text, font: font)
    }
}
