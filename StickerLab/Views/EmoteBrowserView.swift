import SwiftUI

/// Emote tab: 7TV and FrankerFaceZ, with categories, search, multi-select and long-press quick save.
struct EmoteBrowserView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: PackStore

    @State private var source: EmoteSource = .sevenTV
    @State private var category: BrowseCategory = .top
    @State private var filter: SevenTVAPI.Filter = .all
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var emotes: [EmoteItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var selecting = false
    @State private var selected: [EmoteItem] = []

    private var packName: String {
        activeQuery.isEmpty ? "\(source.label) \(category.label)" : activeQuery
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Picker("Fonte", selection: $source) {
                    ForEach(EmoteSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                categoryBar
            }

            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
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
            } else if !loading && emotes.isEmpty {
                Text("Nessuna emote trovata.").foregroundStyle(.secondary).padding(32)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                ForEach(emotes) { emote in
                    EmoteCell(emote: emote, selected: selected.contains(emote))
                        .onTapGesture { tap(emote) }
                        .contextMenu {
                            QuickSaveMenu(media: emote.remote, newPackName: packName, store: store, app: app)
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
        .navigationTitle(activeQuery.isEmpty ? "Emote · \(category.label)" : "Emote · \(activeQuery)")
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
                        let name = packName
                        Task { await app.download(picks.map(\.remote), packName: name) }
                    } label: {
                        Text(selected.isEmpty ? "Tocca le emote da importare" : "Importa \(selected.count) emote").bold()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onChange(of: source) { newSource in
            if !newSource.categories.contains(category) { category = .top }
            Task { await reload() }
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
                    ForEach(source.categories) { item in
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
                .padding(.vertical, 4)
            }
        }
        .opacity(activeQuery.isEmpty ? 1 : 0.5)
    }

    private func tap(_ emote: EmoteItem) {
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
        hasMore = false
        notice = nil
        await fetch()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        page += 1
        await fetch()
    }

    private func applyFilter(_ list: [EmoteItem]) -> [EmoteItem] {
        switch filter {
        case .all: return list
        case .animated: return list.filter(\.animated)
        case .still: return list.filter { !$0.animated }
        }
    }

    private func fetch() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let requestedSource = source
        do {
            var result: [EmoteItem]
            switch requestedSource {
            case .sevenTV:
                let searchCategory: SevenTVAPI.Category = activeQuery.isEmpty ? category.sevenTV : .top
                let response = try await SevenTVAPI.search(activeQuery, page: page, category: searchCategory, filter: filter)
                result = response.emotes.map(\.item)
                hasMore = emotes.count + result.count < response.total && !result.isEmpty
            case .ffz:
                let ffzCategory: BrowseCategory = activeQuery.isEmpty ? category : .top
                // Show the cached list right away; the network answer replaces it when it arrives.
                if page == 1, emotes.isEmpty,
                   let cached = FrankerFaceZAPI.cachedSearch(activeQuery, page: 1, category: ffzCategory) {
                    emotes = applyFilter(cached.emotes)
                    hasMore = cached.hasMore
                    if cached.age < 6 * 3600 { return }
                }
                let response = try await FrankerFaceZAPI.search(activeQuery, page: page, category: ffzCategory)
                result = applyFilter(response.emotes)
                hasMore = response.hasMore
                if page == 1 { emotes = [] }
            }
            guard requestedSource == source else { return }
            let existing = Set(emotes.map(\.id))
            emotes.append(contentsOf: result.filter { !existing.contains($0.id) })
            errorMessage = nil
        } catch {
            guard requestedSource == source else { return }
            // 7TV's search sometimes fails on their side (LOAD_ERROR) while sets still work.
            if requestedSource == .sevenTV, page == 1,
               let global = try? await SevenTVAPI.setEmotes(id: "global"), !global.emotes.isEmpty {
                emotes = applyFilter(global.emotes.map(\.item))
                hasMore = false
                notice = "La ricerca di 7TV è momentaneamente fuori servizio (problema dei loro server). Intanto ecco le emote globali; prova anche FrankerFaceZ."
                errorMessage = nil
            } else {
                errorMessage = "Impossibile caricare le emote.\n\(error.localizedDescription)"
            }
        }
    }
}

struct EmoteCell: View {
    let emote: EmoteItem
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
