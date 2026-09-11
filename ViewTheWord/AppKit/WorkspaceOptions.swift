import AppKit

extension MainWorkspaceController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showPreview(_:)) || menuItem.action == #selector(toggleBlank(_:)) { return windowOpened }
        if menuItem.action == #selector(stopProjection(_:)) { return windowOpened || liveProjection.isProjecting }
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
    }

    @objc func clearBookmarks(_ sender: Any?) {
        bookmarks.clear(undoManager: view.window?.undoManager)
    }

    @objc func clearHistory(_ sender: Any?) {
        history.clear()
    }

    func passageMenu(for reference: VerseReference) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.command("Open in New Tab") { [weak self] in self?.onOpenInNewTab?(reference) }
        return menu
    }

    @objc func openInNewTab(_ sender: Any?) {
        let responder = view.window?.firstResponder
        let reference: VerseReference?
        if responder === books.outline, let book = books.selectedNode?.book {
            reference = VerseReference(book: book, chapter: 1, verse: 1)
        } else if responder === chapters.collection { reference = chapters.selectedReference }
        else if responder === savedBookmarks.outline { reference = savedBookmarks.selectedNode?.reference }
        else if responder === savedHistory.outline { reference = savedHistory.selectedNode?.reference }
        else { reference = verses.selectedReference ?? navigation.refreshReference }
        onOpenInNewTab?(reference)
    }

    func savedMenu(for node: SidebarNode) -> NSMenu? {
        guard let reference = node.reference else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.command("Go to \(reference.verseQuery.title)") { [weak self] in self?.navigate(to: reference, project: true) }
        menu.command("Open in New Tab") { [weak self] in self?.onOpenInNewTab?(reference) }
        menu.command(bookmarks.contains(reference) ? "Remove bookmark" : "Add bookmark") { [weak self] in self?.toggleBookmark(reference) }
        return menu
    }
}
