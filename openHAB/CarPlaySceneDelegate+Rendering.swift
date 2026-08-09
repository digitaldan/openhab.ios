// Copyright (c) 2010-2026 Contributors to the openHAB project
//
// See the NOTICE file(s) distributed with this work for additional
// information.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0
//
// SPDX-License-Identifier: EPL-2.0

import CarPlay
import CommonUI
import OpenHABCore
import os.log
import SFSafeSymbols

// MARK: - Template building

extension CarPlaySceneDelegate {
    @MainActor
    func updateTemplate(page: OpenHABPage, service: OpenAPIService) {
        let candidates = page.widgets.filter(\.visibility)
        let groups = candidates.compactMap(sitemapGroup(for:))
        let promoted = Set(groups.compactMap { $0.source?.widgetId })
        let rootSections = widgetSections(of: page.widgets)
            .map { WidgetSection(header: $0.header, widgets: $0.widgets.filter { !promoted.contains($0.widgetId) }) }
            .filter { !$0.widgets.isEmpty }

        guard !groups.isEmpty || !rootSections.isEmpty else {
            currentListTemplate = nil
            currentTabBarTemplate = nil
            groupTemplates.removeAll()
            currentGroupIds.removeAll()
            activeGroupId = nil
            headerButtons.removeAll()
            headerButtonTitles.removeAll()
            headerButtonImages.removeAll()
            headerButtonIds.removeAll()
            renderedItems.removeAll()
            renderedItemKeys.removeAll()
            renderedImageKeys.removeAll()
            lastRenderFingerprint = nil
            detailTemplate = nil
            interfaceController?.setRootTemplate(placeholderTemplate(), animated: false, completion: nil)
            return
        }

        // No font control on the nav bar, and CarPlay already names the app.
        let title = page.title.isEmpty ? "openHAB" : page.title

        if groups.isEmpty {
            renderList(title: title, sections: rootSections, service: service)
        } else {
            let all = rootSections.isEmpty
                ? groups
                : [SitemapGroup(
                    id: Self.defaultGroupId,
                    title: String(localized: "carplay_default_group"),
                    name: String(localized: "carplay_default_group"),
                    source: nil,
                    sections: rootSections
                )] + groups
            if #available(iOS 26.0, *), anyGroupHasIcon(all) {
                renderGroupedList(title: title, groups: all, service: service)
            } else {
                renderTabBar(groups: all, service: service)
            }
        }

        syncRootStream(groups: groups)
        fetchRemoteIcons(for: candidates + groups.flatMap(\.widgets), page: page, service: service)
    }

    /// One section per frame plus unheaded runs for widgets outside any.
    ///
    /// `OpenHABPage` already flattens its tree, so a frame sits alongside the children that
    /// name it in `parentWidgetId`. Walking into `widget.widgets` too would double them.
    func widgetSections(of widgets: [OpenHABWidget]) -> [WidgetSection] {
        var frameLabels: [String: String] = [:]
        for frame in widgets where frame.type == .frame {
            frameLabels[frame.widgetId] = frame.displayState.labelText
        }

        var order: [String] = []
        var buckets: [String: [OpenHABWidget]] = [:]

        for widget in widgets where widget.visibility && isCompatible(widget) {
            let parent = widget.parentWidgetId ?? ""
            let key = frameLabels[parent] != nil ? parent : ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(widget)
        }

        return order.map { key in
            let label = frameLabels[key] ?? ""
            return WidgetSection(header: label.isEmpty ? nil : label, widgets: buckets[key] ?? [])
        }
    }

    /// A `Text` widget wrapping a linked page becomes a group.
    func sitemapGroup(for widget: OpenHABWidget) -> SitemapGroup? {
        guard let linked = widget.linkedPage else { return nil }
        let sections = widgetSections(of: linked.widgets)
        guard !sections.isEmpty else { return nil }
        let ds = widget.displayState
        let value = ds.labelValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = value.isEmpty ? ds.labelText : "\(ds.labelText) \(value)"

        return SitemapGroup(
            id: linked.pageId.isEmpty ? widget.widgetId : linked.pageId,
            title: title,
            name: ds.labelText,
            source: widget,
            sections: sections
        )
    }

    /// Widgets we can represent.
    func isCompatible(_ widget: OpenHABWidget) -> Bool {
        guard widget.item != nil else { return false }
        switch widget.renderingKind {
        case .toggleSwitch, .segmentedSwitch:
            return widget.type == .switchWidget
        case .setpoint, .slider, .selection, .rollershutterSwitch:
            return true
        case .text:
            // Read-only value display; ones wrapping a linked page became groups.
            return true
        default:
            return false
        }
    }

    // MARK: - Group navigation

    /// Header buttons cost vertical space, so they need artwork to earn it.
    func anyGroupHasIcon(_ groups: [SitemapGroup]) -> Bool {
        groups.contains { group in
            guard let widget = group.source else { return false }
            return !Self.placeholderIconNames.contains(widget.icon.lowercased())
        }
    }

    /// `CPGridButton` draws image and title together; a tab bar drops the image once a
    /// title is set.
    @available(iOS 26.0, *)
    @MainActor
    func renderGroupedList(title: String, groups: [SitemapGroup], service: OpenAPIService) {
        let cap = CPListTemplate.maximumHeaderGridButtonCount
        let shown = Array(groups.prefix(cap))
        if shown.count < groups.count {
            Logger.carPlay.info("CarPlay: \(groups.count - shown.count) group(s) dropped, cap is \(cap)")
        }
        guard let active = shown.first(where: { $0.id == activeGroupId }) ?? shown.first else { return }
        activeGroupId = active.id
        // A sitemap edit can delete the selected group. Self-guards when unchanged.
        repointSubscription(to: active.id)

        // Bail before touching CarPlay when nothing visible moved.
        let fingerprint = renderFingerprint(for: active, shown: shown)
        guard fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint
        refreshDetailTemplate()

        // No fallback header: the button names the group, and a sticky header floats.
        let built = buildSections(active.sections, fallbackHeader: nil, service: service)
        renderedItems = renderedItems.filter { built.keys.contains($0.key) }

        let template: CPListTemplate
        if let existing = currentListTemplate {
            if built.signature != renderedItemKeys {
                renderedItemKeys = built.signature
                existing.updateSections(built.sections)
            }
            template = existing
        } else {
            renderedItemKeys = built.signature
            template = CPListTemplate(title: title, sections: built.sections)
            currentListTemplate = template
            currentTabBarTemplate = nil
            groupTemplates.removeAll()
            currentGroupIds.removeAll()
            interfaceController?.setRootTemplate(template, animated: false, completion: nil)
        }

        // Reassigning the array reinstalls the header and redraws the list beneath it.
        let point = min(
            CPListTemplate.maximumGridButtonImageSize.width,
            CPListTemplate.maximumGridButtonImageSize.height
        )

        var buttons: [CPGridButton] = []
        for group in shown {
            // Resolved URL, not icon name: openHAB varies artwork by state. `loaded` too,
            // since the URL is known before the artwork.
            let icon = group.source
                .flatMap { iconURL(name: $0.icon, widget: $0, includeState: false)?.absoluteString }
                ?? group.source?.icon ?? ""
            let titleKey = group.title
            let imageKey = "\(icon)|\(iconCache[icon] != nil)"

            if let existing = headerButtons[group.id] {
                if headerButtonTitles[group.id] != titleKey {
                    headerButtonTitles[group.id] = titleKey
                    existing.updateTitleVariants([group.title])
                }
                if headerButtonImages[group.id] != imageKey {
                    headerButtonImages[group.id] = imageKey
                    existing.updateImage(groupImage(for: group, size: point))
                }
                buttons.append(existing)
            } else {
                headerButtonTitles[group.id] = titleKey
                headerButtonImages[group.id] = imageKey
                let button = CPGridButton(
                    titleVariants: [group.title],
                    image: groupImage(for: group, size: point)
                ) { [weak self] _ in
                    self?.selectGroup(group.id)
                }
                headerButtons[group.id] = button
                buttons.append(button)
            }
        }

        let ids = shown.map(\.id)
        guard ids != headerButtonIds else { return }
        headerButtonIds = ids
        headerButtons = headerButtons.filter { ids.contains($0.key) }
        headerButtonTitles = headerButtonTitles.filter { ids.contains($0.key) }
        headerButtonImages = headerButtonImages.filter { ids.contains($0.key) }
        template.headerGridButtons = buttons
    }

    @MainActor
    func selectGroup(_ id: String) {
        guard id != activeGroupId else { return }
        activeGroupId = id
        Logger.carPlay.info("CarPlay group selected: \(id)")
        repointSubscription(to: id)
    }

    /// One tab per group, labelled but without artwork. Used when no group has an icon, and
    /// on systems without header buttons.
    @MainActor
    func renderTabBar(groups: [SitemapGroup], service: OpenAPIService) {
        let cap = CPTabBarTemplate.maximumTabCount
        let shown = Array(groups.prefix(cap))
        if shown.count < groups.count {
            Logger.carPlay.info("CarPlay: \(groups.count - shown.count) tab(s) dropped, cap is \(cap)")
        }

        var templates: [CPListTemplate] = []
        var liveKeys: [String] = []
        for group in shown {
            let built = buildSections(group.sections, fallbackHeader: nil, service: service)
            liveKeys.append(contentsOf: built.keys)
            if let existing = groupTemplates[group.id] {
                if built.signature != renderedKeysByGroup[group.id] {
                    renderedKeysByGroup[group.id] = built.signature
                    existing.updateSections(built.sections)
                }
                templates.append(existing)
            } else {
                renderedKeysByGroup[group.id] = built.signature
                let template = CPListTemplate(title: group.title, sections: built.sections)
                groupTemplates[group.id] = template
                templates.append(template)
            }
        }

        // Every tab's rows are live at once.
        renderedItems = renderedItems.filter { liveKeys.contains($0.key) }

        // Replacing templates resets the selected tab.
        let ids = shown.map(\.id)
        guard ids != currentGroupIds else { return }
        currentGroupIds = ids
        groupTemplates = groupTemplates.filter { ids.contains($0.key) }
        renderedKeysByGroup = renderedKeysByGroup.filter { ids.contains($0.key) }

        if let existing = currentTabBarTemplate {
            existing.updateTemplates(templates)
        } else {
            let tabBar = CPTabBarTemplate(templates: templates)
            tabBar.delegate = self
            currentTabBarTemplate = tabBar
            currentListTemplate = nil
            interfaceController?.setRootTemplate(tabBar, animated: false, completion: nil)
            if let first = shown.first { repointSubscription(to: first.id) }
        }
    }

    // MARK: - List rendering

    @MainActor
    func renderList(title: String, sections: [WidgetSection], service: OpenAPIService) {
        let built = buildSections(sections, fallbackHeader: nil, service: service)
        renderedItems = renderedItems.filter { built.keys.contains($0.key) }

        if let existing = currentListTemplate {
            // Title is read-only after creation.
            if built.signature != renderedItemKeys {
                renderedItemKeys = built.signature
                existing.updateSections(built.sections)
            }
        } else {
            renderedItemKeys = built.signature
            let template = CPListTemplate(title: title, sections: built.sections)
            currentListTemplate = template
            currentTabBarTemplate = nil
            groupTemplates.removeAll()
            currentGroupIds.removeAll()
            interfaceController?.setRootTemplate(template, animated: false, completion: nil)
        }
    }

    /// Sections plus a signature covering row identity and frame headings.
    /// `fallbackHeader` names the first unheaded section.
    @MainActor
    func buildSections(_ sections: [WidgetSection],
                       fallbackHeader: String?,
                       service: OpenAPIService) -> BuiltSections {
        var built: [CPListSection] = []
        var signature: [String] = []
        var keys: [String] = []

        // CarPlay truncates past maximumItemCount — lower while moving — silently.
        var budget = CPListTemplate.maximumItemCount
        let total = sections.reduce(0) { $0 + $1.widgets.count }
        if total > budget {
            Logger.carPlay.info("CarPlay: showing \(budget) of \(total) row(s), limit is \(budget)")
        }

        for (index, section) in sections.enumerated() {
            guard budget > 0 else { break }
            let allowed = section.widgets.prefix(budget)
            budget -= allowed.count
            let rendered = allowed.flatMap { reusableRows(for: $0, service: service) }
            let header = section.header ?? (index == 0 ? fallbackHeader : nil)
            built.append(CPListSection(items: rendered.map(\.item), header: header, sectionIndexTitle: nil))
            signature.append("#\(header ?? "")")
            signature.append(contentsOf: rendered.map(\.key))
            keys.append(contentsOf: rendered.map(\.key))
        }

        return BuiltSections(sections: built, signature: signature, keys: keys)
    }

    /// Everything the list draws, compared before any work is done.
    @MainActor
    func renderFingerprint(for active: SitemapGroup, shown: [SitemapGroup]) -> String {
        var parts: [String] = [active.id]
        for section in active.sections {
            parts.append("#\(section.header ?? "")")
            for widget in section.widgets {
                let ds = widget.displayState
                parts.append([
                    widget.widgetId,
                    "\(widget.renderingKind)",
                    ds.labelText,
                    ds.labelValue ?? "",
                    ds.effectiveState,
                    ds.selectedLabel ?? "",
                    "\(ds.adjustedValue)",
                    rowImageKey(for: widget)
                ].joined(separator: ":"))
            }
        }
        for group in shown {
            let icon = group.source
                .flatMap { iconURL(name: $0.icon, widget: $0, includeState: false)?.absoluteString }
                ?? ""
            parts.append("!\(group.id):\(group.title):\(icon):\(iconCache[icon] != nil)")
        }
        return parts.joined(separator: "|")
    }

    /// Artwork identity: the icon URL, or the symbol it falls back to. Cache state counts,
    /// since the URL is known before the artwork.
    @MainActor
    func rowImageKey(for widget: OpenHABWidget) -> String {
        guard let url = iconURL(name: widget.icon, widget: widget)?.absoluteString else {
            return "symbol:\(widget.icon):\(widget.displayState.isOn)"
        }
        return "\(url)|\(iconCache[url] != nil)"
    }

    /// Reuses the on-screen row when the widget's kind is unchanged. `makeListItem` remains
    /// the only place content is decided.
    @MainActor
    func reusableRows(for widget: OpenHABWidget, service: OpenAPIService) -> [(key: String, item: any CPListTemplateItem)] {
        [reuse(makeListItem(for: widget, service: service), for: widget, service: service)]
    }

    @MainActor
    func reuse(_ fresh: any CPListTemplateItem,
               for widget: OpenHABWidget,
               service: OpenAPIService) -> (key: String, item: any CPListTemplateItem) {
        let key = "\(widget.widgetId)|\(widget.renderingKind)"
        let imageKey = rowImageKey(for: widget)

        guard let existing = renderedItems[key] else {
            renderedItems[key] = fresh
            renderedImageKeys[key] = imageKey
            return (key, fresh)
        }

        switch (existing, fresh) {
        case let (live as CPListItem, new as CPListItem):
            // Each setter reloads the row. Images compare by source key, never by object:
            // every render builds a new UIImage, so identity is always unequal.
            if live.text != new.text {
                live.setText(new.text ?? "")
            }
            if live.detailText != new.detailText {
                live.setDetailText(new.detailText)
            }
            if renderedImageKeys[key] != imageKey {
                renderedImageKeys[key] = imageKey
                live.setImage(new.image)
            }
            live.handler = new.handler
            return (key, live)
        default:
            break
        }

        if #available(iOS 26.0, *),
           let live = existing as? CPListImageRowItem,
           let new = fresh as? CPListImageRowItem {
            // Reassigning the array forces a re-layout, but enabled state must carry over.
            for (liveElement, newElement) in zip(live.elements, new.elements)
                where liveElement.isEnabled != newElement.isEnabled {
                liveElement.isEnabled = newElement.isEnabled
            }
            if live.text != new.text {
                live.text = new.text
            }
            live.listImageRowHandler = new.listImageRowHandler
            return (key, live)
        }

        renderedItems[key] = fresh
        return (key, fresh)
    }

    /// Uniform rows that always open something — no row fires a command by being pressed.
    /// Repeated adjustment pushes a screen that stays put; a one-shot choice gets a sheet.
    @MainActor
    func makeListItem(for widget: OpenHABWidget, service: OpenAPIService) -> any CPListTemplateItem {
        switch widget.renderingKind {
        case .text:
            return makeTextItem(for: widget)
        case .setpoint, .slider:
            return makeDetailRow(for: widget) { [weak self] in
                self?.pushStepperDetail(for: widget, service: service)
            }
        case .rollershutterSwitch:
            return makeChoiceRow(for: widget, mappings: Self.rollershutterMappings, service: service)
        case .selection:
            return makeChoiceRow(for: widget, mappings: widget.displayState.mappings, service: service)
        default:
            break
        }

        // renderingKind is the app's precedence: sitemap mappings beat binding options.
        let mappings = widget.displayState.mappings
        if widget.renderingKind == .segmentedSwitch,
           mappings.count > 1 || (mappings.count == 1 && !mappings[0].hasPressReleaseBehavior) {
            return makeChoiceRow(for: widget, mappings: mappings, service: service)
        }

        if let momentary = mappings.first, momentary.hasPressReleaseBehavior {
            return makeChoiceRow(for: widget, mappings: [momentary], service: service)
        }
        return makeChoiceRow(for: widget, mappings: Self.onOffMappings, service: service)
    }

    @MainActor
    func makeChoiceRow(for widget: OpenHABWidget,
                       mappings: [OpenHABWidgetMapping],
                       service: OpenAPIService) -> CPListItem {
        makeDetailRow(for: widget) { [weak self] in
            self?.pushChoiceDetail(for: widget, mappings: mappings, service: service)
        }
    }

    /// The uniform row: icon, label, current value, disclosure.
    @MainActor
    func makeDetailRow(for widget: OpenHABWidget, push: @escaping @MainActor () -> Void) -> CPListItem {
        let ds = widget.displayState
        let item = CPListItem(
            text: ds.labelText,
            detailText: ds.selectedLabel ?? ds.labelValue ?? ds.effectiveState,
            image: iconImage(for: widget, size: rowIconPointSize),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { _, completion in
            push()
            completion()
        }
        return item
    }

    // MARK: - Detail screens

    /// One close affordance for every detail screen, in the nav bar rather than the body so
    /// it never competes with the controls for space.
    @MainActor
    func closeButton() -> CPBarButton {
        let button = CPBarButton(title: String(localized: "Cancel")) { [weak self] _ in
            self?.detailTemplate = nil
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        button.buttonStyle = .rounded
        return button
    }

    /// Choices as a pushed list rather than a sheet: consistent chrome, and room for as many
    /// options as a sitemap defines. Picking one sends it and returns.
    @MainActor
    func pushChoiceDetail(for widget: OpenHABWidget,
                          mappings: [OpenHABWidgetMapping],
                          service: OpenAPIService) {
        let template = CPListTemplate(
            title: widget.displayState.labelText,
            sections: [choiceSection(for: widget, mappings: mappings, service: service)]
        )
        template.trailingNavigationBarButtons = [closeButton()]
        detailTemplate = .choice(template, widget, mappings)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    func choiceSection(for widget: OpenHABWidget,
                       mappings: [OpenHABWidgetMapping],
                       service: OpenAPIService) -> CPListSection {
        let ds = widget.displayState
        let items = mappings.enumerated().map { index, mapping -> CPListItem in
            let item = CPListItem(
                text: mapping.label,
                detailText: nil,
                image: nil,
                accessoryImage: index == ds.selectedIndex ? sfSymbolImage(.checkmark, pointSize: rowIconPointSize) : nil,
                accessoryType: .none
            )
            item.handler = { [weak self] _, completion in
                self?.send(mapping: mapping, for: widget, service: service)
                self?.detailTemplate = nil
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }
        return CPListSection(items: items, header: ds.selectedLabel ?? ds.effectiveState, sectionIndexTitle: nil)
    }

    /// Unlike `CPListTemplate`, this template's items are settable, so the value updates in
    /// place while the screen stays open. Three actions is the cap.
    @MainActor
    func pushStepperDetail(for widget: OpenHABWidget, service: OpenAPIService) {
        let ds = widget.displayState
        let step = ds.step.valueText(step: ds.step)

        let template = CPInformationTemplate(
            title: ds.labelText,
            layout: .leading,
            items: stepperItems(for: widget),
            actions: [
                CPTextButton(title: "−  \(step)", textStyle: .normal) { [weak self] _ in
                    self?.sendStep(for: widget, decreasing: true, service: service)
                },
                CPTextButton(title: "+  \(step)", textStyle: .normal) { [weak self] _ in
                    self?.sendStep(for: widget, decreasing: false, service: service)
                }
            ]
        )
        template.trailingNavigationBarButtons = [closeButton()]
        detailTemplate = .stepper(template, widget)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    func stepperItems(for widget: OpenHABWidget) -> [CPInformationItem] {
        let ds = widget.displayState
        return [CPInformationItem(title: ds.labelText, detail: steppedValueText(ds))]
    }

    /// Keeps an open detail screen in step with incoming state.
    @MainActor
    func refreshDetailTemplate() {
        switch detailTemplate {
        case let .stepper(template, widget):
            template.items = stepperItems(for: widget)
        case let .choice(template, widget, mappings):
            let ds = widget.displayState
            let rows = template.sections.flatMap { $0.items.compactMap { $0 as? CPListItem } }
            for (index, row) in rows.enumerated() where index < mappings.count {
                let wanted = index == ds.selectedIndex
                    ? sfSymbolImage(.checkmark, pointSize: rowIconPointSize) : nil
                if (row.accessoryImage == nil) != (wanted == nil) { row.setAccessoryImage(wanted) }
            }
        case .none:
            break
        }
    }

    func steppedValueText(_ ds: WidgetDisplayState) -> String {
        ds.labelValue ?? ds.adjustedValue.valueText(step: ds.step)
    }

    @MainActor
    func sendStep(for widget: OpenHABWidget, decreasing: Bool, service: OpenAPIService) {
        let ds = widget.displayState
        let newValue = setpointService.calculateNewValue(
            currentValue: ds.adjustedValue,
            step: ds.step,
            minValue: ds.minValue,
            maxValue: ds.maxValue,
            isDecreasing: decreasing
        )
        guard newValue != ds.adjustedValue, let name = widget.item?.name else {
            Logger.carPlay.info("CarPlay step ignored: already at limit, or widget has no item")
            return
        }

        // commandString is the wire format; toString(locale:) is for display.
        let command = NumberState(value: newValue, unit: widget.unit).commandString
        Task {
            do {
                try await service.sendItemCommand(itemname: name, command: command)
            } catch {
                Logger.carPlay.error("CarPlay step \(name) = \(command) failed: \(error)")
            }
        }
    }

    /// A read-only value row. Disabled rather than given a no-op handler: it isn't a
    /// control, so it should neither spin nor take a selection highlight.
    @MainActor
    func makeTextItem(for widget: OpenHABWidget) -> CPListItem {
        let ds = widget.displayState
        let item = CPListItem(
            text: ds.labelText,
            detailText: ds.labelValue ?? ds.effectiveState,
            image: iconImage(for: widget, size: rowIconPointSize),
            accessoryImage: nil,
            accessoryType: .none
        )
        item.isEnabled = false
        return item
    }

    // MARK: - Commands

    /// Honours press/release pairs.
    @MainActor
    func send(mapping: OpenHABWidgetMapping, for widget: OpenHABWidget, service: OpenAPIService) {
        guard let name = widget.item?.name else { return }
        Task {
            if !mapping.command.isEmpty {
                try? await service.sendItemCommand(itemname: name, command: mapping.command)
            }
            if let release = mapping.releaseCommand, !release.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                try? await service.sendItemCommand(itemname: name, command: release)
            }
        }
    }
}
