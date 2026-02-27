import SwiftUI

@main
struct VivacityApp: App {
    init() {
        AppEnvironment.configureForTestingIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 560, height: 620)
    }
}
