import SwiftUI

@main
struct VivacityApp: App {
    var body: some Scene {
        AppEnvironment.configureForTestingIfNeeded()
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 560, height: 620)
    }
}
