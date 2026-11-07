import CoreGraphics
import Foundation

/// Encodes stickers within WhatsApp limits:
/// 512×512 WebP, static ≤ 100 KB, animated ≤ 500 KB and ≤ 10 s, frames ≥ 8 ms.
enum StickerEncoder {
    static let staticLimit = 100 * 1024
    static let animatedLimit = 500 * 1024
    static let maxDuration = 10.0
    static let side = StickerRenderer.canvas

    static func encodeStatic(_ rendered: CGImage) throws -> Data {
        for quality: Float in [92, 85, 75, 65, 55, 45, 35, 25, 15, 8] {
            if let data = WebPCodec.encodeStatic(rendered, quality: quality), data.count <= staticLimit {
                return data
            }
        }
        throw AppError("Impossibile comprimere lo sticker sotto i 100 KB.")
    }

    static func encodeAnimated(_ media: DecodedMedia, render: (CGImage) -> CGImage?) throws -> Data {
        var source = media.limited(maxDuration: maxDuration)
        if source.frames.count == 1 {
            // A still image inside an animated pack: WhatsApp wants an animation.
            source = DecodedMedia(frames: [source.frames[0], source.frames[0]], durations: [0.5, 0.5])
        }
        source = source.resampled(minFrameDuration: 1.0 / 15)

        var renderedFrames: [CGImage] = []
        var renderedDurations: [Double] = []
        for (index, frame) in source.frames.enumerated() {
            if let image = render(frame) {
                renderedFrames.append(image)
                renderedDurations.append(source.durations[index])
            } else if !renderedDurations.isEmpty {
                renderedDurations[renderedDurations.count - 1] += source.durations[index]
            }
        }
        guard !renderedFrames.isEmpty else { throw AppError("Rendering non riuscito.") }
        if renderedFrames.count == 1 {
            renderedFrames.append(renderedFrames[0])
            renderedDurations = [0.5, 0.5]
        }
        let rendered = DecodedMedia(frames: renderedFrames, durations: renderedDurations)

        // (max fps, quality) attempts, from best to smallest.
        let attempts: [(Double, Float)] = [
            (15, 80), (12, 70), (10, 60), (10, 45), (8, 40), (8, 30), (6, 25), (5, 20), (4, 12),
        ]
        var index = 0
        while index < attempts.count {
            let (fps, quality) = attempts[index]
            var candidate = rendered.resampled(minFrameDuration: 1.0 / fps)
            if candidate.frames.count == 1 {
                candidate = DecodedMedia(frames: [candidate.frames[0], candidate.frames[0]], durations: [0.5, 0.5])
            }
            let durationsMs = candidate.durations.map { max(10, Int(($0 * 1000).rounded())) }
            guard let data = WebPCodec.encodeAnimated(
                frames: candidate.frames, durationsMs: durationsMs, quality: quality, width: side, height: side
            ) else {
                throw AppError("Codifica WebP animata non riuscita.")
            }
            if data.count <= animatedLimit { return data }
            // Far over the limit: skip an attempt to save time.
            index += Double(data.count) / Double(animatedLimit) > 1.8 ? 2 : 1
        }
        throw AppError("L'animazione è troppo pesante anche alla qualità minima: accorcia la durata.")
    }
}
