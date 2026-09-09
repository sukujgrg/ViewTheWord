import AppKit

extension MainWorkspaceController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showPreview(_:)) || menuItem.action == #selector(toggleBlank(_:)) { return windowOpened }
        if menuItem.action == #selector(stopProjection(_:)) { return windowOpened || navigation.isProjecting }
        return true
    }
}

extension MainWorkspaceController {
    func rebuildOptionMenus() {
        let viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = false
        viewMenu.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        viewMenu.submenu("Verse text size") { menu in
            for size in [14, 16, 17, 18, 20, 22, 24, 28, 32] {
                menu.command("\(size) pt", checked: rowFontSize == CGFloat(size)) { [weak self] in
                    self?.setPreference(Double(size), key: AppDefaultsKey.verseRowFontSize)
                }
            }
        }
        viewMenu.command("Primary translation only", checked: primaryOnly) { [weak self] in
            guard let self else { return }
            self.setPreference(!self.primaryOnly, key: AppDefaultsKey.showOnlyPrimary)
        }
        viewMenu.command("Dark appearance", checked: defaults.bool(forKey: AppDefaultsKey.preferDarkMode)) { [weak self] in
            guard let self else { return }
            self.setPreference(!self.defaults.bool(forKey: AppDefaultsKey.preferDarkMode), key: AppDefaultsKey.preferDarkMode)
        }
        viewMenu.addItem(.separator())
        viewMenu.command("Show books", checked: !split.splitViewItems[0].isCollapsed) { [weak self] in self?.split.toggleSidebar(nil) }
        for (index, title) in [(1, "Show bookmarks"), (2, "Show history")] {
            viewMenu.command(title, checked: !chapterSplit.splitViewItems[index].isCollapsed) { [weak self] in
                guard let item = self?.chapterSplit.splitViewItems[index] else { return }
                item.animator().isCollapsed.toggle()
            }
        }
        viewOptions.menu = viewMenu

        let projectionMenu = NSMenu(title: "Projection")
        projectionMenu.autoenablesItems = false
        projectionMenu.addItem(withTitle: "Projection", action: nil, keyEquivalent: "")
        projectionMenu.submenu("Output display") { menu in
            menu.command("Automatic", checked: preferredDisplayID == 0) { [weak self] in self?.setPreference(0, key: AppDefaultsKey.projectorScreenDisplayID) }
            for screen in NSScreen.screens {
                menu.command(screen.localizedName, checked: preferredDisplayID == screen.displayID) { [weak self] in
                    self?.setPreference(screen.displayID, key: AppDefaultsKey.projectorScreenDisplayID)
                }
            }
            if preferredDisplayID != 0 && !NSScreen.screens.contains(where: { $0.displayID == preferredDisplayID }) {
                menu.command("Preferred display (disconnected)", checked: true, enabled: false) {}
            }
        }
        projectionMenu.submenu("Text alignment") { menu in
            let current = defaults.string(forKey: AppDefaultsKey.projectorTextAlignment) ?? ProjectorTextAlignmentMode.center.rawValue
            for mode in ProjectorTextAlignmentMode.allCases {
                menu.command(mode.rawValue.capitalized, checked: current == mode.rawValue) { [weak self] in
                    self?.setPreference(mode.rawValue, key: AppDefaultsKey.projectorTextAlignment)
                }
            }
        }
        projectionMenu.submenu("Reading direction") { menu in
            let current = defaults.string(forKey: AppDefaultsKey.projectorReadingDirection) ?? ProjectorReadingDirectionMode.auto.rawValue
            for (mode, title) in [(ProjectorReadingDirectionMode.auto, "Automatic"), (.leftToRight, "Left to right"), (.rightToLeft, "Right to left")] {
                menu.command(title, checked: current == mode.rawValue) { [weak self] in self?.setPreference(mode.rawValue, key: AppDefaultsKey.projectorReadingDirection) }
            }
        }
        projectionMenu.addItem(.separator())
        for (title, key) in [("Stack translations vertically", AppDefaultsKey.projectorDualLayoutVertical),
                             ("Show translation names", AppDefaultsKey.projectorShowTranslationInfo),
                             ("Transparent background", AppDefaultsKey.transparentBackground)] {
            projectionMenu.command(title, checked: defaults.bool(forKey: key)) { [weak self] in
                guard let self else { return }
                self.setPreference(!self.defaults.bool(forKey: key), key: key)
            }
        }
        projectionOptions.menu = projectionMenu

        let savedMenu = NSMenu(title: "Saved")
        savedMenu.autoenablesItems = false
        let first = savedMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        first.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Saved reference actions")
        savedMenu.command("Clear bookmarks", enabled: !bookmarks.entries.isEmpty) { [weak self] in
            guard let self else { return }
            self.bookmarks.clear(undoManager: self.view.window?.undoManager)
        }
        savedActions.menu = savedMenu
        let historyMenu = NSMenu(title: "History")
        historyMenu.autoenablesItems = false
        let historyTitle = historyMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        historyTitle.image = first.image
        historyMenu.command("Clear history", enabled: !history.groupedSections.isEmpty) { [weak self] in self?.history.clear() }
        historyActions.menu = historyMenu
    }

    func savedMenu(for node: SidebarNode) -> NSMenu? {
        guard let reference = node.reference else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.command("Go to \(reference.verseQuery.title)") { [weak self] in self?.navigate(to: reference) }
        menu.command(bookmarks.contains(reference) ? "Remove bookmark" : "Add bookmark") { [weak self] in self?.toggleBookmark(reference) }
        return menu
    }
}
