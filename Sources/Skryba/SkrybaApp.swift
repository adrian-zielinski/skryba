import SwiftUI

struct SkrybaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Skryba") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
