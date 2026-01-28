#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformFont = UIFont
#endif

enum TextEntryMetrics {
    static let defaultFontSize: CGFloat = 14
    static let textInsets = CGSize(width: 2, height: 2)
    static let minWidth: CGFloat = 40
    private static let maxMeasurementWidth: CGFloat = 4096

    // Buffer to avoid last-line clipping
    static let heightBuffer: CGFloat = 4.0

    static func font(for style: TextStyle) -> PlatformFont {
        let size = max(style.fontSize.cg, 1)

        if style.fontName == TextStyle.systemFontName {
            return PlatformFont.systemFont(ofSize: size)
        }

        #if os(macOS)
        // macOS: try family lookup first
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
        #else
        // iOS: UIFont can't reliably resolve "family" the same way; try name, else system
        if let font = UIFont(name: style.fontName, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size)
        #endif
    }

    static func scaledFont(for style: TextStyle, zoom: CGFloat) -> PlatformFont {
        let base = font(for: style)
        let scale = max(zoom, 0.001)
        let size = max(base.pointSize * scale, 1)
        return base.withSize(size)
    }

    static func scaledInsets(for zoom: CGFloat) -> CGSize {
        let scale = max(zoom, 0.001)
        return CGSize(width: textInsets.width * scale, height: textInsets.height * scale)
    }

    static func height(for text: String, maxWidth: CGFloat, font: PlatformFont) -> CGFloat {
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
            with: CGSize(width: availableWidth,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        let lineHeight = font.ascender - font.descender + font.leading
        let height = ceil(max(bounding.height, lineHeight) + textInsets.height * 2 + heightBuffer)
        return max(height, 1)
    }

    static func height(for text: String, maxWidth: CGFloat) -> CGFloat {
        let font = PlatformFont.systemFont(ofSize: defaultFontSize)
        return height(for: text, maxWidth: maxWidth, font: font)
    }

    static func contentSize(for text: String, font: PlatformFont) -> CGSize {
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
            with: CGSize(width: maxMeasurementWidth,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        let measuredWidth = bounding.width.isFinite ? bounding.width : 0
        let width = ceil(min(measuredWidth, maxMeasurementWidth) + textInsets.width * 2)
        let lineHeight = font.ascender - font.descender + font.leading
        let measuredHeight = bounding.height.isFinite ? bounding.height : 0
        let height = ceil(max(measuredHeight, lineHeight) + textInsets.height * 2 + heightBuffer)

        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    static func contentSize(for text: String) -> CGSize {
        let font = PlatformFont.systemFont(ofSize: defaultFontSize)
        return contentSize(for: text, font: font)
    }
}
