import UIKit

enum ImageUtils {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeContext(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func resized(_ image: CGImage, maxPixel: Int) -> CGImage {
        let width = image.width, height = image.height
        guard max(width, height) > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(max(width, height))
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        guard let context = makeContext(width: newWidth, height: newHeight) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    /// Draws the image aspect-fit and centered in a transparent square.
    static func fittedSquare(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = makeContext(width: side, height: side) else { return nil }
        context.interpolationQuality = .high
        let s = CGFloat(side)
        let scale = min(s / CGFloat(image.width), s / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        return context.makeImage()
    }

    /// Non-premultiplied RGBA bytes (top row first), as libwebp expects.
    static func rgbaBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = makeContext(width: width, height: height, data: raw.baseAddress) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var i = 0
        let count = buffer.count
        while i < count {
            let alpha = Int(buffer[i + 3])
            if alpha == 0 {
                buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0
            } else if alpha < 255 {
                buffer[i] = UInt8(min(255, Int(buffer[i]) * 255 / alpha))
                buffer[i + 1] = UInt8(min(255, Int(buffer[i + 1]) * 255 / alpha))
                buffer[i + 2] = UInt8(min(255, Int(buffer[i + 2]) * 255 / alpha))
            }
            i += 4
        }
        return buffer
    }

    /// Creates a CGImage from non-premultiplied RGBA bytes (copies them).
    static func image(rgba: UnsafePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        let data = Data(bytes: rgba, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func pngData(_ image: CGImage) -> Data? {
        UIImage(cgImage: image).pngData()
    }
}
