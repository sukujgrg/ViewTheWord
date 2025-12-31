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
        Window("", id: "main") {
            ContentView()
                .navigationTitle("")
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replace Help menu to avoid duplicates
            CommandGroup(replacing: .help) {
                Button("ViewTheWord Help") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleKeyboardShortcuts"), object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: NSNotification.Name("FocusSearchField"), object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
