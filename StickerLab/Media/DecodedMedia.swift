import CoreGraphics
import Foundation

/// A decoded image or animation: frames with their durations in seconds.
struct DecodedMedia {
    var frames: [CGImage]
    var durations: [Double]

    var isAnimated: Bool { frames.count > 1 }
    var totalDuration: Double { durations.reduce(0, +) }

    func frameIndex(at time: Double) -> Int {
        guard frames.count > 1 else { return 0 }
        let total = totalDuration
        guard total > 0 else { return 0 }
        var t = time.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        for (index, duration) in durations.enumerated() {
            if t < duration { return index }
            t -= duration
        }
        return frames.count - 1
    }

    /// Keeps only the frames visible between `start` and `end` (seconds).
    func trimmed(start: Double, end: Double) -> DecodedMedia {
        guard isAnimated, end > start else { return self }
        var newFrames: [CGImage] = []
        var newDurations: [Double] = []
        var t = 0.0
        for (index, duration) in durations.enumerated() {
            let frameEnd = t + duration
            if frameEnd > start + 0.0001 && t < end - 0.0001 {
                let visible = min(frameEnd, end) - max(t, start)
                newFrames.append(frames[index])
                newDurations.append(max(0.01, visible))
            }
            t = frameEnd
        }
        if newFrames.isEmpty {
            return DecodedMedia(frames: [frames[frameIndex(at: start)]], durations: [0.1])
        }
        return DecodedMedia(frames: newFrames, durations: newDurations)
    }

    func limited(maxDuration: Double) -> DecodedMedia {
        guard totalDuration > maxDuration else { return self }
        return trimmed(start: 0, end: maxDuration)
    }

    /// Drops frames so that no frame is shorter than `minFrameDuration` (merging their time).
    func resampled(minFrameDuration: Double) -> DecodedMedia {
        guard isAnimated else { return self }
        var newFrames: [CGImage] = []
        var newDurations: [Double] = []
        for (index, duration) in durations.enumerated() {
            if let last = newDurations.last, last < minFrameDuration {
                newDurations[newDurations.count - 1] = last + duration
            } else {
                newFrames.append(frames[index])
                newDurations.append(duration)
            }
        }
        return DecodedMedia(frames: newFrames, durations: newDurations)
    }

    func downscaled(maxPixel: Int) -> DecodedMedia {
        DecodedMedia(frames: frames.map { ImageUtils.resized($0, maxPixel: maxPixel) }, durations: durations)
    }
}
