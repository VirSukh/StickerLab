import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MediaPickerPayload: Identifiable {
    let id = UUID()
    let title: String
    let medias: [RemoteMedia]
    let packName: String?
}

struct ImportView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: PackStore

    enum ImporterMode { case media, backup }

    @State private var link = ""
    @State private var resolving = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importerPresented = false
    @State private var importerMode: ImporterMode = .media
    @State private var picker: MediaPickerPayload?
    @State private var browser: IdentifiableURL?
    @State private var shareItem: IdentifiableURL?
    @State private var showTransfer = false

    private static let wastickersType = UTType(filenameExtension: "wastickers") ?? .zip

    var body: some View {
        Form {
            if let id = app.preferredPackID, let pack = store.pack(id: id) {
                Section {
                    HStack {
                        Label("Pacchetto attivo: \(pack.name)", systemImage: "tray.and.arrow.down")
                        Spacer()
                        Button { app.preferredPackID = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .glassRows()
            }

            Section {
                TextField("Incolla un link: Pinterest, 7TV, GIF, sito…", text: $link, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                HStack {
                    Button {
                        link = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("Incolla", systemImage: "doc.on.clipboard")
                    }
                    .glassButton()
                    Spacer()
                    Button {
                        resolveLink()
                    } label: {
                        if resolving {
                            ProgressView()
                        } else {
                            Label("Estrai", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .glassButton(prominent: true)
                    .disabled(link.trimmed.isEmpty || resolving)
                }
                Button { openBrowser() } label: {
                    Label("Apri nel browser integrato", systemImage: "safari")
                }
            } header: {
                Text("Da link")
            } footer: {
                Text("Pinterest (foto, GIF, video, pin.it), 7TV (emote, set, utenti), link diretti e pagine con anteprima. Con un server cobalt configurato anche Instagram, TikTok, X, Reddit…")
            }
            .glassRows()

            Section("Dal telefono") {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                    Label("Galleria (foto, GIF, video)", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    presentImporter(.media)
                } label: {
                    Label("File (immagini, GIF, WebP, video)", systemImage: "folder")
                }
                Button {
                    showTransfer = true
                } label: {
                    Label("Ricevi dal PC (Wi-Fi)", systemImage: "desktopcomputer.and.arrow.down")
                }
            }
            .glassRows()

            Section {
                Button { exportAll() } label: {
                    Label("Esporta backup completo", systemImage: "square.and.arrow.up")
                }
                .disabled(store.packs.isEmpty)
                Button {
                    presentImporter(.backup)
                } label: {
                    Label("Importa backup (.zip) o .wastickers", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Il backup è un file .zip con tutti i pacchetti: salvalo su File o iCloud Drive. Puoi anche aprire un .zip o un .wastickers direttamente con StickerLab dal menu Condividi.")
            }
            .glassRows()
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Importa")
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .onChange(of: app.pendingLink) { _ in consumePendingLink() }
        .onAppear { consumePendingLink() }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: importerMode == .backup
                ? [.zip, .archive, Self.wastickersType]
                : [.image, .gif, .webP, .movie, .mpeg4Movie, .quickTimeMovie, .zip, Self.wastickersType, .data],
            allowsMultipleSelection: importerMode == .media
        ) { result in
            handleFiles(result)
        }
        .sheet(item: $picker) { payload in
            MediaPickerView(payload: payload) { selected in
                picker = nil
                downloadLater(selected, packName: payload.packName)
            }
        }
        .fullScreenCover(item: $browser) { entry in
            BrowserView(startURL: entry.url) { selected in
                browser = nil
                downloadLater(selected, packName: nil)
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .sheet(isPresented: $showTransfer) { TransferView() }
    }

    // MARK: Actions

    private func consumePendingLink() {
        guard let pending = app.pendingLink else { return }
        app.pendingLink = nil
        link = pending
        resolveLink()
    }

    private func resolveLink() {
        let input = link
        guard !input.trimmed.isEmpty else { return }
        resolving = true
        Task {
            do {
                let result = try await LinkResolver.resolve(input)
                resolving = false
                if result.medias.count == 1 {
                    await app.download(result.medias, packName: result.title)
                } else {
                    picker = MediaPickerPayload(
                        title: result.title ?? "\(result.medias.count) media trovati",
                        medias: result.medias,
                        packName: result.title
                    )
                }
            } catch {
                resolving = false
                app.alertMessage = error.localizedDescription
            }
        }
    }

    private func downloadLater(_ medias: [RemoteMedia], packName: String?) {
        guard !medias.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            await app.download(medias, packName: packName)
        }
    }

    private func openBrowser() {
        let url = LinkResolver.normalize(link) ?? URL(string: "https://www.pinterest.com/")!
        browser = IdentifiableURL(url: url)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        app.busyMessage = "Caricamento dalla galleria…"
        var imported: [ImportItem] = []
        for (index, item) in items.enumerated() {
            app.busyMessage = "Caricamento \(index + 1)/\(items.count)…"
            if let data = try? await item.loadTransferable(type: Data.self),
               let file = try? Downloader.store(data) {
                imported.append(ImportItem(fileURL: file, sourceURL: nil, name: "Galleria \(index + 1)"))
            }
        }
        photoItems = []
        app.busyMessage = nil
        if imported.isEmpty {
            app.alertMessage = "Impossibile caricare gli elementi selezionati."
        } else {
            app.open(imported)
        }
    }

    /// Sets the mode first and presents on the next turn: presenting in the same update
    /// can show the picker with the previous mode's file types / selection style.
    private func presentImporter(_ mode: ImporterMode) {
        importerMode = mode
        DispatchQueue.main.async { importerPresented = true }
    }

    /// One importer for everything: archives (.zip / .wastickers) are recognised by their content.
    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            app.logImport("✗ Selettore: \(error.localizedDescription)")
            app.alertLater(error.localizedDescription)
        case .success(let urls):
            app.logImport("Selezionati \(urls.count) file (\(importerMode == .backup ? "backup" : "media"))")
            var items: [ImportItem] = []
            var archives: [URL] = []
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let isArchive = importerMode == .backup || BackupManager.isArchive(url)
                app.logImport("\(url.lastPathComponent): \(isArchive ? "archivio" : "media"), accesso \(access ? "ok" : "non concesso")")
                do {
                    if isArchive {
                        // Copy while we have access: the import runs after the picker closes.
                        archives.append(try BackupManager.copyToTemporary(url))
                        app.logImport("Copia riuscita")
                    } else {
                        let copy = try Downloader.importLocalFile(url)
                        items.append(ImportItem(fileURL: copy, sourceURL: nil, name: url.lastPathComponent))
                    }
                } catch {
                    app.logImport("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !archives.isEmpty {
                app.importBackups(archives, store: store)
            } else if !items.isEmpty {
                if !failures.isEmpty { app.alertLater("\(failures.count) file non importati.\n" + failures.joined(separator: "\n")) }
                app.openDelayed(items)
            } else {
                app.alertLater(failures.isEmpty ? "Nessun file importato." : failures.joined(separator: "\n"))
            }
        }
    }

    private func exportAll() {
        do {
            shareItem = IdentifiableURL(url: try BackupManager.exportAll(store))
        } catch {
            app.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - Media picker

struct MediaPickerView: View {
    let payload: MediaPickerPayload
    let onConfirm: ([RemoteMedia]) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Tocca per selezionare, tieni premuto per salvare subito in un pacchetto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(payload.medias) { media in
                        RemoteMediaCell(media: media, selected: selected.contains(media.id))
                            .onTapGesture {
                                if selected.contains(media.id) { selected.remove(media.id) } else { selected.insert(media.id) }
                            }
                            .contextMenu {
                                QuickSaveMenu(
                                    media: media,
                                    newPackName: payload.packName ?? "Nuovo pacchetto",
                                    store: store,
                                    app: app
                                )
                            }
                    }
                }
                .padding()
            }
            .overlay {
                if let message = app.busyMessage { BusyOverlay(message: message) }
            }
            .overlay(alignment: .top) {
                if let toast = app.toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCapsule(tint: .green)
                        .padding(.top, 6)
                }
            }
            .appBackground()
            .keyboardDismissButton()
            .navigationTitle(payload.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.count == payload.medias.count ? "Nessuno" : "Tutti") {
                        if selected.count == payload.medias.count {
                            selected = []
                        } else {
                            selected = Set(payload.medias.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onConfirm(payload.medias.filter { selected.contains($0.id) })
                    } label: {
                        Text(selected.isEmpty ? "Seleziona i media" : "Importa \(selected.count)").bold()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct RemoteMediaCell: View {
    let media: RemoteMedia
    let selected: Bool

    var body: some View {
        ZStack {
            preview.padding(8)
        }
        .aspectRatio(1, contentMode: .fit)
        .glassCard(cornerRadius: 22, tint: selected ? .accentColor : nil, interactive: true)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let badge {
                Text(badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
    }

    private var badge: String? {
        switch media.kind {
        case .video: return "VIDEO"
        case .gif: return "GIF"
        case .animated: return "ANIM"
        default: return nil
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let url = media.previewURL {
            RemoteAnimatedImage(url: url, placeholderSymbol: media.kind == .video ? "play.rectangle.fill" : "photo")
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: media.kind == .video ? "play.rectangle.fill" : "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
    }
}
