import SwiftUI

/// Meme tab: Imgflip's popular templates. Tap one to open the editor with top/bottom meme text.
struct MemeTemplatesView: View {
    @EnvironmentObject private var app: AppState

    @State private var templates: [MemeTemplate] = []
    @State private var query = ""
    @State private var loading = false
    @State private var errorMessage: String?

    private var filtered: [MemeTemplate] {
        let text = query.trimmed.lowercased()
        guard !text.isEmpty else { return templates }
        return templates.filter { $0.name.lowercased().contains(text) }
    }

    var body: some View {
        ScrollView {
            if let errorMessage, templates.isEmpty {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Riprova") { Task { await load() } }.glassButton()
                }
                .padding(32)
                .glassCard(cornerRadius: 28)
                .padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                ForEach(filtered) { template in
                    Button {
                        open(template)
                    } label: {
                        VStack(spacing: 6) {
                            RemoteAnimatedImage(url: template.url)
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
                    .buttonStyle(.plain)
                }
            }
            .padding()
            if loading { ProgressView().padding() }
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Meme")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca un meme (es. Drake)")
        .task {
            if templates.isEmpty { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            templates = try await ImgflipAPI.templates()
            errorMessage = nil
        } catch {
            errorMessage = "Impossibile caricare i meme.\n\(error.localizedDescription)"
        }
    }

    private func open(_ template: MemeTemplate) {
        Task {
            app.busyMessage = "Download…"
            defer { app.busyMessage = nil }
            do {
                let media = RemoteMedia(url: template.url, previewURL: template.url, title: template.name, kind: .image, pageURL: "https://imgflip.com/meme/\(template.id)")
                let file = try await Downloader.download(media)
                app.editorItem = ImportItem(fileURL: file, sourceURL: media.pageURL, name: template.name, memeTemplate: true)
            } catch {
                app.alertMessage = error.localizedDescription
            }
        }
    }
}
