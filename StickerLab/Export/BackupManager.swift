import Foundation
import ZIPFoundation

/// Backup format (.zip): manifest.json + packs/<pack id>/<files>.
/// Also reads and writes Android-style .wastickers archives.
enum BackupManager {
    struct Manifest: Codable {
        var app = "StickerLab"
        var version = 1
        var createdAt = Date()
        var packs: [StickerPack]
    }

    private static func workDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func outputURL(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) }).trimmed
        return cleaned.isEmpty ? "Pacchetto" : cleaned
    }

    // MARK: Export

    @MainActor
    static func export(_ packs: [StickerPack], store: PackStore, name: String? = nil) throws -> URL {
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let packsFolder = work.appendingPathComponent("packs", isDirectory: true)
        try FileManager.default.createDirectory(at: packsFolder, withIntermediateDirectories: true)
        for pack in packs {
            try FileManager.default.copyItem(at: store.folder(for: pack.id), to: packsFolder.appendingPathComponent(pack.id.uuidString))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(Manifest(packs: packs)).write(to: work.appendingPathComponent("manifest.json"))

        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let fileName = name.map { "\(safeName($0)).zip" } ?? "StickerLab-backup-\(date).zip"
        let destination = outputURL(fileName)
        try FileManager.default.zipItem(at: work, to: destination, shouldKeepParent: false)
        return destination
    }

    @MainActor
    static func exportAll(_ store: PackStore) throws -> URL {
        try export(store.packs, store: store)
    }

    /// Android-compatible archive: title.txt, author.txt, tray.png, 1.webp…
    @MainActor
    static func exportWAStickers(_ pack: StickerPack, store: PackStore) throws -> URL {
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        try pack.name.write(to: work.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        try pack.publisher.write(to: work.appendingPathComponent("author.txt"), atomically: true, encoding: .utf8)
        if let tray = store.trayURL(for: pack) {
            try FileManager.default.copyItem(at: tray, to: work.appendingPathComponent("tray.png"))
        }
        for (index, sticker) in pack.stickers.enumerated() {
            try FileManager.default.copyItem(at: store.fileURL(for: sticker, in: pack), to: work.appendingPathComponent("\(index + 1).webp"))
        }
        let destination = outputURL("\(safeName(pack.name)).wastickers")
        try FileManager.default.zipItem(at: work, to: destination, shouldKeepParent: false)
        return destination
    }

    // MARK: Import

    /// Returns the number of imported packs.
    @MainActor
    static func importArchive(at url: URL, into store: PackStore) throws -> Int {
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.unzipItem(at: url, to: work)
        } catch {
            throw AppError("Impossibile aprire l'archivio: \(error.localizedDescription)")
        }

        if let manifestURL = find(named: "manifest.json", in: work) {
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            let packsFolder = manifestURL.deletingLastPathComponent().appendingPathComponent("packs", isDirectory: true)
            var count = 0
            for pack in manifest.packs.reversed() {
                let folder = packsFolder.appendingPathComponent(pack.id.uuidString, isDirectory: true)
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                try store.adoptPack(pack, from: folder)
                count += 1
            }
            guard count > 0 else { throw AppError("Il backup non contiene pacchetti.") }
            return count
        }
        return try importWAStickers(from: work, into: store)
    }

    @MainActor
    private static func importWAStickers(from folder: URL, into store: PackStore) throws -> Int {
        let files = allFiles(in: folder)
        let webps = files.filter { $0.pathExtension.lowercased() == "webp" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !webps.isEmpty else { throw AppError("L'archivio non contiene sticker WebP.") }

        let title = files.first { $0.lastPathComponent.lowercased() == "title.txt" }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmed
        let author = files.first { $0.lastPathComponent.lowercased() == "author.txt" }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmed

        let datas = webps.compactMap { try? Data(contentsOf: $0) }
        let animated = datas.contains { WebPCodec.frameCount($0) > 1 }
        let baseName = (title?.isEmpty == false ? title! : "Pacchetto importato")
        var pack = store.createPack(name: baseName, publisher: author ?? "", animated: animated)
        var packCount = 1

        for data in datas {
            if store.pack(id: pack.id)?.isFull == true {
                packCount += 1
                pack = store.createPack(name: "\(baseName) \(packCount)", publisher: author ?? "", animated: animated)
            }
            var stickerData = data
            let isAnimated = WebPCodec.frameCount(data) > 1
            let needsReencode = isAnimated != animated
                || (animated ? data.count > StickerEncoder.animatedLimit : data.count > StickerEncoder.staticLimit)
            if needsReencode, let media = WebPCodec.decode(data) {
                stickerData = (try? StickerPipeline.makeSticker(from: media, settings: EditSettings(), animated: animated)) ?? data
            }
            try? store.addSticker(data: stickerData, animated: animated, emojis: ["😀"], source: nil, to: pack.id)
        }
        return packCount
    }

    private static func allFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !$0.path.contains("__MACOSX")
        }
    }

    private static func find(named name: String, in folder: URL) -> URL? {
        allFiles(in: folder).first { $0.lastPathComponent == name }
    }
}
