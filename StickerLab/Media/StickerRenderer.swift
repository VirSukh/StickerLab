import UIKit

enum TextPosition: String, CaseIterable, Identifiable {
    case top, center, bottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .top: return "Sopra"
        case .center: return "Centro"
        case .bottom: return "Sotto"
        }
    }
}

enum TextColorOption: String, CaseIterable, Identifiable {
    case white, black, yellow, red, green, blue, pink
    var id: String { rawValue }
    var fill: UIColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .yellow: return UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
        case .red: return UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1)
        case .green: return UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)
        case .blue: return UIColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        case .pink: return UIColor(red: 1, green: 0.4, blue: 0.75, alpha: 1)
        }
    }
    var stroke: UIColor { self == .black ? .white : .black }
}

struct EditSettings: Equatable {
    var scale: CGFloat = 1
    /// Offset in 512-canvas points (y grows downwards).
    var offset: CGSize = .zero
    /// Degrees.
    var rotation: Double = 0
    /// Aspect-fill instead of aspect-fit.
    var fill = false
    var text = ""
    var textPosition: TextPosition = .bottom
    var textSize: CGFloat = 72
    var textColor: TextColorOption = .white
    /// Trim for animated images (seconds). `trimEnd == 0` means until the end.
    var trimStart: Double = 0
    var trimEnd: Double = 0
}

enum StickerRenderer {
    static let canvas = 512

    /// Renders one frame on a transparent square canvas. `size` < 512 is used for fast previews.
    static func render(_ image: CGImage, _ settings: EditSettings, size: Int = canvas) -> CGImage? {
        let side = CGFloat(size)
        let k = side / CGFloat(canvas)
        guard let context = ImageUtils.makeContext(width: size, height: size) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let base = settings.fill ? max(side / w, side / h) : min(side / w, side / h)
        let drawWidth = w * base * settings.scale
        let drawHeight = h * base * settings.scale

        context.saveGState()
        context.translateBy(x: side / 2 + settings.offset.width * k, y: side / 2 - settings.offset.height * k)
        context.rotate(by: -CGFloat(settings.rotation) * .pi / 180)
        context.draw(image, in: CGRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
        context.restoreGState()

        if !settings.text.trimmed.isEmpty {
            context.saveGState()
            // UIKit text drawing expects a top-left origin.
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            drawText(settings, side: side, k: k)
            UIGraphicsPopContext()
            context.restoreGState()
        }
        return context.makeImage()
    }

    private static func drawText(_ settings: EditSettings, side: CGFloat, k: CGFloat) {
        let font = UIFont.systemFont(ofSize: settings.textSize * k, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let outline = NSAttributedString(string: settings.text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .strokeColor: settings.textColor.stroke,
            .strokeWidth: 18,
        ])
        let fill = NSAttributedString(string: settings.text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: settings.textColor.fill,
        ])

        let margin = 16 * k
        let maxWidth = side - margin * 2
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = fill.boundingRect(with: CGSize(width: maxWidth, height: side), options: options, context: nil)
        let height = ceil(bounds.height)
        let y: CGFloat
        switch settings.textPosition {
        case .top: y = margin
        case .center: y = (side - height) / 2
        case .bottom: y = side - height - margin
        }
        let rect = CGRect(x: margin, y: y, width: maxWidth, height: height)
        outline.draw(with: rect, options: options, context: nil)
        fill.draw(with: rect, options: options, context: nil)
    }
}
