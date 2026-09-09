import AppKit

extension NSToolbarItem.Identifier {
    static let workspaceSearch = Self("workspace-search")
    static let workspaceSearchMode = Self("workspace-search-mode")
    static let workspaceView = Self("workspace-view")
    static let workspaceProjection = Self("workspace-projection")
}

extension MainWorkspaceController: NSToolbarDelegate {
    func buildInterface() {
        addChild(split)
        split.splitView.isVertical = true
        split.splitView.autosaveName = "nativeWorkspaceColumns"
        let bookItem = NSSplitViewItem(sidebarWithViewController: books)
        bookItem.minimumThickness = 160
        bookItem.maximumThickness = 280
        bookItem.preferredThicknessFraction = 0.17
        split.addSplitViewItem(bookItem)

        chapterSplit.splitView.isVertical = false
        chapterSplit.splitView.autosaveName = "nativeChaptersAndSaved"
        let chapterPane = WorkspacePaneController(title: "Chapters", content: chapters.view, heading: chapterTitle)
        chapterPane.addChild(chapters)
        let chapterItem = NSSplitViewItem(viewController: chapterPane)
        chapterItem.minimumThickness = 120
        chapterItem.preferredThicknessFraction = 0.42
        chapterSplit.addSplitViewItem(chapterItem)
        for (title, saved, actions) in [("Bookmarks", savedBookmarks, savedActions), ("History", savedHistory, historyActions)] {
            let pane = WorkspacePaneController(title: title, content: saved.view, accessory: actions)
            pane.addChild(saved)
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 100
            item.canCollapse = true
            chapterSplit.addSplitViewItem(item)
        }
        let middle = NSSplitViewItem(viewController: chapterSplit)
        middle.minimumThickness = 160
        middle.maximumThickness = 400
        middle.preferredThicknessFraction = 0.16
        split.addSplitViewItem(middle)

        let detail = NSViewController()
        detail.view = makeDetailView()
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 530
        split.addSplitViewItem(detailItem)
        pin(split.view, to: view)

        searchModeControl.target = self
        searchModeControl.action = #selector(searchModeChanged(_:))
        searchModeControl.setAccessibilityLabel("Search mode")
        searchModeControl.setToolTip("Book, chapter and verse", forSegment: 0)
        searchModeControl.setToolTip("Words with AND, OR and NOT", forSegment: 1)
        searchModeControl.setToolTip("Exact phrase", forSegment: 2)
        primaryPicker.target = self
        primaryPicker.action = #selector(translationChanged(_:))
        secondaryPicker.target = self
        secondaryPicker.action = #selector(translationChanged(_:))
        primaryPicker.setAccessibilityLabel("Primary translation")
        secondaryPicker.setAccessibilityLabel("Secondary translation")
        primaryPicker.toolTip = "Primary translation"
        secondaryPicker.toolTip = "Secondary translation"
        for button in [previewButton, blankButton, stopButton, loadMoreButton] { button.bezelStyle = .rounded; button.target = self }
        previewButton.action = #selector(showPreview(_:))
        blankButton.action = #selector(toggleBlank(_:))
        stopButton.action = #selector(stopProjection(_:))
        loadMoreButton.action = #selector(loadMore(_:))
        savedActions.bezelStyle = .accessoryBarAction
        historyActions.bezelStyle = .accessoryBarAction
        historyActions.setAccessibilityLabel("History actions")
        savedActions.setAccessibilityLabel("Saved reference actions")
        viewOptions.setAccessibilityLabel("View options")
        projectionOptions.setAccessibilityLabel("Projection options")
    }

    private func makeDetailView() -> NSView {
        let content = NSView()
        let heading = horizontalStack([primaryPicker, NSView(), referenceTitle, NSView(), secondaryPicker], spacing: 10)
        heading.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 10, right: 16)
        // Keep the title centered even when translation names have different widths
        // or the secondary translation is hidden.
        heading.detachesHiddenViews = false
        referenceTitle.alignment = .center
        referenceTitle.centerXAnchor.constraint(equalTo: heading.centerXAnchor).isActive = true
        referenceTitle.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        primaryPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        secondaryPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        primaryPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = horizontalStack([statusLabel, NSView(), loadingLabel, previewButton, blankButton, stopButton])
        status.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        loadingLabel.widthAnchor.constraint(equalToConstant: 86).isActive = true
        loadingLabel.textColor = .secondaryLabelColor
        resultsHeader.orientation = .horizontal
        resultsHeader.addArrangedSubview(resultLabel)
        resultsHeader.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let tableContainer = NSView()
        pin(verses.scrollView, to: tableContainer)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor, constant: -24)
        ])
        footer.orientation = .horizontal
        footer.addArrangedSubview(messageLabel)
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        messageLabel.textColor = .secondaryLabelColor
        let screenRow = horizontalStack([screenLabel, NSView()])
        screenRow.edgeInsets = NSEdgeInsets(top: 5, left: 16, bottom: 5, right: 16)
        screenLabel.textColor = .secondaryLabelColor
        let stack = WorkspaceColumnStack(content: [status, heading, separator(), resultsHeader, tableContainer,
                                       loadMoreButton, footer, separator(), screenRow])
        for row in [heading, status, resultsHeader, footer, screenRow] {
            row.setContentHuggingPriority(.required, for: .vertical)
        }
        pin(stack, to: content)
        return content
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainWorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .workspaceSearch, .workspaceSearchMode, .flexibleSpace, .workspaceView, .workspaceProjection]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        if identifier == .workspaceSearch {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = search.field
            item.preferredWidthForSearchField = 340
            item.resignsFirstResponderWithCancel = false
            item.label = "Search"
            item.visibilityPriority = .high
            searchToolbarItem = item
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case .workspaceSearchMode: item.label = "Search mode"; item.view = searchModeControl; item.visibilityPriority = .high
        case .workspaceView: item.label = "View"; item.view = viewOptions
        case .workspaceProjection: item.label = "Projection"; item.view = projectionOptions
        default: return nil
        }
        return item
    }

    func renderSearchField() {
        let placeholder: String
        switch searchMode {
        case .verseReference: placeholder = "John 3:16"
        case .wordSearch: placeholder = "faith AND hope"
        case .phraseSearch: placeholder = "in the beginning"
        }
        search.apply(text: draft, placeholder: placeholder, accessibilityHint: "Press Return to search. Command-L focuses search.",
                     recentsName: AppDefaultsKey.searchRecents + "." + searchMode.rawValue)
        searchModeControl.selectedSegment = SearchMode.allCases.firstIndex(of: searchMode) ?? 0
    }
    func renderTranslationPickers(_ sources: BibleSources) {
        for (picker, selected) in [(primaryPicker, Optional(sources.primary)), (secondaryPicker, sources.secondary)] {
            let urls = Array(Set(library.urls + [sources.primary] + [sources.secondary].compactMap { $0 })).sorted { $0.lastPathComponent < $1.lastPathComponent }
            if picker.itemArray.compactMap({ $0.representedObject as? String }) != urls.map(\.absoluteString) {
                picker.removeAllItems()
                for url in urls {
                    picker.addItem(withTitle: BibleTranslation.name(for: url))
                    picker.lastItem?.representedObject = url.absoluteString
                }
            }
            if let index = picker.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected?.absoluteString }) {
                picker.selectItem(at: index)
            }
        }
        secondaryPicker.isHidden = primaryOnly
    }
    func renderStatus() {
        let live = windowOpened && projector.projectionOwner != nil
        statusLabel.stringValue = live ? "\(projector.isBlanked ? "Blanked" : "Live") · \(projector.projectorViewData.title)" : "Projection stopped"
        statusLabel.textColor = live && !projector.isBlanked ? .systemGreen : .secondaryLabelColor
        loadingLabel.stringValue = navigation.isProjecting ? "Projecting…" : navigation.isLoading ? "Loading…" : ""
        blankButton.title = projector.isBlanked ? "Unblank" : "Blank"
        previewButton.isEnabled = live
        blankButton.isEnabled = live
        stopButton.isEnabled = live || navigation.isProjecting
        let screen = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID)
        let disconnected = preferredDisplayID != 0 && !NSScreen.screens.contains { $0.displayID == preferredDisplayID }
        screenLabel.stringValue = "Output: \(screen?.localizedName ?? "No display")\(disconnected ? " · preferred display disconnected" : "")"
    }
    @objc private func searchModeChanged(_ sender: NSSegmentedControl) {
        guard SearchMode.allCases.indices.contains(sender.selectedSegment) else { return }
        changeSearchMode(SearchMode.allCases[sender.selectedSegment])
    }
    @objc private func translationChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        setPreference(value, key: sender === primaryPicker ? AppDefaultsKey.primaryBibleName : AppDefaultsKey.secondaryBibleName)
    }
    @objc func loadMore(_ sender: Any?) {
        guard let request = navigation.searchRequest, !navigation.isLoading else { return }
        navigation.search(request, sources: sources, loadMore: true)
    }
    func setPreference(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
        scheduleRender()
    }
}
