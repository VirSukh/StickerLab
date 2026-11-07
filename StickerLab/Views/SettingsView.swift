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

            Section {
                TextField("https://cobalt.tuodominio.com/", text: $cobaltURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                Text("Con un tuo server cobalt (ad esempio su AWS) l'app estrae media anche da Instagram, TikTok, X, Reddit, Tumblr e altri. Pinterest e 7TV funzionano anche senza.")
            }

            Section {
                Text("stickerlab://import?url=LINK")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Comandi Rapidi")
            } footer: {
                Text("Crea un Comando Rapido che riceve link dal menu Condividi e apre questo URL (con il link codificato): così puoi mandare un pin o un post a StickerLab direttamente dall'app Pinterest o da Safari.")
            }

            Section("Informazioni") {
                LabeledContent("Versione", value: version)
                LabeledContent("Pacchetti", value: "\(store.packs.count)")
                LabeledContent("Sticker", value: "\(store.packs.reduce(0) { $0 + $1.stickers.count })")
                LabeledContent("WhatsApp", value: WhatsAppExporter.isWhatsAppInstalled ? "Installato" : "Non trovato")
            }
        }
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
