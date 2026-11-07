import UIKit
import UniformTypeIdentifiers

/// "Condividi → StickerLab": takes the shared link and opens the app with
/// `stickerlab://import?url=…`, where it is extracted automatically.
final class ShareViewController: UIViewController {
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { await handle() }
    }

    private func handle() async {
        guard let link = await findLink(),
              var components = URLComponents(string: "stickerlab://import") else {
            showMessage("Nessun link trovato in questo contenuto.")
            return
        }
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        if let url = components.url, openContainingApp(url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.finish() }
        } else {
            UIPasteboard.general.string = link
            showMessage("Link copiato. Apri StickerLab e premi Incolla.")
        }
    }

    // MARK: - Reading the shared content

    private func findLink() async -> String? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = value as? URL,
                   !url.isFileURL {
                    return url.absoluteString
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let text = value as? String,
                   let link = firstLink(in: text) {
                    return link
                }
            }
            if let text = item.attributedContentText?.string, let link = firstLink(in: text) {
                return link
            }
        }
        return nil
    }

    private func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap { $0.url }
            .first { $0.scheme?.hasPrefix("http") == true }?
            .absoluteString
    }

    // MARK: - Opening the app

    /// Extensions cannot use UIApplication.shared: find the application in the responder chain.
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: "StickerLab", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.finish() })
        present(alert, animated: true)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
