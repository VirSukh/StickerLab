import AVFoundation
import Foundation

struct SoundItem: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

/// MyInstants soundboard (https://www.myinstants.com). Unofficial JSON API + the trending page.
enum MyInstantsAPI {
    static let base = "https://www.myinstants.com"

    /// Search via the JSON API (20 results per page).
    static func search(_ query: String, page: Int) async throws -> (sounds: [SoundItem], hasMore: Bool) {
        var components = URLComponents(string: "\(base)/api/v1/instants/")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query.trimmed),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let root = try await ResponseCache.fetchJSON(components.url!, maxAge: 6 * 3600) as? [String: Any] else {
            throw AppError("MyInstants: risposta non valida.")
        }
        let results = root["results"] as? [[String: Any]] ?? []
        let sounds: [SoundItem] = results.compactMap { item in
            guard let name = item["name"] as? String,
                  let sound = item["sound"] as? String,
                  let url = URL(string: sound) else { return nil }
            return SoundItem(id: (item["slug"] as? String) ?? sound, name: name, url: url)
        }
        return (sounds, root["next"] is String)
    }

    /// Downloads an MP3 to a temporary file (media checks in Downloader are for images/videos).
    static func downloadAudio(_ url: URL) async throws -> URL {
        let (temporary, response) = try await Downloader.session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Errore HTTP \(http.statusCode)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Trending sounds in a country (HTML page: play('/media/sounds/x.mp3') + link text).
    static func trending(country: String = "it") async throws -> [SoundItem] {
        let (html, _, _) = try await Downloader.fetchText(URL(string: "\(base)/en/index/\(country)/")!)
        var sounds: [SoundItem] = []
        var seen = Set<String>()
        for block in html.components(separatedBy: "<div class=\"instant\"").dropFirst() {
            guard let path = block.firstRegexMatch(#"play\('([^']+\.mp3)'"#),
                  let url = URL(string: path.hasPrefix("http") ? path : base + path),
                  seen.insert(path).inserted else { continue }
            let name = block.firstRegexMatch(#"class="instant-link[^"]*"[^>]*>([^<]+)<"#)?.htmlUnescaped.trimmed
                ?? url.deletingPathExtension().lastPathComponent
            sounds.append(SoundItem(id: path, name: name, url: url))
        }
        guard !sounds.isEmpty else { throw AppError("Nessun suono in tendenza trovato.") }
        return sounds
    }
}

/// Plays one sound preview at a time.
@MainActor
final class SoundPlayer: ObservableObject {
    static let shared = SoundPlayer()

    @Published private(set) var playingID: String?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ sound: SoundItem) {
        if playingID == sound.id {
            stop()
        } else {
            play(id: sound.id, url: sound.url)
        }
    }

    func play(id: String, url: URL) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playingID = nil }
        }
        self.player = player
        playingID = id
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingID = nil
    }
}
