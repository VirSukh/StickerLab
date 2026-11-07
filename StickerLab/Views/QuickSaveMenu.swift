import SwiftUI

/// Long-press menu: save straight into a pack (no editor), or open the editor.
struct QuickSaveMenu: View {
    let media: RemoteMedia
    let newPackName: String
    // Passed explicitly: context menus are built outside the normal view hierarchy.
    @ObservedObject var store: PackStore
    @ObservedObject var app: AppState

    var body: some View {
        if let lastID = app.preferredPackID, let last = store.pack(id: lastID), !last.isFull {
            Button {
                save(to: last.id)
            } label: {
                Label("Salva in \(last.name)", systemImage: "bolt.fill")
            }
        }

        Menu {
            ForEach(store.packs) { pack in
                Button {
                    save(to: pack.id)
                } label: {
                    Label(
                        "\(pack.name) (\(pack.stickers.count)/\(StickerPack.maxStickers))",
                        systemImage: pack.animated ? "play.circle" : "photo"
                    )
                }
                .disabled(pack.isFull)
            }
        } label: {
            Label("Salva in un pacchetto…", systemImage: "square.and.arrow.down.on.square")
        }

        Button {
            save(to: nil)
        } label: {
            Label("Salva in un nuovo pacchetto", systemImage: "plus.square.on.square")
        }

        Divider()

        Button {
            Task { await app.download([media], packName: nil) }
        } label: {
            Label("Apri nell'editor", systemImage: "slider.horizontal.3")
        }
    }

    private func save(to packID: UUID?) {
        Task { await app.quickSave(media, to: packID, newPackName: newPackName, store: store) }
    }
}
