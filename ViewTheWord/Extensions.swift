import Foundation
import SwiftUI

private final class ProjectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        requestProjectorClose()
    }

    override func keyDown(with event: NSEvent) {
        // ESC should always close projection when this window is active.
        if event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    private func requestProjectorClose() {
        // Defer close request to next turn of the run loop so AppKit can
        // finish event handling before we tear down the hosted SwiftUI view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .closeProjectorRequested, object: self)
        }
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
    /// The shared live controller has already resolved its UUID assignment.
    /// This helper never chooses a monitor or reads output preferences.
    private func newWindowInternal(with title: String, on targetScreen: NSScreen) -> NSWindow {
        let window = ProjectorWindow(
            contentRect: ProjectionScreenResolver.screenRelativeContentRect(for: targetScreen.frame),
            styleMask: [.closable, .borderless], backing: .buffered, defer: true, screen: targetScreen
        )
        window.setFrame(targetScreen.frame, display: false)
        window.level = NSWindow.Level.screenSaver
        window.isReleasedWhenClosed = false
        window.title = title
        window.canHide = false
        window.hasShadow = false  // this has to be set if NSColor.clear has to work without showing prior verse as shadow.
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        return window
    }

    func makeProjectorWindow(with title: String, on screen: NSScreen) -> NSWindow {
        let window = newWindowInternal(with: title, on: screen)
        let hostView = NSHostingView(rootView: self)
        hostView.sizingOptions = []
        hostView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: window.frame)
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window.contentView = container
        return window
    }
}
