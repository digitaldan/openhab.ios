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

// MARK: - Icons

extension CarPlaySceneDelegate {
    /// Point size for list row images.
    var rowIconPointSize: CGFloat {
        let size = CPListItem.maximumImageSize
        return min(size.width, size.height)
    }

    /// The head unit's scale, for rendering icons at native resolution.
    var carDisplayScale: CGFloat {
        let scale = interfaceController?.carTraitCollection.displayScale ?? 0
        return scale > 0 ? scale : 2
    }

    static func quantisedIconState(_ widget: OpenHABWidget) -> String? {
        guard let raw = widget.iconState() else { return nil }
        // Int(_:) traps on NaN, infinity and anything past Int's range; a Group with an
        // AVG function over no members is enough to produce one.
        guard let value = Double(raw), value.isFinite,
              value >= Double(Int.min / 10), value <= Double(Int.max / 10) else { return raw }
        return String(Int((value / 10).rounded() * 10))
    }

    static func fetchIcon(url: URL, connection: ConnectionInfo, pixelSize: CGFloat) async -> UIImage? {
        let options: KingfisherOptionsInfo = [
            .processor(OpenHABImageProcessor(svgMaxSize: CGSize(width: pixelSize, height: pixelSize))),
            .requestModifier(OpenHABAccessTokenAdapter(connectionConfiguration: connection.configuration))
        ]
        guard let image = try? await KingfisherManager.shared.retrieveImage(with: url, options: options).image else {
            return nil
        }
        // Server icons carry their own colours; template rendering flattens them..
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Server icons preferred, so custom and state-dependent artwork renders as authored.
    /// The SF Symbol is the synchronous placeholder, and the fallback when there is none.
    @MainActor
    func iconImage(for widget: OpenHABWidget,
                   mapping: OpenHABWidgetMapping? = nil,
                   size pointSize: CGFloat) -> UIImage {
        let name = mapping?.icon ?? widget.icon
        if let url = iconURL(name: name, widget: widget),
           let cached = iconCache[url.absoluteString] {
            return squared(cached, to: pointSize)
        }
        return sfSymbol(named: name, isOn: widget.displayState.isOn, pointSize: pointSize)
    }

    @MainActor
    func cacheIcon(_ image: UIImage, for key: String) {
        if iconCache[key] == nil { iconCacheOrder.append(key) }
        iconCache[key] = image

        // Never evict artwork the current page still wants: doing so makes the next render
        // refetch it, cache it, render again, and evict something else — indefinitely.
        var index = 0
        while iconCacheOrder.count > Self.iconCacheLimit, index < iconCacheOrder.count {
            let candidate = iconCacheOrder[index]
            if activeIconKeys.contains(candidate) { index += 1; continue }
            iconCacheOrder.remove(at: index)
            iconCache.removeValue(forKey: candidate)
        }
    }

    /// Aspect-fit on a square canvas of exactly `pointSize`. Fetched icons report scale 1,
    /// so an oversized bitmap gets dropped, and ragged heights stagger the labels beneath.
    @MainActor
    func squared(_ image: UIImage, to pointSize: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }

        let ratio = pointSize / longest
        let drawn = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let origin = CGPoint(x: (pointSize - drawn.width) / 2, y: (pointSize - drawn.height) / 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = carDisplayScale
        format.opaque = false
        let canvas = UIGraphicsImageRenderer(
            size: CGSize(width: pointSize, height: pointSize),
            format: format
        ).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawn))
        }
        return canvas.withRenderingMode(image.renderingMode)
    }

    /// Header button artwork.
    @MainActor
    func groupImage(for group: SitemapGroup, size: CGFloat) -> UIImage {
        // No widget, or openHAB's placeholder icon name: a folder beats an empty box.
        guard let widget = group.source,
              !Self.placeholderIconNames.contains(widget.icon.lowercased()) else {
            return sfSymbolImage(group.id == Self.defaultGroupId ? .house : .folder, pointSize: size)
        }
        // Not template-rendered: header buttons draw the image as given, and flattening an
        // SVG to its alpha turns it into a blob. State-free too, or every state change is a
        // cache miss and the button flickers back to a symbol.
        if let url = iconURL(name: widget.icon, widget: widget, includeState: false),
           let cached = iconCache[url.absoluteString] {
            return squared(cached, to: size)
        }
        return sfSymbol(named: widget.icon, isOn: widget.displayState.isOn, pointSize: size)
    }

    @MainActor
    func sfSymbolImage(_ symbol: SFSymbol, pointSize: CGFloat) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = UIImage(systemSymbol: symbol).applyingSymbolConfiguration(config)
            ?? UIImage(systemSymbol: symbol)
        return squared(image.withRenderingMode(.alwaysTemplate), to: pointSize)
    }

    @MainActor
    func sfSymbol(named name: String, isOn: Bool, pointSize: CGFloat) -> UIImage {
        sfSymbolImage(openHABSFSymbol(for: name, isOn: isOn), pointSize: pointSize)
    }

    /// Rounded to the nearest ten, the granularity openHAB's icon sets are authored at: a
    /// fading dimmer reports every value on the way, each one otherwise a distinct URL.
    @MainActor
    func iconURL(name: String, widget: OpenHABWidget, includeState: Bool = true) -> URL? {
        guard !Self.placeholderIconNames.contains(name.lowercased()),
              let connection = currentConnection else { return nil }
        return Endpoint.icon(
            rootUrl: connection.configuration.url,
            version: connection.version,
            icon: name,
            state: includeState ? Self.quantisedIconState(widget) : nil,
            // SVG, as the phone's IconView does: one cached icon is drawn at both row and
            // header sizes, and a raster resamples badly between them.
            iconType: .svg,
            iconColor: widget.iconColor,
            staticIcon: widget.staticIcon
        )?.url
    }

    /// Fetches what isn't cached, then re-renders. Terminates: the second render finds
    /// everything cached.
    @MainActor
    func fetchRemoteIcons(for widgets: [OpenHABWidget], page: OpenHABPage, service: OpenAPIService) {
        guard let connection = currentConnection else { return }

        // Only what gets drawn: rows use the state-dependent URL, group buttons the
        // state-free one, and mapping artwork is never rendered at all.
        var wanted: Set<String> = []
        var urls: Set<URL> = []
        for widget in widgets {
            let isGroup = widget.linkedPage != nil
            guard let url = iconURL(name: widget.icon, widget: widget, includeState: !isGroup) else { continue }
            let key = url.absoluteString
            wanted.insert(key)
            if iconCache[key] == nil, !pendingIconURLs.contains(key) { urls.insert(url) }
        }
        activeIconKeys = wanted
        guard !urls.isEmpty else { return }

        let pixelSize = (rowIconPointSize * carDisplayScale).rounded()
        for url in urls {
            pendingIconURLs.insert(url.absoluteString)
        }

        // One task per icon, never cancelled by a later render.
        for url in urls {
            Task { @MainActor [weak self] in
                let image = await Self.fetchIcon(url: url, connection: connection, pixelSize: pixelSize)
                guard let self else { return }
                pendingIconURLs.remove(url.absoluteString)

                guard let image else {
                    Logger.carPlay.warning("CarPlay icon fetch failed: \(url.absoluteString, privacy: .public)")
                    return
                }
                cacheIcon(image, for: url.absoluteString)
                // Identity, not id: a refresh mints a new page object with the same id, and
                // rendering the captured one reverts every row to its pre-refresh state.
                guard currentPage === page else { return }
                updateTemplate(page: page, service: service)
            }
        }
    }

    func placeholderButtonImage() -> UIImage {
        UIImage(named: "openHABIcon")?
            .withRenderingMode(.alwaysTemplate)
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    func placeholderTemplate(message: String? = nil) -> CPTemplate {
        guard let message else {
            let button = CPGridButton(
                titleVariants: [String(localized: "carplay_not_configured")],
                image: placeholderButtonImage()
            ) { _ in }
            return CPGridTemplate(title: "openHAB", gridButtons: [button])
        }
        let item = CPInformationItem(title: nil, detail: message)
        return CPInformationTemplate(title: "openHAB", layout: .leading, items: [item], actions: [])
    }
}
