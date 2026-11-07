import UIKit

/// Demo content used only when the app is launched with `-screenshot <screen>` (CI screenshots).
enum DemoData {
    static var screenshotScreen: String? {
        UserDefaults.standard.string(forKey: "screenshot")
    }

    private static func emojiImage(_ emoji: String, rotation: CGFloat = 0, background: UIColor? = nil) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let background {
                background.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 20), cornerRadius: 80).fill()
            }
            let cg = context.cgContext
            cg.translateBy(x: 256, y: 256)
            cg.rotate(by: rotation)
            let text = emoji as NSString
            let font = UIFont.systemFont(ofSize: 360)
            let bounds = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2), withAttributes: [.font: font])
        }
        return image.cgImage
    }

    @MainActor
    static func seed(into store: PackStore) {
        guard store.packs.isEmpty else { return }

        let animatedPack = store.createPack(name: "Reazioni animate", publisher: "Vir", animated: true)
        for emoji in ["🤣", "😎", "🔥", "🥳"] {
            let frames = (0..<8).compactMap { emojiImage(emoji, rotation: sin(Double($0) / 8 * 2 * .pi) * 0.35) }
            let media = DecodedMedia(frames: frames, durations: Array(repeating: 0.1, count: frames.count))
            if let data = try? StickerPipeline.makeSticker(from: media, settings: EditSettings(), animated: true) {
                try? store.addSticker(data: data, animated: true, emojis: [emoji], source: nil, to: animatedPack.id)
            }
        }

        let staticPack = store.createPack(name: "Meme del gruppo", publisher: "Vir", animated: false)
        let items: [(String, String, UIColor?)] = [
            ("😂", "QUANDO", nil), ("🐸", "", UIColor.systemGreen.withAlphaComponent(0.3)),
            ("💀", "MORTO", nil), ("👀", "", nil), ("🍕", "FAME", UIColor.systemOrange.withAlphaComponent(0.3)),
            ("😴", "", nil), ("🫠", "AIUTO", nil),
        ]
        for (emoji, caption, background) in items {
            guard let frame = emojiImage(emoji, background: background) else { continue }
            var settings = EditSettings()
            settings.text = caption
            settings.scale = caption.isEmpty ? 1 : 0.85
            settings.offset = CGSize(width: 0, height: caption.isEmpty ? 0 : -30)
            let media = DecodedMedia(frames: [frame], durations: [0])
            if let data = try? StickerPipeline.makeSticker(from: media, settings: settings, animated: false) {
                try? store.addSticker(data: data, animated: false, emojis: [emoji], source: nil, to: staticPack.id)
            }
        }

        let small = store.createPack(name: "Emote 7TV", publisher: "Vir", animated: true)
        if let frame = emojiImage("🐱") {
            let media = DecodedMedia(frames: [frame, emojiImage("🐱", rotation: 0.3) ?? frame], durations: [0.3, 0.3])
            if let data = try? StickerPipeline.makeSticker(from: media, settings: EditSettings(), animated: true) {
                try? store.addSticker(data: data, animated: true, emojis: ["🐱"], source: nil, to: small.id)
            }
        }
    }

    /// A sample image for the editor screenshot.
    static func editorSample() -> ImportItem? {
        guard let image = emojiImage("🐸", background: UIColor.systemTeal.withAlphaComponent(0.35)),
              let png = ImageUtils.pngData(image),
              let url = try? Downloader.store(png) else { return nil }
        return ImportItem(fileURL: url, sourceURL: nil, name: "demo")
    }

    @MainActor
    static func apply(app: AppState, store: PackStore) {
        guard let screen = screenshotScreen else { return }
        seed(into: store)
        switch screen {
        case "importer": app.selectedTab = .importer
        case "seventv": app.selectedTab = .sevenTV
        case "settings": app.selectedTab = .settings
        case "detail":
            app.selectedTab = .packs
            if let pack = store.packs.first(where: { $0.name == "Meme del gruppo" }) { app.packsPath = [pack.id] }
        case "animated":
            app.selectedTab = .packs
            if let pack = store.packs.first(where: { $0.name == "Reazioni animate" }) { app.packsPath = [pack.id] }
        case "editor":
            app.selectedTab = .packs
            if let item = editorSample() { app.editorItem = item }
        default:
            app.selectedTab = .packs
        }
    }
}
