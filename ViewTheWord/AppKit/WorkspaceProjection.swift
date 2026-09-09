import AppKit
import SwiftUI

extension MainWorkspaceController {
    func publish(_ projection: PreparedProjection, preserveBlanking: Bool = false) {
        projector.project(projection.data, owner: projection.owner, preserveBlanking: preserveBlanking)
        openProjector()
        scheduleRender()
    }

    func applyProjectorAppearance(_ window: NSWindow) {
        let transparent = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .black
    }
    func repositionProjector(_ window: NSWindow) {
        guard let screen = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID), window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }
    func scheduleProjectorReposition() {
        repositionTask?.cancel()
        repositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.windowOpened, let window = self.ownedProjectorWindow else { return }
            self.repositionProjector(window)
        }
    }
    func openProjector() {
        if let window = ownedProjectorWindow {
            applyProjectorAppearance(window)
            repositionProjector(window)
            let priorKeyWindow = NSApplication.shared.keyWindow
            window.orderFrontRegardless()
            if let priorKeyWindow, priorKeyWindow !== window { priorKeyWindow.makeKey() }
            windowOpened = true
            return
        }
        guard !windowOpened, projector.projectionOwner != nil else { return }
        windowOpened = true
        if let projectorWindowFactory { ownedProjectorWindow = projectorWindowFactory(projector) }
        else { ownedProjectorWindow = ProjectorView().environmentObject(projector).openNewWindow(with: AppWindowTitle.projector) }
        guard let window = ownedProjectorWindow else { windowOpened = false; return }
        applyProjectorAppearance(window)
    }
    func closeProjector() {
        navigation.cancelProjection()
        repositionTask?.cancel()
        repositionTask = nil
        preview.performClose(nil)
        if let window = ownedProjectorWindow { window.close() }
        else { handleProjectorWindowClosed() }
    }
    func handleProjectorWindowClosed() {
        repositionTask?.cancel()
        let cancellationID = navigation.cancelProjection(updateStatus: false)
        let revision = projector.revision
        let closingWindow = ownedProjectorWindow
        // Window close notifications arrive inside AppKit teardown. Keep both
        // guards so deferred cleanup cannot erase a newer projection intent.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.projector.revision == revision, self.ownedProjectorWindow === closingWindow else { return }
            self.repositionTask = nil
            self.navigation.finishProjectionCancellation(cancellationID)
            self.projector.clearProjection()
            self.ownedProjectorWindow = nil
            self.windowOpened = false
            self.scheduleRender()
        }
    }
    @objc func stopProjection(_ sender: Any?) { closeProjector() }
    @objc func toggleBlank(_ sender: Any?) {
        guard windowOpened else { return }
        projector.toggleBlank()
    }
    @objc func showPreview(_ sender: Any?) {
        guard windowOpened else { return }
        if preview.isShown { preview.performClose(sender); return }
        let size = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID)?.frame.size ?? NSSize(width: 1920, height: 1080)
        preview.behavior = .transient
        preview.contentViewController = NSHostingController(rootView: ProjectionPreview(outputSize: size).environmentObject(projector))
        preview.show(relativeTo: previewButton.bounds, of: previewButton, preferredEdge: .maxY)
    }
}

private struct ProjectionPreview: View {
    let outputSize: CGSize
    var body: some View {
        let scale = min(520 / max(1, outputSize.width), 320 / max(1, outputSize.height))
        VStack(alignment: .leading, spacing: 10) {
            ProjectorView()
                .frame(width: outputSize.width, height: outputSize.height)
                .background(.black)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: outputSize.width * scale, height: outputSize.height * scale, alignment: .topLeading)
                .clipped()
            Text("Live output preview").font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}
