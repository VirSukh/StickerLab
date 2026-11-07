import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

enum FileKind {
    case gif, webp, png, jpeg, heic, avif, video, unknown

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .webp: return "webp"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        case .video: return "mp4"
        case .unknown: return "bin"
        }
    }
}

enum MediaDecoder {
    /// Frames are decoded at most at this size: stickers are 512×512.
    static let maxPixel = 512
    /// Memory guard for long GIFs.
    static let maxFrames = 200

    /// Detects the real file type from its first bytes (links often lie about extensions).
    static func sniff(_ url: URL) -> FileKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32) else { return .unknown }
        return sniff(data: data)
    }

    static func sniff(data: Data) -> FileKind {
        let b = [UInt8](data.prefix(32))
        guard b.count >= 12 else { return .unknown }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return .gif }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return .png }
        if b[0] == 0xFF && b[1] == 0xD8 { return .jpeg }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return .webp }
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
            if ["avif", "avis"].contains(brand) { return .avif }
            return .video
        }
        return .unknown
    }

    // MARK: Images (static and animated)

    static func decodeImage(at url: URL) throws -> DecodedMedia {
        let kind = sniff(url)
        if kind == .webp {
            let data = try Data(contentsOf: url)
            guard let media = WebPCodec.decode(data, maxFrames: maxFrames) else {
                throw AppError("File WebP non valido.")
            }
            return media.downscaled(maxPixel: maxPixel)
        }
        if kind == .video { throw AppError("Questo è un video.") }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AppError("Formato non supportato.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw AppError("Immagine vuota o danneggiata.") }

        let step = max(1, Int(ceil(Double(count) / Double(maxFrames))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = []
        var durations: [Double] = []
        var index = 0
        while index < count {
            var duration = 0.0
            for j in index..<min(index + step, count) { duration += frameDelay(source, j) }
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                frames.append(image)
                durations.append(duration)
            }
            index += step
        }
        guard !frames.isEmpty else { throw AppError("Impossibile leggere l'immagine.") }
        return DecodedMedia(frames: frames, durations: durations)
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictKey, unclampedKey, clampedKey) in keys {
            if let dict = props[dictKey] as? [CFString: Any] {
                let value = (dict[unclampedKey] as? Double) ?? (dict[clampedKey] as? Double) ?? 0.1
                return value < 0.02 ? 0.1 : value
            }
        }
        return 0.1
    }

    // MARK: Video

    static func videoDuration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw AppError("Video non leggibile.") }
        return seconds
    }

    static func decodeVideo(_ url: URL, start: Double, end: Double, fps: Double = 12) async throws -> DecodedMedia {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = 1.0 / fps
        var frames: [CGImage] = []
        var t = max(0, start)
        let stop = max(end, t + step)
        while t < stop - 0.001 && frames.count < maxFrames {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append(result.image)
            }
            t += step
        }
        guard !frames.isEmpty else { throw AppError("Impossibile estrarre fotogrammi dal video.") }
        return DecodedMedia(frames: frames, durations: Array(repeating: step, count: frames.count))
    }
}
