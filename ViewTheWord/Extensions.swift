import Foundation
import SwiftUI

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
        let transparentBackground = UserDefaults.standard.bool(forKey: "transparentBackground")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.closable, .borderless],
            backing: .buffered,
            defer: true
        )

        // Use the last screen if available (typically the projector), otherwise use main screen
        guard let targetScreen = NSScreen.screens.last ?? NSScreen.main else {
            logger.warning("No screen available for projector window")
            return nil
        }

        window.setFrame(targetScreen.frame, display: true)
        window.level = NSWindow.Level.screenSaver
        window.orderFrontRegardless()  // useful when showing over a fullscreen background video.
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
        window.contentView = NSHostingView(rootView: self)
    }
}
