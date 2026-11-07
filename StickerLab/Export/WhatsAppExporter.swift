import UIKit

struct StickerProblem: Identifiable {
    let id: UUID          // sticker id
    let position: Int     // 1-based
    let reasons: [String]
}

/// Checks each sticker against WhatsApp's official rules (WhatsApp/stickers validator).
enum StickerValidator {
    static func reasons(for data: Data, packAnimated: Bool) -> [String] {
        guard let info = WebPCodec.inspect(data) else { return ["File WebP non leggibile"] }
        var reasons: [String] = []
        if info.width != 512 || info.height != 512 {
            reasons.append("Dimensioni \(info.width)×\(info.height) invece di 512×512")
        }
        if packAnimated {
            if info.frameCount < 2 { reasons.append("Non è animato, ma il pacchetto è animato") }
            if data.count > StickerEncoder.animatedLimit { reasons.append("Pesa \(formatBytes(data.count)), massimo 500 KB") }
            if info.frameCount > 1 && info.minFrameMs < 8 { reasons.append("Fotogrammi troppo brevi (\(info.minFrameMs) ms, minimo 8)") }
            if info.totalMs > 10_000 { reasons.append("Dura \(info.totalMs / 1000) s, massimo 10 s") }
        } else {
            if info.frameCount > 1 { reasons.append("È animato, ma il pacchetto è statico") }
            if data.count > StickerEncoder.staticLimit { reasons.append("Pesa \(formatBytes(data.count)), massimo 100 KB") }
        }
        return reasons
    }

    /// Runs off the main thread: decoding every sticker takes a moment.
    static func check(files: [(UUID, URL)], packAnimated: Bool) async -> [StickerProblem] {
        await Task.detached(priority: .userInitiated) {
            var problems: [StickerProblem] = []
            for (index, file) in files.enumerated() {
                let reasons: [String]
                if let data = try? Data(contentsOf: file.1) {
                    reasons = Self.reasons(for: data, packAnimated: packAnimated)
                } else {
                    reasons = ["File mancante"]
                }
                if !reasons.isEmpty { problems.append(StickerProblem(id: file.0, position: index + 1, reasons: reasons)) }
            }
            return problems
        }.value
    }

    /// Re-encodes a sticker so it follows the rules of its pack.
    static func repair(_ data: Data, packAnimated: Bool) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let media = WebPCodec.decode(data) else { throw AppError("Sticker illeggibile: eliminalo e reimportalo.") }
            return try StickerPipeline.makeSticker(from: media, settings: EditSettings(), animated: packAnimated)
        }.value
    }
}

/// Sends a pack to WhatsApp using the official iOS mechanism:
/// JSON on the pasteboard + opening `whatsapp://stickerPack`.
enum WhatsAppExporter {
    static let pasteboardType = "net.whatsapp.third-party.sticker-pack"

    static var isWhatsAppInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "whatsapp://")!)
    }

    @MainActor
    static func problems(for pack: StickerPack, store: PackStore) -> [String] {
        var problems: [String] = []
        if pack.stickers.count < StickerPack.minStickers {
            problems.append("Servono almeno \(StickerPack.minStickers) sticker (ora \(pack.stickers.count)).")
        }
        if pack.stickers.count > StickerPack.maxStickers {
            problems.append("Massimo \(StickerPack.maxStickers) sticker per pacchetto.")
        }
        if pack.name.trimmed.isEmpty { problems.append("Il pacchetto non ha un nome.") }
        if pack.publisher.trimmed.isEmpty { problems.append("Manca l'autore.") }
        if pack.stickers.contains(where: { $0.animated != pack.animated }) {
            problems.append("Alcuni sticker non sono del tipo del pacchetto (statico/animato).")
        }
        if !pack.stickers.isEmpty && store.trayURL(for: pack) == nil {
            problems.append("Icona del pacchetto mancante: imposta uno sticker come icona.")
        }
        return problems
    }

    @MainActor
    static func send(_ pack: StickerPack, store: PackStore) throws {
        guard isWhatsAppInstalled else { throw AppError("WhatsApp non risulta installato su questo iPhone.") }
        guard let trayURL = store.trayURL(for: pack), let tray = try? Data(contentsOf: trayURL) else {
            throw AppError("Icona del pacchetto mancante.")
        }
        let limit = pack.animated ? StickerEncoder.animatedLimit : StickerEncoder.staticLimit
        var stickers: [[String: Any]] = []
        for sticker in pack.stickers {
            let data = try Data(contentsOf: store.fileURL(for: sticker, in: pack))
            guard data.count <= limit else {
                throw AppError("Uno sticker supera il limite di \(formatBytes(limit)).")
            }
            stickers.append([
                "image_data": data.base64EncodedString(),
                "emojis": sticker.emojis.isEmpty ? ["😀"] : sticker.emojis,
            ])
        }
        let json: [String: Any] = [
            "identifier": pack.whatsAppIdentifier,
            "name": pack.name,
            "publisher": pack.publisher,
            "tray_image": tray.base64EncodedString(),
            "animated_sticker_pack": pack.animated,
            "ios_app_store_link": "",
            "android_play_store_link": "",
            "stickers": stickers,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        UIPasteboard.general.setItems(
            [[pasteboardType: data]],
            options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 60)]
        )
        UIApplication.shared.open(URL(string: "whatsapp://stickerPack")!)
    }
}
