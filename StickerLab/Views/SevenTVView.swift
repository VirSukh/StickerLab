import SwiftUI

struct SevenTVView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: PackStore

    @State private var query = ""
    @State private var category: SevenTVAPI.Category = .top
    @State private var filter: SevenTVAPI.Filter = .all
    @State private var emotes: [SevenTVEmote] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selecting = false
    @State private var selected: [SevenTVEmote] = []
    @State private var activeQuery = ""
    @State private var searchDown = false

    var body: some View {
        ScrollView {
            categoryBar

            if searchDown {
                Label("La ricerca di 7TV è momentaneamente fuori servizio (problema dei loro server). Intanto ecco le emote globali; i link a emote e set funzionano.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .glassCard(cornerRadius: 18, tint: .orange)
                    .padding(.horizontal)
            }

            if let errorMessage, emotes.isEmpty {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Riprova") { Task { await reload() } }.glassButton()
                }
                .padding(32)
                .glassCard(cornerRadius: 28)
                .padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                ForEach(emotes) { emote in
                    EmoteCell(emote: emote, selected: selected.contains(emote))
                        .onTapGesture { tap(emote) }
                        .contextMenu {
                            QuickSaveMenu(
                                media: emote.remote,
                                newPackName: activeQuery.isEmpty ? "7TV \(category.label)" : "7TV \(activeQuery)",
                                store: store,
                                app: app
                            )
                        } preview: {
                            RemoteAnimatedImage(url: emote.previewURL)
                                .frame(width: 220, height: 220)
                                .padding()
                        }
                        .onAppear {
                            if emote.id == emotes.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            if loading { ProgressView().padding() }
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle(activeQuery.isEmpty ? "7TV · \(category.label)" : "7TV · \(activeQuery)")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca emote")
        .onSubmit(of: .search) { Task { await reload() } }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Tipo", selection: $filter) {
                        ForEach(SevenTVAPI.Filter.allCases) { option in Text(option.label).tag(option) }
                    }
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(selecting ? "Fine" : "Seleziona") {
                    selecting.toggle()
                    if !selecting { selected = [] }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if selecting {
                    Button {
                        let picks = selected
                        selecting = false
                        selected = []
                        let name = activeQuery.isEmpty ? "7TV \(category.label)" : activeQuery
                        Task { await app.download(picks.map(\.remote), packName: name) }
                    } label: {
                        Text(selected.isEmpty ? "Tocca le emote da importare" : "Importa \(selected.count) emote").bold()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onChange(of: filter) { _ in Task { await reload() } }
        .onChange(of: category) { _ in Task { await reload() } }
        .onChange(of: query) { value in
            if value.isEmpty && !activeQuery.isEmpty { Task { await reload() } }
        }
        .task {
            if emotes.isEmpty { await reload() }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SevenTVAPI.Category.allCases) { item in
                        Button {
                            category = item
                        } label: {
                            Label(item.label, systemImage: item.symbol)
                                .font(.subheadline.weight(category == item ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(category == item ? Color.white : Color.primary)
                                .glassCapsule(tint: category == item ? .accentColor : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .opacity(activeQuery.isEmpty ? 1 : 0.5)
    }

    private func tap(_ emote: SevenTVEmote) {
        if selecting {
            if let index = selected.firstIndex(of: emote) {
                selected.remove(at: index)
            } else if selected.count < 120 {
                selected.append(emote)
            }
        } else {
            Task { await app.download([emote.remote], packName: nil) }
        }
    }

    private func reload() async {
        activeQuery = query.trimmed
        page = 1
        emotes = []
        total = 0
        await fetch()
    }

    private func loadMore() async {
        guard !loading, emotes.count < total else { return }
        page += 1
        await fetch()
    }

    private func fetch() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            // Searches always look in the whole catalogue.
            let searchCategory: SevenTVAPI.Category = activeQuery.isEmpty ? category : .top
            let result = try await SevenTVAPI.search(activeQuery, page: page, category: searchCategory, filter: filter)
            let existing = Set(emotes.map(\.id))
            emotes.append(contentsOf: result.emotes.filter { !existing.contains($0.id) })
            total = result.total
            errorMessage = nil
            searchDown = false
        } catch {
            // 7TV's search sometimes fails on their side (LOAD_ERROR) while sets still work.
            if page == 1, let global = try? await SevenTVAPI.setEmotes(id: "global"), !global.emotes.isEmpty {
                var list = global.emotes
                if filter == .animated { list = list.filter(\.animated) }
                if filter == .still { list = list.filter { !$0.animated } }
                emotes = list
                total = list.count
                searchDown = true
                errorMessage = nil
            } else {
                errorMessage = "Impossibile caricare le emote 7TV.\n\(error.localizedDescription)"
            }
        }
    }
}

struct EmoteCell: View {
    let emote: SevenTVEmote
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            RemoteAnimatedImage(url: emote.previewURL)
                .padding(12)
                .aspectRatio(1, contentMode: .fit)
                .glassCard(cornerRadius: 22, tint: selected ? .accentColor : nil, interactive: true)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(4)
                    }
                }
            Text(emote.name).font(.caption2).lineLimit(1)
        }
    }
}
