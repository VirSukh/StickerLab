import Foundation

/// Turns any link into downloadable media, trying the extractors in order.
enum LinkResolver {
    static func normalize(_ input: String) -> URL? {
        let text = input.trimmed
        guard !text.isEmpty else { return nil }
        // Shared text often contains words around the link.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let url = match.url,
           url.scheme?.hasPrefix("http") == true {
            return url
        }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    static func directKind(_ url: URL) -> RemoteMedia.Kind? {
        switch url.pathExtension.lowercased() {
        case "gif": return .gif
        case "webp", "png", "jpg", "jpeg", "heic", "avif": return .image
        case "mp4", "mov", "m4v": return .video
        default: return nil
        }
    }

    static func resolve(_ input: String) async throws -> ResolvedLink {
        guard let url = normalize(input) else { throw AppError("Link non valido.") }

        if SevenTVAPI.handles(url) {
            return try await SevenTVAPI.resolve(url)
        }

        if let kind = directKind(url) {
            let media = kind == .video
                ? RemoteMedia(url: url, kind: .video, pageURL: nil)
                : RemoteMedia.image(url)
            return ResolvedLink(title: nil, medias: [media])
        }

        var errors: [String] = []

        if PinterestExtractor.handles(url) {
            do {
                let medias = try await PinterestExtractor.resolve(url)
                if !medias.isEmpty { return ResolvedLink(title: nil, medias: medias) }
            } catch {
                errors.append("Pinterest: \(error.localizedDescription)")
            }
        }

        if CobaltClient.isConfigured {
            do {
                let medias = try await CobaltClient.resolve(url)
                if !medias.isEmpty { return ResolvedLink(title: nil, medias: medias) }
            } catch {
                errors.append("cobalt: \(error.localizedDescription)")
            }
        }

        do {
            let medias = try await HTMLMediaExtractor.resolve(url)
            if !medias.isEmpty { return ResolvedLink(title: nil, medias: medias) }
        } catch {
            errors.append("Pagina: \(error.localizedDescription)")
        }

        var message = "Nessun media trovato in questo link."
        if !errors.isEmpty { message += "\n\n" + errors.joined(separator: "\n") }
        if !CobaltClient.isConfigured {
            message += "\n\nSuggerimento: configura un server cobalt nelle Impostazioni per Instagram, TikTok, X…"
        }
        message += "\nPuoi anche aprire il link nel browser integrato e scegliere i media a mano."
        throw AppError(message)
    }
}

/// Generic extractor: Open Graph / Twitter cards and <video>/<img> tags.
enum HTMLMediaExtractor {
    static func resolve(_ url: URL) async throws -> [RemoteMedia] {
        let (html, finalURL, mime) = try await Downloader.fetchText(url)
        if let mime, mime.hasPrefix("image/") || mime.hasPrefix("video/") {
            let kind: RemoteMedia.Kind = mime.hasPrefix("video/") ? .video : (mime == "image/gif" ? .gif : .image)
            return [RemoteMedia(url: finalURL, previewURL: kind == .video ? nil : finalURL, kind: kind)]
        }
        return extract(from: html, pageURL: finalURL)
    }

    static func extract(from html: String, pageURL: URL) -> [RemoteMedia] {
        let meta = metaTags(html)
        let page = pageURL.absoluteString
        var results: [RemoteMedia] = []
        var seen = Set<String>()

        func add(_ raw: String, video: Bool) {
            let cleaned = raw.htmlUnescaped.trimmed
            guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: pageURL)?.absoluteURL else { return }
            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            if video {
                let lower = key.lowercased()
                guard !lower.contains(".m3u8"), !lower.contains("youtube.com"), !lower.contains("/embed") else { return }
                seen.insert(key)
                results.append(RemoteMedia(url: url, kind: .video, pageURL: page))
            } else {
                seen.insert(key)
                results.append(RemoteMedia.image(url, pageURL: page))
            }
        }

        for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            meta[key]?.forEach { add($0, video: true) }
        }
        for src in html.regexMatches(#"<(?:video|source)[^>]+src\s*=\s*["']([^"']+\.(?:mp4|mov|m4v)[^"']*)["']"#, group: 1) {
            add(src, video: true)
        }
        for key in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            meta[key]?.forEach { add($0, video: false) }
        }
        if results.isEmpty {
            for src in html.regexMatches(#"<img[^>]+src\s*=\s*["']([^"']+\.(?:gif|webp|png|jpe?g)[^"']*)["']"#, group: 1).prefix(40) {
                add(src, video: false)
            }
        }
        return results
    }

    static func metaTags(_ html: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for tag in html.regexMatches(#"<meta\b[^>]*>"#) {
            guard let key = tag.firstRegexMatch(#"(?:property|name)\s*=\s*["']([^"']+)["']"#)?.lowercased(),
                  let content = tag.firstRegexMatch(#"content\s*=\s*["']([^"']*)["']"#) else { continue }
            result[key, default: []].append(content)
        }
        return result
    }
}
