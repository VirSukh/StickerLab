import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PackStore
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView(selection: $app.selectedTab) {
            NavigationStack(path: $app.packsPath) { PackListView() }
                .tabItem { Label("Pacchetti", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.packs)
            NavigationStack { ImportView() }
                .tabItem { Label("Importa", systemImage: "square.and.arrow.down.fill") }
                .tag(AppTab.importer)
            NavigationStack { EmoteBrowserView() }
                .tabItem { Label("Emote", systemImage: "face.smiling.inverse") }
                .tag(AppTab.sevenTV)
            NavigationStack { MemeTemplatesView() }
                .tabItem { Label("Meme", systemImage: "theatermasks.fill") }
                .tag(AppTab.memes)
            NavigationStack { SettingsView() }
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .minimizingTabBar()
        .preferredColorScheme(.dark)
        .sheet(item: $app.editorItem) { item in
            EditorView(item: item)
                .environmentObject(store)
                .environmentObject(app)
        }
        .sheet(item: $app.batchRequest) { request in
            BatchImportView(request: request)
                .environmentObject(store)
                .environmentObject(app)
        }
        .overlay {
            if let message = app.busyMessage { BusyOverlay(message: message) }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCapsule(tint: .green)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        app.toast = nil
                    }
            }
        }
        .animation(.spring(response: 0.35), value: app.toast)
        .alert(
            "StickerLab",
            isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        .onAppear {
            Downloader.cleanTemporaryFiles()
            FontRegistry.registerAll()
        }
    }
}
