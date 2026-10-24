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
    var rowIconPointSize: CGFloat {
        let size = CPListItem.maximumImageSize
        return min(size.width, size.height)
    }

    var carDisplayScale: CGFloat {
        let scale = interfaceController?.carTraitCollection.displayScale ?? 0
        return scale > 0 ? scale : 2
    }

    /// Rounded to tens, like openHAB's icon sets, so a fading dimmer doesn't fetch every step.
    static func quantisedIconState(_ widget: OpenHABWidget) -> String? {
        guard let raw = widget.iconState() else { return nil }
        // Int(_:) traps on non-finite values, e.g. AVG over an empty Group.
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
        // Keep server icon colours.
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Cached server icon, else an SF Symbol.
    @MainActor
    func iconImage(for widget: OpenHABWidget, size pointSize: CGFloat) -> UIImage {
        let name = widget.icon
        if let url = iconURL(name: name, widget: widget),
           let cached = iconCache[url.absoluteString] {
            return squared(cached, to: pointSize)
        }
        return sfSymbol(named: name, isOn: widget.displayState.isOn, pointSize: pointSize)
    }

    @MainActor
    func cacheIcon(_ image: UIImage, for key: String) {
        if iconCache[key] == nil {
            iconCacheOrder.append(key)
        }
        iconCache[key] = image

        // Evicting icons the page still needs would loop: refetch, render, evict.
        var index = 0
        while iconCacheOrder.count > Self.iconCacheLimit, index < iconCacheOrder.count {
            let candidate = iconCacheOrder[index]
            if activeIconKeys.contains(candidate) {
                index += 1; continue
            }
            iconCacheOrder.remove(at: index)
            iconCache.removeValue(forKey: candidate)
        }
    }

    /// Aspect-fit into an exact square, so oversized or uneven icons don't break the layout.
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

    @MainActor
    func groupImage(for group: SitemapGroup, size: CGFloat) -> UIImage {
        guard let widget = group.source,
              !Self.placeholderIconNames.contains(widget.icon.lowercased()) else {
            return sfSymbolImage(group.id == Self.defaultGroupId ? .house : .folder, pointSize: size)
        }
        // State-free URL, so state changes don't flicker the button back to a symbol.
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

    @MainActor
    func iconURL(name: String, widget: OpenHABWidget, includeState: Bool = true) -> URL? {
        guard !Self.placeholderIconNames.contains(name.lowercased()),
              let connection = currentConnection else { return nil }
        return Endpoint.icon(
            rootUrl: connection.configuration.url,
            version: connection.version,
            icon: name,
            state: includeState ? Self.quantisedIconState(widget) : nil,
            // One cached icon serves both row and header sizes.
            iconType: .svg,
            iconColor: widget.iconColor,
            staticIcon: widget.staticIcon
        )?.url
    }

    /// Fetches what isn't cached, then re-renders.
    @MainActor
    func fetchRemoteIcons(for widgets: [OpenHABWidget], page: OpenHABPage, service: OpenAPIService) {
        guard let connection = currentConnection else { return }

        var wanted: Set<String> = []
        var urls: Set<URL> = []
        for widget in widgets {
            let isGroup = widget.linkedPage != nil
            guard let url = iconURL(name: widget.icon, widget: widget, includeState: !isGroup) else { continue }
            let key = url.absoluteString
            wanted.insert(key)
            if iconCache[key] == nil, !pendingIconURLs.contains(key) {
                urls.insert(url)
            }
        }
        activeIconKeys = wanted
        guard !urls.isEmpty else { return }

        let pixelSize = (rowIconPointSize * carDisplayScale).rounded()
        for url in urls {
            pendingIconURLs.insert(url.absoluteString)
        }

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
                // Identity, not id: a refresh keeps the id but replaces the page.
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
