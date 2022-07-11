import Foundation
import SwiftUI

extension Array: RawRepresentable where Element: Codable {
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
    private func newWindowInternal(with title: String) -> NSWindow {
        @AppStorage("transparentBackground") var transparentBackground = false


        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.closable, .borderless],
            backing: .buffered,
            defer: true
        )

        guard let secondScreen = NSScreen.screens.last else {
            return window
        }

        window.setFrame(secondScreen.frame, display: true)
        window.level = NSWindow.Level.screenSaver
        window.isReleasedWhenClosed = false
        window.title = title
        window.orderFront(nil)
        window.canHide = true
        window.hasShadow = false  // this has to set if NSColor.clear has to work without showing prior verse as shadow.
        if transparentBackground {
            window.isOpaque = false
            window.backgroundColor = NSColor.clear // NSColor(red: 1, green: 0.5, blue: 0.5, alpha: 0.5)
        } else {
            window.isOpaque = true
        }
        return window
    }

    func openNewWindow(with title: String = "new Window") {
        newWindowInternal(with: title).contentView = NSHostingView(rootView: self)
    }
}


extension NSTextField {
    override open var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
}
