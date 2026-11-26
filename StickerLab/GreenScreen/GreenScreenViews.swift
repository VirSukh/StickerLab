import PhotosUI
import SwiftUI

struct GreenScreenJob: Identifiable {
    let id = UUID()
    let file: URL
    let name: String
}

// MARK: - Library

struct GreenScreenLibraryView: View {
    @EnvironmentObject private var app: AppState

    @State private var source: GreenScreenSource = .gsm
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var templates: [GreenTemplate] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var job: GreenScreenJob?
    @State private var opening = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Libreria", selection: $source) {
                    ForEach(GreenScreenSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(source == .gsm ? "Oltre 7.000 template · greenscreenmemes.com · uso personale" : "Circa 300 template · memes-download.com · uso personale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage, templates.isEmpty {
                    VStack(spacing: 12) {
                        Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Riprova") { Task { await reload() } }.glassButton()
                    }
                    .padding(28)
                    .glassCard(cornerRadius: 26)
                } else if !loading && templates.isEmpty {
                    Text("Nessun template trovato.").foregroundStyle(.secondary).padding(30)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                    ForEach(templates) { template in
                        Button {
                            Task { await open(template) }
                        } label: {
                            GreenTemplateCell(template: template)
                        }
                        .buttonStyle(.plain)
                        .disabled(opening)
                        .onAppear {
                            if template.id == templates.last?.id { Task { await loadMore() } }
                        }
                    }
                }
                if loading { ProgressView().padding() }
            }
            .padding()
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Green screen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca (es. cat, dance, shocked)")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: query) { value in
            if value.isEmpty && !activeQuery.isEmpty { Task { await reload() } }
        }
        .onChange(of: source) { _ in Task { await reload() } }
        .task { if templates.isEmpty { await reload() } }
        .sheet(item: $job) { job in GreenScreenEditorView(job: job) }
    }

    private func reload() async {
        activeQuery = query.trimmed
        page = 1
        templates = []
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
        let requested = source
        do {
            switch requested {
            case .gsm:
                let result = try await GreenScreenAPI.searchGSM(activeQuery, page: page)
                guard requested == source else { return }
                let existing = Set(templates.map(\.id))
                templates.append(contentsOf: result.templates.filter { !existing.contains($0.id) })
                hasMore = result.hasMore
            case .memesDownload:
                let all = try await GreenScreenAPI.memesDownloadAll()
                guard requested == source else { return }
                let text = activeQuery.lowercased()
                templates = text.isEmpty ? all : all.filter { $0.name.lowercased().contains(text) }
                hasMore = false
            }
            errorMessage = nil
        } catch {
            errorMessage = "Impossibile caricare i template.\n\(error.localizedDescription)"
        }
    }

    private func open(_ template: GreenTemplate) async {
        opening = true
        app.busyMessage = "Download del template…"
        defer {
            opening = false
            app.busyMessage = nil
        }
        do {
            let url = try await GreenScreenAPI.videoURL(for: template)
            let file = try await Downloader.download(RemoteMedia(url: url, title: template.name, kind: .video))
            job = GreenScreenJob(file: file, name: template.name)
        } catch {
            app.alertMessage = "Download non riuscito: \(error.localizedDescription)"
        }
    }
}

struct GreenTemplateCell: View {
    let template: GreenTemplate

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(red: 0, green: 0.55, blue: 0.2).opacity(0.25)
                if let thumb = template.thumbnailURL {
                    RemoteAnimatedImage(url: thumb, placeholderSymbol: "film")
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "film.stack").font(.largeTitle)
                        Text("Green screen").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.green)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(6)
            .glassCard(cornerRadius: 22, interactive: true)
            Text(template.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Editor

struct GreenScreenEditorView: View {
    let job: GreenScreenJob
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss

    enum MoveTarget: String, CaseIterable, Identifiable {
        case background, template
        var id: String { rawValue }
        var label: String { self == .background ? "Sposta sfondo" : "Sposta template" }
    }

    @State private var videoDuration: Double = 0
    @State private var start: Double = 0
    @State private var length: Double = 5
    @State private var raw: DecodedMedia?
    @State private var keyed: DecodedMedia?
    @State private var keyColor: KeyColor = .green
    @State private var settings = GreenScreenSettings()
    @State private var background: DecodedMedia?
    @State private var moveTarget: MoveTarget = .background
    @State private var dragOrigin: CGSize?
    @State private var pinchBase: CGFloat?
    @State private var photoItem: PhotosPickerItem?
    @State private var showStickerChooser = false
    @State private var videoBackground: SoundStickerView.Background = .black
    @State private var working: String?
    @State private var message: String?
    @State private var shareItem: IdentifiableURL?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    if let loadError {
                        Text(loadError).foregroundStyle(.orange).font(.subheadline)
                    }
                    backgroundSection
                    keySection
                    positionSection
                    timeSection
                    exportSection
                }
                .padding()
            }
            .appBackground()
            .navigationTitle(job.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .overlay { if let working { BusyOverlay(message: working) } }
            .alert("StickerLab", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
            .sheet(isPresented: $showStickerChooser) {
                StickerChooserView { data in
                    background = WebPCodec.decode(data)
                    moveTarget = .background
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await loadBackground(item) }
            }
            .task { await loadTemplate(initial: true) }
        }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let side = geo.size.width - 12
            ZStack {
                Checkerboard()
                if let keyed {
                    TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let frame = keyed.frames[keyed.frameIndex(at: t)]
                        let back = background.map { $0.frames[$0.frameIndex(at: t)] }
                        if let image = GreenScreenCompositor.compose(template: frame, background: back, settings: settings, size: 320) {
                            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        }
                    }
                } else if loadError == nil {
                    ProgressView("Preparazione…")
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(6)
            .glassCard(cornerRadius: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let k = CGFloat(StickerRenderer.canvas) / max(side, 1)
                        let current = moveTarget == .background ? settings.backgroundOffset : settings.templateOffset
                        let origin = dragOrigin ?? current
                        if dragOrigin == nil { dragOrigin = origin }
                        let moved = CGSize(width: origin.width + value.translation.width * k, height: origin.height + value.translation.height * k)
                        if moveTarget == .background { settings.backgroundOffset = moved } else { settings.templateOffset = moved }
                    }
                    .onEnded { _ in dragOrigin = nil }
                    .simultaneously(with: MagnificationGesture()
                        .onChanged { value in
                            let current = moveTarget == .background ? settings.backgroundScale : settings.templateScale
                            let base = pinchBase ?? current
                            if pinchBase == nil { pinchBase = base }
                            let scaled = min(max(base * value, 0.2), 5)
                            if moveTarget == .background { settings.backgroundScale = scaled } else { settings.templateScale = scaled }
                        }
                        .onEnded { _ in pinchBase = nil })
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Sections

    private var backgroundSection: some View {
        SectionBox(title: "La tua immagine dietro") {
            PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                Label("Dalla galleria (foto, GIF, video)", systemImage: "photo.on.rectangle")
            }
            Button {
                showStickerChooser = true
            } label: {
                Label("Da un mio sticker", systemImage: "square.grid.2x2")
            }
            .disabled(store.packs.allSatisfy { $0.stickers.isEmpty })
            if background != nil {
                Button(role: .destructive) {
                    background = nil
                } label: {
                    Label("Togli lo sfondo (resta trasparente)", systemImage: "xmark.circle")
                }
            }
            Text("Senza immagine dietro, il template resta su sfondo trasparente: perfetto come sticker.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var keySection: some View {
        SectionBox(title: "Rimozione del verde") {
            HStack {
                Circle()
                    .fill(Color(red: keyColor.r, green: keyColor.g, blue: keyColor.b))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white.opacity(0.5)))
                Text("Colore rilevato automaticamente").font(.subheadline)
                Spacer()
            }
            HStack {
                Text("Tolleranza")
                Slider(value: $settings.tolerance, in: 0.02...0.4, onEditingChanged: { editing in
                    if !editing { Task { await rekey() } }
                })
            }
            HStack {
                Text("Bordi morbidi")
                Slider(value: $settings.softness, in: 0.01...0.25, onEditingChanged: { editing in
                    if !editing { Task { await rekey() } }
                })
            }
            Text("Se resta del verde attorno, alza la tolleranza; se sparisce parte del soggetto, abbassala.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var positionSection: some View {
        SectionBox(title: "Posizione") {
            Picker("Trascina per", selection: $moveTarget) {
                ForEach(MoveTarget.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Zoom sfondo")
                Slider(value: $settings.backgroundScale, in: 0.3...4)
            }
            .disabled(background == nil)
            HStack {
                Text("Zoom template")
                Slider(value: $settings.templateScale, in: 0.3...3)
            }
            HStack {
                Button {
                    Task { await autoFrame() }
                } label: {
                    Label("Inquadra soggetto", systemImage: "viewfinder")
                }
                Spacer()
                Button("Reimposta") {
                    settings.backgroundScale = 1
                    settings.backgroundOffset = .zero
                    settings.templateScale = 1
                    settings.templateOffset = .zero
                }
            }
            .glassButton()
        }
    }

    private var timeSection: some View {
        SectionBox(title: "Tempo (video \(String(format: "%.1f", videoDuration))s)") {
            Text("Inizio: \(start, specifier: "%.1f")s").font(.subheadline)
            Slider(value: $start, in: 0...max(videoDuration - 0.5, 0.01), onEditingChanged: { editing in
                if !editing { Task { await loadTemplate(initial: false) } }
            })
            Text("Durata: \(length, specifier: "%.1f")s").font(.subheadline)
            Slider(value: $length, in: 0.5...max(min(10, videoDuration), 0.6), onEditingChanged: { editing in
                if !editing { Task { await loadTemplate(initial: false) } }
            })
            Text("Sticker animati e sticker con audio: massimo 10 secondi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var exportSection: some View {
        VStack(spacing: 10) {
            GlassGroup {
                VStack(spacing: 10) {
                    Button {
                        Task { await makeSticker() }
                    } label: {
                        Label("Crea sticker animato", systemImage: "face.smiling").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true, tint: .green)
                    .controlSize(.large)

                    Button {
                        Task { await makeVideo(save: true) }
                    } label: {
                        Label("Video con audio in Galleria", systemImage: "speaker.wave.2").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.large)

                    Button {
                        Task { await makeVideo(save: false) }
                    } label: {
                        Label("Condividi video con audio", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }
            .disabled(keyed == nil || working != nil)
            if background == nil {
                Picker("Sfondo del video", selection: $videoBackground) {
                    ForEach(SoundStickerView.Background.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Il video non può essere trasparente: senza immagine dietro usa questo colore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func loadTemplate(initial: Bool) async {
        do {
            if initial {
                videoDuration = try await MediaDecoder.videoDuration(job.file)
                length = min(5, max(0.5, videoDuration))
            }
            let clampedStart = min(start, max(0, videoDuration - 0.5))
            let end = min(videoDuration, clampedStart + length)
            let decoded = try await MediaDecoder.decodeVideo(job.file, start: clampedStart, end: end, fps: 12)
            raw = decoded
            if initial, let first = decoded.frames.first {
                keyColor = await Task.detached(priority: .userInitiated) {
                    GreenScreenCompositor.detectKeyColor(first)
                }.value
            }
            await rekey()
            if initial { await autoFrame() }
        } catch {
            loadError = "Impossibile leggere il video: \(error.localizedDescription)"
        }
    }

    private func rekey() async {
        guard let raw else { return }
        let color = keyColor, tolerance = settings.tolerance, softness = settings.softness
        keyed = await Task.detached(priority: .userInitiated) {
            GreenScreenCompositor.key(raw, color: color, tolerance: tolerance, softness: softness)
        }.value
    }

    /// Zooms on the subject so it fills the sticker.
    private func autoFrame() async {
        guard let keyed else { return }
        if let frame = await Task.detached(priority: .userInitiated, operation: { GreenScreenCompositor.autoFrame(keyed) }).value {
            settings.templateScale = frame.scale
            settings.templateOffset = frame.offset
        }
    }

    private func loadBackground(_ item: PhotosPickerItem) async {
        working = "Caricamento…"
        defer { working = nil; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let file = try Downloader.store(data)
            background = try await StickerPipeline.loadDefault(ImportItem(fileURL: file, sourceURL: nil, name: nil))
            moveTarget = .background
        } catch {
            message = error.localizedDescription
        }
    }

    private func composite() async -> DecodedMedia? {
        guard let keyed else { return nil }
        let back = background, current = settings
        return await Task.detached(priority: .userInitiated) {
            GreenScreenCompositor.composite(template: keyed, background: back, settings: current)
        }.value
    }

    /// Writes a high-quality animated WebP and opens it in the editor (text, outline, save to pack).
    private func makeSticker() async {
        working = "Creazione dello sticker…"
        defer { working = nil }
        guard let result = await composite() else { return }
        let file = await Task.detached(priority: .userInitiated) { () -> URL? in
            let durations = result.durations.map { max(20, Int(($0 * 1000).rounded())) }
            guard let data = WebPCodec.encodeAnimated(
                frames: result.frames, durationsMs: durations, quality: 90,
                width: StickerRenderer.canvas, height: StickerRenderer.canvas
            ) else { return nil }
            return try? Downloader.store(data)
        }.value
        guard let file else {
            message = "Creazione non riuscita."
            return
        }
        dismiss()
        app.openDelayed([ImportItem(fileURL: file, sourceURL: nil, name: job.name)])
    }

    private func makeVideo(save: Bool) async {
        working = "Creazione del video…"
        defer { working = nil }
        guard let result = await composite() else { return }
        do {
            let url = try await SoundStickerExporter.export(
                media: result, audioFile: job.file, audioStart: start, duration: length, background: videoBackground.color
            )
            if save {
                try await SoundStickerExporter.saveToPhotos(url)
                message = "Video salvato in Galleria: in WhatsApp crealo come sticker con audio."
            } else {
                shareItem = IdentifiableURL(url: url)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
