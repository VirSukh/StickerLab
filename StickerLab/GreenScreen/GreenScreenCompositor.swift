import CoreGraphics
import Foundation

struct KeyColor: Equatable {
    var r: Double, g: Double, b: Double   // 0…1

    var cb: Double { -0.168736 * r - 0.331264 * g + 0.5 * b }
    var cr: Double { 0.5 * r - 0.418688 * g - 0.081312 * b }

    enum Dominant { case green, blue, red }
    var dominant: Dominant {
        if g >= r && g >= b { return .green }
        return b >= r ? .blue : .red
    }

    static let green = KeyColor(r: 0, g: 1, b: 0)
}

struct GreenScreenSettings {
    var tolerance: Double = 0.13
    var softness: Double = 0.08
    var backgroundScale: CGFloat = 1
    /// In 512-canvas points.
    var backgroundOffset: CGSize = .zero
    var templateScale: CGFloat = 1
    var templateOffset: CGSize = .zero
}

/// Chroma key (green / blue / red screen) and compositing over a background.
enum GreenScreenCompositor {
    /// Average color of the top and side borders of the first frame (subjects usually touch the bottom).
    static func detectKeyColor(_ image: CGImage) -> KeyColor {
        let w = image.width, h = image.height
        let pixels = ImageUtils.rgbaBytes(image, width: w, height: h)
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        func add(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            guard pixels[i + 3] > 200 else { return }
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
        }
        let band = max(2, h / 40)
        for y in 0..<band { for x in stride(from: 0, to: w, by: 3) { add(x, y) } }
        for y in stride(from: 0, to: h * 3 / 4, by: 3) {
            for x in 0..<band { add(x, y); add(w - 1 - x, y) }
        }
        guard n > 0 else { return .green }
        return KeyColor(r: r / n / 255, g: g / n / 255, b: b / n / 255)
    }

    /// Makes the key color transparent (soft edges) and removes color spill.
    static func key(_ image: CGImage, color: KeyColor, tolerance: Double, softness: Double) -> CGImage? {
        let w = image.width, h = image.height
        var pixels = ImageUtils.rgbaBytes(image, width: w, height: h)
        let kcb = color.cb, kcr = color.cr
        let soft = max(softness, 0.001)
        let dominant = color.dominant
        var i = 0
        let count = pixels.count
        while i < count {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let cb = -0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 0.5 * r - 0.418688 * g - 0.081312 * b
            let distance = ((cb - kcb) * (cb - kcb) + (cr - kcr) * (cr - kcr)).squareRoot()
            let keep = min(max((distance - tolerance) / soft, 0), 1)
            if keep < 1 {
                // Spill suppression on the semi-transparent edge and near-key pixels.
                switch dominant {
                case .green: pixels[i + 1] = min(pixels[i + 1], max(pixels[i], pixels[i + 2]))
                case .blue: pixels[i + 2] = min(pixels[i + 2], max(pixels[i], pixels[i + 1]))
                case .red: pixels[i] = min(pixels[i], max(pixels[i + 1], pixels[i + 2]))
                }
            }
            pixels[i + 3] = UInt8(Double(pixels[i + 3]) * keep)
            i += 4
        }
        return pixels.withUnsafeBufferPointer { buffer in
            ImageUtils.image(rgba: buffer.baseAddress!, width: w, height: h)
        }
    }

    static func key(_ media: DecodedMedia, color: KeyColor, tolerance: Double, softness: Double) -> DecodedMedia {
        DecodedMedia(
            frames: media.frames.map { key($0, color: color, tolerance: tolerance, softness: softness) ?? $0 },
            durations: media.durations
        )
    }

    /// Background (aspect-fill) under the keyed template (aspect-fit), on a square canvas.
    static func compose(template: CGImage, background: CGImage?, settings: GreenScreenSettings, size: Int) -> CGImage? {
        let side = CGFloat(size)
        let k = side / CGFloat(StickerRenderer.canvas)
        guard let context = ImageUtils.makeContext(width: size, height: size) else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))

        func draw(_ image: CGImage, fill: Bool, scale: CGFloat, offset: CGSize) {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let base = fill ? max(side / w, side / h) : min(side / w, side / h)
            let dw = w * base * scale, dh = h * base * scale
            let x = (side - dw) / 2 + offset.width * k
            let y = (side - dh) / 2 - offset.height * k
            context.draw(image, in: CGRect(x: x, y: y, width: dw, height: dh))
        }

        if let background {
            draw(background, fill: true, scale: settings.backgroundScale, offset: settings.backgroundOffset)
        }
        draw(template, fill: false, scale: settings.templateScale, offset: settings.templateOffset)
        return context.makeImage()
    }

    /// Full-size result following the template's timing (background loops if shorter).
    static func composite(template: DecodedMedia, background: DecodedMedia?, settings: GreenScreenSettings) -> DecodedMedia {
        var frames: [CGImage] = []
        var time = 0.0
        for (index, frame) in template.frames.enumerated() {
            let back = background.map { $0.frames[$0.frameIndex(at: time)] }
            frames.append(compose(template: frame, background: back, settings: settings, size: StickerRenderer.canvas) ?? frame)
            time += template.durations[index]
        }
        return DecodedMedia(frames: frames, durations: template.durations)
    }
}
