import Foundation

/// A media file found online, not downloaded yet.
struct RemoteMedia: Identifiable, Hashable {
    enum Kind: String { case image, gif, animated, video, unknown }

    let id = UUID()
    var url: URL
    /// Tried in order if `url` fails (e.g. Pinterest originals with a different extension).
    var fallbacks: [URL] = []
    var previewURL: URL?
    var title: String?
    var kind: Kind = .unknown
    /// Page the media comes from (sent as Referer).
    var pageURL: String?

    static func image(_ url: URL, title: String? = nil, pageURL: String? = nil) -> RemoteMedia {
        let kind: Kind = url.pathExtension.lowercased() == "gif" ? .gif : .image
        if url.host?.lowercased().contains("pinimg.com") == true {
            let candidates = PinterestExtractor.imageCandidates(for: url)
            return RemoteMedia(
                url: candidates[0], fallbacks: Array(candidates.dropFirst()), previewURL: url,
                title: title, kind: kind, pageURL: pageURL
            )
        }
        return RemoteMedia(url: url, previewURL: url, title: title, kind: kind, pageURL: pageURL)
    }
}

struct ResolvedLink {
    var title: String?
    var medias: [RemoteMedia]
}

enum Downloader {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": "it-IT,it;q=0.9,en;q=0.8",
        ]
        return URLSession(configuration: configuration)
    }()

    static var tempDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func download(_ media: RemoteMedia) async throws -> URL {
        var lastError: Error = AppError("Download non riuscito.")
        for url in [media.url] + media.fallbacks {
            do {
                return try await download(url: url, referer: media.pageURL)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func download(url: URL, referer: String?) async throws -> URL {
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (temporary, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw AppError("Errore HTTP \(http.statusCode)")
        }
        return try adopt(temporary, move: true)
    }

    /// Copies a local file (Files app) into the import folder.
    static func importLocalFile(_ url: URL) throws -> URL {
        try adopt(url, move: false)
    }

    static func store(_ data: Data) throws -> URL {
        let url = tempDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return try adopt(url, move: true)
    }

    /// Checks the file is a supported media and gives it the right extension.
    private static func adopt(_ url: URL, move: Bool) throws -> URL {
        let kind = MediaDecoder.sniff(url)
        guard kind != .unknown else {
            if move { try? FileManager.default.removeItem(at: url) }
            throw AppError("Il file non è un'immagine, una GIF o un video supportato.")
        }
        var ext = kind.fileExtension
        if kind == .video, let handle = try? FileHandle(forReadingFrom: url) {
            let head = (try? handle.read(upToCount: 12)) ?? Data()
            try? handle.close()
            if head.count >= 12, String(bytes: head[8..<12], encoding: .ascii) == "qt  " { ext = "mov" }
        }
        let destination = tempDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        if move {
            try FileManager.default.moveItem(at: url, to: destination)
        } else {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }

    /// Fetches a page as text. Returns the final URL after redirects.
    static func fetchText(_ url: URL, headers: [String: String] = [:]) async throws -> (String, URL, String?) {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Errore HTTP \(http.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (text, response.url ?? url, response.mimeType)
    }

    static func fetchJSON(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Errore HTTP \(http.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Removes leftover downloads (called at launch).
    static func cleanTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

/// Small on-disk cache for slow JSON APIs (FrankerFaceZ popular lists take 5–15 s to answer).
enum ResponseCache {
    private static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("api-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for url: URL) -> URL {
        let key = url.absoluteString.unicodeScalars.reduce(into: UInt64(1469598103934665603)) { hash, scalar in
            hash = (hash ^ UInt64(scalar.value)) &* 1099511628211
        }
        return folder.appendingPathComponent(String(key, radix: 16) + ".json")
    }

    /// Cached JSON and its age in seconds, if any.
    static func cached(_ url: URL) -> (json: Any, age: TimeInterval)? {
        let path = file(for: url)
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date else {
            return nil
        }
        return (json, Date().timeIntervalSince(modified))
    }

    /// Fresh cache if younger than `maxAge`, otherwise network (falling back to stale cache on errors).
    static func fetchJSON(_ url: URL, maxAge: TimeInterval) async throws -> Any {
        if let hit = cached(url), hit.age < maxAge { return hit.json }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 45
            let (data, response) = try await Downloader.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError("Errore HTTP \(http.statusCode)")
            }
            let json = try JSONSerialization.jsonObject(with: data)
            try? data.write(to: file(for: url), options: .atomic)
            return json
        } catch {
            if let stale = cached(url) { return stale.json }
            throw error
        }
    }
}
