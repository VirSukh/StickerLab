import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState
    @AppStorage("defaultPublisher") private var defaultPublisher = ""
    @AppStorage("defaultEmoji") private var defaultEmoji = "😀"
    @AppStorage(CobaltClient.urlKey) private var cobaltURL = ""
    @AppStorage(CobaltClient.apiKeyKey) private var cobaltKey = ""
    @AppStorage(GiphyAPI.keyKey) private var giphyKey = ""

    @State private var showWhatsNew = false
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

            Section {
                HStack {
                    SecureField("Chiave API GIPHY", text: $giphyKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let text = UIPasteboard.general.string?.trimmed, !text.isEmpty { giphyKey = text }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
                Link(destination: URL(string: "https://developers.giphy.com/dashboard/")!) {
                    Label("Crea una chiave gratuita", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("GIPHY")
            } footer: {
                Text("Serve per le fonti GIF e Sticker nella scheda Emote. Sul sito: Create an App → API → copia la API Key.")
            }
            .glassRows()

            Section {
                if app.importLog.isEmpty {
                    Text("Ancora nessuna importazione in questa sessione.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(app.importLog.prefix(25).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.contains("✗") ? .red : .primary)
                    }
                    Button {
                        UIPasteboard.general.string = app.importLog.joined(separator: "\n")
                    } label: {
                        Label("Copia registro", systemImage: "doc.on.doc")
                    }
                }
            } header: {
                Text("Registro importazione")
            } footer: {
                Text("Se un'importazione non funziona, fai uno screenshot di questa sezione.")
            }
            .glassRows()

            Section("Informazioni") {
                LabeledContent("Versione", value: version)
                Button {
                    showWhatsNew = true
                } label: {
                    Label("Novità", systemImage: "sparkles")
                }
                LabeledContent("Pacchetti", value: "\(store.packs.count)")
                LabeledContent("Sticker", value: "\(store.packs.reduce(0) { $0 + $1.stickers.count })")
                LabeledContent("WhatsApp", value: WhatsAppExporter.isWhatsAppInstalled ? "Installato" : "Non trovato")
            }
            .glassRows()
        }
        .appBackground()
        .keyboardDismissButton()
        .navigationTitle("Impostazioni")
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
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
