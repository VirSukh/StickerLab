import CoreImage
import UIKit

/// Finishes inspired by printed stickers: holographic foil, glitter, halftone screens.
enum StickerEffect: String, CaseIterable, Identifiable {
    case none, holographic, glitter, halftone, halftoneColor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nessuno"
        case .holographic: return "Olografico"
        case .glitter: return "Glitter"
        case .halftone: return "Retino B/N"
        case .halftoneColor: return "Retino colore"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .holographic: return "rainbow"
        case .glitter: return "sparkles"
        case .halftone: return "circle.grid.3x3.fill"
        case .halftoneColor: return "circle.hexagongrid.fill"
        }
    }

    /// Effects that can shimmer over time.
    var canShimmer: Bool { self == .holographic || self == .glitter }
    /// Applied to the picture only (text and drawings stay crisp).
    var isHalftone: Bool { self == .halftone || self == .halftoneColor }
}

enum StickerEffects {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Halftone

    static func halftone(_ image: CGImage, color: Bool, dotSize: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let flat = input.composited(over: CIImage(color: .white).cropped(to: extent))
        let screened: CIImage
        if color {
            screened = flat.applyingFilter("CICMYKHalftone", parameters: [
                kCIInputWidthKey: dotSize,
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputSharpnessKey: 0.75,
                "inputGCR": 1.0,
                "inputUCR": 0.5,
            ])
        } else {
            screened = flat
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15])
                .applyingFilter("CIDotScreen", parameters: [
                    kCIInputWidthKey: dotSize,
                    kCIInputAngleKey: 0.5,
                    kCIInputSharpnessKey: 0.8,
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                ])
        }
        let masked = screened.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: input,
        ])
        return context.createCGImage(masked, from: extent)
    }

    // MARK: Holographic

    private static var holoCache: [String: CGImage] = [:]
    private static let cacheLock = NSLock()

    /// Pastel rainbow foil texture; `phase` (0…1) slides the colors for the shimmer.
    private static func holoTexture(size: Int, phase: Double) -> CGImage? {
        let bucket = Int((phase.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 32)
        let key = "holo-\(size)-\(bucket)"
        cacheLock.lock()
        if let cached = holoCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let side = CGFloat(size)
        guard let ctx = ImageUtils.makeContext(width: size, height: size) else { return nil }
        let pastel: [UIColor] = [
            UIColor(red: 1.00, green: 0.62, blue: 0.86, alpha: 1),
            UIColor(red: 0.70, green: 0.64, blue: 1.00, alpha: 1),
            UIColor(red: 0.55, green: 0.92, blue: 1.00, alpha: 1),
            UIColor(red: 0.62, green: 1.00, blue: 0.78, alpha: 1),
            UIColor(red: 1.00, green: 0.97, blue: 0.62, alpha: 1),
            UIColor(red: 1.00, green: 0.74, blue: 0.62, alpha: 1),
        ]
        // Two full cycles so the gradient can slide and still cover the canvas.
        let colors = (pastel + pastel + [pastel[0]]).map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: ImageUtils.sRGB, colors: colors, locations: nil) else { return nil }
        let shift = CGFloat(Double(bucket) / 32) * side
        let start = CGPoint(x: -side + shift, y: -side * 0.4 + shift * 0.4)
        let end = CGPoint(x: side + shift, y: side * 1.4 + shift * 0.4)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Soft color blobs for a less regular foil.
        for (index, color) in pastel.enumerated() {
            let angle = Double(index) * 1.7 + Double(bucket) / 32 * .pi * 2
            let center = CGPoint(x: side * (0.5 + 0.35 * cos(angle)), y: side * (0.5 + 0.35 * sin(angle * 1.3)))
            let blob = CGGradient(colorsSpace: ImageUtils.sRGB, colors: [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(blob, startCenter: center, startRadius: 0, endCenter: center, endRadius: side * 0.35, options: [])
        }
        guard let image = ctx.makeImage() else { return nil }
        cacheLock.lock()
        if holoCache.count > 200 { holoCache.removeAll() }
        holoCache[key] = image
        cacheLock.unlock()
        return image
    }

    /// Light band sweeping across (the shine of a foil sticker).
    private static func sheen(size: Int, phase: Double) -> CIImage {
        let side = CGFloat(size)
        let p = CGFloat(phase.truncatingRemainder(dividingBy: 1))
        return bandImage(size: size, center: -side * 0.5 + p * side * 2)
    }

    private static func bandImage(size: Int, center: CGFloat) -> CIImage {
        let side = CGFloat(size)
        guard let ctx = ImageUtils.makeContext(width: size, height: size) else { return CIImage.empty() }
        let colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: ImageUtils.sRGB, colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: center - side * 0.15, y: side - (center - side * 0.15)),
            end: CGPoint(x: center + side * 0.15, y: side - (center + side * 0.15)),
            options: []
        )
        return ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    static func holographic(_ image: CGImage, intensity: Double, phase: Double) -> CGImage? {
        guard let texture = holoTexture(size: image.width, phase: phase) else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let metal = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.55, kCIInputBrightnessKey: 0.06, kCIInputContrastKey: 1.05,
        ])
        let foil = CIImage(cgImage: texture).applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: metal])
        let shined = sheen(size: image.width, phase: phase).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: foil])
        let mixed = input.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: shined, kCIInputTimeKey: min(max(intensity, 0), 1),
        ])
        let masked = mixed.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: input,
        ])
        return context.createCGImage(masked, from: extent)
    }

    // MARK: Glitter

    /// Deterministic sparkles; `phase` makes them twinkle.
    private static func glitterLayer(size: Int, phase: Double, intensity: Double) -> CGImage? {
        let side = CGFloat(size)
        guard let ctx = ImageUtils.makeContext(width: size, height: size) else { return nil }
        let palette: [UIColor] = [.white, UIColor(red: 1, green: 0.6, blue: 0.9, alpha: 1), UIColor(red: 0.55, green: 0.95, blue: 1, alpha: 1), UIColor(red: 1, green: 0.9, blue: 0.5, alpha: 1), UIColor(red: 0.75, green: 0.65, blue: 1, alpha: 1)]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let k = side / 512
        let dots = Int(1400 * intensity) + 300
        for _ in 0..<dots {
            let x = random() * side, y = random() * side
            let radius = (0.6 + random() * 1.6) * k
            let offset = random()
            let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin((phase + offset) * 2 * .pi))
            let color = palette[Int(random() * Double(palette.count)) % palette.count]
            ctx.setFillColor(color.withAlphaComponent(twinkle).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        // Four-point stars
        let stars = Int(14 * intensity) + 4
        for _ in 0..<stars {
            let x = random() * side, y = random() * side
            let length = (6 + random() * 12) * k
            let offset = random()
            let twinkle = 0.5 + 0.5 * sin((phase + offset) * 2 * .pi)
            let color = palette[Int(random() * Double(palette.count)) % palette.count]
            ctx.setFillColor(color.withAlphaComponent(twinkle).cgColor)
            let thin = length * 0.18
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: y + length))
            path.addLine(to: CGPoint(x: x + thin, y: y + thin))
            path.addLine(to: CGPoint(x: x + length, y: y))
            path.addLine(to: CGPoint(x: x + thin, y: y - thin))
            path.addLine(to: CGPoint(x: x, y: y - length))
            path.addLine(to: CGPoint(x: x - thin, y: y - thin))
            path.addLine(to: CGPoint(x: x - length, y: y))
            path.addLine(to: CGPoint(x: x - thin, y: y + thin))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    static func glitter(_ image: CGImage, intensity: Double, phase: Double) -> CGImage? {
        // A light foil tint under the sparkles.
        let base = holographic(image, intensity: 0.35 * intensity, phase: phase) ?? image
        guard let sparkles = glitterLayer(size: image.width, phase: phase, intensity: intensity) else { return base }
        let input = CIImage(cgImage: base)
        let extent = input.extent
        let lit = CIImage(cgImage: sparkles).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: input])
        let masked = lit.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: CIImage(cgImage: image),
        ])
        return context.createCGImage(masked, from: extent)
    }

    // MARK: Shadow

    /// Soft drop shadow (like a sticker lying on paper).
    static func shadow(_ image: CGImage, k: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let silhouette = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.42),
            "inputBiasVector": CIVector(x: 0.1, y: 0.1, z: 0.12, w: 0),
        ])
        let soft = silhouette
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3 * k])
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: 5 * k, y: -8 * k))
        let result = input.composited(over: soft).cropped(to: extent)
        return context.createCGImage(result, from: extent)
    }
}
