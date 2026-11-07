import SwiftUI

/// Loads (and animates) small previews for grids.
/// Replaces AsyncImage, which cancels loads in scrolling grids and never retries.
@MainActor
final class PreviewLoader {
    static let shared = PreviewLoader()

    private final class Box {
        let media: DecodedMedia
        init(_ media: DecodedMedia) { self.media = media }
    }

    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 300
        return cache
    }()
    private var inFlight: [URL: Task<DecodedMedia?, Never>] = [:]

    func cached(_ url: URL) -> DecodedMedia? {
        cache.object(forKey: url as NSURL)?.media
    }

    func media(for url: URL) async -> DecodedMedia? {
        if let cached = cached(url) { return cached }
        if let running = inFlight[url] { return await running.value }

        // Detached: keeps loading even if the cell scrolls away, so the result is cached.
        let task = Task.detached(priority: .utility) { () -> DecodedMedia? in
            for attempt in 0..<3 {
                if let result = try? await Downloader.session.data(from: url),
                   (result.1 as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
                   let media = MediaDecoder.decodeImage(data: result.0, maxPixel: 192, maxFrames: 150) {
                    return media
                }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
            return nil
        }
        inFlight[url] = task
        let media = await task.value
        inFlight[url] = nil
        if let media { cache.setObject(Box(media), forKey: url as NSURL) }
        return media
    }
}

/// Remote image or animation (GIF / animated WebP) that plays in place.
struct RemoteAnimatedImage: View {
    let url: URL
    var placeholderSymbol = "photo"
    @State private var media: DecodedMedia?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let media {
                AnimatedMediaView(media: media)
            } else if failed {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            if let cached = PreviewLoader.shared.cached(url) {
                media = cached
                return
            }
            failed = false
            let loaded = await PreviewLoader.shared.media(for: url)
            media = loaded
            failed = loaded == nil
        }
    }
}
