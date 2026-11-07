import PencilKit
import SwiftUI

struct EditorView: View {
    let item: ImportItem
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultEmoji") private var defaultEmoji = "😀"

    enum Tab: String, CaseIterable, Identifiable {
        case image, text, draw, effects, time
        var id: String { rawValue }
        var label: String {
            switch self {
            case .image: return "Immagine"
            case .text: return "Testo"
            case .draw: return "Disegno"
            case .effects: return "Bordo"
            case .time: return "Tempo"
            }
        }
        var symbol: String {
            switch self {
            case .image: return "photo"
            case .text: return "textformat"
            case .draw: return "pencil.tip"
            case .effects: return "seal"
            case .time: return "timer"
            }
        }
    }

    private enum DragTarget {
        case image(CGSize)
        case layer(UUID, CGPoint)
    }

    // Media
    @State private var media: DecodedMedia?
    @State private var loadError: String?
    @State private var isVideo = false
    @State private var videoDuration: Double = 0
    @State private var videoStart: Double = 0
    @State private var videoLength: Double = 3
    @State private var reloadingVideo = false
    @State private var backgroundRemoved = false

    // Editing
    @State private var settings = EditSettings()
    @State private var tab: Tab = .image
    @State private var selectedLayerID: UUID?
    @State private var dragTarget: DragTarget?
    @State private var pinchBase: CGFloat?
    @State private var emojiText = ""

    // Drawing
    @State private var pkDrawing = PKDrawing()
    @State private var penColor: TextColorOption = .white
    @State private var penWidth: CGFloat = 8
    @State private var useMarker = false
    @State private var erasing = false
    @State private var canvasSide: CGFloat = 300

    // UI
    @State private var working: String?
    @State private var errorMessage: String?
    @State private var showPackPicker = false
    @State private var configured = false

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

    private var availableTabs: [Tab] {
        let animated = isVideo || (media?.isAnimated ?? false)
        return Tab.allCases.filter { $0 != .time || animated }
    }

    private var previewMedia: DecodedMedia? {
        guard let media else { return nil }
        if !isVideo, media.isAnimated, settings.trimEnd > 0 {
            return media.trimmed(start: settings.trimStart, end: settings.trimEnd)
        }
        return media
    }

    private var selectedIndex: Int? {
        settings.textLayers.firstIndex { $0.id == selectedLayerID }
    }

    private func editor(_ media: DecodedMedia) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                tabBar
                switch tab {
                case .image: imageSection
                case .text: textSection
                case .draw: drawSection
                case .effects: effectsSection(media)
                case .time: timeSection(media)
                }
                emojiSection
            }
            .padding()
        }
        .scrollDisabled(tab == .draw)
        .appBackground()
        .keyboardDismissButton()
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let side = geo.size.width - 12
            ZStack {
                Checkerboard()
                if let previewMedia {
                    AnimatedMediaView(media: previewMedia) { frame in
                        StickerRenderer.render(frame, settings, size: 384)
                    }
                }
                if tab == .text, let index = selectedIndex {
                    let rect = StickerRenderer.textRect(settings.textLayers[index])
                    let k = side / CGFloat(StickerRenderer.canvas)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: rect.width * k + 12, height: rect.height * k + 8)
                        .rotationEffect(.degrees(settings.textLayers[index].rotation))
                        .position(x: rect.midX * k, y: rect.midY * k)
                        .allowsHitTesting(false)
                }
                if tab == .draw {
                    DrawingCanvas(drawing: $pkDrawing, tool: currentTool)
                        .onAppear { canvasSide = side }
                }
                if reloadingVideo { ProgressView().controlSize(.large) }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(6)
            .glassCard(cornerRadius: 34)
            .contentShape(Rectangle())
            .gesture(dragGesture(side: side).simultaneously(with: pinchGesture), including: tab == .draw ? .subviews : .all)
            .onChange(of: pkDrawing.strokes.count) { _ in renderDrawing(side: side) }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let k = CGFloat(StickerRenderer.canvas) / max(side, 1)
                if dragTarget == nil {
                    let point = CGPoint(x: value.startLocation.x * k, y: value.startLocation.y * k)
                    if let layer = settings.textLayers.last(where: {
                        !$0.text.trimmed.isEmpty && StickerRenderer.textRect($0).insetBy(dx: -28, dy: -28).contains(point)
                    }) {
                        selectedLayerID = layer.id
                        if tab != .text { tab = .text }
                        dragTarget = .layer(layer.id, layer.center)
                    } else {
                        dragTarget = .image(settings.offset)
                    }
                }
                switch dragTarget {
                case .image(let origin):
                    settings.offset = CGSize(
                        width: origin.width + value.translation.width * k,
                        height: origin.height + value.translation.height * k
                    )
                case .layer(let id, let origin):
                    if let index = settings.textLayers.firstIndex(where: { $0.id == id }) {
                        let dx = value.translation.width / max(side, 1)
                        let dy = value.translation.height / max(side, 1)
                        settings.textLayers[index].center = CGPoint(
                            x: min(max(origin.x + dx, 0.05), 0.95),
                            y: min(max(origin.y + dy, 0.05), 0.95)
                        )
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in dragTarget = nil }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if tab == .text, let index = selectedIndex {
                    let base = pinchBase ?? settings.textLayers[index].size
                    if pinchBase == nil { pinchBase = base }
                    settings.textLayers[index].size = min(max(base * value, 16), 200)
                } else {
                    let base = pinchBase ?? settings.scale
                    if pinchBase == nil { pinchBase = base }
                    settings.scale = min(max(base * value, 0.2), 5)
                }
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(availableTabs) { item in
                        Button {
                            tab = item
                            hideKeyboard()
                        } label: {
                            Label(item.label, systemImage: item.symbol)
                                .font(.subheadline.weight(tab == item ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .foregroundStyle(tab == item ? Color.white : Color.primary)
                                .glassCapsule(tint: tab == item ? .accentColor : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Image

    private var imageSection: some View {
        SectionBox(title: "Immagine") {
            HStack {
                Text("Zoom")
                Slider(value: $settings.scale, in: 0.2...5)
            }
            HStack {
                Text("Rotazione")
                Slider(value: $settings.rotation, in: -180...180)
            }
            Toggle("Riempi tutto il riquadro", isOn: $settings.fill)
            HStack {
                Button { settings.rotation -= 90 } label: { Image(systemName: "rotate.left") }
                Button { settings.rotation += 90 } label: { Image(systemName: "rotate.right") }
                Button { settings.flipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Spacer()
                Button("Reimposta") {
                    settings.scale = 1
                    settings.offset = .zero
                    settings.rotation = 0
                    settings.fill = false
                    settings.flipped = false
                }
            }
            .glassButton()
            Text("Trascina e pizzica l'anteprima per spostare e ingrandire.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Text

    private var textSection: some View {
        SectionBox(title: "Testo") {
            HStack {
                Button {
                    var layer = TextLayer()
                    layer.center = CGPoint(x: 0.5, y: settings.textLayers.isEmpty ? 0.85 : 0.5)
                    settings.textLayers.append(layer)
                    selectedLayerID = layer.id
                } label: {
                    Label("Aggiungi testo", systemImage: "plus")
                }
                Button {
                    let top = TextLayer.memeTop(), bottom = TextLayer.memeBottom()
                    settings.textLayers.append(contentsOf: [top, bottom])
                    selectedLayerID = top.id
                } label: {
                    Label("Meme sopra/sotto", systemImage: "text.aligncenter")
                }
            }
            .glassButton()

            if !settings.textLayers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(settings.textLayers.enumerated()), id: \.element.id) { index, layer in
                            Button {
                                selectedLayerID = layer.id
                            } label: {
                                Text(layer.text.trimmed.isEmpty ? "Testo \(index + 1)" : layer.displayText)
                                    .lineLimit(1)
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(selectedLayerID == layer.id ? Color.white : Color.primary)
                                    .glassCapsule(tint: selectedLayerID == layer.id ? .accentColor : nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let index = selectedIndex {
                layerEditor(index)
            } else if settings.textLayers.isEmpty {
                Text("Aggiungi un testo o il formato meme classico. Puoi trascinare le scritte direttamente sull'anteprima.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func layerEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Scrivi qui…", text: $settings.textLayers[index].text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            Text("Font").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerFont.allCases) { font in
                        let active = settings.textLayers[index].font == font
                        Button {
                            settings.textLayers[index].font = font
                        } label: {
                            Text(font.label)
                                .font(Font(font.uiFont(size: 17) as CTFont))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .glassCapsule(tint: active ? .accentColor : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Colore").font(.caption).foregroundStyle(.secondary)
            colorRow(selection: $settings.textLayers[index].color)
            Text("Contorno").font(.caption).foregroundStyle(.secondary)
            colorRow(selection: $settings.textLayers[index].strokeColor)

            HStack {
                Text("Dimensione")
                Slider(value: $settings.textLayers[index].size, in: 16...200)
            }
            HStack {
                Text("Contorno")
                Slider(value: $settings.textLayers[index].strokeWidth, in: 0...30)
            }
            HStack {
                Text("Rotazione")
                Slider(value: $settings.textLayers[index].rotation, in: -45...45)
            }
            Toggle("TUTTO MAIUSCOLO", isOn: $settings.textLayers[index].uppercase)
            Button(role: .destructive) {
                let id = settings.textLayers[index].id
                settings.textLayers.removeAll { $0.id == id }
                selectedLayerID = settings.textLayers.last?.id
            } label: {
                Label("Elimina questo testo", systemImage: "trash")
            }
            .glassButton()
        }
    }

    private func colorRow(selection: Binding<TextColorOption>) -> some View {
        HStack(spacing: 10) {
            ForEach(TextColorOption.allCases) { option in
                Circle()
                    .fill(Color(uiColor: option.color))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle().stroke(
                            selection.wrappedValue == option ? Color.accentColor : Color.gray.opacity(0.5),
                            lineWidth: selection.wrappedValue == option ? 3 : 1
                        )
                    )
                    .onTapGesture { selection.wrappedValue = option }
            }
        }
    }

    // MARK: Draw

    private var currentTool: PKTool {
        if erasing { return PKEraserTool(.vector) }
        return PKInkingTool(useMarker ? .marker : .pen, color: penColor.color, width: penWidth)
    }

    private var drawSection: some View {
        SectionBox(title: "Disegno") {
            colorRow(selection: $penColor)
            HStack {
                Text("Spessore")
                Slider(value: $penWidth, in: 2...40)
            }
            Picker("Strumento", selection: Binding(
                get: { erasing ? 2 : (useMarker ? 1 : 0) },
                set: { erasing = $0 == 2; useMarker = $0 == 1 }
            )) {
                Text("Penna").tag(0)
                Text("Evidenziatore").tag(1)
                Text("Gomma").tag(2)
            }
            .pickerStyle(.segmented)
            HStack {
                Button {
                    var strokes = pkDrawing.strokes
                    if !strokes.isEmpty { strokes.removeLast() }
                    pkDrawing = PKDrawing(strokes: strokes)
                } label: { Label("Annulla tratto", systemImage: "arrow.uturn.backward") }
                .disabled(pkDrawing.strokes.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    pkDrawing = PKDrawing()
                } label: { Label("Cancella", systemImage: "trash") }
                .disabled(pkDrawing.strokes.isEmpty)
            }
            .glassButton()
            Text("Disegna con il dito direttamente sull'anteprima. Il disegno resta sopra tutti i fotogrammi delle animazioni.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func renderDrawing(side: CGFloat) {
        guard !pkDrawing.strokes.isEmpty else {
            settings.drawing = nil
            return
        }
        let size = max(side, 1)
        var image: UIImage?
        // Render with light traits so the colors are exactly the ones chosen.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = pkDrawing.image(
                from: CGRect(x: 0, y: 0, width: size, height: size),
                scale: CGFloat(StickerRenderer.canvas) / size
            )
        }
        settings.drawing = image?.cgImage
    }

    // MARK: Effects

    private func effectsSection(_ media: DecodedMedia) -> some View {
        VStack(spacing: 14) {
            SectionBox(title: "Bordo sticker") {
                Toggle("Contorno attorno allo sticker", isOn: $settings.outline)
                if settings.outline {
                    HStack {
                        Text("Spessore")
                        Slider(value: $settings.outlineWidth, in: 2...24)
                    }
                    colorRow(selection: $settings.outlineColor)
                    Text("Se il bordo viene tagliato ai lati, rimpicciolisci un po' l'immagine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SectionBox(title: "Sfondo") {
                if #available(iOS 17.0, *) {
                    Button {
                        Task { await removeBackground() }
                    } label: {
                        Label(backgroundRemoved ? "Sfondo rimosso" : "Rimuovi sfondo automaticamente", systemImage: "wand.and.stars")
                    }
                    .glassButton(prominent: true)
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
    }

    // MARK: Time

    @ViewBuilder
    private func timeSection(_ media: DecodedMedia) -> some View {
        if isVideo {
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
        } else {
            let total = media.totalDuration
            let end = settings.trimEnd > 0 ? settings.trimEnd : total
            SectionBox(title: "Animazione (\(media.frames.count) fotogrammi, \(String(format: "%.1f", total))s)") {
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
        if !configured {
            configured = true
            if emojiText.isEmpty { emojiText = defaultEmoji }
            if item.memeTemplate {
                let top = TextLayer.memeTop(), bottom = TextLayer.memeBottom()
                settings.textLayers = [top, bottom]
                selectedLayerID = top.id
                tab = .text
            }
        }
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

/// PencilKit canvas over the preview (transparent, true colors).
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawing = drawing
        canvas.tool = tool
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = tool
        // Undo / clear from the buttons: push the new drawing into the canvas.
        if canvas.drawing.strokes.count != drawing.strokes.count {
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        init(_ parent: DrawingCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
