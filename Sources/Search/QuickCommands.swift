import AppKit

// Quick Commands, Vivaldi's, on ⌘K: the tabs you have open, and — once you
// type — your bookmarks, where you have been, every command in the menus
// with the key it is on, the pages of Settings, your command chains and
// your web panels, in one list. Nothing is fetched or indexed for it: each
// source is already in memory, and is only read when a letter is typed.

/// Something the app does, as a row in the ⌘K list.
struct QuickAction: Equatable {
    enum Target: Equatable {
        case command(String)
        case settings(String)
        case chain(UUID)
        case panel(UUID)
        case savedGroup(UUID)
        case containerTab(UUID)
    }

    let target: Target
    /// As the menus show it, in the Mac's language.
    let title: String
    /// The key it is on, or where it lives.
    let detail: String
    let symbol: String
    /// The title in English, so either finds it.
    var alias = ""
}

@MainActor
enum QuickCommands {
    /// How many of each the list shows for a word typed, so it stays short
    /// enough to read at a glance (Raycast's rule: the first rows are the
    /// answer, or the word needs another letter).
    static let most = 4

    /// Actions matching \`needle\`, best first: the start of the title, then
    /// the start of a word in it, then anywhere in it.
    static func actions(matching needle: String, in window: WindowModel) -> [QuickAction] {
        let words = needle.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored = everything(in: window).compactMap { action -> (Int, QuickAction)? in
            let best = [score(action.title, words), score(action.alias, words)].compactMap { $0 }.min()
            return best.map { ($0, action) }
        }
        return scored.sorted { $0.0 < $1.0 }.prefix(most).map(\.1)
    }

    /// Nil when some word isn't in the title at all; lower is better.
    static func score(_ title: String, _ words: [String]) -> Int? {
        let hay = title.lowercased()
        let starts = hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for word in words {
            if hay.hasPrefix(word) { continue }
            if starts.contains(where: { $0.hasPrefix(word) }) { total += 1; continue }
            if hay.contains(word) { total += 3; continue }
            return nil
        }
        return total
    }

    private static func everything(in window: WindowModel) -> [QuickAction] {
        let shortcuts = window.profile.shortcuts
        var all = ShortcutCommand.all.filter { $0.id != "tabs.search" }.map { command in
            QuickAction(target: .command(command.id), title: command.title.saidNow.replacingOccurrences(of: "…", with: ""),
                        detail: shortcuts.key(for: command.id)?.display ?? command.section.rawValue.saidNow, symbol: "command",
                        alias: command.title.replacingOccurrences(of: "…", with: ""))
        }
        all += SettingsPanel.Page.allCases.map { page in
            QuickAction(target: .settings(page.rawValue), title: "\(page.title.saidNow) · \("Settings".saidNow)", detail: "Settings".saidNow,
                        symbol: page.icon, alias: "\(page.title) Settings")
        }
        all += Chains.shared.all.filter { !$0.steps.isEmpty }.map { chain in
            QuickAction(target: .chain(chain.id), title: chain.name, detail: chain.key?.display ?? "Chain", symbol: "link")
        }
        all += WebPanels.shared.sites.map { site in
            QuickAction(target: .panel(site.id), title: "\(site.name) Panel", detail: "Web panel", symbol: "sidebar.right")
        }
        all += SavedGroups.shared.all.map { group in
            QuickAction(target: .savedGroup(group.id), title: group.name,
                        detail: "Saved group".saidNow + " · \(group.pages.count)", symbol: "square.stack",
                        alias: "\(group.name) saved group")
        }
        if !window.isPrivate {
            all += Containers.shared.all.map { container in
                QuickAction(target: .containerTab(container.id), title: "\(container.name) · \("New Tab".saidNow)",
                            detail: "Container".saidNow, symbol: "square.on.square.dashed",
                            alias: "New \(container.name) Tab container")
            }
        }
        return all
    }

    static func run(_ action: QuickAction, in window: WindowModel) {
        let browser = window.profile
        switch action.target {
        case .command(let id):
            if let command = ShortcutCommand.named(id) { browser.run(command, in: window) }
        case .settings(let page):
            browser.tuningPage = page
            browser.tuning = true
        case .chain(let id):
            if let chain = Chains.shared.chain(id) { Chains.shared.run(chain, browser: browser, window: window) }
        case .panel(let id):
            if let site = WebPanels.shared.site(id) { window.togglePanel(site) }
        case .savedGroup(let id):
            window.reopenSavedGroup(id)
        case .containerTab(let id):
            window.newTab(inContainer: id)
        }
    }
}

extension WindowModel {
    /// ⌘K's list. Nothing typed: the tabs you have open, most recent first.
    /// A word typed: those tabs, and the commands, bookmarks and places that
    /// match it — a command first when its name starts with the word, since
    /// "settings" typed here means the panel, not a tab about settings.
    func quickOffers(for typed: String) -> [Suggestion] {
        let tabs = openQuickPages(matching: typed)
        let needle = typed.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return tabs }
        let actions = QuickCommands.actions(matching: needle, in: self)
        var seen = Set(tabs.map(\.url.absoluteString))
        let marks = profile.bookmarks.matches(needle)
            .compactMap { found -> Suggestion? in
                guard let raw = found.node.url, let url = URL(string: raw), seen.insert(raw).inserted else { return nil }
                return Suggestion(key: found.node.title, title: Address.pretty(url), url: url, kind: .bookmark)
            }
            .prefix(3)
        let been = profile.history.suggestions(for: needle, limit: 3)
            .filter { seen.insert($0.url.absoluteString).inserted }
            .prefix(2)
        let words = needle.lowercased().split(separator: " ").map(String.init)
        let leads = actions.first.map { QuickCommands.score($0.title, words) == 0 } ?? false
        let offered = actions.map(Suggestion.action)
        return leads ? offered + tabs + marks + been : tabs + offered + marks + been
    }
}
