import SwiftUI

@main
struct StickerLabApp: App {
    @StateObject private var store = PackStore()
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(app)
                .onOpenURL { url in
                    app.handleOpenURL(url, store: store)
                }
        }
    }
}
