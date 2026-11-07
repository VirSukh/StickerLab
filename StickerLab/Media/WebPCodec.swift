import CoreGraphics
import Foundation
import libwebp

/// Thin wrapper around libwebp: iOS can decode WebP but cannot encode it.
enum WebPCodec {
    // MARK: Encoding

    static func encodeStatic(_ image: CGImage, quality: Float) -> Data? {
        let width = image.width, height = image.height
        let rgba = ImageUtils.rgbaBytes(image, width: width, height: height)
        var output: UnsafeMutablePointer<UInt8>?
        let size = rgba.withUnsafeBufferPointer { buffer -> Int in
            WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(width * 4), quality, &output)
        }
        guard size > 0, let output else { return nil }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    /// All frames must already be `width`×`height`. Durations are in milliseconds.
    static func encodeAnimated(frames: [CGImage], durationsMs: [Int], quality: Float, width: Int, height: Int) -> Data? {
        guard !frames.isEmpty, frames.count == durationsMs.count else { return nil }

        var animOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&animOptions) != 0 else { return nil }
        animOptions.anim_params.loop_count = 0
        animOptions.allow_mixed = 0

        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &animOptions) else { return nil }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        config.quality = quality
        config.method = 4
        config.lossless = 0
        config.alpha_quality = 90

        var timestamp: Int32 = 0
        for (index, frame) in frames.enumerated() {
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else { return nil }
            picture.width = Int32(width)
            picture.height = Int32(height)
            picture.use_argb = 1
            let rgba = ImageUtils.rgbaBytes(frame, width: width, height: height)
            let imported = rgba.withUnsafeBufferPointer { buffer in
                WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(width * 4))
            }
            guard imported != 0 else {
                WebPPictureFree(&picture)
                return nil
            }
            let added = WebPAnimEncoderAdd(encoder, &picture, timestamp, &config)
            WebPPictureFree(&picture)
            guard added != 0 else { return nil }
            timestamp += Int32(durationsMs[index])
        }
        // Final call marks the end of the last frame.
        guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else { return nil }

        var webpData = WebPData()
        WebPDataInit(&webpData)
        guard WebPAnimEncoderAssemble(encoder, &webpData) != 0, let bytes = webpData.bytes else { return nil }
        defer { WebPDataClear(&webpData) }
        return Data(bytes: bytes, count: webpData.size)
    }

    // MARK: Decoding

    static func decode(_ data: Data, maxFrames: Int = 400) -> DecodedMedia? {
        data.withUnsafeBytes { raw -> DecodedMedia? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var webpData = WebPData(bytes: base, size: data.count)

            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else { return nil }
            options.color_mode = MODE_RGBA
            options.use_threads = 1

            guard let decoder = WebPAnimDecoderNew(&webpData, &options) else { return nil }
            defer { WebPAnimDecoderDelete(decoder) }

            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else { return nil }
            let width = Int(info.canvas_width), height = Int(info.canvas_height)
            guard width > 0, height > 0 else { return nil }

            var frames: [CGImage] = []
            var durations: [Double] = []
            var previous: Int32 = 0
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 && frames.count < maxFrames {
                var buffer: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &buffer, &timestamp) != 0, let buffer else { break }
                if let image = ImageUtils.image(rgba: buffer, width: width, height: height) {
                    frames.append(image)
                    let duration = Double(timestamp - previous) / 1000
                    durations.append(duration < 0.02 ? 0.1 : duration)
                }
                previous = timestamp
            }
            guard !frames.isEmpty else { return nil }
            return DecodedMedia(frames: frames, durations: durations)
        }
    }

    static func frameCount(_ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var webpData = WebPData(bytes: base, size: data.count)
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0,
                  let decoder = WebPAnimDecoderNew(&webpData, &options) else { return 0 }
            defer { WebPAnimDecoderDelete(decoder) }
            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else { return 0 }
            return Int(info.frame_count)
        }
    }

    struct Info {
        let width: Int
        let height: Int
        let frameCount: Int
        let minFrameMs: Int
        let totalMs: Int
    }

    /// Reads canvas size, frame count and frame timings (for WhatsApp validation).
    static func inspect(_ data: Data) -> Info? {
        data.withUnsafeBytes { raw -> Info? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var webpData = WebPData(bytes: base, size: data.count)
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else { return nil }
            options.color_mode = MODE_RGBA
            guard let decoder = WebPAnimDecoderNew(&webpData, &options) else { return nil }
            defer { WebPAnimDecoderDelete(decoder) }
            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else { return nil }
            let frames = Int(info.frame_count)
            guard frames > 1 else {
                return Info(width: Int(info.canvas_width), height: Int(info.canvas_height), frameCount: frames, minFrameMs: 0, totalMs: 0)
            }
            var previous: Int32 = 0
            var minimum = Int.max
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var buffer: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &buffer, &timestamp) != 0 else { break }
                minimum = min(minimum, Int(timestamp - previous))
                previous = timestamp
            }
            return Info(
                width: Int(info.canvas_width), height: Int(info.canvas_height), frameCount: frames,
                minFrameMs: minimum == Int.max ? 0 : minimum, totalMs: Int(previous)
            )
        }
    }

    static func isAnimated(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return frameCount(data) > 1
    }
}
