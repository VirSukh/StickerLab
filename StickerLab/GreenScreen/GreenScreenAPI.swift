import Foundation

struct GreenTemplate: Identifiable, Hashable {
    enum Source: String { case gsm, memesDownload }

    let id: String
    let name: String
    let thumbnailURL: URL?
    let source: Source
    /// greenscreenmemes.com: id of the WordPress media item holding the MP4.
    var videoMediaID: Int?
    /// memes-download.com: direct MP4.
    var videoURL: URL?
}

enum GreenScreenSource: String, CaseIterable, Identifiable {
    case gsm, memesDownload
    var id: String { rawValue }
    var label: String { self == .gsm ? "GreenScreenMemes" : "Memes-Download" }
}

/// Free green screen meme libraries (personal use).
enum GreenScreenAPI {
    // MARK: greenscreenmemes.com (WordPress REST API, ~7,000 clips)

    private static let gsmBase = "https://greenscreenmemes.com/wp-json/wp/v2"

    static func cleanName(_ raw: String) -> String {
        // Twice: some titles are escaped twice (&#34; -> &#34; -> ").
        var name = raw.htmlUnescaped.htmlUnescaped
            .replacingOccurrences(of: "&#8217;", with: "’")
            .replacingOccurrences(of: "&#8211;", with: "–")
        for suffix in [" Download", " Template", " Video", " Memes", " Meme", " Green Screen", " Green screen"] {
            while name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.trimmed
    }

    /// Newest first when the query is empty.
    static func searchGSM(_ query: String, page: Int, perPage: Int = 30) async throws -> (templates: [GreenTemplate], hasMore: Bool) {
        var components = URLComponents(string: "\(gsmBase)/posts")!
        var items = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "_embed", value: "wp:featuredmedia"),
            URLQueryItem(name: "_fields", value: "id,title,acf.video_url,_links,_embedded"),
        ]
        if !query.trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: query.trimmed)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Downloader.session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 400 { return ([], false) }   // page past the end
        if let code = http?.statusCode, !(200..<300).contains(code) { throw AppError("Errore HTTP \(code)") }
        guard let posts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppError("GreenScreenMemes: risposta non valida.")
        }
        let templates: [GreenTemplate] = posts.compactMap { post in
            guard let id = post["id"] as? Int,
                  let title = (post["title"] as? [String: Any])?["rendered"] as? String,
                  let mediaID = (post["acf"] as? [String: Any])?["video_url"] as? Int else { return nil }
            let media = ((post["_embedded"] as? [String: Any])?["wp:featuredmedia"] as? [[String: Any]])?.first
            let thumb = (media?["source_url"] as? String).flatMap(URL.init(string:))
            return GreenTemplate(id: "gsm-\(id)", name: cleanName(title), thumbnailURL: thumb, source: .gsm, videoMediaID: mediaID)
        }
        let totalPages = Int(http?.value(forHTTPHeaderField: "X-WP-TotalPages") ?? "") ?? page
        return (templates, page < totalPages)
    }

    // MARK: memes-download.com (one page with ~300 green screen clips)

    private static var memesDownloadCache: [GreenTemplate]?

    static func memesDownloadAll() async throws -> [GreenTemplate] {
        if let cached = memesDownloadCache { return cached }
        let (html, _, _) = try await Downloader.fetchText(URL(string: "https://www.memes-download.com/category/green-screen")!)
        // The page embeds escaped JSON: \"title\":\"...\",\"url\":\"https://api.memes-download.com/...mp4\"
        let pattern = #"\\"title\\":\\"(.*?)\\",\\"url\\":\\"(https:[^"\\]+?\.mp4)\\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var templates: [GreenTemplate] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges >= 3 {
            let title = ns.substring(with: match.range(at: 1))
            let link = ns.substring(with: match.range(at: 2))
            guard seen.insert(link).inserted, let url = URL(string: link) else { continue }
            templates.append(GreenTemplate(id: "md-\(link)", name: cleanName(title), thumbnailURL: nil, source: .memesDownload, videoURL: url))
        }
        guard !templates.isEmpty else { throw AppError("Memes-Download: nessun template trovato.") }
        memesDownloadCache = templates
        return templates
    }

    // MARK: Video

    static func videoURL(for template: GreenTemplate) async throws -> URL {
        if let url = template.videoURL { return url }
        guard let mediaID = template.videoMediaID,
              let json = try await Downloader.fetchJSON(URL(string: "\(gsmBase)/media/\(mediaID)?_fields=source_url")!) as? [String: Any],
              let source = json["source_url"] as? String,
              let url = URL(string: source) else {
            throw AppError("Video del template non trovato.")
        }
        return url
    }
}
