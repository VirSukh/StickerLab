import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Ricevi dal PC": shows the address / QR code of the local transfer page while the server runs.
struct TransferView: View {
    @EnvironmentObject private var store: PackStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var server = TransferServer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let address = server.address {
                        VStack(spacing: 14) {
                            Text("Sul PC apri nel browser")
                                .font(.headline)
                            Text(address)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .textSelection(.enabled)
                                .multilineTextAlignment(.center)
                            if let qr = Self.qrCode(address) {
                                Image(uiImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 180, height: 180)
                                    .padding(10)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                            }
                            Button {
                                UIPasteboard.general.string = address
                            } label: {
                                Label("Copia indirizzo", systemImage: "doc.on.doc")
                            }
                            .glassButton()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                        .glassCard(cornerRadius: 28)
                    } else if let error = server.errorText {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                            .padding(20)
                            .glassCard(cornerRadius: 24, tint: .orange)
                    } else {
                        ProgressView("Avvio…").padding(30)
                    }

                    SectionBox(title: "Come funziona") {
                        Label("iPhone e PC sulla stessa rete Wi-Fi", systemImage: "wifi")
                        Label("Sul PC scegli il pacchetto e trascina GIF, immagini o video", systemImage: "arrow.down.doc")
                        Label("Tieni StickerLab aperta su questa schermata durante l'invio", systemImage: "iphone")
                    }
                    .font(.subheadline)

                    SectionBox(title: "Ricevuti: \(server.received)") {
                        if server.events.isEmpty {
                            Text("In attesa di file dal PC…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(server.events.enumerated()), id: \.offset) { _, event in
                                Text(event)
                                    .font(.caption)
                                    .foregroundStyle(event.hasPrefix("✗") ? .red : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding()
            }
            .appBackground()
            .navigationTitle("Ricevi dal PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
        .onAppear {
            server.start(store: store)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            server.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
