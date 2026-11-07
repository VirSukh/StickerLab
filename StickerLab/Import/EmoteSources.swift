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
    case sevenTV, ffz
    var id: String { rawValue }
    var label: String { self == .sevenTV ? "7TV" : "FrankerFaceZ" }
    var categories: [BrowseCategory] {
        self == .sevenTV ? BrowseCategory.allCases : [.top, .new]
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

    static func search(_ query: String, page: Int, category: BrowseCategory, perPage: Int = 60) async throws -> (emotes: [EmoteItem], hasMore: Bool) {
        var components = URLComponents(string: "\(base)/emotes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.trimmed),
            URLQueryItem(name: "sort", value: category == .new ? "created-desc" : "count-desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        let json: Any
        do {
            json = try await Downloader.fetchJSON(components.url!)
        } catch {
            // FFZ answers 404 when a search has no results.
            if (error as? AppError)?.message.contains("404") == true { return ([], false) }
            throw error
        }
        guard let root = json as? [String: Any] else { throw AppError("FrankerFaceZ: risposta non valida.") }
        let list = (root["emoticons"] as? [[String: Any]] ?? []).compactMap(parse)
        let pages = root["_pages"] as? Int ?? page
        return (list, page < pages)
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
