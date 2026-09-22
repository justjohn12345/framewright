import SwiftUI

@main
struct VidEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VidEdit") {
            ContentView()
        }
    }
}
