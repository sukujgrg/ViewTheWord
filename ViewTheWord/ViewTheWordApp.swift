import SwiftUI


// https://www.optionalmap.com/posts/swiftui_single_window_app/
// disabled multiple window and tabs.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

@main
struct ViewTheWordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("View The Word", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView()
        }
    }
}
