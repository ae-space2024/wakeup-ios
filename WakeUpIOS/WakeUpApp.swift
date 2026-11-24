import SwiftUI

@main
struct WakeUpApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(state)
                .accentColor(.green)
        }
    }
}
