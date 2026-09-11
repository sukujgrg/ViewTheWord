import AppKit

extension NSToolbarItem.Identifier {
    static let workspaceSearch = Self("workspace-search")
    static let workspaceSearchMode = Self("workspace-search-mode")
    static let workspaceView = Self("workspace-view")
    static let workspaceProjection = Self("workspace-projection")
    static let workspaceUpdate = Self("workspace-update")
}

extension MainWorkspaceController: NSToolbarDelegate {
    func buildInterface() {
        addChild(split)
        split.splitView.isVertical = true
        split.splitView.autosaveName = "nativeWorkspaceColumns"
        testamentControl.controlSize = .small
        testamentControl.segmentDistribution = .fillEqually
        testamentControl.target = self
        testamentControl.action = #selector(changeTestament(_:))
        testamentControl.setAccessibilityLabel("Testament")
        testamentControl.setAccessibilityIdentifier("workspace-testament")
        for testament in BibleTestament.allCases {
            testamentControl.setToolTip("Show \(testament.title) books", forSegment: testament.rawValue)
        }
        let bookItem = NSSplitViewItem(sidebarWithViewController: books)
        bookItem.minimumThickness = max(160, testamentControl.intrinsicContentSize.width + 24)
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
        for (title, saved, button) in [("Bookmarks", savedBookmarks, clearBookmarksButton), ("History", savedHistory, clearHistoryButton)] {
            let pane = WorkspacePaneController(title: title, content: saved.view, accessory: button)
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
        primaryPicker.toolTip = "Primary translation for this tab"
        secondaryPicker.toolTip = "Secondary translation for this tab. Choose None to show only the primary translation."
        for button in [previewButton, blankButton, stopButton, loadMoreButton] { button.bezelStyle = .rounded; button.target = self }
        previewButton.action = #selector(showPreview(_:))
        blankButton.action = #selector(toggleBlank(_:))
        stopButton.action = #selector(stopProjection(_:))
        loadMoreButton.action = #selector(loadMore(_:))
        for (button, label) in [(clearBookmarksButton, "Clear bookmarks"), (clearHistoryButton, "Clear history")] {
            button.bezelStyle = .accessoryBar
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        clearBookmarksButton.action = #selector(clearBookmarks(_:))
        clearHistoryButton.action = #selector(clearHistory(_:))
        viewOptions.setAccessibilityLabel("View options")
        projectionOptions.setAccessibilityLabel("Projection options")
    }

    private func makeDetailView() -> NSView {
        let content = NSView()
        func translationControl(_ title: String, picker: NSPopUpButton, alignment: NSLayoutConstraint.Attribute) -> NSStackView {
            let label = nativeLabel(title, size: 11)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, picker])
            stack.orientation = .vertical
            stack.alignment = alignment
            stack.spacing = 6
            return stack
        }
        let primaryControl = translationControl("Primary", picker: primaryPicker, alignment: .leading)
        let secondaryControl = translationControl("Secondary", picker: secondaryPicker, alignment: .trailing)
        let heading = horizontalStack([primaryControl, NSView(), referenceTitle, NSView(), secondaryControl], spacing: 16)
        heading.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 18, right: 16)
        // Keep the title centered even when the picker selections have different widths.
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
        dismissProjectionMessageButton.bezelStyle = .inline
        dismissProjectionMessageButton.controlSize = .small
        dismissProjectionMessageButton.target = self
        dismissProjectionMessageButton.action = #selector(dismissProjectionMessage(_:))
        dismissProjectionMessageButton.setAccessibilityLabel("Dismiss projection message")
        dismissProjectionMessageButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissProjectionMessageButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.addArrangedSubview(dismissProjectionMessageButton)
        footer.spacing = 8
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
            + (updates?.state.availableVersion == nil ? [] : [.workspaceUpdate])
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let items = toolbarDefaultItemIdentifiers(toolbar)
        return items.contains(.workspaceUpdate) ? items : items + [.workspaceUpdate]
    }
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
        case .workspaceUpdate:
            item.label = "Update"
            item.visibilityPriority = .high
            let button = NSButton(title: "Update", image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)!,
                                  target: updates, action: #selector(AppUpdateController.checkForUpdates(_:)))
            button.bezelStyle = .rounded
            button.contentTintColor = .controlAccentColor
            button.isEnabled = updates?.state.canCheckForUpdates == true
            button.toolTip = updates?.state.availableVersion.map { "View The Word \($0) is available" }
            button.setAccessibilityLabel("Update View The Word")
            item.view = button
        default: return nil
        }
        return item
    }

    func renderUpdateToolbar() {
        guard let toolbar = view.window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .workspaceUpdate }
        guard let version = updates?.state.availableVersion else {
            if let index { toolbar.removeItem(at: index) }
            return
        }
        if index == nil { toolbar.insertItem(withItemIdentifier: .workspaceUpdate, at: toolbar.items.count) }
        let button = toolbar.items.first { $0.itemIdentifier == .workspaceUpdate }?.view as? NSButton
        button?.isEnabled = updates?.state.canCheckForUpdates == true
        button?.toolTip = "View The Word \(version) is available"
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
    func renderTranslationPickers(_ sources: BibleSources?) {
        let entries = library.urls.map { (title: BibleTranslation.name(for: $0), value: $0.absoluteString) }
        for (picker, selected) in [(primaryPicker, sources?.primary), (secondaryPicker, sources?.secondary)] {
            let choices = picker === secondaryPicker ? [(title: "None", value: "")] + entries
                : entries.isEmpty ? [(title: "No translations", value: "")] : entries
            if picker.itemArray.compactMap({ $0.representedObject as? String }) != choices.map(\.value) {
                picker.removeAllItems()
                for choice in choices {
                    picker.addItem(withTitle: choice.title)
                    picker.lastItem?.representedObject = choice.value
                }
            }
            if let index = picker.itemArray.firstIndex(where: { ($0.representedObject as? String) == (selected?.absoluteString ?? "") }) {
                picker.selectItem(at: index)
            }
            picker.isEnabled = sources != nil
            let preferred = picker === primaryPicker ? translations.primary : translations.primaryOnly ? nil : translations.secondary
            if let preferred, let selected, preferred.lastPathComponent != selected.lastPathComponent {
                picker.toolTip = "\(BibleTranslation.name(for: preferred)) is unavailable. Using \(BibleTranslation.name(for: selected)) until it is imported again."
            } else {
                picker.toolTip = picker === primaryPicker ? "Primary translation for this tab"
                    : "Secondary translation for this tab. Choose None to show only the primary translation."
            }
        }
    }
    func renderStatus() {
        let live = windowOpened && projector.projectionOwner != nil
        if !live { preview.performClose(nil) }
        statusLabel.stringValue = live ? "\(projector.isBlanked ? "Blanked" : "Live") · \(projector.projectorViewData.title)" : "Projection stopped"
        statusLabel.textColor = live && !projector.isBlanked ? .systemGreen : .secondaryLabelColor
        loadingLabel.stringValue = liveProjection.isProjecting ? "Projecting…" : navigation.isLoading ? "Loading…" : ""
        blankButton.title = projector.isBlanked ? "Unblank" : "Blank"
        previewButton.isEnabled = live
        blankButton.isEnabled = live
        stopButton.isEnabled = live || liveProjection.isProjecting
        let screen = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID)
        let disconnected = preferredDisplayID != 0 && !NSScreen.screens.contains { $0.displayID == preferredDisplayID }
        screenLabel.stringValue = "Output: \(screen?.localizedName ?? "No display")\(disconnected ? " · preferred display disconnected" : "")"
    }

    func renderTabHeading(_ sources: BibleSources?) {
        guard let window = view.window else { return }
        let reference = navigation.refreshReference
        let searchPage = visibleSearchPage
        let passage = searchPage != nil ? "Search"
            : reference.flatMap { browsedBook == nil || $0.book == browsedBook ? $0.verseQuery.title : nil } ?? browsedBook ?? "New Passage"
        let urls = [sources?.primary, sources?.secondary].compactMap { $0 }
        let shortNames = urls.map(BibleTranslation.shortName)
        // Identical edition abbreviations in different languages need the language
        // code as well. Full translation names remain available in the tooltip.
        let names = zip(urls, shortNames).map { url, name in
            Set(urls).count > 1 && Set(shortNames).count < shortNames.count ? url.deletingPathExtension().lastPathComponent : name
        }.joined(separator: " / ")
        let heading = "\(passage) · \(names.isEmpty ? "No translations" : names)"
        let ownsOutput = windowOpened && projector.projectionOwner != nil && liveProjection.source?.tabID == tabID
        let status = ownsOutput ? (projector.isBlanked ? "● Blanked" : "● Live") : nil
        let title = status.map { "\($0) · \(heading)" } ?? heading
        window.title = heading
        window.tab.title = title
        if let status {
            let attributed = NSMutableAttributedString(string: title)
            attributed.addAttribute(.foregroundColor, value: projector.isBlanked ? NSColor.secondaryLabelColor : NSColor.systemGreen,
                                    range: NSRange(location: 0, length: (status as NSString).length))
            window.tab.attributedTitle = attributed
        } else { window.tab.attributedTitle = nil }
        let detail = searchPage.map { "Search: " + $0.request.text } ?? passage
        let liveDetail = ownsOutput ? "\n\(projector.isBlanked ? "Blanked" : "Live") from this tab: \(projector.projectorViewData.title)" : ""
        window.tab.toolTip = detail + "\n" + urls.map(BibleTranslation.name).joined(separator: " / ") + liveDetail
    }
    @objc private func searchModeChanged(_ sender: NSSegmentedControl) {
        guard SearchMode.allCases.indices.contains(sender.selectedSegment) else { return }
        changeSearchMode(SearchMode.allCases[sender.selectedSegment])
    }
    @objc private func translationChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        if sender === secondaryPicker {
            setSecondaryTranslation(value.isEmpty ? nil : URL(string: value))
        } else if sender === primaryPicker, let url = URL(string: value) {
            var selection = translations
            selection.primary = url
            setTranslations(selection)
        }
    }
    @objc func loadMore(_ sender: Any?) {
        guard let sources, let request = navigation.searchRequest, !navigation.isLoading else { return }
        navigation.search(request, sources: sources, loadMore: true)
    }
    func setPreference(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
        liveProjection.refreshPreferences()
        scheduleRender()
    }
}
