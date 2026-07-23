import SwiftUI

@main
struct PSTConvertApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 480)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
