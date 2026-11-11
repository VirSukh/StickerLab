import Foundation

/// An emote from any source (7TV, FrankerFaceZ), shown in the Emote tab.
struct EmoteItem: Identifiable, Hashable {
    let id: String
    let name: String
    let animated: Bool
    let previewURL: URL
    let remote: RemoteMedia
}

extension SevenTVEmote {
    var item: EmoteItem {
        EmoteItem(id: "7tv-\(id)", name: name, animated: animated, previewURL: previewURL, remote: remote)
    }
}

enum EmoteSource: String, CaseIterable, Identifiable {
    case sevenTV, ffz, giphyGifs, giphyStickers
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sevenTV: return "7TV"
        case .ffz: return "FFZ"
        case .giphyGifs: return "GIF"
        case .giphyStickers: return "Sticker"
        }
    }
    var isGiphy: Bool { self == .giphyGifs || self == .giphyStickers }
    var categories: [BrowseCategory] {
        switch self {
        case .sevenTV: return BrowseCategory.allCases
        case .ffz: return [.top, .new]
        case .giphyGifs, .giphyStickers: return [.trendingDay]
        }
    }
}

enum BrowseCategory: String, CaseIterable, Identifiable {
    case top, trendingDay, trendingWeek, trendingMonth, new
    var id: String { rawValue }
    var label: String {
        switch self {
        case .top: return "Popolari"
        case .trendingDay: return "Tendenza oggi"
        case .trendingWeek: return "Tendenza settimana"
        case .trendingMonth: return "Tendenza mese"
        case .new: return "Nuove"
        }
    }
    var symbol: String {
        switch self {
        case .top: return "crown.fill"
        case .trendingDay: return "flame.fill"
        case .trendingWeek: return "chart.line.uptrend.xyaxis"
        case .trendingMonth: return "calendar"
        case .new: return "sparkles"
        }
    }
    var sevenTV: SevenTVAPI.Category {
        switch self {
        case .top: return .top
        case .trendingDay: return .trendingDay
        case .trendingWeek: return .trendingWeek
        case .trendingMonth: return .trendingMonth
        case .new: return .new
        }
    }
}

// MARK: - FrankerFaceZ

/// FrankerFaceZ public API (https://api.frankerfacez.com/v1).
enum FrankerFaceZAPI {
    static let base = "https://api.frankerfacez.com/v1"

    static func handles(_ url: URL) -> Bool {
        (url.host?.lowercased() ?? "").contains("frankerfacez.com")
    }

    static func emoteItem(id: Int, name: String, animated: Bool) -> EmoteItem {
        let cdn = "https://cdn.frankerfacez.com/emote/\(id)"
        let full = animated ? "\(cdn)/animated/4" : "\(cdn)/4"
        let fallback = animated ? "\(cdn)/animated/2" : "\(cdn)/2"
        let preview = URL(string: animated ? "\(cdn)/animated/2" : "\(cdn)/2")!
        let remote = RemoteMedia(
            url: URL(string: full)!,
            fallbacks: [URL(string: fallback)!, URL(string: "\(cdn)/1")!],
            previewURL: preview,
            title: name,
            kind: animated ? .animated : .image,
            pageURL: "https://www.frankerfacez.com/emoticon/\(id)"
        )
        return EmoteItem(id: "ffz-\(id)", name: name, animated: animated, previewURL: preview, remote: remote)
    }

    private static func parse(_ object: [String: Any]) -> EmoteItem? {
        guard let id = object["id"] as? Int, let name = object["name"] as? String else { return nil }
        let animated = (object["animated"] as? [String: Any])?.isEmpty == false
        return emoteItem(id: id, name: name, animated: animated)
    }

    static func searchURL(_ query: String, page: Int, category: BrowseCategory, perPage: Int = 60) -> URL {
        var components = URLComponents(string: "\(base)/emotes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.trimmed),
            URLQueryItem(name: "sort", value: category == .new ? "created-desc" : "count-desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        return components.url!
    }

    private static func decode(_ json: Any, page: Int) throws -> (emotes: [EmoteItem], hasMore: Bool) {
        guard let root = json as? [String: Any] else { throw AppError("FrankerFaceZ: risposta non valida.") }
        let list = (root["emoticons"] as? [[String: Any]] ?? []).compactMap(parse)
        let pages = root["_pages"] as? Int ?? page
        return (list, page < pages)
    }

    /// Browsing lists (no query) are slow on FFZ's side: cache them for 6 hours; searches for 1 hour.
    static func search(_ query: String, page: Int, category: BrowseCategory, perPage: Int = 60) async throws -> (emotes: [EmoteItem], hasMore: Bool) {
        let url = searchURL(query, page: page, category: category, perPage: perPage)
        let maxAge: TimeInterval = query.trimmed.isEmpty ? 6 * 3600 : 3600
        do {
            return try decode(try await ResponseCache.fetchJSON(url, maxAge: maxAge), page: page)
        } catch {
            // FFZ answers 404 when a search has no results.
            if (error as? AppError)?.message.contains("404") == true { return ([], false) }
            throw error
        }
    }

    /// Whatever is cached for this list, even if old (shown instantly while refreshing).
    static func cachedSearch(_ query: String, page: Int, category: BrowseCategory) -> (emotes: [EmoteItem], hasMore: Bool, age: TimeInterval)? {
        guard let hit = ResponseCache.cached(searchURL(query, page: page, category: category)),
              let result = try? decode(hit.json, page: page) else { return nil }
        return (result.emotes, result.hasMore, hit.age)
    }

    /// Downloads the popular list in the background at launch, so the Emote tab opens instantly.
    static func prefetch() {
        Task.detached(priority: .background) {
            for category in [BrowseCategory.top, .new] {
                _ = try? await search("", page: 1, category: category)
            }
        }
    }

    /// Links like https://www.frankerfacez.com/emoticon/724094-Dance
    static func resolve(_ url: URL) async throws -> ResolvedLink {
        guard let idString = url.absoluteString.firstRegexMatch(#"emoticon/(\d+)"#)
                ?? url.absoluteString.firstRegexMatch(#"emote/(\d+)"#),
              let id = Int(idString) else {
            throw AppError("Link FrankerFaceZ non riconosciuto.")
        }
        guard let root = try await Downloader.fetchJSON(URL(string: "\(base)/emote/\(id)")!) as? [String: Any],
              let emote = root["emote"] as? [String: Any],
              let item = parse(emote) else {
            throw AppError("Emote FrankerFaceZ non trovata.")
        }
        return ResolvedLink(title: item.name, medias: [item.remote])
    }
}

// MARK: - Imgflip

struct MemeTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let width: Int
    let height: Int
    let boxCount: Int
}

/// Imgflip's most popular meme templates (https://api.imgflip.com/get_memes).
enum ImgflipAPI {
    static func templates() async throws -> [MemeTemplate] {
        guard let root = try await Downloader.fetchJSON(URL(string: "https://api.imgflip.com/get_memes")!) as? [String: Any],
              root["success"] as? Bool == true,
              let data = root["data"] as? [String: Any],
              let memes = data["memes"] as? [[String: Any]] else {
            throw AppError("Imgflip non risponde.")
        }
        return memes.compactMap { meme in
            guard let id = meme["id"] as? String,
                  let name = meme["name"] as? String,
                  let string = meme["url"] as? String,
                  let url = URL(string: string) else { return nil }
            return MemeTemplate(
                id: id, name: name, url: url,
                width: meme["width"] as? Int ?? 0, height: meme["height"] as? Int ?? 0,
                boxCount: meme["box_count"] as? Int ?? 2
            )
        }
    }
}
