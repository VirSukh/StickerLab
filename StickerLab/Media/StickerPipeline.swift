import CoreGraphics
import Foundation
import Vision
import CoreImage

enum StickerPipeline {
    /// Seconds taken from a video when importing without the editor.
    static let defaultVideoSeconds = 3.0

    static func makeSticker(from media: DecodedMedia, settings: EditSettings, animated: Bool) throws -> Data {
        var source = media
        if source.isAnimated, settings.trimEnd > 0 {
            source = source.trimmed(start: settings.trimStart, end: settings.trimEnd)
        }
        if animated {
            return try StickerEncoder.encodeAnimated(source) { StickerRenderer.render($0, settings) }
        }
        let frameIndex = source.isAnimated ? source.frameIndex(at: 0) : 0
        guard let rendered = StickerRenderer.render(source.frames[frameIndex], settings) else {
            throw AppError("Rendering non riuscito.")
        }
        return try StickerEncoder.encodeStatic(rendered)
    }

    static func loadDefault(_ item: ImportItem) async throws -> DecodedMedia {
        let url = item.fileURL
        if MediaDecoder.sniff(url) == .video {
            let duration = try await MediaDecoder.videoDuration(url)
            return try await MediaDecoder.decodeVideo(url, start: 0, end: min(duration, defaultVideoSeconds))
        }
        return try await Task.detached(priority: .userInitiated) {
            try MediaDecoder.decodeImage(at: url)
        }.value
    }

    /// Import without the editor (batch): default framing, no text.
    static func makeDefaultSticker(from item: ImportItem, animated: Bool) async throws -> Data {
        let media = try await loadDefault(item)
        return try await Task.detached(priority: .userInitiated) {
            try makeSticker(from: media, settings: EditSettings(), animated: animated)
        }.value
    }

    /// 96×96 PNG (≤ 50 KB) from the first frame of a sticker.
    static func trayPNG(fromWebP data: Data) -> Data? {
        guard let media = WebPCodec.decode(data, maxFrames: 1),
              let frame = media.frames.first,
              let tray = ImageUtils.fittedSquare(frame, side: 96) else { return nil }
        return ImageUtils.pngData(tray)
    }
}

@available(iOS 17.0, *)
enum BackgroundRemover {
    /// Cuts out the foreground subjects of every frame. Returns nil if no subject is found.
    static func apply(to media: DecodedMedia) -> DecodedMedia? {
        var frames: [CGImage] = []
        let context = CIContext()
        for frame in media.frames {
            guard let cut = removeBackground(frame, context: context) else {
                if frames.isEmpty { return nil }
                frames.append(frames[frames.count - 1])
                continue
            }
            frames.append(cut)
        }
        return DecodedMedia(frames: frames, durations: media.durations)
    }

    static func removeBackground(_ image: CGImage, context: CIContext) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(ciImage, from: ciImage.extent)
        } catch {
            return nil
        }
    }
}
