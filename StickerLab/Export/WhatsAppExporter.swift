import UIKit

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
