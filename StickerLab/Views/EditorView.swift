import SwiftUI

struct EditorView: View {
    let item: ImportItem
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultEmoji") private var defaultEmoji = "😀"

    @State private var media: DecodedMedia?
    @State private var loadError: String?
    @State private var isVideo = false
    @State private var videoDuration: Double = 0
    @State private var videoStart: Double = 0
    @State private var videoLength: Double = 3
    @State private var reloadingVideo = false
    @State private var backgroundRemoved = false

    @State private var settings = EditSettings()
    @State private var baseScale: CGFloat = 1
    @State private var dragOrigin: CGSize?
    @State private var emojiText = ""

    @State private var working: String?
    @State private var errorMessage: String?
    @State private var showPackPicker = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Editor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Salva") { showPackPicker = true }
                            .bold()
                            .disabled(media == nil || working != nil || reloadingVideo)
                    }
                }
                .sheet(isPresented: $showPackPicker) {
                    PackPickerView(suggestedAnimated: media?.isAnimated ?? false) { id in save(to: id) }
                        .environmentObject(store)
                        .environmentObject(app)
                }
                .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
                .overlay {
                    if let working { BusyOverlay(message: working) }
                }
        }
        .interactiveDismissDisabled(working != nil)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let media {
            editor(media)
        } else if let loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(loadError).multilineTextAlignment(.center)
            }
            .padding()
        } else {
            ProgressView("Caricamento…")
        }
    }

    private var previewMedia: DecodedMedia? {
        guard let media else { return nil }
        if !isVideo, media.isAnimated, settings.trimEnd > 0 {
            return media.trimmed(start: settings.trimStart, end: settings.trimEnd)
        }
        return media
    }

    private func editor(_ media: DecodedMedia) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                if isVideo {
                    videoSection
                } else if media.isAnimated {
                    animationSection(media)
                }
                transformSection
                textSection
                backgroundSection(media)
                emojiSection
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Checkerboard()
                if let previewMedia {
                    AnimatedMediaView(media: previewMedia) { frame in
                        StickerRenderer.render(frame, settings, size: 384)
                    }
                }
                if reloadingVideo { ProgressView().controlSize(.large) }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.3)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let origin = dragOrigin ?? settings.offset
                        if dragOrigin == nil { dragOrigin = origin }
                        let k = CGFloat(StickerRenderer.canvas) / max(side, 1)
                        settings.offset = CGSize(
                            width: origin.width + value.translation.width * k,
                            height: origin.height + value.translation.height * k
                        )
                    }
                    .onEnded { _ in dragOrigin = nil }
                    .simultaneously(with:
                        MagnificationGesture()
                            .onChanged { value in settings.scale = min(max(baseScale * value, 0.2), 5) }
                            .onEnded { _ in baseScale = settings.scale }
                    )
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Sections

    private var videoSection: some View {
        SectionBox(title: "Video (\(String(format: "%.1f", videoDuration))s)") {
            Text("Inizio: \(videoStart, specifier: "%.1f")s").font(.subheadline)
            Slider(value: $videoStart, in: 0...max(videoDuration - 0.3, 0.01), onEditingChanged: { editing in
                if !editing { Task { await reloadVideo() } }
            })
            Text("Durata: \(videoLength, specifier: "%.1f")s").font(.subheadline)
            Slider(value: $videoLength, in: 0.5...max(min(10, videoDuration), 0.6), onEditingChanged: { editing in
                if !editing { Task { await reloadVideo() } }
            })
            Text("WhatsApp accetta animazioni fino a 10 s e 500 KB: per una buona qualità conviene 2–5 secondi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func animationSection(_ media: DecodedMedia) -> some View {
        let total = media.totalDuration
        let end = settings.trimEnd > 0 ? settings.trimEnd : total
        return SectionBox(title: "Animazione (\(media.frames.count) fotogrammi, \(String(format: "%.1f", total))s)") {
            Text("Inizio: \(settings.trimStart, specifier: "%.1f")s").font(.subheadline)
            Slider(value: $settings.trimStart, in: 0...max(total, 0.1))
            Text("Fine: \(end, specifier: "%.1f")s").font(.subheadline)
            Slider(value: Binding(get: { end }, set: { settings.trimEnd = $0 }), in: 0...max(total, 0.1))
            if total > StickerEncoder.maxDuration {
                Text("WhatsApp accetta al massimo 10 secondi: il resto verrà tagliato.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var transformSection: some View {
        SectionBox(title: "Posizione") {
            HStack {
                Text("Zoom")
                Slider(value: Binding(get: { settings.scale }, set: { settings.scale = $0; baseScale = $0 }), in: 0.2...5)
            }
            HStack {
                Text("Rotazione")
                Slider(value: $settings.rotation, in: -180...180)
            }
            Toggle("Riempi tutto il riquadro", isOn: $settings.fill)
            HStack {
                Button { settings.rotation -= 90 } label: { Image(systemName: "rotate.left") }
                Button { settings.rotation += 90 } label: { Image(systemName: "rotate.right") }
                Spacer()
                Button("Reimposta") {
                    settings.scale = 1
                    baseScale = 1
                    settings.offset = .zero
                    settings.rotation = 0
                    settings.fill = false
                }
            }
            .buttonStyle(.bordered)
            Text("Trascina e pizzica l'anteprima per spostare e ingrandire.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        SectionBox(title: "Testo") {
            TextField("Scritta (opzionale)", text: $settings.text)
                .textFieldStyle(.roundedBorder)
            Picker("Posizione", selection: $settings.textPosition) {
                ForEach(TextPosition.allCases) { position in Text(position.label).tag(position) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                ForEach(TextColorOption.allCases) { option in
                    Circle()
                        .fill(Color(uiColor: option.fill))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(
                                settings.textColor == option ? Color.accentColor : Color.gray.opacity(0.5),
                                lineWidth: settings.textColor == option ? 3 : 1
                            )
                        )
                        .onTapGesture { settings.textColor = option }
                }
            }
            HStack {
                Text("Dimensione")
                Slider(value: $settings.textSize, in: 24...160)
            }
        }
    }

    private func backgroundSection(_ media: DecodedMedia) -> some View {
        SectionBox(title: "Sfondo") {
            if #available(iOS 17.0, *) {
                Button {
                    Task { await removeBackground() }
                } label: {
                    Label(backgroundRemoved ? "Sfondo rimosso" : "Rimuovi sfondo automaticamente", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(backgroundRemoved)
                if media.isAnimated {
                    Text("Su GIF e video viene applicato a ogni fotogramma: può richiedere qualche secondo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("La rimozione automatica dello sfondo richiede iOS 17.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emojiSection: some View {
        SectionBox(title: "Emoji") {
            TextField("😀", text: $emojiText)
                .textFieldStyle(.roundedBorder)
            Text("Fino a 3 emoji: WhatsApp le usa per suggerire lo sticker.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func load() async {
        guard media == nil, loadError == nil else { return }
        if emojiText.isEmpty { emojiText = defaultEmoji }
        let url = item.fileURL
        do {
            if MediaDecoder.sniff(url) == .video {
                isVideo = true
                videoDuration = try await MediaDecoder.videoDuration(url)
                videoLength = min(3, max(0.5, videoDuration))
                media = try await MediaDecoder.decodeVideo(url, start: 0, end: videoLength)
            } else {
                media = try await Task.detached(priority: .userInitiated) {
                    try MediaDecoder.decodeImage(at: url)
                }.value
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadVideo() async {
        guard isVideo else { return }
        reloadingVideo = true
        defer { reloadingVideo = false }
        let start = min(videoStart, max(0, videoDuration - 0.3))
        let end = min(videoDuration, start + videoLength)
        do {
            var decoded = try await MediaDecoder.decodeVideo(item.fileURL, start: start, end: end)
            if backgroundRemoved {
                if #available(iOS 17.0, *) {
                    let source = decoded
                    if let cut = await Task.detached(priority: .userInitiated, operation: { BackgroundRemover.apply(to: source) }).value {
                        decoded = cut
                    }
                }
            }
            media = decoded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @available(iOS 17.0, *)
    private func removeBackground() async {
        guard let source = media else { return }
        working = "Rimozione sfondo…"
        let result = await Task.detached(priority: .userInitiated) { BackgroundRemover.apply(to: source) }.value
        working = nil
        if let result {
            media = result
            backgroundRemoved = true
        } else {
            errorMessage = "Non ho trovato un soggetto da ritagliare in questa immagine."
        }
    }

    private func save(to packID: UUID) {
        guard let media, let pack = store.pack(id: packID) else { return }
        var finalSettings = settings
        if isVideo {
            finalSettings.trimStart = 0
            finalSettings.trimEnd = 0
        }
        let animated = pack.animated
        let emojis = EmojiParser.parse(emojiText)
        let source = item.sourceURL
        working = animated ? "Creazione sticker animato…\nPuò richiedere qualche secondo." : "Creazione sticker…"
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try StickerPipeline.makeSticker(from: media, settings: finalSettings, animated: animated)
                }.value
                try store.addSticker(data: data, animated: animated, emojis: emojis, source: source, to: packID)
                working = nil
                app.preferredPackID = packID
                dismiss()
            } catch {
                working = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
