import AVFoundation
import CoreVideo
import Photos
import UIKit

/// Builds a square MP4 (picture + sound) for WhatsApp's "sticker with sound" creator.
enum SoundStickerExporter {
    static let side = 512
    static let fps = 15.0
    static let maxDuration = 10.0

    static func export(media: DecodedMedia, audioFile: URL, audioStart: Double = 0, duration: Double, background: UIColor) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sound-stickers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let silentVideo = folder.appendingPathComponent("\(UUID().uuidString)-video.mp4")
        let output = folder.appendingPathComponent("StickerLab-\(Int(Date().timeIntervalSince1970)).mp4")
        defer { try? FileManager.default.removeItem(at: silentVideo) }

        let length = min(max(duration, 0.5), maxDuration)
        try await writeVideo(media: media, duration: length, background: background, to: silentVideo)
        try await mux(video: silentVideo, audio: audioFile, audioStart: audioStart, duration: length, to: output)
        return output
    }

    // MARK: Video frames

    private static func writeVideo(media: DecodedMedia, duration: Double, background: UIColor, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        guard writer.canAdd(input) else { throw AppError("Impossibile creare il video.") }
        writer.add(input)
        guard writer.startWriting() else { throw AppError("Impossibile creare il video: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)

        // Each distinct frame is rendered once and reused.
        var cache: [Int: CVPixelBuffer] = [:]
        let total = max(1, Int(ceil(duration * fps)))
        for index in 0..<total {
            let frameIndex = media.frameIndex(at: Double(index) / fps)
            let buffer: CVPixelBuffer
            if let cached = cache[frameIndex] {
                buffer = cached
            } else {
                guard let made = pixelBuffer(for: media.frames[frameIndex], background: background) else { continue }
                cache[frameIndex] = made
                buffer = made
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw AppError("Creazione del video non riuscita: \(writer.error?.localizedDescription ?? "")")
        }
    }

    private static func pixelBuffer(for frame: CGImage, background: UIColor) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: ImageUtils.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(background.cgColor)
        context.fill(rect)
        if let sticker = StickerRenderer.render(frame, EditSettings()) {
            context.draw(sticker, in: rect)
        }
        return buffer
    }

    // MARK: Audio

    private static func mux(video: URL, audio: URL, audioStart: Double, duration: Double, to output: URL) async throws {
        let composition = AVMutableComposition()
        let length = CMTime(seconds: duration, preferredTimescale: 600)

        let videoAsset = AVURLAsset(url: video)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("Video non valido.")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try videoOut.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(length, videoDuration)), of: videoTrack, at: .zero)

        let audioAsset = AVURLAsset(url: audio)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let start = CMTimeMinimum(CMTime(seconds: max(0, audioStart), preferredTimescale: 600), audioDuration)
            let available = CMTimeSubtract(audioDuration, start)
            try audioOut.insertTimeRange(CMTimeRange(start: start, duration: CMTimeMinimum(length, available)), of: audioTrack, at: .zero)
        } else {
            throw AppError("Il file audio non è leggibile.")
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError("Esportazione non disponibile.")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw AppError("Esportazione non riuscita: \(session.error?.localizedDescription ?? "")")
        }
    }

    // MARK: Photos

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AppError("Permesso negato: consenti l'accesso a Foto in Impostazioni → StickerLab.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func audioDuration(_ url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }
}
