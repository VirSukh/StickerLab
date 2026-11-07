import Foundation

struct Sticker: Codable, Identifiable, Hashable {
    var id = UUID()
    /// WebP file name inside the pack folder.
    var fileName: String
    var emojis: [String] = ["😀"]
    var animated: Bool
    var sourceURL: String?
}

struct StickerPack: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var publisher: String
    var animated: Bool
    var stickers: [Sticker] = []
    /// 96×96 PNG inside the pack folder.
    var trayFileName: String?
    var createdAt = Date()
    var updatedAt = Date()

    static let maxStickers = 30
    static let minStickers = 3

    var whatsAppIdentifier: String { id.uuidString }
    var isFull: Bool { stickers.count >= Self.maxStickers }
}
