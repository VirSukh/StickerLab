import CoreImage
import CoreText
import UIKit

// MARK: - Fonts

/// Fonts bundled in Resources/Fonts (open licenses: OFL / Apache) plus system styles.
enum StickerFont: String, CaseIterable, Identifiable {
    case meme, comic, marker, bubbly, systemHeavy, rounded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meme: return "Meme"
        case .comic: return "Fumetto"
        case .marker: return "Pennarello"
        case .bubbly: return "Bolla"
        case .systemHeavy: return "Classico"
        case .rounded: return "Tondo"
        }
    }

    private var fileName: String? {
        switch self {
        case .meme: return "Anton-Regular"
        case .comic: return "Bangers-Regular"
        case .marker: return "PermanentMarker-Regular"
        case .bubbly: return "LuckiestGuy-Regular"
        default: return nil
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        if let fileName, let name = FontRegistry.postScriptName(forFile: fileName),
           let font = UIFont(name: name, size: size) {
            return font
        }
        switch self {
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: .black)
            if let descriptor = base.fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return base
        default:
            return UIFont.systemFont(ofSize: size, weight: .heavy)
        }
    }
}

/// Registers the bundled fonts at runtime (no Info.plist list needed).
enum FontRegistry {
    private static let names: [String: String] = {
        var result: [String: String] = [:]
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            guard let provider = CGDataProvider(url: url as CFURL),
                  let font = CGFont(provider),
                  let name = font.postScriptName as String? else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
            result[url.deletingPathExtension().lastPathComponent] = name
        }
        return result
    }()

    static func postScriptName(forFile file: String) -> String? { names[file] }
    static func registerAll() { _ = names }
}

// MARK: - Options

enum TextColorOption: String, CaseIterable, Identifiable {
    case white, black, yellow, red, green, blue, pink, purple
    var id: String { rawValue }
    var color: UIColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .yellow: return UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
        case .red: return UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1)
        case .green: return UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)
        case .blue: return UIColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        case .pink: return UIColor(red: 1, green: 0.4, blue: 0.75, alpha: 1)
        case .purple: return UIColor(red: 0.6, green: 0.35, blue: 1, alpha: 1)
        }
    }
}

struct TextLayer: Identifiable {
    var id = UUID()
    var text = ""
    var font: StickerFont = .meme
    var size: CGFloat = 70
    var color: TextColorOption = .white
    var strokeColor: TextColorOption = .black
    /// Outline thickness, in % of the font size (0 = none).
    var strokeWidth: CGFloat = 14
    var uppercase = true
    /// Center of the text, normalized 0…1 on the 512 canvas.
    var center = CGPoint(x: 0.5, y: 0.85)
    /// Degrees.
    var rotation: Double = 0

    var displayText: String { uppercase ? text.uppercased() : text }

    static func memeTop() -> TextLayer { TextLayer(center: CGPoint(x: 0.5, y: 0.12)) }
    static func memeBottom() -> TextLayer { TextLayer(center: CGPoint(x: 0.5, y: 0.88)) }
}

struct EditSettings {
    var scale: CGFloat = 1
    /// Offset in 512-canvas points (y grows downwards).
    var offset: CGSize = .zero
    /// Degrees.
    var rotation: Double = 0
    /// Aspect-fill instead of aspect-fit.
    var fill = false
    var flipped = false
    var textLayers: [TextLayer] = []
    /// Hand drawing, already rendered at 512×512 (transparent).
    var drawing: CGImage?
    /// Sticker outline around everything (WhatsApp style).
    var outline = false
    var outlineWidth: CGFloat = 10
    var outlineColor: TextColorOption = .white
    /// Trim for animated images (seconds). `trimEnd == 0` means until the end.
    var trimStart: Double = 0
    var trimEnd: Double = 0
}

// MARK: - Renderer

enum StickerRenderer {
    static let canvas = 512
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders one frame on a transparent square canvas. `size` < 512 is used for fast previews.
    static func render(_ image: CGImage, _ settings: EditSettings, size: Int = canvas) -> CGImage? {
        let side = CGFloat(size)
        let k = side / CGFloat(canvas)
        guard let context = ImageUtils.makeContext(width: size, height: size) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high

        // Image
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let base = settings.fill ? max(side / w, side / h) : min(side / w, side / h)
        let drawWidth = w * base * settings.scale
        let drawHeight = h * base * settings.scale
        context.saveGState()
        context.translateBy(x: side / 2 + settings.offset.width * k, y: side / 2 - settings.offset.height * k)
        context.rotate(by: -CGFloat(settings.rotation) * .pi / 180)
        if settings.flipped { context.scaleBy(x: -1, y: 1) }
        context.draw(image, in: CGRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
        context.restoreGState()

        // Drawing
        if let drawing = settings.drawing {
            context.draw(drawing, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        // Text (UIKit drawing expects a top-left origin)
        let layers = settings.textLayers.filter { !$0.text.trimmed.isEmpty }
        if !layers.isEmpty {
            context.saveGState()
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            for layer in layers { draw(layer, side: side, k: k, in: context) }
            UIGraphicsPopContext()
            context.restoreGState()
        }

        guard let composed = context.makeImage() else { return nil }
        if settings.outline, settings.outlineWidth > 0 {
            return addOutline(composed, radius: settings.outlineWidth * k, color: settings.outlineColor.color) ?? composed
        }
        return composed
    }

    // MARK: Text

    private static func attributed(_ layer: TextLayer, k: CGFloat) -> (fill: NSAttributedString, outline: NSAttributedString) {
        let font = layer.font.uiFont(size: layer.size * k)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95
        let text = layer.displayText
        let fill = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: layer.color.color,
        ])
        let outline = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph,
            .strokeColor: layer.strokeColor.color, .strokeWidth: layer.strokeWidth,
        ])
        return (fill, outline)
    }

    /// Text box in 512-canvas coordinates (top-left origin), used for hit-testing drags.
    static func textRect(_ layer: TextLayer) -> CGRect {
        let side = CGFloat(canvas)
        let maxWidth = side - 24
        let (fill, _) = attributed(layer, k: 1)
        let bounds = fill.boundingRect(
            with: CGSize(width: maxWidth, height: side * 2),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        let width = min(maxWidth, ceil(bounds.width)), height = ceil(bounds.height)
        return CGRect(x: layer.center.x * side - width / 2, y: layer.center.y * side - height / 2, width: width, height: height)
    }

    private static func draw(_ layer: TextLayer, side: CGFloat, k: CGFloat, in context: CGContext) {
        let (fill, outline) = attributed(layer, k: k)
        let maxWidth = side - 24 * k
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = fill.boundingRect(with: CGSize(width: maxWidth, height: side * 2), options: options, context: nil)
        let height = ceil(bounds.height)
        let rect = CGRect(x: -maxWidth / 2, y: -height / 2, width: maxWidth, height: height)

        context.saveGState()
        context.translateBy(x: layer.center.x * side, y: layer.center.y * side)
        context.rotate(by: CGFloat(layer.rotation) * .pi / 180)
        if layer.strokeWidth > 0 { outline.draw(with: rect, options: options, context: nil) }
        fill.draw(with: rect, options: options, context: nil)
        context.restoreGState()
    }

    // MARK: Outline

    /// Solid outline around all visible pixels (dilated silhouette under the image).
    static func addOutline(_ image: CGImage, radius: CGFloat, color: UIColor) -> CGImage? {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let input = CIImage(cgImage: image)
        let silhouette = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: r, y: g, z: b, w: 0),
        ])
        let dilated = silhouette
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, radius)])
        let result = input.composited(over: dilated).cropped(to: input.extent)
        return ciContext.createCGImage(result, from: input.extent)
    }
}
