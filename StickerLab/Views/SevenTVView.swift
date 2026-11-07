import SwiftUI

struct SevenTVView: View {
    @EnvironmentObject private var app: AppState

    @State private var query = ""
    @State private var filter: SevenTVAPI.Filter = .all
    @State private var emotes: [SevenTVEmote] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selecting = false
    @State private var selected: [SevenTVEmote] = []
    @State private var activeQuery = ""

    var body: some View {
        ScrollView {
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
                        .onAppear {
                            if emote.id == emotes.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
        }
        .appBackground()
        .navigationTitle(activeQuery.isEmpty ? "7TV · Popolari" : "7TV · \(activeQuery)")
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
                    Image(systemName: "line.3.horizontal.decrease.circle")
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
                        Task { await app.download(picks.map(\.remote), packName: activeQuery.isEmpty ? "7TV" : activeQuery) }
                    } label: {
                        Text(selected.isEmpty ? "Tocca le emote da importare" : "Importa \(selected.count) emote").bold()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onChange(of: filter) { _ in Task { await reload() } }
        .onChange(of: query) { value in
            if value.isEmpty && !activeQuery.isEmpty { Task { await reload() } }
        }
        .task {
            if emotes.isEmpty { await reload() }
        }
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
            let result = try await SevenTVAPI.search(activeQuery, page: page, filter: filter)
            let existing = Set(emotes.map(\.id))
            emotes.append(contentsOf: result.emotes.filter { !existing.contains($0.id) })
            total = result.total
            errorMessage = nil
        } catch {
            errorMessage = "Impossibile caricare le emote 7TV.\n\(error.localizedDescription)"
        }
    }
}

struct EmoteCell: View {
    let emote: SevenTVEmote
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                AsyncImage(url: emote.previewURL) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFit()
                    } else if phase.error != nil {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(12)
            }
            .aspectRatio(1, contentMode: .fit)
            .glassCard(cornerRadius: 22, tint: selected ? .accentColor : nil, interactive: true)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(4)
                } else if emote.animated {
                    Image(systemName: "play.circle.fill").font(.caption).foregroundStyle(.secondary).padding(5)
                }
            }
            Text(emote.name).font(.caption2).lineLimit(1)
        }
    }
}
