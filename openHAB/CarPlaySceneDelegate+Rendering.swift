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

        refreshDetailTemplate()
        syncRootStream(groups: groups)
        fetchRemoteIcons(for: candidates + groups.flatMap(\.widgets), page: page, service: service)
    }

    /// One section per frame, plus unheaded runs for widgets outside any.
    /// The page is already flat; children point at their frame via `parentWidgetId`.
    func widgetSections(of widgets: [OpenHABWidget]) -> [WidgetSection] {
        // Also drops empty frames and children of hidden ones.
        let visible = sitemapVisibleWidgets(widgets)
        var frameLabels: [String: String] = [:]
        for frame in visible where frame.type == .frame {
            frameLabels[frame.widgetId] = frame.displayState.labelText
        }

        var sections: [WidgetSection] = []
        var currentKey: String?
        var current: [OpenHABWidget] = []

        func flush() {
            guard !current.isEmpty else { return }
            let label = currentKey.flatMap { frameLabels[$0] } ?? ""
            sections.append(WidgetSection(header: label.isEmpty ? nil : label, widgets: current))
            current = []
        }

        for widget in visible where isCompatible(widget) {
            let parent = widget.parentWidgetId ?? ""
            let key = frameLabels[parent] != nil ? parent : ""
            if key != currentKey {
                flush()
                currentKey = key
            }
            current.append(widget)
        }
        flush()
        return sections
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

    func isCompatible(_ widget: OpenHABWidget) -> Bool {
        guard widget.item != nil else { return false }
        switch widget.renderingKind {
        case .toggleSwitch, .segmentedSwitch:
            return widget.type == .switchWidget
        case .setpoint, .slider, .selection, .rollershutterSwitch, .text:
            return true
        default:
            return false
        }
    }

    // MARK: - Group navigation

    /// Header buttons take vertical space, so only use them with artwork.
    func anyGroupHasIcon(_ groups: [SitemapGroup]) -> Bool {
        groups.contains { group in
            guard let widget = group.source else { return false }
            return !Self.placeholderIconNames.contains(widget.icon.lowercased())
        }
    }

    /// Header buttons, since a tab bar drops the image once a title is set.
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
        // The selected group may have been removed.
        repointSubscription(to: active.id)

        let fingerprint = renderFingerprint(for: active, shown: shown)
        guard fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint

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

        let point = min(
            CPListTemplate.maximumGridButtonImageSize.width,
            CPListTemplate.maximumGridButtonImageSize.height
        )

        var buttons: [CPGridButton] = []
        for group in shown {
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

        // Reassigning redraws the list.
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

    /// Fallback when no group has an icon, or before iOS 26.
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
                // `name`, not `title`: the tab title can't change, so a value would go stale.
                let template = CPListTemplate(title: group.name, sections: built.sections)
                groupTemplates[group.id] = template
                templates.append(template)
            }
        }

        renderedItems = renderedItems.filter { liveKeys.contains($0.key) }

        // Replacing templates resets the selected tab.
        let ids = shown.map(\.id)
        guard ids != currentGroupIds else { return }
        currentGroupIds = ids
        groupTemplates = groupTemplates.filter { ids.contains($0.key) }
        renderedKeysByGroup = renderedKeysByGroup.filter { ids.contains($0.key) }

        if let existing = currentTabBarTemplate {
            existing.updateTemplates(templates)
            // CarPlay reselects the first tab without calling the delegate.
            if let first = shown.first {
                repointSubscription(to: first.id)
            }
        } else {
            let tabBar = CPTabBarTemplate(templates: templates)
            tabBar.delegate = self
            currentTabBarTemplate = tabBar
            currentListTemplate = nil
            interfaceController?.setRootTemplate(tabBar, animated: false, completion: nil)
            if let first = shown.first {
                repointSubscription(to: first.id)
            }
        }
    }

    // MARK: - List rendering

    @MainActor
    func renderList(title: String, sections: [WidgetSection], service: OpenAPIService) {
        let built = buildSections(sections, fallbackHeader: nil, service: service)
        renderedItems = renderedItems.filter { built.keys.contains($0.key) }

        if let existing = currentListTemplate {
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

    @MainActor
    func buildSections(_ sections: [WidgetSection],
                       fallbackHeader: String?,
                       service: OpenAPIService) -> BuiltSections {
        var built: [CPListSection] = []
        var signature: [String] = []
        var keys: [String] = []

        // CarPlay silently truncates past this, and it drops while driving.
        var budget = CPListTemplate.maximumItemCount
        let total = sections.reduce(0) { $0 + $1.widgets.count }
        if total > budget {
            Logger.carPlay.info("CarPlay: showing \(budget) of \(total) row(s), limit is \(budget)")
        }

        for (index, section) in sections.enumerated() {
            guard budget > 0 else { break }
            let allowed = section.widgets.prefix(budget)
            let rendered = allowed.map { reusableRow(for: $0, service: service) }
            budget -= rendered.count
            let header = section.header ?? (index == 0 ? fallbackHeader : nil)
            built.append(CPListSection(items: rendered.map(\.item), header: header, sectionIndexTitle: nil))
            signature.append("#\(header ?? "")")
            signature.append(contentsOf: rendered.map(\.key))
            keys.append(contentsOf: rendered.map(\.key))
        }

        return BuiltSections(sections: built, signature: signature, keys: keys)
    }

    @MainActor
    func renderFingerprint(for active: SitemapGroup, shown: [SitemapGroup]) -> String {
        var parts: [String] = [active.id, "\(CPListTemplate.maximumItemCount)"]
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

    @MainActor
    func rowImageKey(for widget: OpenHABWidget) -> String {
        guard let url = iconURL(name: widget.icon, widget: widget)?.absoluteString else {
            return "symbol:\(widget.icon):\(widget.displayState.isOn)"
        }
        return "\(url)|\(iconCache[url] != nil)"
    }

    /// Updates the on-screen row in place when its kind is unchanged.
    @MainActor
    func reusableRow(for widget: OpenHABWidget, service: OpenAPIService) -> (key: String, item: CPListItem) {
        let fresh = makeListItem(for: widget, service: service)
        let key = "\(widget.widgetId)|\(widget.renderingKind)"
        let imageKey = rowImageKey(for: widget)

        guard let live = renderedItems[key] else {
            renderedItems[key] = fresh
            renderedImageKeys[key] = imageKey
            return (key, fresh)
        }

        // Each setter reloads the row, so only set what changed.
        if live.text != fresh.text {
            live.setText(fresh.text ?? "")
        }
        if live.detailText != fresh.detailText {
            live.setDetailText(fresh.detailText)
        }
        if renderedImageKeys[key] != imageKey {
            renderedImageKeys[key] = imageKey
            live.setImage(fresh.image)
        }
        live.handler = fresh.handler
        return (key, live)
    }

    /// No row sends a command directly; each opens a detail screen.
    @MainActor
    func makeListItem(for widget: OpenHABWidget, service: OpenAPIService) -> CPListItem {
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

        let mappings = widget.displayState.mappings
        if widget.renderingKind == .segmentedSwitch,
           mappings.count > 1 || (mappings.count == 1 && !mappings[0].hasPressReleaseBehavior) {
            return makeChoiceRow(for: widget, mappings: mappings, service: service)
        }

        if let momentary = mappings.first, momentary.hasPressReleaseBehavior {
            return makeChoiceRow(for: widget, mappings: [momentary], service: service)
        }
        if let widgetLevel = Self.widgetLevelMapping(for: widget) {
            return makeChoiceRow(for: widget, mappings: [widgetLevel], service: service)
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

    @MainActor
    func pushChoiceDetail(for widget: OpenHABWidget,
                          mappings: [OpenHABWidgetMapping],
                          service: OpenAPIService) {
        let template = CPListTemplate(
            title: widget.displayState.labelText,
            sections: [choiceSection(for: widget, mappings: mappings, service: service)]
        )
        detailTemplate = .choice(template, widget.widgetId, mappings)
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

    /// An information template, because its items can be updated in place.
    @MainActor
    func pushStepperDetail(for initialWidget: OpenHABWidget, service: OpenAPIService) {
        let ds = initialWidget.displayState
        let step = ds.step.valueText(step: ds.step)

        // Look up by id on each press; a captured widget goes stale after a refresh.
        let widgetId = initialWidget.widgetId
        let template = CPInformationTemplate(
            title: stepperTitle(for: initialWidget),
            layout: .leading,
            items: stepperItems(for: initialWidget),
            actions: [
                CPTextButton(title: "−  \(step)", textStyle: .normal) { [weak self] _ in
                    guard let self, let live = widget(withId: widgetId) else { return }
                    sendStep(for: live, decreasing: true, service: service)
                },
                CPTextButton(title: "+  \(step)", textStyle: .normal) { [weak self] _ in
                    guard let self, let live = widget(withId: widgetId) else { return }
                    sendStep(for: live, decreasing: false, service: service)
                }
            ]
        )
        // Only 3 actions are allowed, so on/off goes in the nav bar.
        if ds.switchSupport {
            template.trailingNavigationBarButtons = Self.onOffMappings.map { mapping in
                let button = CPBarButton(title: mapping.label) { [weak self] _ in
                    guard let self, let live = widget(withId: widgetId) else { return }
                    send(mapping: mapping, for: live, service: service)
                }
                button.buttonStyle = .rounded
                return button
            }
        }
        detailTemplate = .stepper(template, widgetId)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// The nav bar is the only large text, so the value goes there.
    @MainActor
    func stepperTitle(for widget: OpenHABWidget) -> String {
        let ds = widget.displayState
        if let value = ds.labelValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return "\(ds.labelText) \(value)"
        }
        let unit = widget.unit.map { " \($0)" } ?? (widget.renderingKind == .slider ? "%" : "")
        return "\(ds.labelText) \(ds.adjustedValue.valueText(step: ds.step))\(unit)"
    }

    @MainActor
    func stepperItems(for widget: OpenHABWidget) -> [CPInformationItem] {
        [CPInformationItem(title: steppedValueText(widget.displayState), detail: nil)]
    }

    @MainActor
    func refreshDetailTemplate() {
        switch detailTemplate {
        case let .stepper(template, widgetId):
            guard let widget = widget(withId: widgetId) else { return }
            template.title = stepperTitle(for: widget)
            template.items = stepperItems(for: widget)
        case let .choice(template, widgetId, mappings):
            guard let widget = widget(withId: widgetId) else { return }
            let ds = widget.displayState
            let rows = template.sections.flatMap { $0.items.compactMap { $0 as? CPListItem } }
            for (index, row) in rows.enumerated() where index < mappings.count {
                let wanted = index == ds.selectedIndex
                    ? sfSymbolImage(.checkmark, pointSize: rowIconPointSize) : nil
                if (row.accessoryImage == nil) != (wanted == nil) {
                    row.setAccessoryImage(wanted)
                }
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

        let command = NumberState(value: newValue, unit: widget.unit).commandString
        Task {
            do {
                try await service.sendItemCommand(itemname: name, command: command)
            } catch {
                Logger.carPlay.error("CarPlay step \(name) = \(command) failed: \(error)")
            }
        }
    }

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
        // Without a handler, a tap spins forever.
        item.handler = { _, completion in
            completion()
        }
        return item
    }

    // MARK: - Commands

    @MainActor
    func send(mapping: OpenHABWidgetMapping, for widget: OpenHABWidget, service: OpenAPIService) {
        guard let name = widget.item?.name else { return }
        Task {
            let pressed = !mapping.command.isEmpty
            if pressed {
                try? await service.sendItemCommand(itemname: name, command: mapping.command)
            }
            if let release = mapping.releaseCommand, !release.isEmpty {
                if pressed {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await service.sendItemCommand(itemname: name, command: release)
            }
        }
    }
}
