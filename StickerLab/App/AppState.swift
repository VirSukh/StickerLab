import SwiftUI

enum AppTab: Hashable {
    case packs, importer, sevenTV, settings
}

/// A local media file ready to be turned into a sticker.
struct ImportItem: Identifiable {
    let id = UUID()
    let fileURL: URL
    var sourceURL: String?
    var name: String?
}

struct BatchRequest: Identifiable {
    let id = UUID()
    let items: [ImportItem]
    var suggestedPackName: String?
    var suggestedAnimated: Bool
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .packs
    @Published var editorItem: ImportItem?
    @Published var batchRequest: BatchRequest?
    @Published var busyMessage: String?
    @Published var alertMessage: String?
    /// Link received through the `stickerlab://import?url=` scheme.
    @Published var pendingLink: String?
    /// Pack that new stickers should go to by default.
    @Published var preferredPackID: UUID?
    /// Navigation path of the Packs tab.
    @Published var packsPath: [UUID] = []

    func open(_ items: [ImportItem], packName: String? = nil) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            editorItem = items[0]
        } else {
            let animated = items.contains { item in
                let kind = MediaDecoder.sniff(item.fileURL)
                return kind == .video || kind == .gif || (kind == .webp && WebPCodec.isAnimated(fileURL: item.fileURL))
            }
            batchRequest = BatchRequest(items: items, suggestedPackName: packName, suggestedAnimated: animated)
        }
    }

    /// Opens items after a short delay, so that a sheet being dismissed has time to go away.
    func openDelayed(_ items: [ImportItem], packName: String? = nil) {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            open(items, packName: packName)
        }
    }

    func download(_ medias: [RemoteMedia], packName: String? = nil) async {
        guard !medias.isEmpty else { return }
        var items: [ImportItem] = []
        var failures: [String] = []
        for (index, media) in medias.enumerated() {
            busyMessage = medias.count == 1 ? "Download…" : "Download \(index + 1)/\(medias.count)…"
            do {
                let file = try await Downloader.download(media)
                items.append(ImportItem(fileURL: file, sourceURL: media.pageURL ?? media.url.absoluteString, name: media.title))
            } catch {
                failures.append("\(media.title ?? media.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        busyMessage = nil
        if items.isEmpty {
            alertMessage = "Download non riuscito.\n" + failures.prefix(5).joined(separator: "\n")
            return
        }
        if !failures.isEmpty {
            alertMessage = "\(failures.count) elementi non scaricati.\n" + failures.prefix(5).joined(separator: "\n")
        }
        open(items, packName: packName)
    }

    func handleOpenURL(_ url: URL, store: PackStore) {
        if url.scheme?.lowercased() == "stickerlab" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let link = components?.queryItems?.first(where: { $0.name == "url" || $0.name == "link" })?.value {
                selectedTab = .importer
                pendingLink = link
            }
            return
        }
        if url.isFileURL {
            importBackup(url, store: store)
        }
    }

    func importBackup(_ url: URL, store: PackStore) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        busyMessage = "Importazione backup…"
        defer { busyMessage = nil }
        do {
            let count = try BackupManager.importArchive(at: url, into: store)
            selectedTab = .packs
            alertMessage = count == 1 ? "Importato 1 pacchetto." : "Importati \(count) pacchetti."
        } catch {
            alertMessage = error.localizedDescription
        }
        // Files opened with "Open in" are copied into Documents/Inbox: clean them up.
        if url.path.contains("/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
