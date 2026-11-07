import Foundation

/// Pinterest has no public API for pin media. Strategy:
/// 1. resolve pin.it short links, 2. widget endpoint (JSON), 3. pin page HTML.
enum PinterestExtractor {
    static func handles(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "pin.it" || host.contains("pinterest.")
    }

    static func resolve(_ url: URL) async throws -> [RemoteMedia] {
        var foundID = extractPinID(from: url.absoluteString)
        if foundID == nil {
            // Short link (pin.it) or other page: follow redirects and look inside.
            let (html, finalURL, _) = try await Downloader.fetchText(url)
            foundID = extractPinID(from: finalURL.absoluteString) ?? extractPinID(from: html)
        }
        guard let pinID = foundID else { throw AppError("Non trovo l'ID del pin in questo link.") }
        let page = "https://www.pinterest.com/pin/\(pinID)/"

        if let medias = try? await fromWidgetAPI(pinID: pinID, page: page), !medias.isEmpty {
            return medias
        }
        return try await fromHTML(page: page)
    }

    static func extractPinID(from text: String) -> String? {
        text.firstRegexMatch(#"pin/(?:[^/?#"]*?--)?(\d{6,})"#)
    }

    // MARK: Widget endpoint

    static func fromWidgetAPI(pinID: String, page: String) async throws -> [RemoteMedia] {
        let url = URL(string: "https://widgets.pinterest.com/v3/pidgets/pins/info/?pin_ids=\(pinID)")!
        guard let root = try await Downloader.fetchJSON(url) as? [String: Any],
              let pins = root["data"] as? [[String: Any]],
              let pin = pins.first else { return [] }
        return medias(fromPin: pin, page: page)
    }

    static func medias(fromPin pin: [String: Any], page: String) -> [RemoteMedia] {
        let title = [pin["grid_title"], pin["title"], pin["description"]]
            .compactMap { ($0 as? String)?.trimmed }
            .first { !$0.isEmpty }

        // Strip subtrees that contain avatars and board thumbnails.
        var content = pin
        for key in ["pinner", "board", "origin_pinner", "aggregated_pin_data"] { content.removeValue(forKey: key) }

        // 1. Videos (video pins and story/idea pins).
        let videos = videoURLs(in: content)
        if !videos.isEmpty {
            let preview = (content["images"] as? [String: Any]).flatMap { bestImageURL(in: $0) }
            return videos.map { RemoteMedia(url: $0, previewURL: preview, title: title, kind: .video, pageURL: page) }
        }

        // 2. GIF embeds.
        if let embed = content["embed"] as? [String: Any],
           let src = embed["src"] as? String,
           src.lowercased().contains(".gif"),
           let url = URL(string: src) {
            return [RemoteMedia(url: url, previewURL: url, title: title, kind: .gif, pageURL: page)]
        }

        // 3. Images (main image first, then carousel / story pages).
        var urls: [URL] = []
        if let images = content["images"] as? [String: Any], let best = bestImageURL(in: images) { urls.append(best) }
        content.removeValue(forKey: "images")
        for images in collect(key: "images", in: content) {
            if let best = bestImageURL(in: images), !urls.contains(best) { urls.append(best) }
        }
        return urls.map { RemoteMedia.image($0, title: title, pageURL: page) }
    }

    // MARK: HTML fallback

    static func fromHTML(page: String) async throws -> [RemoteMedia] {
        let (raw, _, _) = try await Downloader.fetchText(URL(string: page)!)
        let html = raw.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u002F", with: "/")

        let videos = Array(Set(html.regexMatches(#"https://v\d*\.pinimg\.com/videos/[^"'\s\\]+?\.mp4"#)))
        if !videos.isEmpty {
            let best = videos.sorted { score($0) > score($1) }.first!
            if let url = URL(string: best) { return [RemoteMedia(url: url, kind: .video, pageURL: page)] }
        }

        let originals = html.regexMatches(#"https://i\.pinimg\.com/originals/[^"'\s\\]+?\.(?:jpe?g|png|gif|webp)"#)
        if let first = originals.first, let url = URL(string: first) {
            return [RemoteMedia.image(url, pageURL: page)]
        }

        let generic = HTMLMediaExtractor.extract(from: raw, pageURL: URL(string: page)!)
        if !generic.isEmpty { return generic }
        throw AppError("Nessun media trovato nel pin (potrebbe essere privato).")
    }

    private static func score(_ videoURL: String) -> Int {
        if videoURL.contains("720p") { return 3 }
        if videoURL.contains("expMp4") { return 2 }
        if videoURL.contains("480p") { return 1 }
        return 0
    }

    // MARK: JSON helpers

    private static func collect(key: String, in object: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            for (k, value) in dict {
                if k == key, let match = value as? [String: Any] { found.append(match) }
                found.append(contentsOf: collect(key: key, in: value))
            }
        } else if let array = object as? [Any] {
            for value in array { found.append(contentsOf: collect(key: key, in: value)) }
        }
        return found
    }

    private static func videoURLs(in pin: [String: Any]) -> [URL] {
        let preferred = ["V_720P", "V_EXP7", "V_EXP6", "V_EXP5", "V_EXP4", "V_EXP3", "V_480P", "V_360P", "V_240P"]
        var result: [URL] = []
        for list in collect(key: "video_list", in: pin) {
            var chosen: String?
            for key in preferred {
                if let entry = list[key] as? [String: Any], let url = entry["url"] as? String, url.contains(".mp4") {
                    chosen = url
                    break
                }
            }
            if chosen == nil {
                chosen = list.values.compactMap { ($0 as? [String: Any])?["url"] as? String }.first { $0.contains(".mp4") }
            }
            if let chosen, let url = URL(string: chosen), !result.contains(url) { result.append(url) }
        }
        return result
    }

    private static func bestImageURL(in images: [String: Any]) -> URL? {
        for key in ["orig", "originals"] {
            if let entry = images[key] as? [String: Any], let url = entry["url"] as? String {
                return URL(string: url)
            }
        }
        let entries = images.values.compactMap { $0 as? [String: Any] }
        let best = entries.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        return (best?["url"] as? String).flatMap(URL.init(string:))
    }

    /// Full-size candidates for an i.pinimg.com image (the original may have another extension).
    static func imageCandidates(for url: URL) -> [URL] {
        let string = url.absoluteString
        guard string.contains("i.pinimg.com"), !string.contains("/originals/") else { return [url] }
        guard let range = string.range(of: #"i\.pinimg\.com/[^/]+/"#, options: .regularExpression) else { return [url] }
        let original = string.replacingCharacters(in: range, with: "i.pinimg.com/originals/")
        let ext = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        var candidates = [original]
        for other in ["gif", "png", "webp", "jpg"] where other != ext.lowercased() {
            candidates.append("\(stem).\(other)")
        }
        candidates.append(string.replacingCharacters(in: range, with: "i.pinimg.com/736x/"))
        candidates.append(string)
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }.compactMap(URL.init(string:))
    }
}
