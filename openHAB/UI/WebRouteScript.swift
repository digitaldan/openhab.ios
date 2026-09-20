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

import Foundation
import OpenHABCore

/// Keeps track of the pages the user opens in the Main UI, and puts them back there after a
/// connection switch.
///
/// The script below only reports pages the Main UI can open again on its own. Deciding what to
/// put back is done here in Swift, where it can be tested.
enum WebRouteScript {
    /// What a load already knows about itself, for deciding whether to put the user back.
    struct Load {
        /// A page someone asked for by name, rather than us opening the Main UI on our own.
        let path: String?
        /// The user pulled to refresh, or the app is reloading after a problem.
        let force: Bool
        let isShowingTile: Bool
        /// Whether the user has moved around in this home since the app started.
        let hasCapturedThisSession: Bool
        /// The home's own start page, empty when none is set.
        let defaultMainUIPath: String
    }

    private struct Payload: Decodable {
        let history: [String]
        let url: String
    }

    /// The kind of message the script below sends us.
    static let messageType = "routeState"

    /// We add one browser history entry per page, and iOS quietly stops accepting them after
    /// about a hundred in half a minute, which would leave the user on the wrong page. The
    /// Main UI's own list only ever grows, so cut it short. Nobody goes back twenty pages.
    static let maxSeededEntries = 20

    /// Settings pages ask for a login when the connection has no admin rights. Matched by
    /// address, since there is no dependable way to ask the Main UI which pages are protected.
    private static let adminPrefixes = ["/settings", "/developer", "/addons", "/setup-wizard"]

    /// Reads the message the script sends.
    static func snapshot(fromJSON json: String, connectionURL: String, capturedAt: Date = Date()) -> WebRouteSnapshot? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.history.isEmpty, !payload.url.isEmpty else { return nil }
        return WebRouteSnapshot(
            history: payload.history,
            url: payload.url,
            connectionURL: connectionURL,
            capturedAt: capturedAt
        )
    }

    /// Whether to put the user back where they were.
    ///
    /// Only when we are opening the Main UI by ourselves. If a particular page was asked for,
    /// the user pulled to refresh, or a tile is showing, that choice wins instead.
    ///
    /// The first time after the app starts, the home's own start page wins. Opening there is
    /// why it was set. Once the user has moved around, where they were is the better answer.
    static func snapshotToRestore(_ stored: WebRouteSnapshot?, for load: Load) -> WebRouteSnapshot? {
        guard let stored, load.path == nil, !load.force, !load.isShowingTile else { return nil }
        guard load.hasCapturedThisSession || load.defaultMainUIPath.isEmpty else { return nil }
        return stored
    }

    /// The pages to put back and the one to show, or nil if nothing usable is left.
    ///
    /// - Parameter dropAdmin: true when the user is landing on a different connection, which
    ///   may not have admin rights.
    static func seed(for snapshot: WebRouteSnapshot, dropAdmin: Bool) -> (history: [String], url: String)? {
        var history = dropAdmin ? snapshot.history.filter { !isAdminPath($0) } : snapshot.history
        // Removing pages can leave the same page sitting next to itself.
        history = history.reduce(into: [String]()) { result, url in
            if result.last != url { result.append(url) }
        }
        history = Array(history.suffix(maxSeededEntries))
        guard let last = history.last else { return nil }
        // The Main UI cuts the list at the first place the current page appears, so an earlier
        // copy of it would quietly throw away everything after that.
        return (history.dropLast().filter { $0 != last } + [last], last)
    }

    static func isAdminPath(_ url: String) -> Bool {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        return adminPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Builds the script that runs as a page opens.
    ///
    /// - Parameters:
    ///   - restore: the pages to put back, oldest first. Pass nil to leave the Main UI's own
    ///     memory alone, which is what we want when the app has just started.
    ///   - basePath: what the app's address hangs off, with no trailing slash, so a cloud
    ///     connection's extra path is kept. Empty when the app sits at the top.
    static func source(restore: [String]?, basePath: String = "") -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let restoreLiteral = restore
            .flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let baseLiteral = (try? encoder.encode(basePath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #""""#

        return #"""
        (function () {
            var RESTORE = \#(restoreLiteral)
            var BASE = \#(baseLiteral)
            var VIEW_ID = 'view_main' // the name the Main UI gives its main view
            var STORAGE_KEY = 'f7router-' + VIEW_ID + '-history'

            // Write this before the Main UI starts up. It reads the list as it starts.
            //
            // Only on the app's front page, which is what we asked for. These same scripts run
            // for every page the app opens, so a tile or a retry could otherwise pick this up
            // and get dragged off to the wrong page.
            if (RESTORE && RESTORE.length && isAppRoot()) {
                try { localStorage.setItem(STORAGE_KEY, JSON.stringify(RESTORE)) } catch (e) {}
                seedBrowserHistory(RESTORE)
            }

            function isAppRoot() {
                var path = location.pathname
                return path === BASE || path === BASE + '/'
            }

            // Two jobs. Going back in the Main UI is really the browser going back, and a page
            // that just opened has nothing behind it, so give it something. And we asked for
            // the app's front page rather than the page we want, so this is also what moves us
            // to that page. Changing the address is safe. Everything the page needs is fetched
            // from the top, not relative to wherever we are.
            function seedBrowserHistory(stack) {
                try {
                    history.replaceState(stateFor(stack[0]), '', BASE + stack[0])
                    for (var i = 1; i < stack.length; i++) {
                        history.pushState(stateFor(stack[i]), '', BASE + stack[i])
                    }
                } catch (e) {}
            }

            // The Main UI looks here to work out where "back" goes, so match what it writes.
            function stateFor(url) {
                var state = {}
                state[VIEW_ID] = { url: url }
                return state
            }

            var MODAL_KEYS = ['popup', 'popover', 'sheet', 'actions', 'panel', 'loginScreen', 'customModal']
            var PROPS_ONLY = /\/(duplicate|stub)$/ // only work when opened from inside the app

            function router() {
                var el = document.querySelector('.view-main')
                return el && el.f7View ? el.f7View.router : null
            }

            // Popups and the like show up in the address but cannot be opened again directly.
            function navigable(r, url) {
                if (!url || url.charAt(0) !== '/') return false
                var path = url.split('#')[0]
                if (PROPS_ONLY.test(path.split('?')[0])) return false
                var m
                try { m = r.findMatchingRoute(path) } catch (e) { return false }
                if (!m || !m.route) return false
                if (m.route.path === '(.*)') return false // nothing real behind this address
                for (var i = 0; i < MODAL_KEYS.length; i++) {
                    if (m.route[MODAL_KEYS[i]]) return false // a popup, e.g. /analyzer/
                }
                return true
            }

            function capture() {
                var r = router()
                if (!r || !r.history) return null
                var stack = []
                for (var i = 0; i < r.history.length; i++) {
                    var url = String(r.history[i]).split('#')[0]
                    if (!navigable(r, url)) continue
                    if (stack.length && stack[stack.length - 1] === url) continue // same page twice
                    stack.push(url)
                }
                if (!stack.length) return null
                return { history: stack, url: stack[stack.length - 1] }
            }

            var lastSent = null
            var pending = null

            function report() {
                if (pending) clearTimeout(pending)
                // Let the Main UI finish updating before we read anything.
                pending = setTimeout(function () {
                    pending = null
                    var state = capture()
                    if (!state) return
                    var json = JSON.stringify(state)
                    if (json === lastSent) return // nothing moved, e.g. a popup opened
                    lastSent = json
                    try {
                        window.webkit.messageHandlers.mainUi.postMessage({
                            type: 'routeState', state: json
                        })
                    } catch (e) {}
                }, 0)
            }

            var origPush = history.pushState
            var origReplace = history.replaceState

            history.pushState = function () {
                var out = origPush.apply(history, arguments)
                report()
                return out
            }
            history.replaceState = function () {
                var out = origReplace.apply(history, arguments)
                report()
                return out
            }
            window.addEventListener('popstate', report)

            // The Main UI normally announces its first page itself, which we catch above.
            // This is a fallback in case it doesn't.
            var tries = 0
            var poll = setInterval(function () {
                if (router() || ++tries > 100) {
                    clearInterval(poll)
                    report()
                }
            }, 100)
        })()
        """#
    }
}
