import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PackStore
    @AppStorage("defaultPublisher") private var defaultPublisher = ""
    @AppStorage("defaultEmoji") private var defaultEmoji = "😀"
    @AppStorage(CobaltClient.urlKey) private var cobaltURL = ""
    @AppStorage(CobaltClient.apiKeyKey) private var cobaltKey = ""

    @State private var testResult: String?
    @State private var testing = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Predefiniti") {
                TextField("Autore dei pacchetti", text: $defaultPublisher)
                TextField("Emoji predefinita", text: $defaultEmoji)
            }
            .glassRows()

            Section {
                HStack {
                    TextField("https://…trycloudflare.com/", text: $cobaltURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let text = UIPasteboard.general.string?.trimmed, !text.isEmpty {
                            cobaltURL = text
                            testResult = nil
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
                SecureField("API key (facoltativa)", text: $cobaltKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Prova connessione")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(cobaltURL.trimmed.isEmpty || testing)
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Server cobalt (facoltativo)")
            } footer: {
                Text("Con un tuo server cobalt l'app estrae media anche da Instagram, TikTok, X, Reddit, Tumblr e altri. Pinterest e 7TV funzionano anche senza.")
            }
            .glassRows()

            Section {
                Label("Nell'app (Instagram, TikTok, Pinterest, Safari…) tocca Condividi", systemImage: "square.and.arrow.up")
                Label("Scorri le app e scegli StickerLab", systemImage: "app.badge")
                Label("Se non c'è: tocca Altro e attiva StickerLab", systemImage: "plus.circle")
            } header: {
                Text("Condividi da altre app")
            } footer: {
                Text("StickerLab si apre ed estrae il media in automatico.")
            }
            .font(.subheadline)
            .glassRows()

            Section("Informazioni") {
                LabeledContent("Versione", value: version)
                LabeledContent("Pacchetti", value: "\(store.packs.count)")
                LabeledContent("Sticker", value: "\(store.packs.reduce(0) { $0 + $1.stickers.count })")
                LabeledContent("WhatsApp", value: WhatsAppExporter.isWhatsAppInstalled ? "Installato" : "Non trovato")
            }
            .glassRows()
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Impostazioni")
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            testResult = try await CobaltClient.testConnection()
        } catch {
            testResult = "Errore: \(error.localizedDescription)"
        }
    }
}
