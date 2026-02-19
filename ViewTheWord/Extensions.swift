import Foundation
import SwiftUI

private final class ProjectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        // ESC should always close projection when this window is active.
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }
}

extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

extension View {
    private func newWindowInternal(with title: String) -> NSWindow? {
        let transparentBackground = UserDefaults.standard.bool(forKey: AppDefaultsKey.transparentBackground)

        let window = ProjectorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.closable, .borderless],
            backing: .buffered,
            defer: true
        )

        // Use the last screen if available (typically the projector), otherwise use main screen
        // Filter to only active screens to avoid stale display identifiers
        let availableScreens = NSScreen.screens.filter { screen in
            // Check if screen frame is valid (not zero)
            return screen.frame.width > 0 && screen.frame.height > 0
        }

        guard let targetScreen = availableScreens.last ?? NSScreen.main else {
            logger.warning("No screen available for projector window")
            return nil
        }

        window.setFrame(targetScreen.frame, display: true)
        window.level = NSWindow.Level.screenSaver
        window.isReleasedWhenClosed = false
        window.title = title
        window.canHide = false
        window.hasShadow = false  // this has to be set if NSColor.clear has to work without showing prior verse as shadow.

        if transparentBackground {
            window.isOpaque = false
            window.backgroundColor = NSColor.clear
        } else {
            window.isOpaque = true
        }

        return window
    }

    func openNewWindow(with title: String = "new Window") {
        guard let window = newWindowInternal(with: title) else {
            logger.error("Failed to create projector window")
            return
        }
        let priorKeyWindow = NSApplication.shared.keyWindow
        window.contentView = NSHostingView(rootView: self)
        window.orderFrontRegardless()  // useful when showing over a fullscreen background video.

        // Keep keyboard focus on the main app window so verse navigation shortcuts
        // continue working while projection is visible.
        if let priorKeyWindow, priorKeyWindow != window {
            priorKeyWindow.makeKey()
        }
    }
}
