import SwiftUI

/// Release notes from the bundled CHANGELOG.md ("## version" headings, "- " bullet lines).
struct ReleaseNotes {
    struct Release: Identifiable {
        let version: String
        let items: [String]
        var id: String { version }
    }

    static let all: [Release] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var releases: [Release] = []
        var version: String?
        var items: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if let version { releases.append(Release(version: version, items: items)) }
                version = String(line.dropFirst(3))
                items = []
            } else if line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
            }
        }
        if let version { releases.append(Release(version: version, items: items)) }
        return releases
    }()

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ReleaseNotes.all) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Versione \(release.version)").font(.title3.weight(.bold))
                                Spacer()
                                if release.version == ReleaseNotes.currentVersion {
                                    Text("Installata")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .glassCapsule(tint: .green)
                                }
                            }
                            ForEach(release.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "sparkle")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.top, 3)
                                    Text(item).font(.subheadline)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 26)
                    }
                    if ReleaseNotes.all.isEmpty {
                        Text("Nessuna nota disponibile.").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .appBackground()
            .navigationTitle("Novità")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
    }
}
