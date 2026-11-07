import SwiftUI

struct PackRowLabel: View {
    let pack: StickerPack
    let trayURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let trayURL {
                    StickerThumbnail(url: trayURL).padding(6)
                } else {
                    Image(systemName: "face.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            .glassCard(cornerRadius: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(pack.stickers.count)/\(StickerPack.maxStickers)")
                    Text("·")
                    Label(pack.animated ? "Animato" : "Statico", systemImage: pack.animated ? "play.circle" : "photo")
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PackListView: View {
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @State private var showNewPack = false

    var body: some View {
        Group {
            if store.packs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.badge.automatic")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Nessun pacchetto").font(.title3.weight(.semibold))
                    Text("Importa immagini, GIF, video o emote 7TV per creare il tuo primo pacchetto di sticker WhatsApp.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    GlassGroup {
                        HStack {
                            Button("Importa") { app.selectedTab = .importer }.glassButton(prominent: true)
                            Button("Nuovo pacchetto") { showNewPack = true }.glassButton()
                        }
                    }
                }
                .padding(32)
                .glassCard(cornerRadius: 32)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.packs) { pack in
                            NavigationLink(value: pack.id) {
                                HStack {
                                    PackRowLabel(pack: pack, trayURL: store.trayURL(for: pack))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                                .glassCard(cornerRadius: 24, interactive: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { store.deletePack(id: pack.id) } label: {
                                    Label("Elimina pacchetto", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .appBackground()
        .navigationTitle("Pacchetti")
        .navigationDestination(for: UUID.self) { id in PackDetailView(packID: id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewPack = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNewPack) { PackFormView(pack: nil) }
    }
}

struct PackFormView: View {
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPublisher") private var defaultPublisher = ""

    let pack: StickerPack?
    @State private var name = ""
    @State private var publisher = ""
    @State private var animated = false
    @State private var loaded = false

    private var typeLocked: Bool { !(pack?.stickers.isEmpty ?? true) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome pacchetto", text: $name)
                    TextField("Autore", text: $publisher)
                }
                .glassRows()
                Section {
                    Toggle("Pacchetto animato", isOn: $animated).disabled(typeLocked)
                } footer: {
                    Text(typeLocked
                         ? "Il tipo non si può cambiare: il pacchetto contiene già sticker."
                         : "WhatsApp non permette di mischiare sticker statici e animati nello stesso pacchetto.")
                }
                .glassRows()
            }
            .appBackground()
            .navigationTitle(pack == nil ? "Nuovo pacchetto" : "Modifica pacchetto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }.disabled(name.trimmed.isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = pack?.name ?? ""
                publisher = pack?.publisher ?? defaultPublisher
                animated = pack?.animated ?? false
            }
        }
    }

    private func save() {
        if var pack {
            pack.name = name.trimmed
            pack.publisher = publisher.trimmed.isEmpty ? "StickerLab" : publisher.trimmed
            if !typeLocked { pack.animated = animated }
            store.updatePack(pack)
        } else {
            store.createPack(name: name, publisher: publisher, animated: animated)
        }
        dismiss()
    }
}

/// Lets the user choose (or create) the pack a sticker goes into.
struct PackPickerView: View {
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPublisher") private var defaultPublisher = ""

    let suggestedAnimated: Bool
    let onPick: (UUID) -> Void
    @State private var newName = ""
    @State private var newAnimated: Bool

    init(suggestedAnimated: Bool, onPick: @escaping (UUID) -> Void) {
        self.suggestedAnimated = suggestedAnimated
        self.onPick = onPick
        _newAnimated = State(initialValue: suggestedAnimated)
    }

    private var sortedPacks: [StickerPack] {
        guard let preferred = app.preferredPackID else { return store.packs }
        return store.packs.filter { $0.id == preferred } + store.packs.filter { $0.id != preferred }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.packs.isEmpty {
                    Section("Aggiungi a un pacchetto") {
                        ForEach(sortedPacks) { pack in
                            Button { pick(pack.id) } label: {
                                HStack {
                                    PackRowLabel(pack: pack, trayURL: store.trayURL(for: pack))
                                    Spacer()
                                    if pack.isFull { Text("Pieno").font(.caption).foregroundStyle(.red) }
                                    else if pack.animated != suggestedAnimated {
                                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                                    }
                                }
                            }
                            .disabled(pack.isFull)
                        }
                    }
                    .glassRows()
                }
                Section {
                    TextField("Nome del nuovo pacchetto", text: $newName)
                    Toggle("Animato", isOn: $newAnimated)
                    Button("Crea e aggiungi") {
                        let name = newName.trimmed.isEmpty ? "Nuovo pacchetto" : newName
                        let pack = store.createPack(name: name, publisher: defaultPublisher, animated: newAnimated)
                        pick(pack.id)
                    }
                } header: {
                    Text("Nuovo pacchetto")
                } footer: {
                    Text("Le animazioni salvate in un pacchetto statico useranno il primo fotogramma; le immagini fisse in un pacchetto animato diventano animazioni di un fotogramma.")
                }
                .glassRows()
            }
            .appBackground()
            .navigationTitle("Salva in…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            }
        }
    }

    private func pick(_ id: UUID) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(id) }
    }
}
