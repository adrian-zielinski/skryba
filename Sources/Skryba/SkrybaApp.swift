import SwiftUI

struct SkrybaApp: App {
    var body: some Scene {
        WindowGroup("Skryba") {
            RootView()
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
