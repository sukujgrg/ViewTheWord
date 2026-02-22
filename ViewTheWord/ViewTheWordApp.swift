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
    @AppStorage(AppDefaultsKey.preferDarkMode) private var preferDarkMode = false

    var body: some Scene {
        Window("", id: "main") {
            ContentView()
                .navigationTitle("")
                .preferredColorScheme(preferDarkMode ? .dark : .light)
        }
        // Keep only minimum content-size enforcement; full content-size tracking
        // can trigger recursive constraint updates on complex split hierarchies.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replace Help menu to avoid duplicates
            CommandGroup(replacing: .help) {
                Button("ViewTheWord Help") {
                    NotificationCenter.default.post(name: .toggleKeyboardShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(preferDarkMode ? .dark : .light)
        }
    }
}
