import AppKit
import SwiftUI
import Combine

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workspace: MainWorkspaceController
    private let bookmarkUndo: UndoManager
    weak var passages: PassageTabsController?
    var onClose: () -> Void = {}

    init(workspace: MainWorkspaceController? = nil, savesFrame: Bool = true, bookmarkUndo: UndoManager? = nil) {
        self.workspace = workspace ?? MainWorkspaceController()
        self.bookmarkUndo = bookmarkUndo ?? UndoManager()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "New Passage"
        window.tabbingIdentifier = "ViewTheWord.Passage"
        window.tabbingMode = .preferred
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = self.workspace
        window.contentMinSize = NSSize(width: 950, height: 600)
        window.toolbar = self.workspace.makeToolbar()
        window.initialFirstResponder = self.workspace.search.field
        window.delegate = self
        if !savesFrame || !window.setFrameUsingName("NativeMainWorkspace") {
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()
        }
        if savesFrame { window.setFrameAutosaveName("NativeMainWorkspace") }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { bookmarkUndo }
    func windowWillClose(_ notification: Notification) { workspace.shutdown(); onClose() }
    func windowDidBecomeKey(_ notification: Notification) {
        passages?.didSelect(self)
        workspace.scheduleRender()
    }
    override func newWindowForTab(_ sender: Any?) { passages?.open(after: self) }
    @objc func openInNewTab(_ sender: Any?) { workspace.openInNewTab(sender) }
    @objc func closePassageWindow(_ sender: Any?) {
        for tab in window?.tabGroup?.windows ?? [window].compactMap({ $0 }) { tab.performClose(sender) }
    }
    @objc func moveTabLeft(_ sender: Any?) { moveTab(by: -1) }
    @objc func moveTabRight(_ sender: Any?) { moveTab(by: 1) }
    private func moveTab(by offset: Int) {
        guard let window, let group = window.tabGroup, let index = group.windows.firstIndex(of: window),
              group.windows.indices.contains(index + offset) else { return }
        group.insertWindow(window, at: index + offset)
        group.selectedWindow = window
    }
    @objc func undo(_ sender: Any?) { bookmarkUndo.undo() }
    @objc func redo(_ sender: Any?) { bookmarkUndo.redo() }
    // Toolbar editors join the window's responder chain, outside the content
    // controller hierarchy. Keep the same commands available from that context.
    @objc func focusSearch(_ sender: Any?) { workspace.focusSearch(sender) }
    @objc func toggleSidebar(_ sender: Any?) { workspace.split.toggleSidebar(sender) }
    @objc func showPreview(_ sender: Any?) { workspace.showPreview(sender) }
    @objc func toggleBlank(_ sender: Any?) { workspace.toggleBlank(sender) }
    @objc func stopProjection(_ sender: Any?) { workspace.stopProjection(sender) }
    override func cancelOperation(_ sender: Any?) { workspace.closeProjector() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { menuItem.title = bookmarkUndo.undoMenuItemTitle; return bookmarkUndo.canUndo }
        if menuItem.action == #selector(redo(_:)) { menuItem.title = bookmarkUndo.redoMenuItemTitle; return bookmarkUndo.canRedo }
        if menuItem.action == #selector(showPreview(_:)) || menuItem.action == #selector(toggleBlank(_:)) { return workspace.windowOpened }
        if menuItem.action == #selector(stopProjection(_:)) { return workspace.windowOpened || workspace.liveProjection.isProjecting }
        if menuItem.action == #selector(moveTabLeft(_:)) { return window?.tabGroup?.windows.first !== window }
        if menuItem.action == #selector(moveTabRight(_:)) { return window?.tabGroup?.windows.last !== window }
        return true
    }
}

/// Retains passage controllers even when AppKit hides or detaches their tabs.
/// Native tab groups own ordering/selection; no workspace is rebuilt on a switch.
@MainActor
final class PassageTabsController {
    let liveProjection: LiveProjectionController
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let bookmarkUndo = UndoManager()
    let updates: AppUpdateController?
    private let navigationFactory: @MainActor () -> VerseTargetModel
    private let savesFrames: Bool
    private(set) var windows: [MainWindowController] = []
    private weak var lastSelected: MainWindowController?

    init(liveProjection: LiveProjectionController? = nil, history: HistoryStore? = nil,
         bookmarks: BookmarkStore? = nil, savesFrames: Bool = true, updates: AppUpdateController? = nil,
         navigationFactory: @escaping @MainActor () -> VerseTargetModel = { VerseTargetModel() }) {
        self.liveProjection = liveProjection ?? LiveProjectionController()
        self.history = history ?? .shared
        self.bookmarks = bookmarks ?? .shared
        self.savesFrames = savesFrames
        self.updates = updates
        self.navigationFactory = navigationFactory
    }
    var selected: MainWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? MainWindowController,
           windows.contains(where: { $0 === controller }) { return controller }
        return lastSelected ?? windows.first
    }
    func didSelect(_ controller: MainWindowController) { lastSelected = controller }

    @discardableResult
    func open(reference: VerseReference? = nil, after origin: MainWindowController? = nil) -> MainWindowController {
        let workspace = MainWorkspaceController(navigation: navigationFactory(), history: history, bookmarks: bookmarks,
                                                liveProjection: liveProjection, updates: updates)
        let controller = MainWindowController(workspace: workspace, savesFrame: savesFrames, bookmarkUndo: bookmarkUndo)
        controller.passages = self
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            if self.lastSelected === controller { self.lastSelected = nil }
        }
        workspace.onOpenInNewTab = { [weak self, weak controller] reference in
            guard let self, let controller else { return }
            self.open(reference: reference, after: controller)
        }
        if let originWindow = origin?.window, let window = controller.window {
            originWindow.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if let window = controller.window {
            window.tabGroup?.selectedWindow = window
            if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
        }
        lastSelected = controller
        if let reference { workspace.navigate(to: reference) }
        workspace.scheduleRender()
        return controller
    }
    func showSelected() {
        let controller = selected ?? open()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.workspace.scheduleRender()
    }
    func shutdown() {
        for controller in windows { controller.workspace.shutdown() }
        liveProjection.shutdown()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var passages = PassageTabsController(updates: updates)
    private let updates: AppUpdateController?
    private var settingsWindow: NSWindowController?
    private var helpWindow: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        #if SWIFT_PACKAGE || VTW_REVIEW
        updates = nil
        #else
        updates = AppUpdateController(driver: SparkleUpdateDriver())
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.register(defaults: [
            AppDefaultsKey.fontSizeVerse: AppDefaults.verseFontSize,
            AppDefaultsKey.fontSizeVerseRef: AppDefaults.referenceFontSize,
            AppDefaultsKey.projectorPadding: AppDefaults.projectorPadding,
            AppDefaultsKey.verseRowFontSize: 17.0,
            AppDefaultsKey.projectorShowTranslationInfo: true,
            AppDefaultsKey.projectorTextAlignment: ProjectorTextAlignmentMode.center.rawValue,
            AppDefaultsKey.projectorReadingDirection: ProjectorReadingDirectionMode.auto.rawValue
        ])
        buildMenu()
        applyAppearance()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.applyAppearance() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .toggleKeyboardShortcuts)
            .sink { [weak self] _ in self?.showHelp(nil) }.store(in: &subscriptions)
        showMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        updates?.start()
    }
    private func applyAppearance() {
        let name: NSAppearance.Name = UserDefaults.standard.bool(forKey: AppDefaultsKey.preferDarkMode) ? .darkAqua : .aqua
        if NSApplication.shared.appearance?.name != name { NSApplication.shared.appearance = NSAppearance(named: name) }
    }
    private func showMainWindow() { passages.showSelected() }
    @objc func newWindowForTab(_ sender: Any?) { passages.open(after: passages.selected) }
    @objc func newPassageWindow(_ sender: Any?) { passages.open() }
    @objc func stopProjection(_ sender: Any?) { passages.liveProjection.closeProjector() }
    @objc func toggleBlank(_ sender: Any?) { passages.liveProjection.toggleBlank() }
    @objc func showPreview(_ sender: Any?) {
        showMainWindow()
        passages.selected?.workspace.showPreview(sender)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { passages.shutdown() }
    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        for url in urls { BibleLibrary.shared.importFile(url, presenter: .main) }
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = hostedWindow(title: "Settings", root: SettingsView(), size: NSSize(width: 540, height: 440)) }
        settingsWindow?.showWindow(sender)
        settingsWindow?.window?.makeKeyAndOrderFront(sender)
    }
    @objc func showHelp(_ sender: Any?) {
        if helpWindow == nil {
            helpWindow = hostedWindow(title: "View The Word Help", root: KeyboardShortcutsView(dismiss: { [weak self] in self?.helpWindow?.close() }), size: NSSize(width: 880, height: 650), resizable: true)
        }
        helpWindow?.showWindow(sender)
        helpWindow?.window?.makeKeyAndOrderFront(sender)
    }
    private func hostedWindow<Content: View>(title: String, root: Content, size: NSSize, resizable: Bool = false) -> NSWindowController {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: resizable ? [.titled, .closable, .resizable] : [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
    func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            bar.addItem(item)
            return item.submenu!
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil,
                  modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
        }
        let app = menu("View The Word")
        item(app, "About View The Word", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        if let updates {
            item(app, "Check for Updates…", #selector(AppUpdateController.checkForUpdates(_:)), target: updates)
            item(app, "Automatically Check for Updates", #selector(AppUpdateController.toggleAutomaticChecks(_:)), target: updates)
        }
        app.addItem(.separator())
        item(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        app.addItem(services)
        NSApplication.shared.servicesMenu = services.submenu
        app.addItem(.separator())
        item(app, "Hide View The Word", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit View The Word", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New Tab", #selector(NSResponder.newWindowForTab(_:)), "t")
        item(file, "New Window", #selector(newPassageWindow(_:)), "n", target: self)
        item(file, "Open in New Tab", #selector(MainWindowController.openInNewTab(_:)), "\r")
        file.addItem(.separator())
        item(file, "Close Tab", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Close Window", #selector(MainWindowController.closePassageWindow(_:)), "w", modifiers: [.command, .shift])
        let edit = menu("Edit")
        item(edit, "Undo", #selector(MainWindowController.undo(_:)), "z")
        item(edit, "Redo", #selector(MainWindowController.redo(_:)), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = menu("View")
        item(view, "Focus Search", #selector(MainWorkspaceController.focusSearch(_:)), "l")
        item(view, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", modifiers: [.command, .control])
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let projection = menu("Projection")
        item(projection, "Preview", #selector(MainWorkspaceController.showPreview(_:)))
        item(projection, "Blank / Unblank", #selector(MainWorkspaceController.toggleBlank(_:)))
        item(projection, "Stop", #selector(MainWorkspaceController.stopProjection(_:)))
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        item(window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift])
        item(window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift])
        item(window, "Select Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", modifiers: [.control, .shift])
        item(window, "Select Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", modifiers: .control)
        item(window, "Move Tab Left", #selector(MainWindowController.moveTabLeft(_:)))
        item(window, "Move Tab Right", #selector(MainWindowController.moveTabRight(_:)))
        item(window, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
        item(window, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
        item(window, "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)))
        window.addItem(.separator())
        item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApplication.shared.windowsMenu = window
        let help = menu("Help")
        item(help, "View The Word Help", #selector(showHelp(_:)), "/", target: self)
        NSApplication.shared.helpMenu = help
        NSApplication.shared.mainMenu = bar
    }
}
