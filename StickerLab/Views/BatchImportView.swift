import SwiftUI

/// Imports many items at once with default framing (no editor).
struct BatchImportView: View {
    let request: BatchRequest
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPublisher") private var defaultPublisher = ""
    @AppStorage("defaultEmoji") private var defaultEmoji = "😀"

    @State private var target: UUID?
    @State private var newName = ""
    @State private var newAnimated = true
    @State private var running = false
    @State private var finished = false
    @State private var done = 0
    @State private var failures: [String] = []
    @State private var configured = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("\(request.items.count) elementi da importare", systemImage: "square.stack.3d.up")
                }
                .glassRows()
                Section("Destinazione") {
                    Picker("Pacchetto", selection: $target) {
                        Text("Nuovo pacchetto").tag(UUID?.none)
                        ForEach(store.packs) { pack in
                            Text("\(pack.name) (\(pack.stickers.count)/\(StickerPack.maxStickers))").tag(UUID?.some(pack.id))
                        }
                    }
                    if target == nil {
                        TextField("Nome del nuovo pacchetto", text: $newName)
                        Toggle("Animato", isOn: $newAnimated)
                    }
                }
                .glassRows()
                .disabled(running || finished)

                Section {
                    if running {
                        ProgressView(value: Double(done), total: Double(max(request.items.count, 1))) {
                            Text("Elaborazione \(done)/\(request.items.count)…")
                        }
                    } else if finished {
                        Label("Importati \(request.items.count - failures.count) sticker", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        ForEach(failures, id: \.self) { failure in
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Button("Importa tutto") { Task { await run() } }.bold()
                    }
                } footer: {
                    Text("Ogni elemento viene adattato a 512×512 automaticamente (dai video vengono presi i primi 3 secondi). Oltre 30 sticker viene creato un pacchetto aggiuntivo. Per ritocchi apri gli elementi uno alla volta.")
                }
                .glassRows()
            }
            .appBackground()
            .navigationTitle("Importazione multipla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Chiudi" : "Annulla") { dismiss() }.disabled(running)
                }
            }
            .onAppear {
                guard !configured else { return }
                configured = true
                newName = request.suggestedPackName ?? ""
                newAnimated = request.suggestedAnimated
                if let preferred = app.preferredPackID, store.pack(id: preferred) != nil { target = preferred }
            }
        }
        .interactiveDismissDisabled(running)
    }

    private func run() async {
        running = true
        let emojis = EmojiParser.parse(defaultEmoji)
        var packID: UUID
        var baseName: String
        if let target, let existing = store.pack(id: target) {
            packID = existing.id
            baseName = existing.name
        } else {
            baseName = newName.trimmed.isEmpty ? "Nuovo pacchetto" : newName.trimmed
            packID = store.createPack(name: baseName, publisher: defaultPublisher, animated: newAnimated).id
        }
        var extraPacks = 1

        for item in request.items {
            do {
                guard let current = store.pack(id: packID) else { break }
                if current.isFull {
                    extraPacks += 1
                    packID = store.createPack(name: "\(baseName) \(extraPacks)", publisher: current.publisher, animated: current.animated).id
                }
                let animated = store.pack(id: packID)?.animated ?? false
                let data = try await StickerPipeline.makeDefaultSticker(from: item, animated: animated)
                try store.addSticker(data: data, animated: animated, emojis: emojis, source: item.sourceURL, to: packID)
            } catch {
                failures.append("\(item.name ?? item.fileURL.lastPathComponent): \(error.localizedDescription)")
            }
            done += 1
        }
        app.preferredPackID = packID
        running = false
        finished = true
    }
}
