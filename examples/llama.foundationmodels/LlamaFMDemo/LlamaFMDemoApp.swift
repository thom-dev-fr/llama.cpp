import LlamaEngine
import SwiftUI

@main
struct LlamaFMDemoApp: App {
    // Created at launch, background launches included: the downloads object
    // must exist to reattach the transfers of its background session.
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { old, new in
            model.scenePhaseChanged(from: old, to: new)
        }
        #if os(iOS)
        .backgroundTask(.urlSession(LlamaModelDownloads.defaultSessionIdentifier)) { [downloads = model.downloads] in
            await downloads?.backgroundEventsFinished()
        }
        #endif
    }
}
