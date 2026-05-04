import SwiftUI

@main
struct BucketsApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("BucketKit Test App") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 620)
        }
    }
}
