import AppKit

// \`./bench audit\`: the features added from the browser audit — Quick
// Commands, chains, focus, saving power, web panels, split views of up to
// four, group actions and the peek's split — driven through the same calls
// their menus and buttons make, with the state they leave behind. Only on a
// SEARCH_PROBE run.

@MainActor
enum AuditProbe {
    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard let window = browser.key else { return ["error": "no window"] }
        func tab(_ key: String = "id") -> Tab? {
            guard let ref = (request[key] as? String)?.lowercased(), !ref.isEmpty else { return nil }
            return window.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
        }
        func group() -> UUID? {
            guard let ref = (request["group"] as? String)?.lowercased() else { return nil }
            return window.tabGroups.first { $0.id.uuidString.lowercased().hasPrefix(ref) }?.id
        }
        switch request["step"] as? String ?? "state" {
        case "state":
            break
        case "group":
            let members = ((request["ids"] as? [String]) ?? []).compactMap { ref in
                window.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }
            }
            guard let first = members.first else { return ["error": "group needs ids"] }
            let id = window.addTabGroup(containing: first)
            window.editingGroupID = nil
            for other in members.dropFirst() { window.move(other, toGroup: id) }
        case "groupAct":
            guard let id = group() else { return ["error": "no such group"] }
            switch request["act"] as? String {
            case "tile": window.tileGroup(id)
            case "sleep": window.sleepGroup(id)
            case "bookmark": window.bookmarkGroup(id)
            case "pin": window.pinGroup(id)
            default: return ["error": "act is tile, sleep, bookmark or pin"]
            }
        case "summon":
            window.summon()
            window.typed = request["text"] as? String ?? ""
        case "take":
            guard let index = request["index"] as? Int, window.offers.indices.contains(index) else { return ["error": "no such row"] }
            window.take(window.offers[index])
        case "dismiss":
            window.dismiss()
        case "port104":
            // The pieces brought over from upstream 1.0.4, driven the way
            // their menus drive them, with the state they leave behind.
            return Port104Probe.run(request, browser: browser)
        case "update":
            // Settings › About's Update button.
            Updater.shared.update()
        case "pin":
            // A tab's menu's Pin.
            guard let target = tab() else { return ["error": "no such tab"] }
            window.pin(target)
        case "compat":
            // The site card's Turn On/Off Compatibility Mode.
            guard let host = request["host"] as? String else { return ["error": "compat needs a host"] }
            Protections.setCompatible(host, request["on"] as? Bool ?? true, in: browser)
            return ["compatible": Protections.compatible(host), "shieldPaused": Shield.shared.isPaused(on: host)]
        case "pickIcon":
            // Choose Icon… on a group: the column held out, the Mac's emoji
            // picker brought up.
            guard let id = group() else { return ["error": "no such group"] }
            window.choosingIconFor = id
            NSApp.orderFrontCharacterPalette(nil)
        case "tabMenu":
            // A tab's own menu, opened on `id` (see TabMenu): what it acts on.
            guard let target = tab() else { return ["error": "no such tab"] }
            if let ids = request["select"] as? [String] {
                window.selectedTabs = Set(window.tabs.filter { t in ids.contains { t.id.uuidString.lowercased().hasPrefix($0) } }.map(\.id))
            }
            let chosen = window.menuTabs(for: target)
            switch request["act"] as? String {
            case "unload": window.unload(chosen)
            case "unloadOthers": window.unloadTabs(besides: chosen)
            default: break
            }
        case "focus":
            window.toggleFocus()
        case "power":
            if let mode = (request["mode"] as? String).flatMap(Power.Mode.init) { Power.shared.mode = mode }
        case "panel":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { return ["error": "panel needs a url"] }
            let site = WebPanels.shared.add(url, name: request["name"] as? String ?? "")
            if request["mobile"] as? Bool == true { WebPanels.shared.setMobile(site.id, true) }
            window.togglePanel(WebPanels.shared.site(site.id) ?? site)
        case "panelMobile":
            window.setPanelMobile(request["on"] as? Bool ?? true)
        case "panelClose":
            window.closePanel()
        case "panelTab":
            window.panelToTab()
        case "panelForget":
            for site in WebPanels.shared.sites { WebPanels.shared.remove(site.id) }
        case "peek":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)), let from = window.active else { return ["error": "peek needs a url and a tab"] }
            window.peek(url, from: from)
        case "peekSplit":
            window.splitPeek()
        case "chain":
            var chain = Chains.shared.add()
            chain.name = request["name"] as? String ?? chain.name
            chain.steps = request["steps"] as? [String] ?? []
            Chains.shared.update(chain)
            if request["run"] as? Bool == true, let saved = Chains.shared.chain(chain.id) {
                Chains.shared.run(saved, browser: browser, window: window)
            }
        case "chainForget":
            for chain in Chains.shared.all { Chains.shared.remove(chain.id) }
        case "select":
            guard let target = tab() else { return ["error": "no such tab"] }
            window.select(target)
        case "close":
            guard let target = tab() else { return ["error": "no such tab"] }
            window.close(target)
        case "groupEmoji":
            guard let id = group() else { return ["error": "no such group"] }
            window.setEmoji(request["emoji"] as? String, forGroup: id)
        case "saveGroup":
            guard let id = group() else { return ["error": "no such group"] }
            window.saveAndCloseGroup(id)
        case "container":
            guard let target = tab() else { return ["error": "no such tab"] }
            let named = request["name"] as? String
            let id = named.flatMap { name in Containers.shared.all.first { $0.name == name }?.id }
            if named != nil, id == nil { return ["error": "no such container"] }
            window.put(target, inContainer: id)
        case "containerDelete":
            guard let name = request["name"] as? String, let found = Containers.shared.all.first(where: { $0.name == name })
            else { return ["error": "no such container"] }
            Containers.shared.remove(found.id, in: browser)
        case "openFrom":
            // A link ⌘-clicked or middle-clicked on the tab's page.
            guard let source = tab(), let url = (request["url"] as? String).flatMap(URL.init(string:)) else { return ["error": "openFrom needs a tab and a url"] }
            window.open(url, foreground: false, from: source)
        default:
            return ["error": "unknown step"]
        }
        return state(window, browser: browser)
    }

    static func state(_ window: WindowModel, browser: Browser) -> [String: Any] {
        func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
        let web = window.panel as? WebPanel
        return [
            "active": window.activeID.map(short) ?? "",
            "update": { () -> String in
                switch Updater.shared.stage {
                case .none: return "none"
                case .fetching: return "fetching"
                case .ready: return "ready"
                case .offered: return "offered"
                case .waiting: return "waiting"
                }
            }(),
            "tabs": window.tabs.map { tab in
                ["id": short(tab.id), "url": tab.address?.absoluteString ?? "", "group": tab.groupID.map(short) ?? "",
                 "pin": tab.pin ?? "", "asleep": tab.asleep,
                 "container": Containers.shared.container(tab.container)?.name ?? ""] as [String: Any]
            },
            "groups": window.tabGroups.map { ["id": short($0.id), "name": $0.name, "emoji": $0.emoji ?? ""] },
            "savedGroups": SavedGroups.shared.all.map { ["name": $0.name, "emoji": $0.emoji ?? "", "pages": $0.pages.map(\.url)] },
            "containers": Containers.shared.all.map(\.name),
            "pairs": window.splitPairs.map { ["members": $0.members.map(short), "layout": $0.layout.rawValue] },
            "visiblePair": window.visiblePair.map { $0.members.map(short) } ?? [],
            "peek": window.peekTab.map { short($0.id) } ?? "",
            "offers": window.offers.map { offer -> [String: Any] in
                let kind: String
                switch offer.kind {
                case .open: kind = "open"
                case .bookmark: kind = "bookmark"
                case .visited: kind = "visited"
                case .action: kind = "action"
                case .command: kind = "command"
                case .search: kind = "search"
                case .known: kind = "known"
                }
                return ["key": offer.key, "kind": kind, "detail": offer.title]
            },
            "summoning": window.summoning,
            "placeholder": Bench.addressField(in: browser.keyHost?.contentView).map { field -> [String: String] in
                var editor = ""
                if let text = field.currentEditor() as? NSTextView, text.responds(to: NSSelectorFromString("placeholderAttributedString")) {
                    editor = (text.value(forKey: "placeholderAttributedString") as? NSAttributedString)?.string ?? ""
                }
                return ["field": field.placeholderAttributedString?.string ?? "", "editor": editor]
            } ?? [:],
            "focusing": window.focusing.map(short) ?? "",
            "folded": window.folded,
            "peeking": window.peeking,
            "panel": web.map { panel -> [String: Any] in
                ["id": panel.id, "url": panel.tab.address?.absoluteString ?? "", "loading": panel.tab.loading,
                 "agent": panel.tab.built?.customUserAgent ?? ""]
            } ?? [:],
            "panelSites": WebPanels.shared.sites.map { ["name": $0.name, "url": $0.url, "mobile": $0.mobile] },
            "power": ["mode": Power.shared.mode.rawValue, "saving": Power.shared.saving,
                      "sleepAfter": Browser.sleepAfter, "lowPowerMac": ProcessInfo.processInfo.isLowPowerModeEnabled],
            "chains": Chains.shared.all.map { ["name": $0.name, "steps": $0.steps] },
            "bookmarkFolders": Bookmarks.folders(browser.bookmarks.roots).map { ["title": $0.node.title, "count": $0.node.children?.count ?? 0] },
        ]
    }
}
