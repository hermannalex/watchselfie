import SwiftUI

@main
struct WatchSelfieWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
        }
    }
}
