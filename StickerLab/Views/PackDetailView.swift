import SwiftUI

struct PackDetailView: View {
    let packID: UUID
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showEdit = false
    @State private var shareItem: IdentifiableURL?
    @State private var previewSticker: Sticker?
    @State private var emojiSticker: Sticker?
    @State private var emojiInput = ""
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var working: String?
    @State private var problemReport: ProblemReport?
    @State private var invalidIDs: Set<UUID> = []

    struct ProblemReport: Identifiable {
        let id = UUID()
        let problems: [StickerProblem]
    }

    var body: some View {
        if let pack = store.pack(id: packID) {
            content(pack)
        } else {
            Text("Pacchetto eliminato").foregroundStyle(.secondary)
        }
    }

    private func content(_ pack: StickerPack) -> some View {
        let problems = WhatsAppExporter.problems(for: pack, store: store)
        return ScrollView {
            VStack(spacing: 16) {
                header(pack)

                Button {
                    Task { await checkAndSend(pack) }
                } label: {
                    Label("Aggiungi a WhatsApp", systemImage: "paperplane.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassButton(prominent: true, tint: .green)
                .controlSize(.large)
                .disabled(!problems.isEmpty)

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle").font(.caption.weight(.medium))
                        }
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(cornerRadius: 20, tint: .orange)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(Array(pack.stickers.enumerated()), id: \.element.id) { index, sticker in
                        stickerCell(sticker, pack: pack, isTray: index == 0)
                    }
                    if !pack.isFull {
                        Button {
                            app.preferredPackID = pack.id
                            app.selectedTab = .importer
                        } label: {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(.secondary))
                                .glassCard(cornerRadius: 22, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Tieni premuto uno sticker per emoji, icona o eliminazione. Il primo sticker è l'icona del pacchetto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .appBackground()
        .navigationTitle(pack.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showEdit = true } label: { Label("Modifica nome e autore", systemImage: "pencil") }
                    Button {
                        app.preferredPackID = pack.id
                        app.selectedTab = .importer
                    } label: { Label("Aggiungi sticker", systemImage: "plus") }
                    Divider()
                    Button { share { try BackupManager.export([pack], store: store, name: pack.name) } } label: {
                        Label("Backup del pacchetto (.zip)", systemImage: "archivebox")
                    }
                    Button { share { try BackupManager.exportWAStickers(pack, store: store) } } label: {
                        Label("Esporta .wastickers (Android)", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina pacchetto", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay { if let working { BusyOverlay(message: working) } }
        .sheet(item: $problemReport) { report in
            ProblemsSheet(
                pack: pack,
                problems: report.problems,
                onRepair: { problemReport = nil; Task { await repair(report.problems, pack: pack) } },
                onRemove: {
                    problemReport = nil
                    report.problems.forEach { store.deleteSticker($0.id, from: pack.id) }
                    invalidIDs = []
                }
            )
        }
        .sheet(isPresented: $showEdit) { PackFormView(pack: pack) }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .sheet(item: $previewSticker) { sticker in StickerPreviewView(url: store.fileURL(for: sticker, in: pack)) }
        .alert("Emoji dello sticker", isPresented: Binding(get: { emojiSticker != nil }, set: { if !$0 { emojiSticker = nil } })) {
            TextField("😀🔥", text: $emojiInput)
            Button("Salva") {
                if let sticker = emojiSticker {
                    store.setEmojis(EmojiParser.parse(emojiInput), for: sticker.id, in: pack.id)
                }
                emojiSticker = nil
            }
            Button("Annulla", role: .cancel) { emojiSticker = nil }
        } message: {
            Text("Fino a 3 emoji: WhatsApp le usa per suggerire lo sticker.")
        }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Eliminare il pacchetto \"\(pack.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                store.deletePack(id: pack.id)
                dismiss()
            }
        }
    }

    private func header(_ pack: StickerPack) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if let tray = store.trayURL(for: pack) { StickerThumbnail(url: tray).padding(8) }
            }
            .frame(width: 76, height: 76)
            .glassCard(cornerRadius: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(pack.name).font(.title3.weight(.bold))
                Text(pack.publisher).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("\(pack.stickers.count)/\(StickerPack.maxStickers)")
                    Label(pack.animated ? "Animato" : "Statico", systemImage: pack.animated ? "play.circle" : "photo")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassCapsule()
            }
            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 30)
    }

    private func stickerCell(_ sticker: Sticker, pack: StickerPack, isTray: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            StickerThumbnail(url: store.fileURL(for: sticker, in: pack))
                .padding(10)
                .aspectRatio(1, contentMode: .fit)
            if isTray {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).padding(8)
            }
            if invalidIDs.contains(sticker.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(sticker.emojis.joined())
                .font(.caption2)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .aspectRatio(1, contentMode: .fit)
        .glassCard(cornerRadius: 22, interactive: true)
        .contentShape(Rectangle())
        .onTapGesture { previewSticker = sticker }
        .contextMenu {
            Button {
                emojiInput = sticker.emojis.joined()
                emojiSticker = sticker
            } label: { Label("Modifica emoji", systemImage: "face.smiling") }
            if !isTray {
                Button { store.makeFirst(sticker.id, in: pack.id) } label: {
                    Label("Usa come icona del pacchetto", systemImage: "star")
                }
            }
            Button(role: .destructive) { store.deleteSticker(sticker.id, from: pack.id) } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
    }

    private func share(_ make: () throws -> URL) {
        do { shareItem = IdentifiableURL(url: try make()) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: WhatsApp

    private func stickerFiles(_ pack: StickerPack) -> [(UUID, URL)] {
        pack.stickers.map { ($0.id, store.fileURL(for: $0, in: pack)) }
    }

    /// Validates every sticker with WhatsApp's rules before sending.
    private func checkAndSend(_ pack: StickerPack) async {
        working = "Controllo degli sticker…"
        let problems = await StickerValidator.check(files: stickerFiles(pack), packAnimated: pack.animated)
        working = nil
        invalidIDs = Set(problems.map(\.id))
        if problems.isEmpty {
            send(pack)
        } else {
            problemReport = ProblemReport(problems: problems)
        }
    }

    private func repair(_ problems: [StickerProblem], pack: StickerPack) async {
        var failures: [String] = []
        for (index, problem) in problems.enumerated() {
            working = "Riparazione \(index + 1)/\(problems.count)…"
            guard let current = store.pack(id: pack.id),
                  let sticker = current.stickers.first(where: { $0.id == problem.id }) else { continue }
            do {
                let data = try Data(contentsOf: store.fileURL(for: sticker, in: current))
                let fixed = try await StickerValidator.repair(data, packAnimated: current.animated)
                try store.replaceSticker(problem.id, in: current.id, with: fixed)
            } catch {
                failures.append("Sticker \(problem.position): \(error.localizedDescription)")
            }
        }
        working = nil
        guard let updated = store.pack(id: pack.id) else { return }
        if failures.isEmpty {
            await checkAndSend(updated)
        } else {
            errorMessage = "Alcuni sticker non si possono riparare: eliminali e reimportali.\n" + failures.joined(separator: "\n")
        }
    }

    private func send(_ pack: StickerPack) {
        do { try WhatsAppExporter.send(pack, store: store) } catch { errorMessage = error.localizedDescription }
    }
}

/// Lists stickers that WhatsApp would reject, with automatic repair.
struct ProblemsSheet: View {
    let pack: StickerPack
    let problems: [StickerProblem]
    let onRepair: () -> Void
    let onRemove: () -> Void
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("WhatsApp rifiuterebbe \(problems.count == 1 ? "questo sticker" : "questi \(problems.count) sticker"). La riparazione li ricodifica secondo le regole del pacchetto (\(pack.animated ? "animato" : "statico")).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(problems) { problem in
                        HStack(alignment: .top, spacing: 12) {
                            if let sticker = pack.stickers.first(where: { $0.id == problem.id }) {
                                StickerThumbnail(url: store.fileURL(for: sticker, in: pack))
                                    .frame(width: 56, height: 56)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sticker \(problem.position)").font(.headline)
                                ForEach(problem.reasons, id: \.self) { reason in
                                    Label(reason, systemImage: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 20)
                    }
                    GlassGroup {
                        VStack(spacing: 10) {
                            Button(action: onRepair) {
                                Label("Ripara e invia a WhatsApp", systemImage: "wrench.and.screwdriver.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .glassButton(prominent: true, tint: .green)
                            .controlSize(.large)
                            Button(role: .destructive, action: onRemove) {
                                Label("Elimina questi sticker", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .glassButton()
                            .controlSize(.large)
                        }
                    }
                }
                .padding()
            }
            .appBackground()
            .navigationTitle("Sticker non validi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
        }
    }
}

struct StickerPreviewView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var media: DecodedMedia?
    @State private var size = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Checkerboard()
                    if let media { AnimatedMediaView(media: media) } else { ProgressView() }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                if let media {
                    Text("\(media.frames.count) fotogrammi · \(formatBytes(size)) · 512×512")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .appBackground()
            .navigationTitle("Anteprima")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let data = try? Data(contentsOf: url) else { return }
            size = data.count
            media = await Task.detached { WebPCodec.decode(data) }.value
        }
    }
}
