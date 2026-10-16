import AppKit

struct DefaultOutputMenuInput: Equatable {
    let configuration: OutputConfiguration
    let recoveryNotice: String?
    let displayRevision: Int
    let openNativeOutputs: Set<UUID>
    let receiverConnected: Bool
    let templates: [AltViewTemplateDescriptor]?
}

extension MainWorkspaceController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showPreview(_:)) { return windowOpened || liveProjection.hasNativeWindows }
        if menuItem.action == #selector(toggleBlank(_:)) { return windowOpened }
        if menuItem.action == #selector(stopProjection(_:)) { return windowOpened || liveProjection.isProjecting || liveProjection.hasNativeWindows }
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
        // AppKit uses the first item as the pull-down button's title.
        // Hide it before attachment so rebuilding an open menu cannot show it.
        let projectionTitle = NSMenuItem(title: "Projection", action: nil, keyEquivalent: "")
        projectionTitle.isHidden = true
        projectionMenu.addItem(projectionTitle)
        projectionMenu.command("Project selected passage") { [weak self] in self?.projectSelectedPassage(nil) }
        projectionMenu.command("Blank", enabled: windowOpened) { [weak self] in self?.toggleBlank(nil) }
        projectionMenu.command("Stop", enabled: windowOpened || liveProjection.isProjecting || liveProjection.hasNativeWindows) { [weak self] in self?.stopProjection(nil) }
        projectionMenu.addItem(.separator())
        projectionMenu.command("Manage Outputs…") { [weak self] in self?.manageOutputs(nil) }
        projectionOptions.menu = projectionMenu
        rebuildDefaultOutputMenu()
    }

    private func rebuildDefaultOutputMenu() {
        let outputs = liveProjection.outputs
        let output = outputs.defaultDestination
        let service = output.flatMap { liveProjection.altViewServices[$0.id] }
        let input = DefaultOutputMenuInput(configuration: outputs.configuration, recoveryNotice: outputs.recoveryNotice,
            displayRevision: liveProjection.projectionDisplays.revision, openNativeOutputs: Set(liveProjection.nativeOutputs.keys),
            receiverConnected: service?.status.connected == true, templates: service?.status.templateCapabilities.templates)
        // Keep an attached menu stable through scripture and routine receiver
        // feedback updates. Only inputs that change its controls rebuild it.
        guard input != defaultOutputMenuInput else { return }
        defaultOutputMenuInput = input
        let menu = NSMenu(title: "Default output")
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        heading.isHidden = true; menu.addItem(heading)
        menu.submenu("Default output: " + (output?.name ?? "None"), enabled: outputs.canEdit) { choices in
            choices.command("None", checked: output == nil) { [weak self] in self?.liveProjection.outputs.setDefaultDestination(nil) }
            for destination in outputs.destinations {
                choices.command(destination.name + (destination.enabled ? "" : " · Disabled"), checked: destination.id == output?.id) { [weak self] in
                    self?.liveProjection.outputs.setDefaultDestination(destination.id)
                }
            }
        }
        let problem = outputs.recoveryNotice != nil ? "Restore saved outputs in Manage Outputs to edit."
            : output == nil ? "Choose a default output."
            : output?.enabled == false ? "Default output is disabled." : nil
        if let problem { menu.command(problem, enabled: false) {} }
        outputOptions.toolTip = [output.map { "Quick controls for \($0.name). Changes affect only this output." } ?? "Choose a default output for quick controls.", problem].compactMap { $0 }.joined(separator: "\n")
        outputOptions.setAccessibilityLabel("Default output controls" + (output.map { ": \($0.name)" } ?? "") + (problem.map { ". \($0)" } ?? ""))
        menu.addItem(.separator())
        if let output, output.altView != nil {
            menu.command("Appearance is controlled in AltView.", enabled: false) {}
            menu.submenu("Layout", enabled: problem == nil && service?.status.connected == true) { choices in
                choices.command("Receiver’s layout", checked: output.altView?.template == nil) { [weak self] in
                    self?.editDefaultAltView(output.id, template: nil)
                }
                let templates = service?.status.templateCapabilities.templates ?? []
                for template in templates {
                    choices.command(template.name, checked: output.altView?.template == template.id) { [weak self] in
                        self?.editDefaultAltView(output.id, template: template.id)
                    }
                }
                if let saved = output.altView?.template, !templates.contains(where: { $0.id == saved }) {
                    choices.command(saved.rawValue + " · Unavailable", checked: true, enabled: false) {}
                }
            }
        } else {
            let profile = output?.native.flatMap { outputs.profile($0.profileID) }
            let enabled = problem == nil && profile != nil
            menu.submenu("Projection monitor", enabled: enabled && output.map { liveProjection.nativeOutputs[$0.id] == nil } == true) { choices in
                let selected = output?.native?.monitor
                choices.command("None", checked: selected == nil, enabled: enabled) { [weak self] in
                    if let output { self?.editDefaultMonitor(output.id, target: nil) }
                }
                let displays = liveProjection.projectionDisplays
                let connected = displays.displays.map(\.target)
                var targets = connected + displays.knownTargets.filter { target in !connected.contains { $0.identity == target.identity } }
                if let selected, !targets.contains(where: { $0.identity == selected.identity }) { targets.append(selected) }
                for target in targets {
                    var candidate = output
                    if var assignment = candidate?.native { assignment.monitor = target; candidate?.assignment = .native(assignment) }
                    let available = displays.problem(for: target) == nil && candidate.map { outputs.conflict(for: $0) == nil } == true
                    choices.command(displays.label(for: target) + (displays.resolve(target) == nil ? " · Unavailable" : ""),
                                    checked: selected?.identity == target.identity, enabled: enabled && available) { [weak self] in
                        if let output { self?.editDefaultMonitor(output.id, target: target) }
                    }
                }
            }
            let textSizes: [Double] = [16, 24, 28, 32, 40, 48, 64, 80, 100, 120, 160, 200]
            let paddingSizes: [Double] = [0, 16, 24, 32, 48, 64, 100, 150, 200]
            for (title, key, presets) in [("Verse size", \NativeOutputProfile.verse.size, textSizes), ("Reference size", \.reference.size, textSizes), ("Translation name size", \.translationNames.size, textSizes), ("Padding", \.padding, paddingSizes)] {
                let current = profile?[keyPath: key]
                var sizes = presets
                if let current, !sizes.contains(current) { sizes.append(current); sizes.sort() }
                menu.submenu(title, enabled: enabled) { choices in
                    for size in sizes {
                        choices.command("\(size.formatted()) pt", checked: current == size, enabled: enabled) { [weak self] in
                            if let output { self?.editDefaultAppearance(output.id) { $0[keyPath: key] = size } }
                        }
                    }
                }
            }
            menu.submenu("Text alignment", enabled: enabled) { choices in
                for mode in ProjectorTextAlignmentMode.allCases {
                    choices.command(mode.rawValue.capitalized, checked: profile?.alignment == mode, enabled: enabled) { [weak self] in
                        if let output { self?.editDefaultAppearance(output.id) { $0.alignment = mode } }
                    }
                }
            }
            menu.submenu("Reading direction", enabled: enabled) { choices in
                for (mode, title) in [(ProjectorReadingDirectionMode.auto, "Automatic"), (.leftToRight, "Left to right"), (.rightToLeft, "Right to left")] {
                    choices.command(title, checked: profile?.readingDirection == mode, enabled: enabled) { [weak self] in
                        if let output { self?.editDefaultAppearance(output.id) { $0.readingDirection = mode } }
                    }
                }
            }
            menu.addItem(.separator())
            menu.command("Stack translations vertically", checked: profile?.translationLayout == .vertical, enabled: enabled) { [weak self] in
                if let output { self?.editDefaultAppearance(output.id) { $0.translationLayout = $0.translationLayout == .vertical ? .horizontal : .vertical } }
            }
            for (title, key) in [("Show translation names", \NativeOutputProfile.showTranslationNames), ("Transparent background", \.transparent)] {
                menu.command(title, checked: profile?[keyPath: key] == true, enabled: enabled) { [weak self] in
                    if let output { self?.editDefaultAppearance(output.id) { $0[keyPath: key].toggle() } }
                }
            }
        }
        menu.addItem(.separator())
        menu.command("Manage Outputs…") { [weak self] in self?.manageOutputs(nil) }
        outputOptions.menu = menu
        if let item = view.window?.toolbar?.items.first(where: { $0.itemIdentifier == .workspaceOutput }) {
            item.label = outputOptions.accessibilityLabel() ?? "Default output"; item.toolTip = outputOptions.toolTip
        }
    }

    private func editDefaultAppearance(_ id: UUID, edit: (inout NativeOutputProfile) -> Void) {
        liveProjection.outputs.editDefaultProfile(destinationID: id, edit)
        liveProjection.refreshPreferences()
        rebuildDefaultOutputMenu()
    }
    private func editDefaultMonitor(_ id: UUID, target: ProjectionMonitorTarget?) {
        let outputs = liveProjection.outputs
        guard outputs.canEdit, var output = outputs.defaultDestination, output.id == id, output.enabled,
              var assignment = output.native, liveProjection.nativeOutputs[id] == nil,
              target.map({ liveProjection.projectionDisplays.problem(for: $0) == nil }) ?? true else { return }
        assignment.monitor = target; output.assignment = .native(assignment)
        guard outputs.update(output) == nil else { return }
        liveProjection.refreshPreferences(); liveProjection.showStandby(id)
        rebuildDefaultOutputMenu()
    }
    private func editDefaultAltView(_ id: UUID, template: AltViewContentTemplate?) {
        guard liveProjection.outputs.canEdit, let output = liveProjection.outputs.defaultDestination,
              output.id == id, output.enabled, output.altView != nil,
              let service = liveProjection.altViewServices[id], service.status.connected else { return }
        service.selectTemplate(template)
        rebuildDefaultOutputMenu()
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
