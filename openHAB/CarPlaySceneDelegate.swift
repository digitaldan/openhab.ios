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
import Kingfisher
import OpenHABCore
import os.log
import SFSafeSymbols

enum StreamOutcome {
    /// Streamed then ended — reconnect promptly.
    case ended
    /// Never got that far — back off.
    case failed
    /// Nothing to stream until preferences change.
    case idle
}

struct BuiltSections {
    let sections: [CPListSection]
    /// Row keys interleaved with headers, so a renamed frame counts as a change.
    let signature: [String]
    let keys: [String]
}

/// The pushed detail screen, kept live by incoming state.
/// Holds a widget id, not a widget: a page refresh replaces every `OpenHABWidget`, and a
/// retained one would report — and act on — the state it had when the screen opened.
enum CarPlayDetail {
    case stepper(CPInformationTemplate, String)
    case choice(CPListTemplate, String, [OpenHABWidgetMapping])

    /// Press/release declared on the widget rather than in a mapping.
    var template: CPTemplate {
        switch self {
        case let .stepper(template, _): template
        case let .choice(template, _, _): template
        }
    }
}

/// A run of widgets under an optional heading, from a sitemap `Frame`.
struct WidgetSection {
    let header: String?
    let widgets: [OpenHABWidget]
}

/// A sitemap `Text` widget and the linked page it wraps, shown as one header button.
struct SitemapGroup {
    let id: String
    /// Label plus live value, for the header button.
    let title: String
    /// Label only, for section headings.
    let name: String
    /// nil for the synthesised Default group.
    let source: OpenHABWidget?
    let sections: [WidgetSection]

    var widgets: [OpenHABWidget] {
        sections.flatMap(\.widgets)
    }
}

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    static let defaultGroupId = "__default__"

    /// openHAB's stand-ins for "no icon". Fetching them returns an empty-looking glyph.
    static let placeholderIconNames: Set<String> = ["", "none", "text", "frame"]

    static let iconCacheLimit = 120

    static let onOffMappings = [
        OpenHABWidgetMapping(command: "ON", label: String(localized: "carplay_on")),
        OpenHABWidgetMapping(command: "OFF", label: String(localized: "carplay_off"))
    ]

    static let rollershutterMappings = [
        OpenHABWidgetMapping(command: "UP", label: String(localized: "carplay_open")),
        OpenHABWidgetMapping(command: "STOP", label: String(localized: "carplay_stop")),
        OpenHABWidgetMapping(command: "DOWN", label: String(localized: "carplay_close"))
    ]

    var interfaceController: CPInterfaceController?
    var streamTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var preferencesTask: Task<Void, Never>?
    let sitemapEventStream = SitemapEventStream()
    /// openHAB scopes a subscription per page and the main stream follows the selected
    /// group, so a group's own `Text` widget needs its own.
    let rootEventStream = SitemapEventStream()
    var rootStreamTask: Task<Void, Never>?
    /// Reports when the car restricts list length.
    var sessionConfiguration: CPSessionConfiguration?
    var currentListTemplate: CPListTemplate?
    /// Which sitemap group the header buttons currently have selected.
    var activeGroupId: String?
    /// Mutated rather than replaced; reassigning the array redraws the list.
    var headerButtons: [String: CPGridButton] = [:]
    var headerButtonTitles: [String: String] = [:]
    var headerButtonImages: [String: String] = [:]
    var headerButtonIds: [String] = []
    /// Mutated rather than replaced; CarPlay cross-fades a replaced row.
    var renderedItems: [String: any CPListTemplateItem] = [:]
    /// Sections are only replaced when this changes.
    var renderedItemKeys: [String] = []
    /// Artwork identity per row; an image reloads only when its source changes.
    var renderedImageKeys: [String: String] = [:]
    /// Lets an identical render be skipped outright.
    var lastRenderFingerprint: String?
    var detailTemplate: CarPlayDetail?
    var currentTabBarTemplate: CPTabBarTemplate?
    var groupTemplates: [String: CPListTemplate] = [:]
    var currentGroupIds: [String] = []
    /// Per tab, so a tab replaces its section only when its own rows change.
    var renderedKeysByGroup: [String: [String]] = [:]
    /// One page per subscription, so only the visible tab is live. nil is the home page.
    var subscribedPageId: String?
    let setpointService = SetPointService()
    // Retained across SSE restarts so page refreshes don't need a full stream teardown.
    var currentPage: OpenHABPage?
    var currentService: OpenAPIService?
    var currentConnection: ConnectionInfo?
    /// Cached from runStream: Preferences is actor-isolated, and syncRootStream is not async.
    var currentSitemapName = ""
    /// In flight, so repeated renders don't queue duplicates.
    var pendingIconURLs: Set<String> = []
    /// Keyed by icon URL so re-renders resolve synchronously.
    var iconCache: [String: UIImage] = [:]
    /// Artwork the current page needs; exempt from eviction.
    var activeIconKeys: Set<String> = []
    /// Eviction order: state-dependent URLs mint an entry per dimmer level.
    var iconCacheOrder: [String] = []

    static func widgetLevelMapping(for widget: OpenHABWidget) -> OpenHABWidgetMapping? {
        let press = widget.releaseOnly == true ? nil : widget.command
        let release = widget.releaseCommand
        guard press?.isEmpty == false || release?.isEmpty == false else { return nil }
        return OpenHABWidgetMapping(
            command: press,
            label: widget.displayState.labelText,
            releaseCommand: release
        )
    }

    /// Backoff capped at 30s so repeated failures stop hammering a dead network.
    static func retryDelay(failures: Int) -> Int {
        guard failures > 0 else { return 2 }
        return min(30, 1 << min(failures, 5))
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        interfaceController.setRootTemplate(placeholderTemplate(), animated: false, completion: nil)
        startStreaming()
        startObservingPreferences()
        Logger.carPlay.info("CarPlay scene connected")
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        streamTask?.cancel()
        streamTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        preferencesTask?.cancel()
        preferencesTask = nil
        pendingIconURLs.removeAll()
        rootStreamTask?.cancel()
        rootStreamTask = nil
        Task { await sitemapEventStream.stop() }
        Task { [rootEventStream] in await rootEventStream.stop() }
        self.interfaceController = nil
        currentListTemplate = nil
        currentTabBarTemplate = nil
        groupTemplates.removeAll()
        currentGroupIds.removeAll()
        renderedKeysByGroup.removeAll()
        activeGroupId = nil
        headerButtons.removeAll()
        headerButtonTitles.removeAll()
        headerButtonImages.removeAll()
        headerButtonIds.removeAll()
        subscribedPageId = nil
        renderedItems.removeAll()
        renderedItemKeys.removeAll()
        renderedImageKeys.removeAll()
        lastRenderFingerprint = nil
        detailTemplate = nil
        currentPage = nil
        currentService = nil
        currentConnection = nil
        currentSitemapName = ""
        iconCache.removeAll()
        iconCacheOrder.removeAll()
        activeIconKeys.removeAll()
        sessionConfiguration = nil
        Logger.carPlay.info("CarPlay scene disconnected")
    }

    // MARK: - Streaming

    func startStreaming() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await runStream()
                guard !Task.isCancelled else { return }
                switch outcome {
                case .idle:
                    return
                case .ended:
                    failures = 0
                case .failed:
                    failures += 1
                }
                let delay = Self.retryDelay(failures: failures)
                Logger.carPlay.info("CarPlay stream ended (\(String(describing: outcome))), retrying in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func startObservingPreferences() {
        preferencesTask?.cancel()
        preferencesTask = Task { [weak self] in
            // currentHomePreferencesStream is backed by currentHomePreferencesPublisher but
            // delivered via AsyncStream continuation — avoids the dispatch_assert_queue crash
            // that the Combine AsyncPublisher bridge (.values) caused here previously.
            var lastSitemap = await Preferences.shared.currentHomePreferences.sitemapForCarPlay
            for await prefs in await Preferences.shared.currentHomePreferencesStream {
                guard !Task.isCancelled else { break }
                let newSitemap = prefs.sitemapForCarPlay
                guard newSitemap != lastSitemap else { continue }
                lastSitemap = newSitemap
                // Sitemap selection changed — full restart needed (different page/subscription).
                await MainActor.run { self?.startStreaming() }
            }
        }
    }

    @MainActor
    func runStream() async -> StreamOutcome {
        let prefs = await Preferences.shared.currentHomePreferences
        await NetworkTracker.shared.startTracking(connectionConfigurations: [
            prefs.localConnectionConfig,
            prefs.remoteConnectionConfig
        ])
        guard let connection = await NetworkTracker.shared.waitForActiveConnection() else {
            Logger.carPlay.warning("CarPlay: no active connection")
            showUnreachableIfEmpty()
            return .failed
        }
        let sitemapName = await Preferences.shared.currentHomePreferences.sitemapForCarPlay
        currentSitemapName = sitemapName
        guard !sitemapName.isEmpty else {
            Logger.carPlay.info("CarPlay: no sitemap configured")
            interfaceController?.setRootTemplate(
                placeholderTemplate(message: String(localized: "carplay_not_configured_detail")),
                animated: false, completion: nil
            )
            return .idle
        }
        do {
            let service = try OpenAPIService(connectionConfiguration: connection.configuration)
            currentService = service
            currentConnection = connection

            guard let page = try await fetchPage(sitemapName: sitemapName, service: service) else {
                showUnreachableIfEmpty()
                return .failed
            }
            currentPage = page
            updateTemplate(page: page, service: service)

            // A failed probe is not "no SSE" — retry rather than long-poll all session.
            let serverProps: OpenHABServerProperties
            do {
                serverProps = try await service.getRoot()
            } catch {
                Logger.carPlay.warning("CarPlay server probe failed, will retry: \(error)")
                return .failed
            }

            if serverProps.hasSseSupport() {
                await runSSE(sitemapName: sitemapName, connection: connection)
            } else {
                await runLongPoll(sitemapName: sitemapName, pageId: page.pageId, service: service)
            }
            return .ended
        } catch {
            Logger.carPlay.error("CarPlay stream error: \(error)")
            showUnreachableIfEmpty()
            return .failed
        }
    }

    /// Finds a widget on the current page or any of its linked pages.
    @MainActor
    func widget(withId id: String) -> OpenHABWidget? {
        guard let page = currentPage else { return nil }
        if let match = page.widgets.first(where: { $0.widgetId == id }) { return match }
        for widget in page.widgets {
            if let match = widget.linkedPage?.widgets.first(where: { $0.widgetId == id }) { return match }
        }
        return nil
    }

    /// Losing signal mid-drive leaves the last known state visible.
    @MainActor
    func showUnreachableIfEmpty() {
        guard currentListTemplate == nil, currentTabBarTemplate == nil else { return }
        interfaceController?.setRootTemplate(
            placeholderTemplate(message: String(localized: "carplay_unreachable")),
            animated: false, completion: nil
        )
    }

    @MainActor
    func runSSE(sitemapName: String, connection: ConnectionInfo) async {
        await sitemapEventStream.startMonitoringNetworkIfNeeded(initialConnection: connection)
        let homePageId = currentPage.map { $0.pageId.isEmpty ? sitemapName : $0.pageId } ?? sitemapName
        let pageId = subscribedPageId ?? homePageId
        let stream = await sitemapEventStream.stream(sitemap: sitemapName, pageId: pageId)
        Logger.carPlay.info("CarPlay SSE starting for \(sitemapName)/\(pageId)")

        // Refresh on reconnect so structural changes missed during a disconnect are caught.
        var needsRefreshOnReconnect = false

        for await msg in stream {
            guard !Task.isCancelled else { break }
            switch msg {
            case .connected:
                Logger.carPlay.info("CarPlay SSE connected")
                if needsRefreshOnReconnect {
                    needsRefreshOnReconnect = false
                    schedulePageRefresh(sitemapName: sitemapName)
                }
            case let .disconnected(error):
                needsRefreshOnReconnect = true
                if let error { Logger.carPlay.warning("CarPlay SSE disconnected: \(error)") }
            case let .event(message):
                handleSseMessage(message, sitemapName: sitemapName)
            }
        }
    }

    @MainActor
    func handleSseMessage(_ message: SitemapEventMessage, sitemapName: String) {
        switch message {
        case .alive:
            break
        case .sitemapChanged:
            Logger.carPlay.info("CarPlay SSE: sitemap changed, refreshing page")
            // Refresh page content only — do not restart the SSE stream.
            schedulePageRefresh(sitemapName: sitemapName)
        case let .widget(event):
            guard let page = currentPage, let service = currentService else { return }
            var result = page.apply(event: event)
            // apply(event:) descends into `widgets` but not `linkedPage`.
            if result == .notFound {
                result = applyToLinkedPages(event: event, in: page)
            }
            switch result {
            case .applied:
                updateTemplate(page: page, service: service)
            case .requiresPageReload, .notFound:
                Logger.carPlay.info("CarPlay SSE: widget \(event.widgetId ?? "") requires reload")
                schedulePageRefresh(sitemapName: sitemapName)
            case .unchanged:
                break
            }
        case .unknown:
            break
        }
    }

    /// Moves the subscription to a tab's page; other tabs go quiet until selected, so each
    /// switch refreshes first.
    @MainActor
    func repointSubscription(to groupId: String) {
        let pageId: String? = groupId == Self.defaultGroupId ? nil : groupId
        guard pageId != subscribedPageId else { return }
        subscribedPageId = pageId

        startStreaming()
    }

    /// Whole sitemap: `pollDataForPage` returns linked pages as childless stubs.
    func fetchPage(sitemapName: String, service: OpenAPIService) async throws -> OpenHABPage? {
        try await service.pollDataForSitemap(sitemapname: sitemapName)?.page
    }

    /// Only when a group carries an item, so the common case costs one connection.
    @MainActor
    func syncRootStream(groups: [SitemapGroup]) {
        let sitemapName = currentSitemapName
        let needed = subscribedPageId != nil
            && !sitemapName.isEmpty
            && groups.contains { $0.source?.item != nil }

        guard needed else {
            guard rootStreamTask != nil else { return }
            Logger.carPlay.info("CarPlay root SSE no longer needed, closing")
            rootStreamTask?.cancel()
            rootStreamTask = nil
            Task { [rootEventStream] in await rootEventStream.stop() }
            return
        }

        guard rootStreamTask == nil, let connection = currentConnection else { return }
        let pageId = currentPage.map { $0.pageId.isEmpty ? sitemapName : $0.pageId } ?? sitemapName
        rootStreamTask = Task { @MainActor [weak self] in
            await self?.runRootSSE(sitemapName: sitemapName, pageId: pageId, connection: connection)
        }
    }

    @MainActor
    func runRootSSE(sitemapName: String, pageId: String, connection: ConnectionInfo) async {
        await rootEventStream.startMonitoringNetworkIfNeeded(initialConnection: connection)
        var failures = 0

        while !Task.isCancelled {
            let stream = await rootEventStream.stream(sitemap: sitemapName, pageId: pageId)
            Logger.carPlay.info("CarPlay root SSE starting for \(sitemapName)/\(pageId)")

            for await msg in stream {
                guard !Task.isCancelled else { return }
                switch msg {
                case .connected:
                    failures = 0
                    Logger.carPlay.info("CarPlay root SSE connected")
                case let .disconnected(error):
                    if let error { Logger.carPlay.warning("CarPlay root SSE disconnected: \(error)") }
                case let .event(message):
                    handleRootSseMessage(message, sitemapName: sitemapName)
                }
            }

            guard !Task.isCancelled else { return }
            failures += 1
            let delay = Self.retryDelay(failures: failures)
            Logger.carPlay.info("CarPlay root SSE ended, retrying in \(delay)s")
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    @MainActor
    func handleRootSseMessage(_ message: SitemapEventMessage, sitemapName: String) {
        switch message {
        case .alive:
            break
        case .sitemapChanged:
            schedulePageRefresh(sitemapName: sitemapName)
        case let .widget(event):
            guard let page = currentPage, let service = currentService else { return }
            switch page.apply(event: event) {
            case .applied:
                updateTemplate(page: page, service: service)
            case .requiresPageReload:
                schedulePageRefresh(sitemapName: sitemapName)
            case .notFound, .unchanged:
                break
            }
        case .unknown:
            break
        }
    }

    @MainActor
    func applyToLinkedPages(event: OpenHABSitemapWidgetEvent,
                            in page: OpenHABPage) -> SitemapWidgetEventApplicationResult {
        for widget in page.widgets {
            guard let linked = widget.linkedPage else { continue }
            let result = linked.apply(event: event)
            if result != .notFound { return result }
        }
        return .notFound
    }

    /// Refreshes without restarting the stream. The delay is what actually coalesces:
    /// cancelling alone lets a steady event rate abort every fetch before it lands.
    func schedulePageRefresh(sitemapName: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await refreshPage(sitemapName: sitemapName)
        }
    }

    @MainActor
    func refreshPage(sitemapName: String) async {
        guard let service = currentService else { return }
        do {
            guard let page = try await fetchPage(sitemapName: sitemapName, service: service) else { return }
            currentPage = page
            updateTemplate(page: page, service: service)
        } catch {
            Logger.carPlay.error("CarPlay page refresh error: \(error)")
        }
    }

    @MainActor
    func runLongPoll(sitemapName: String, pageId: String, service: OpenAPIService) async {
        Logger.carPlay.info("CarPlay using long-poll for \(sitemapName)")
        do {
            for try await event in SitemapPageLoader.stream(sitemapName: sitemapName, pageId: pageId, service: service) {
                guard !Task.isCancelled else { break }
                // The polled page carries linked pages as childless stubs, so adopting it
                // would drop every group. Use it only as a signal to refetch the tree.
                if case .longPoll = event {
                    schedulePageRefresh(sitemapName: sitemapName)
                }
            }
        } catch {
            Logger.carPlay.error("CarPlay long-poll error: \(error)")
        }
    }
}

// MARK: - CPTabBarTemplateDelegate

extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard let id = groupTemplates.first(where: { $0.value === selectedTemplate })?.key else { return }
        Logger.carPlay.info("CarPlay tab selected: \(id)")
        repointSubscription(to: id)
    }
}

// MARK: - CPSessionConfigurationDelegate

extension CarPlaySceneDelegate: CPSessionConfigurationDelegate {
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        Logger.carPlay.info("CarPlay limited UI changed: lists=\(limitedUserInterfaces.contains(.lists))")
        guard let page = currentPage, let service = currentService else { return }
        updateTemplate(page: page, service: service)
    }
}

// MARK: - CPInterfaceControllerDelegate

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        // However it was dismissed, stop refreshing it.
        guard detailTemplate?.template === aTemplate else { return }
        detailTemplate = nil
    }
}
