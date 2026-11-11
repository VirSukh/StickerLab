import Foundation

/// GIPHY API (needs a free key from developers.giphy.com). GIFs and transparent stickers.
enum GiphyAPI {
    static let keyKey = "giphyKey"
    static var apiKey: String { UserDefaults.standard.string(forKey: keyKey)?.trimmed ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }

    private static func url(_ images: [String: Any]?, _ name: String, _ field: String) -> URL? {
        ((images?[name] as? [String: Any])?[field] as? String).flatMap(URL.init(string:))
    }

    private static func parse(_ object: [String: Any], stickers: Bool) -> EmoteItem? {
        guard let id = object["id"] as? String else { return nil }
        let images = object["images"] as? [String: Any]
        guard let full = url(images, "original", "webp") ?? url(images, "original", "url") else { return nil }
        let preview = url(images, "fixed_width_small", "webp") ?? url(images, "fixed_width", "webp")
            ?? url(images, "fixed_width_small", "url") ?? full
        let fallbacks = [url(images, "original", "url"), url(images, "downsized", "url")]
            .compactMap { $0 }
            .filter { $0 != full }
        let rawTitle = (object["title"] as? String)?.trimmed ?? ""
        let title = rawTitle.isEmpty ? "GIPHY" : rawTitle
        let remote = RemoteMedia(
            url: full, fallbacks: fallbacks, previewURL: preview, title: title,
            kind: .gif, pageURL: object["url"] as? String
        )
        return EmoteItem(id: "giphy-\(stickers ? "s" : "g")-\(id)", name: title, animated: true, previewURL: preview, remote: remote)
    }

    /// Empty query = trending.
    static func search(_ query: String, page: Int, stickers: Bool, limit: Int = 48) async throws -> (emotes: [EmoteItem], hasMore: Bool) {
        guard isConfigured else {
            throw AppError("Serve una chiave GIPHY gratuita: aggiungila in Impostazioni → GIPHY.")
        }
        let text = query.trimmed
        let kind = stickers ? "stickers" : "gifs"
        let endpoint = text.isEmpty ? "trending" : "search"
        var components = URLComponents(string: "https://api.giphy.com/v1/\(kind)/\(endpoint)")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String((page - 1) * limit)),
            URLQueryItem(name: "rating", value: "r"),
            URLQueryItem(name: "lang", value: "it"),
        ]
        if !text.isEmpty { items.append(URLQueryItem(name: "q", value: text)) }
        components.queryItems = items

        let json: Any
        do {
            json = try await ResponseCache.fetchJSON(components.url!, maxAge: text.isEmpty ? 1800 : 3600)
        } catch {
            let message = (error as? AppError)?.message ?? ""
            if message.contains("401") || message.contains("403") {
                throw AppError("La chiave GIPHY non è valida: controllala in Impostazioni → GIPHY.")
            }
            if message.contains("429") {
                throw AppError("Limite di richieste GIPHY raggiunto: riprova tra un po'.")
            }
            throw error
        }
        guard let root = json as? [String: Any] else { throw AppError("GIPHY: risposta non valida.") }
        let list = (root["data"] as? [[String: Any]] ?? []).compactMap { parse($0, stickers: stickers) }
        let pagination = root["pagination"] as? [String: Any]
        let total = pagination?["total_count"] as? Int ?? 0
        let offset = pagination?["offset"] as? Int ?? 0
        let count = pagination?["count"] as? Int ?? list.count
        return (list, count > 0 && offset + count < min(total, 4999))
    }
}
