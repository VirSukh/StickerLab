import Foundation

/// Client for a self-hosted cobalt instance (https://github.com/imputnet/cobalt).
enum CobaltClient {
    static let urlKey = "cobaltURL"
    static let apiKeyKey = "cobaltKey"

    static var baseURL: String { UserDefaults.standard.string(forKey: urlKey)?.trimmed ?? "" }
    static var apiKey: String { UserDefaults.standard.string(forKey: apiKeyKey)?.trimmed ?? "" }
    static var isConfigured: Bool { URL(string: baseURL)?.host != nil }

    private static func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func resolve(_ link: URL) async throws -> [RemoteMedia] {
        guard let endpoint = URL(string: baseURL) else { throw AppError("URL del server cobalt non valido.") }
        var request = request(endpoint, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": link.absoluteString,
            "videoQuality": "720",
            "downloadMode": "auto",
            "filenameStyle": "basic",
        ])
        let (data, _) = try await Downloader.session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Risposta non valida dal server.")
        }
        let page = link.absoluteString
        switch json["status"] as? String {
        case "tunnel", "redirect":
            guard let string = json["url"] as? String, let url = URL(string: string) else { break }
            return [media(url: url, filename: json["filename"] as? String, type: nil, thumb: nil, page: page)]
        case "picker":
            let items = json["picker"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let string = item["url"] as? String, let url = URL(string: string) else { return nil }
                let thumb = (item["thumb"] as? String).flatMap(URL.init(string:))
                return media(url: url, filename: nil, type: item["type"] as? String, thumb: thumb, page: page)
            }
        case "local-processing":
            let tunnels = json["tunnel"] as? [String] ?? []
            if let first = tunnels.first, let url = URL(string: first) {
                return [media(url: url, filename: nil, type: json["type"] as? String, thumb: nil, page: page)]
            }
        case "error":
            let code = (json["error"] as? [String: Any])?["code"] as? String ?? "sconosciuto"
            throw AppError(code)
        default:
            break
        }
        throw AppError("Risposta non riconosciuta dal server.")
    }

    private static func media(url: URL, filename: String?, type: String?, thumb: URL?, page: String) -> RemoteMedia {
        let name = (filename ?? url.lastPathComponent).lowercased()
        let kind: RemoteMedia.Kind
        if type == "video" || name.hasSuffix(".mp4") || name.hasSuffix(".mov") || name.hasSuffix(".webm") {
            kind = .video
        } else if type == "gif" || name.hasSuffix(".gif") {
            kind = .gif
        } else {
            kind = .image
        }
        return RemoteMedia(url: url, previewURL: thumb ?? (kind == .video ? nil : url), title: filename, kind: kind, pageURL: page)
    }

    /// GET / returns server info: used by the "test" button.
    static func testConnection() async throws -> String {
        guard let endpoint = URL(string: baseURL) else { throw AppError("URL non valido.") }
        let (data, response) = try await Downloader.session.data(for: request(endpoint, method: "GET"))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AppError("Il server ha risposto \(http.statusCode).")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let version = (json?["cobalt"] as? [String: Any])?["version"] as? String
        return version.map { "Connesso a cobalt \($0)" } ?? "Il server risponde."
    }
}
