import SwiftUI
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    let webView: WKWebView
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var canGoBack = false
    private var observations: [NSKeyValueObservation] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Downloader.userAgent
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.currentURL = view.url }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Collects images and videos currently in the page.
    func scanMedia() async -> [RemoteMedia] {
        let value: Any? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Self.scanScript) { result, _ in
                continuation.resume(returning: result)
            }
        }
        guard let entries = value as? [String] else { return [] }
        let page = currentURL?.absoluteString
        return entries.compactMap { entry -> RemoteMedia? in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
            if parts[0] == "V" { return RemoteMedia(url: url, kind: .video, pageURL: page) }
            return RemoteMedia.image(url, pageURL: page)
        }
    }

    private static let scanScript = """
    (function() {
      var out = [], seen = {};
      function add(kind, u) {
        if (!u || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
        try { u = new URL(u, location.href).href; } catch (e) { return; }
        if (seen[u]) return;
        seen[u] = 1;
        out.push(kind + '|' + u);
      }
      document.querySelectorAll('video').forEach(function(v) {
        add('V', v.currentSrc); add('V', v.src);
        v.querySelectorAll('source').forEach(function(s) { add('V', s.src); });
      });
      document.querySelectorAll('img').forEach(function(i) {
        var best = i.currentSrc || i.src;
        if (i.srcset) {
          var parts = i.srcset.split(',').map(function(s) { return s.trim().split(/\\s+/); });
          var last = parts[parts.length - 1];
          if (last && last[0]) best = last[0];
        }
        if ((i.naturalWidth || 0) >= 80 || (i.width || 0) >= 80) add('I', best);
      });
      document.querySelectorAll('meta[property="og:image"],meta[name="twitter:image"]').forEach(function(m) { add('I', m.content); });
      document.querySelectorAll('meta[property="og:video"],meta[property="og:video:url"]').forEach(function(m) { add('V', m.content); });
      return out.slice(0, 300);
    })();
    """
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct BrowserView: View {
    let startURL: URL
    let onPick: ([RemoteMedia]) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()
    @State private var address = ""
    @State private var picker: MediaPickerPayload?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Indirizzo o link", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { go() }
                    if model.isLoading { ProgressView() }
                }
                .padding(8)
                WebViewContainer(webView: model.webView)
            }
            .keyboardDismissButton()
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack)
                    Spacer()
                    Button { Task { await extractPage() } } label: {
                        Label("Estrai da questa pagina", systemImage: "wand.and.rays")
                    }
                    Spacer()
                    Button { Task { await scanPage() } } label: {
                        Label("Media nella pagina", systemImage: "photo.stack")
                    }
                }
            }
            .sheet(item: $picker) { payload in
                MediaPickerView(payload: payload) { selected in
                    picker = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onPick(selected) }
                }
            }
            .overlay { if working { BusyOverlay(message: "Ricerca media…") } }
            .alert("Browser", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if model.webView.url == nil {
                    model.load(startURL)
                    address = startURL.absoluteString
                }
            }
            .onChange(of: model.currentURL) { url in
                if let url { address = url.absoluteString }
            }
        }
    }

    private func go() {
        let text = address.trimmed
        if let url = LinkResolver.normalize(text), text.contains(".") {
            model.load(url)
        } else if let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.google.com/search?q=\(query)") {
            model.load(url)
        }
    }

    /// Runs the automatic extractors on the current page (best for Pinterest pins and 7TV).
    private func extractPage() async {
        guard let url = model.currentURL else { return }
        working = true
        defer { working = false }
        do {
            let result = try await LinkResolver.resolve(url.absoluteString)
            present(result.medias, title: result.title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Lists the images and videos visible in the page.
    private func scanPage() async {
        working = true
        let medias = await model.scanMedia()
        working = false
        present(medias, title: nil)
    }

    private func present(_ medias: [RemoteMedia], title: String?) {
        if medias.isEmpty {
            errorMessage = "Nessun media trovato in questa pagina."
        } else if medias.count == 1 {
            onPick(medias)
        } else {
            picker = MediaPickerPayload(title: title ?? "\(medias.count) media trovati", medias: medias, packName: title)
        }
    }
}
