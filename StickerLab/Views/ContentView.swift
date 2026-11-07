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
            NavigationStack { SevenTVView() }
                .tabItem { Label("7TV", systemImage: "face.smiling.inverse") }
                .tag(AppTab.sevenTV)
            NavigationStack { SettingsView() }
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
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
            DemoData.apply(app: app, store: store)
        }
    }
}
