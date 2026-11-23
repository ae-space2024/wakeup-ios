import SwiftUI

@main
struct WakeUpApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                WakeView()
                    .tabItem {
                        Label("远程开机", systemImage: "power")
                    }
                PowerView()
                    .tabItem {
                        Label("功率监控", systemImage: "bolt.fill")
                    }
            }
            .environmentObject(state)
            .accentColor(.green)
        }
    }
}
