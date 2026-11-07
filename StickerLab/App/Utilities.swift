import SwiftUI
import UIKit

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func regexMatches(_ pattern: String, group: Int = 0, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard group < match.numberOfRanges else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    func firstRegexMatch(_ pattern: String, group: Int = 1) -> String? {
        regexMatches(pattern, group: group).first
    }

    var htmlUnescaped: String {
        var s = self
        let replacements: [(String, String)] = [
            ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&#x2F;", "/"), ("&#47;", "/"),
            ("\\u0026", "&"), ("\\/", "/"), ("&amp;", "&"),
        ]
        for (from, to) in replacements { s = s.replacingOccurrences(of: from, with: to) }
        return s
    }
}

extension Character {
    var isEmojiCharacter: Bool {
        guard let first = unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && (unicodeScalars.count > 1 || first.value > 0x238C)
    }
}

enum EmojiParser {
    /// Keeps up to 3 emoji from free text. Falls back to 😀 because WhatsApp wants at least one.
    static func parse(_ text: String) -> [String] {
        let emojis = text.filter { $0.isEmojiCharacter }.map { String($0) }
        let unique = emojis.reduce(into: [String]()) { result, e in if !result.contains(e) { result.append(e) } }
        return unique.isEmpty ? ["😀"] : Array(unique.prefix(3))
    }
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

// MARK: - Shared small views

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            }
            .padding(28)
            .glassCard(cornerRadius: 28)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 12
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(Color.gray.opacity(0.14)))
                }
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 26)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct AnimatedMediaView: View {
    let media: DecodedMedia
    var render: ((CGImage) -> CGImage?)? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !media.isAnimated)) { context in
            let index = media.frameIndex(at: context.date.timeIntervalSinceReferenceDate)
            let frame = media.frames[index]
            let shown = render?(frame) ?? frame
            Image(decorative: shown, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()

    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: UIImage? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if url.pathExtension.lowercased() == "webp",
               let media = WebPCodec.decode(data, maxFrames: 1),
               let frame = media.frames.first {
                return UIImage(cgImage: frame)
            }
            return UIImage(data: data)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct StickerThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url) }
    }
}
