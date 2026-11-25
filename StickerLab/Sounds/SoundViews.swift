import PhotosUI
import SwiftUI

/// Meme tab: Imgflip templates or MyInstants sounds.
struct MemeTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case templates, sounds
        var id: String { rawValue }
        var label: String { self == .templates ? "Modelli" : "Suoni" }
    }

    @State private var mode: Mode = .templates

    var body: some View {
        Group {
            switch mode {
            case .templates: MemeTemplatesView()
            case .sounds: SoundsView()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Sezione", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Sound list

struct SoundsView: View {
    @ObservedObject private var player = SoundPlayer.shared

    @State private var query = ""
    @State private var activeQuery = ""
    @State private var sounds: [SoundItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selected: SoundItem?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                Text(activeQuery.isEmpty ? "In tendenza in Italia · MyInstants" : "Risultati per \"\(activeQuery)\" · MyInstants")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage, sounds.isEmpty {
                    VStack(spacing: 12) {
                        Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Riprova") { Task { await reload() } }.glassButton()
                    }
                    .padding(28)
                    .glassCard(cornerRadius: 26)
                }

                ForEach(sounds) { sound in
                    SoundRow(sound: sound, playing: player.playingID == sound.id) {
                        player.toggle(sound)
                    } onUse: {
                        player.stop()
                        selected = sound
                    }
                    .onAppear {
                        if sound.id == sounds.last?.id { Task { await loadMore() } }
                    }
                }
                if loading { ProgressView().padding() }
            }
            .padding()
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Suoni")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca un suono (es. bruh, vine boom)")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: query) { value in
            if value.isEmpty && !activeQuery.isEmpty { Task { await reload() } }
        }
        .task { if sounds.isEmpty { await reload() } }
        .onDisappear { player.stop() }
        .sheet(item: $selected) { sound in SoundStickerView(sound: sound) }
    }

    private func reload() async {
        activeQuery = query.trimmed
        page = 1
        sounds = []
        hasMore = false
        await fetch()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        page += 1
        await fetch()
    }

    private func fetch() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            if activeQuery.isEmpty {
                sounds = try await MyInstantsAPI.trending()
                hasMore = false
            } else {
                let result = try await MyInstantsAPI.search(activeQuery, page: page)
                let existing = Set(sounds.map(\.id))
                sounds.append(contentsOf: result.sounds.filter { !existing.contains($0.id) })
                hasMore = result.hasMore
            }
            errorMessage = nil
        } catch {
            errorMessage = "Impossibile caricare i suoni.\n\(error.localizedDescription)"
        }
    }
}

struct SoundRow: View {
    let sound: SoundItem
    let playing: Bool
    let onPlay: () -> Void
    let onUse: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.white)
                    .glassCapsule(tint: playing ? .pink : .accentColor, interactive: true)
            }
            .buttonStyle(.plain)
            Text(sound.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Usa", action: onUse)
                .glassButton(prominent: true)
        }
        .padding(10)
        .glassCard(cornerRadius: 22)
    }
}

// MARK: - Sticker with sound

struct SoundStickerView: View {
    let sound: SoundItem
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = SoundPlayer.shared

    enum Background: String, CaseIterable, Identifiable {
        case black, white, green
        var id: String { rawValue }
        var label: String {
            switch self {
            case .black: return "Nero"
            case .white: return "Bianco"
            case .green: return "Verde chat"
            }
        }
        var color: UIColor {
            switch self {
            case .black: return .black
            case .white: return .white
            case .green: return UIColor(red: 0.07, green: 0.18, blue: 0.15, alpha: 1)
            }
        }
    }

    @State private var audioFile: URL?
    @State private var audioLength: Double = 0
    @State private var media: DecodedMedia?
    @State private var photoItem: PhotosPickerItem?
    @State private var showStickerChooser = false
    @State private var background: Background = .black
    @State private var duration: Double = 3
    @State private var working: String?
    @State private var message: String?
    @State private var shareItem: IdentifiableURL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    soundBar
                    SectionBox(title: "Immagine") {
                        PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                            Label("Dalla galleria (foto, GIF, video)", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showStickerChooser = true
                        } label: {
                            Label("Da un mio sticker", systemImage: "square.grid.2x2")
                        }
                        .disabled(store.packs.allSatisfy { $0.stickers.isEmpty })
                    }
                    SectionBox(title: "Opzioni") {
                        Picker("Sfondo", selection: $background) {
                            ForEach(Background.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("Durata \(duration, specifier: "%.1f")s")
                            Slider(value: $duration, in: 1...max(1.5, min(SoundStickerExporter.maxDuration, max(audioLength, 1.5))))
                        }
                        Text("WhatsApp usa fino a 10 secondi di audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GlassGroup {
                        VStack(spacing: 10) {
                            Button {
                                Task { await export(save: true) }
                            } label: {
                                Label("Salva il video in Galleria", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                            }
                            .glassButton(prominent: true, tint: .green)
                            .controlSize(.large)
                            Button {
                                Task { await export(save: false) }
                            } label: {
                                Label("Condividi", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .glassButton()
                            .controlSize(.large)
                        }
                    }
                    .disabled(media == nil || audioFile == nil || working != nil)
                    SectionBox(title: "Come usarlo su WhatsApp") {
                        Label("Apri una chat → icona sticker → Crea", systemImage: "1.circle")
                        Label("Scegli questo video dalla galleria", systemImage: "2.circle")
                        Label("Tieni l'audio originale e salva lo sticker", systemImage: "3.circle")
                        Text("Gli sticker con audio sono in arrivo su WhatsApp: se non vedi l'opzione audio, la funzione non è ancora attiva sul tuo account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .padding()
            }
            .appBackground()
            .navigationTitle(sound.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
            .overlay { if let working { BusyOverlay(message: working) } }
            .alert("StickerLab", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
            .sheet(isPresented: $showStickerChooser) {
                StickerChooserView { data in
                    media = WebPCodec.decode(data)
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .task { await loadAudio() }
            .onDisappear { player.stop() }
        }
    }

    private var preview: some View {
        ZStack {
            Color(uiColor: background.color)
            if let media {
                AnimatedMediaView(media: media) { StickerRenderer.render($0, EditSettings(), size: 384) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus").font(.largeTitle)
                    Text("Scegli un'immagine, una GIF o un video").font(.subheadline)
                }
                .foregroundStyle(background == .white ? Color.gray : Color.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(6)
        .glassCard(cornerRadius: 32)
    }

    private var soundBar: some View {
        HStack(spacing: 12) {
            Button {
                if let audioFile {
                    if player.playingID == "local" { player.stop() } else { player.play(id: "local", url: audioFile) }
                }
            } label: {
                Image(systemName: player.playingID == "local" ? "stop.fill" : "speaker.wave.2.fill")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .glassCapsule(tint: .accentColor, interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(audioFile == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(audioFile == nil ? "Download del suono…" : "Durata suono \(audioLength, specifier: "%.1f")s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .glassCard(cornerRadius: 22)
    }

    private func loadAudio() async {
        guard audioFile == nil else { return }
        do {
            let file = try await MyInstantsAPI.downloadAudio(sound.url)
            audioFile = file
            audioLength = await SoundStickerExporter.audioDuration(file)
            duration = min(SoundStickerExporter.maxDuration, max(1, audioLength > 0 ? audioLength : 3))
        } catch {
            message = "Impossibile scaricare il suono: \(error.localizedDescription)"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        working = "Caricamento…"
        defer { working = nil; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let file = try Downloader.store(data)
            media = try await StickerPipeline.loadDefault(ImportItem(fileURL: file, sourceURL: nil, name: nil))
        } catch {
            message = error.localizedDescription
        }
    }

    private func export(save: Bool) async {
        guard let media, let audioFile else { return }
        working = "Creazione del video…"
        defer { working = nil }
        do {
            let url = try await SoundStickerExporter.export(media: media, audioFile: audioFile, duration: duration, background: background.color)
            if save {
                try await SoundStickerExporter.saveToPhotos(url)
                message = "Video salvato in Galleria. Ora crealo come sticker con audio in WhatsApp."
            } else {
                shareItem = IdentifiableURL(url: url)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Pick one of your stickers (returns its WebP data).
struct StickerChooserView: View {
    let onPick: (Data) -> Void
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.packs.filter { !$0.stickers.isEmpty }) { pack in
                        Text(pack.name).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                            ForEach(pack.stickers) { sticker in
                                let url = store.fileURL(for: sticker, in: pack)
                                Button {
                                    if let data = try? Data(contentsOf: url) { onPick(data) }
                                    dismiss()
                                } label: {
                                    StickerThumbnail(url: url)
                                        .padding(8)
                                        .aspectRatio(1, contentMode: .fit)
                                        .glassCard(cornerRadius: 18, interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .appBackground()
            .navigationTitle("Scegli uno sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
        }
    }
}
