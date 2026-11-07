import Foundation

struct SevenTVEmote: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let animated: Bool

    private var cdn: String { "https://cdn.7tv.app/emote/\(id)" }
    var previewURL: URL { URL(string: "\(cdn)/2x.webp")! }

    var remote: RemoteMedia {
        RemoteMedia(
            url: URL(string: "\(cdn)/4x.webp")!,
            fallbacks: [URL(string: "\(cdn)/3x.webp")!, URL(string: "\(cdn)/4x.gif")!, URL(string: "\(cdn)/4x.png")!],
            previewURL: previewURL,
            title: name,
            kind: animated ? .animated : .image,
            pageURL: "https://7tv.app/emotes/\(id)"
        )
    }
}

/// 7TV public API (v3 REST + GraphQL).
enum SevenTVAPI {
    static let base = "https://7tv.io/v3"

    static func handles(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "7tv.app" || host.hasSuffix(".7tv.app") || host == "7tv.io" || host.hasSuffix(".7tv.io")
    }

    // MARK: Search

    enum Filter: String, CaseIterable, Identifiable {
        case all, animated, still
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Tutte"
            case .animated: return "Animate"
            case .still: return "Statiche"
            }
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case top = "TOP"
        case trendingDay = "TRENDING_DAY"
        case trendingWeek = "TRENDING_WEEK"
        case trendingMonth = "TRENDING_MONTH"
        case new = "NEW"

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
    }

    private struct SearchResponse: Decodable {
        struct DataObject: Decodable {
            struct Emotes: Decodable {
                let count: Int
                let items: [SevenTVEmote?]
            }
            let emotes: Emotes
        }
        struct GQLError: Decodable { let message: String }
        let data: DataObject?
        let errors: [GQLError]?
    }

    /// Empty query = most popular emotes.
    static func search(_ query: String, page: Int, category: Category = .top, filter: Filter, limit: Int = 60) async throws -> (emotes: [SevenTVEmote], total: Int) {
        let gql = """
        query SearchEmotes($query: String!, $page: Int, $limit: Int, $filter: EmoteSearchFilter, $sort: Sort) {
          emotes(query: $query, page: $page, limit: $limit, filter: $filter, sort: $sort) {
            count
            items { id name animated }
          }
        }
        """
        let variables: [String: Any] = [
            "query": query.trimmed,
            "page": page,
            "limit": limit,
            "filter": [
                "category": category.rawValue,
                "exact_match": false,
                "case_sensitive": false,
                "ignore_tags": false,
                "zero_width": false,
                "animated": filter == .animated,
                "aspect_ratio": "",
            ],
            "sort": ["value": "popularity", "order": "DESCENDING"],
        ]
        var request = URLRequest(url: URL(string: "\(base)/gql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": gql, "variables": variables])
        let (data, _) = try await Downloader.session.data(for: request)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        if let error = response.errors?.first { throw AppError("7TV: \(error.message)") }
        guard let emotes = response.data?.emotes else { throw AppError("7TV: risposta vuota.") }
        var items = emotes.items.compactMap { $0 }
        if filter == .still { items = items.filter { !$0.animated } }
        return (items, emotes.count)
    }

    // MARK: Links

    static func resolve(_ url: URL) async throws -> ResolvedLink {
        let components = url.pathComponents.filter { $0 != "/" }
        func value(after keys: [String]) -> String? {
            for (index, component) in components.enumerated() where keys.contains(component.lowercased()) {
                if index + 1 < components.count { return components[index + 1] }
            }
            return nil
        }

        if let setID = value(after: ["emote-sets", "emote-set", "sets"]) {
            return try await emoteSet(id: setID)
        }
        if let emoteID = value(after: ["emotes", "emote"]) {
            let emote = try await emote(id: emoteID)
            return ResolvedLink(title: emote.name, medias: [emote.remote])
        }
        if let userID = value(after: ["users", "user"]) {
            return try await userSet(id: userID)
        }
        throw AppError("Link 7TV non riconosciuto. Usa il link di un'emote, di un set o di un utente.")
    }

    static func emote(id: String) async throws -> SevenTVEmote {
        guard let json = try await Downloader.fetchJSON(URL(string: "\(base)/emotes/\(id)")!) as? [String: Any],
              let emoteID = json["id"] as? String else {
            throw AppError("Emote 7TV non trovata.")
        }
        return SevenTVEmote(id: emoteID, name: json["name"] as? String ?? "emote", animated: json["animated"] as? Bool ?? false)
    }

    static func emoteSet(id: String) async throws -> ResolvedLink {
        guard let json = try await Downloader.fetchJSON(URL(string: "\(base)/emote-sets/\(id)")!) as? [String: Any] else {
            throw AppError("Set 7TV non trovato.")
        }
        let name = json["name"] as? String
        let entries = json["emotes"] as? [[String: Any]] ?? []
        let emotes: [SevenTVEmote] = entries.compactMap { entry in
            let data = entry["data"] as? [String: Any]
            guard let emoteID = (data?["id"] as? String) ?? (entry["id"] as? String) else { return nil }
            let emoteName = (entry["name"] as? String) ?? (data?["name"] as? String) ?? "emote"
            return SevenTVEmote(id: emoteID, name: emoteName, animated: data?["animated"] as? Bool ?? false)
        }
        guard !emotes.isEmpty else { throw AppError("Il set 7TV è vuoto.") }
        return ResolvedLink(title: name, medias: emotes.map(\.remote))
    }

    static func userSet(id: String) async throws -> ResolvedLink {
        guard let json = try await Downloader.fetchJSON(URL(string: "\(base)/users/\(id)")!) as? [String: Any] else {
            throw AppError("Utente 7TV non trovato.")
        }
        let connections = json["connections"] as? [[String: Any]] ?? []
        let setID = connections.compactMap { ($0["emote_set_id"] as? String) ?? (($0["emote_set"] as? [String: Any])?["id"] as? String) }.first
            ?? (json["emote_sets"] as? [[String: Any]])?.first?["id"] as? String
        guard let setID else { throw AppError("Questo utente 7TV non ha un set di emote.") }
        var result = try await emoteSet(id: setID)
        if result.title == nil { result.title = json["display_name"] as? String }
        return result
    }
}
