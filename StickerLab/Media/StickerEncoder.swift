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
            var data = try encode(candidate, quality: quality)
            // The encoder merges identical frames: a still image would end up with a single
            // frame, and WhatsApp rejects non-animated stickers in animated packs.
            if (WebPCodec.inspect(data)?.frameCount ?? 0) < 2 {
                data = try encode(stillAnimation(candidate.frames[0], total: candidate.totalDuration), quality: quality)
            }
            if data.count <= animatedLimit { return data }
            // Far over the limit: skip an attempt to save time.
            index += Double(data.count) / Double(animatedLimit) > 1.8 ? 2 : 1
        }
        throw AppError("L'animazione è troppo pesante anche alla qualità minima: accorcia la durata.")
    }

    /// Encodes with WhatsApp timing rules: every frame ≥ 8 ms, total ≤ 10 s.
    private static func encode(_ media: DecodedMedia, quality: Float) throws -> Data {
        var durationsMs = media.durations.map { max(20, Int(($0 * 1000).rounded())) }
        var excess = durationsMs.reduce(0, +) - Int(maxDuration * 1000)
        var index = durationsMs.count - 1
        while excess > 0 && index >= 0 {
            let cut = min(excess, durationsMs[index] - 20)
            durationsMs[index] -= cut
            excess -= cut
            index -= 1
        }
        guard let data = WebPCodec.encodeAnimated(
            frames: media.frames, durationsMs: durationsMs, quality: quality, width: side, height: side
        ) else {
            throw AppError("Codifica WebP animata non riuscita.")
        }
        return data
    }

    /// Two frames that differ by a 1-pixel shift, so the encoder cannot merge them.
    private static func stillAnimation(_ frame: CGImage, total: Double) -> DecodedMedia {
        let half = max(0.5, min(total, maxDuration) / 2)
        guard let context = ImageUtils.makeContext(width: side, height: side) else {
            return DecodedMedia(frames: [frame, frame], durations: [half, half])
        }
        context.draw(frame, in: CGRect(x: 0, y: 1, width: side, height: side))
        let shifted = context.makeImage() ?? frame
        return DecodedMedia(frames: [frame, shifted], durations: [half, half])
    }
}
