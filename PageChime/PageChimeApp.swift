import SwiftUI

@main
struct PageChimeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up new cloud sounds on launch and whenever the app returns.
            if phase == .active {
                Task { await SoundLibrary.shared.refresh() }
            }
        }
    }
}
