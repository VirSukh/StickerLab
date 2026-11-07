import Foundation

/// Keeps packs in Documents/packs.json and their files in Documents/Packs/<pack id>/.
@MainActor
final class PackStore: ObservableObject {
    @Published private(set) var packs: [StickerPack] = []

    let rootURL: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Packs", isDirectory: true)
        indexURL = documents.appendingPathComponent("packs.json")
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        packs = (try? JSONDecoder().decode([StickerPack].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(packs) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Paths

    func folder(for packID: UUID) -> URL {
        rootURL.appendingPathComponent(packID.uuidString, isDirectory: true)
    }

    func fileURL(for sticker: Sticker, in pack: StickerPack) -> URL {
        folder(for: pack.id).appendingPathComponent(sticker.fileName)
    }

    func trayURL(for pack: StickerPack) -> URL? {
        guard let name = pack.trayFileName else { return nil }
        let url = folder(for: pack.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func pack(id: UUID) -> StickerPack? {
        packs.first { $0.id == id }
    }

    // MARK: Packs

    @discardableResult
    func createPack(name: String, publisher: String, animated: Bool) -> StickerPack {
        let pack = StickerPack(
            name: String(name.trimmed.prefix(128)),
            publisher: String((publisher.trimmed.isEmpty ? "StickerLab" : publisher.trimmed).prefix(128)),
            animated: animated
        )
        try? FileManager.default.createDirectory(at: folder(for: pack.id), withIntermediateDirectories: true)
        packs.insert(pack, at: 0)
        save()
        return pack
    }

    func updatePack(_ pack: StickerPack) {
        guard let index = packs.firstIndex(where: { $0.id == pack.id }) else { return }
        var updated = pack
        updated.name = String(updated.name.prefix(128))
        updated.publisher = String(updated.publisher.prefix(128))
        updated.updatedAt = Date()
        packs[index] = updated
        save()
    }

    func deletePack(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        packs.removeAll { $0.id == id }
        save()
    }

    /// Adds a pack whose files already sit in `sourceFolder` (used by backup import).
    func adoptPack(_ pack: StickerPack, from sourceFolder: URL) throws {
        var pack = pack
        if packs.contains(where: { $0.id == pack.id }) { pack.id = UUID() }
        let destination = folder(for: pack.id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceFolder, to: destination)
        // Drop stickers whose files are missing.
        pack.stickers = pack.stickers.filter {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.fileName).path)
        }
        packs.insert(pack, at: 0)
        if let index = packs.firstIndex(where: { $0.id == pack.id }), trayURL(for: pack) == nil {
            regenerateTray(at: index)
        }
        save()
    }

    // MARK: Stickers

    func addSticker(data: Data, animated: Bool, emojis: [String], source: String?, to packID: UUID) throws {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else {
            throw AppError("Pacchetto non trovato.")
        }
        guard !packs[index].isFull else {
            throw AppError("Il pacchetto è pieno (massimo \(StickerPack.maxStickers) sticker).")
        }
        let folder = folder(for: packID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sticker = Sticker(fileName: "\(UUID().uuidString).webp", emojis: emojis, animated: animated, sourceURL: source)
        try data.write(to: folder.appendingPathComponent(sticker.fileName), options: .atomic)
        packs[index].stickers.append(sticker)
        packs[index].updatedAt = Date()
        if packs[index].stickers.count == 1 || trayURL(for: packs[index]) == nil {
            regenerateTray(at: index)
        }
        save()
    }

    func deleteSticker(_ stickerID: UUID, from packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[index].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        let sticker = packs[index].stickers.remove(at: stickerIndex)
        try? FileManager.default.removeItem(at: folder(for: packID).appendingPathComponent(sticker.fileName))
        packs[index].updatedAt = Date()
        if stickerIndex == 0 { regenerateTray(at: index) }
        save()
    }

    func setEmojis(_ emojis: [String], for stickerID: UUID, in packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[index].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        packs[index].stickers[stickerIndex].emojis = emojis
        save()
    }

    /// Moves a sticker to the first position; the first sticker is used for the tray icon.
    func makeFirst(_ stickerID: UUID, in packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[index].stickers.firstIndex(where: { $0.id == stickerID }),
              stickerIndex != 0 else { return }
        let sticker = packs[index].stickers.remove(at: stickerIndex)
        packs[index].stickers.insert(sticker, at: 0)
        regenerateTray(at: index)
        save()
    }

    private func regenerateTray(at index: Int) {
        let pack = packs[index]
        let folder = folder(for: pack.id)
        if let old = pack.trayFileName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        packs[index].trayFileName = nil
        guard let first = pack.stickers.first,
              let data = try? Data(contentsOf: folder.appendingPathComponent(first.fileName)),
              let png = StickerPipeline.trayPNG(fromWebP: data) else { return }
        let name = "tray-\(UUID().uuidString.prefix(8)).png"
        if (try? png.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil {
            packs[index].trayFileName = name
        }
    }
}
