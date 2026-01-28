import SwiftUI

struct ContentView: View {
    @StateObject private var model: AstraIOSAppModel
    @StateObject private var store: BoardStore

    init() {
        let m = AstraIOSAppModel()
        _model = StateObject(wrappedValue: m)
        _store = StateObject(wrappedValue: BoardStore(
            boardID: m.defaultBoardId,
            persistence: m.persistence,
            aiService: m.aiService,
            webSearchService: m.webSearchService,
            authService: m.authService
        ))
    }

    var body: some View {
        BoardCanvasView_iOS(store: store)
            .environmentObject(store)
            .environmentObject(store.authService)
            .environmentObject(store.syncService)
            .onOpenURL { url in
                guard AuthService.isAuthCallbackURL(url) else { return }
                Task {
                    do {
                        try await model.authService.handleOpenURL(url)
                    } catch {
                        NSLog("Supabase auth: callback handling failed: \(error)")
                    }
                }
            }
    }
}
