import WebKit

// The ad blocker. No settings, no counter, no shield icon going green — it is
// compiled once at launch and then it is simply true that the page is lighter.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    private(set) var list: WKContentRuleList?
    private var waiting: [WKUserContentController] = []

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// The lists on: the built-in one, uBO's, their scriptlets and their
    /// pop-up hosts. Off, only the checks on what a page does are left
    /// (Intent), which know no names.
    var listsOn = true

    /// Whether pages on this site are held to the checks on behaviour.
    func judges(_ host: String?) -> Bool {
        enabled && !isPaused(on: host)
    }

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return paused.contains(host) || (host.hasPrefix("www.") && paused.contains(String(host.dropFirst(4))))
            || Protections.compatible(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Before each page: the lists go on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        put(enabled && !isPaused(on: host), on: controller)
    }

    /// The built-in list and uBO's lists (see Filters), whichever are ready.
    private var everything: [WKContentRuleList] {
        guard listsOn else { return [] }
        // Yours after uBO's, your rules last (see OwnFilters).
        return (list.map { [$0] } ?? []) + Filters.shared.lists + OwnFilters.shared.lists
    }

    /// What each controller was last given: the lists in place when it was
    /// on, nothing when off. Taking every list off and putting it back on
    /// each page load is work for WebKit's page process all the same, so it
    /// happens only when this changes.
    private let given = NSMapTable<WKUserContentController, NSArray>.weakToStrongObjects()

    private func put(_ on: Bool, on controller: WKUserContentController) {
        let lists = on ? everything : []
        if let before = given.object(forKey: controller) as? [WKContentRuleList],
           before.count == lists.count, zip(before, lists).allSatisfy({ $0 === $1 }) { return }
        controller.removeAllContentRuleLists()
        lists.forEach(controller.add)
        given.setObject(lists as NSArray, forKey: controller)
    }

    /// The scriptlets uBO's lists ask for in a document at `host` on a page
    /// at `top`: none for almost every site, and none where the blocker is
    /// off.
    func scriptlets(for host: String, top: String?) -> [[String]] {
        guard enabled, listsOn, !isPaused(on: top ?? host) else { return [] }
        let other = top == host ? nil : top
        return Scriptlets.calls(for: host, top: other, in: Filters.shared.table)
            + Scriptlets.calls(for: host, top: other, in: OwnFilters.shared.table)
    }

    /// The lists' extras and yours, as one table; made again when either changes.
    private var mergedExtras: FilterCompiler.Extras?
    var extras: FilterCompiler.Extras {
        if let mergedExtras { return mergedExtras }
        let made = Filters.shared.extras.merged(with: OwnFilters.shared.extras)
        mergedExtras = made
        return made
    }
    func forgetExtras() {
        mergedExtras = nil
        sharedCache = nil
    }

    /// The redirect rules for every site with a stand-in SearchX has.
    private var sharedCache: [[String: String]]?
    var sharedRedirects: [[String: String]] {
        if let sharedCache { return sharedCache }
        let made = RuleMatch.forPage(extras.redirect, host: "") {
            $0.ifDomain.isEmpty && ($0.exception || PageFilters.Stubs.all[$0.value] != nil)
        }
        sharedCache = made
        return made
    }

    /// A document or frame refused for a header its response carries
    /// (uBO's $header) — never on a protected page or in a protected frame.
    func refuses(_ response: HTTPURLResponse, top: URL?) -> Bool {
        guard enabled, listsOn, let url = response.url, !Protected.page(url), !(top.map(Protected.page) ?? false),
              !isPaused(on: top?.host()?.lowercased() ?? url.host()?.lowercased()) else { return false }
        let rules = extras.header
        guard !rules.isEmpty else { return false }
        return RuleMatch.refuses(response, url: url, context: top?.host()?.lowercased(), in: rules)
    }

    /// What SearchX's own scripts do in a document at \`url\` on a page at
    /// \`top\` (see PageFilters): nothing where the blocker is off, and
    /// nothing on a sign-in, passkey, captcha or payment page or in such a
    /// frame (see Protected).
    func work(for url: URL, top: URL?) -> PageFilters.Work {
        guard enabled, let host = url.host()?.lowercased(), !host.isEmpty,
              !isPaused(on: top?.host()?.lowercased() ?? host),
              !Protected.page(url), !(top.map(Protected.page) ?? false) else { return PageFilters.Work() }
        var work = PageFilters.Work()
        work.shared = listsOn
        if listsOn {
            let extras = self.extras
            work.procedural = PageFilters.procedural(for: host, in: extras)
            // Only the stand-ins SearchX has; the rest are plain blocks. The
            // ones for every site go to a page once (sharedRedirects).
            work.redirect = RuleMatch.forPage(extras.redirect, host: host) {
                !$0.ifDomain.isEmpty && ($0.exception || PageFilters.Stubs.all[$0.value] != nil)
            }
            work.replace = RuleMatch.forPage(extras.replace, host: host, ownSite: true)
            if top == nil || top == url { work.csp = RuleMatch.policies(for: url, in: extras.csp) }
        }
        // Your rule against a site's inline scripts: only scripts from
        // somewhere, none written into the page.
        if top == nil || top == url, PageFilters.siteNames(host).contains(where: OwnFilters.shared.inlineBlocked.contains) {
            work.csp.append("script-src * blob: data: 'unsafe-eval'")
        }
        return work
    }

    func compile() {
        guard list == nil else { return }
        trouble = nil
        guard let json = ShieldRules.json() else {
            trouble = "Couldn't build the block list"
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            trouble = "WebKit has nowhere to compile it"
            return
        }
        // Named for the rules themselves, so WebKit's compiled copy from an
        // earlier launch is taken as it is, and compiling happens only when
        // the rules have changed — once, not on every launch.
        let identifier = Shield.prefix + Shield.digest(json)
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] found, _ in
            MainActor.assumeIsolated {
                if let found {
                    self?.ready(found)
                    return
                }
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] compiled, error in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let compiled else {
                            self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                            return
                        }
                        self.ready(compiled)
                        Shield.forgetOthers(than: identifier, in: store)
                    }
                }
            }
        }
    }

    private static let prefix = "office-shield"

    private func ready(_ compiled: WKContentRuleList) {
        list = compiled
        // Tabs that opened while this was still compiling get it now.
        if enabled { waiting.forEach { put(true, on: $0) } }
        waiting = []
    }

    /// The copies compiled from older rules, which WebKit would otherwise
    /// keep on disk for good.
    private static func forgetOthers(than identifier: String, in store: WKContentRuleListStore) {
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for old in identifiers ?? [] where old.hasPrefix(prefix) && old != identifier {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    /// FNV-1a over the rules: stable from one launch to the next, which
    /// Swift's own hashing is not.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "-" + String(hash, radix: 36)
    }

    /// A page's address without the parameters that only say where a click
    /// came from — uBO's removeparam, the lists' and yours, and the built-in
    /// set. Nil when there is nothing to take off, the blocker is off there,
    /// or it is a sign-in, passkey or payment address, whose parameters
    /// carry what the sign-in or payment needs (see Protected).
    func cleaned(_ url: URL) -> URL? {
        guard enabled, !isPaused(on: url.host()?.lowercased()),
              !Protected.page(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, !items.isEmpty
        else { return nil }
        let listed = listsOn ? RuleMatch.removals(for: url, in: extras.removeparam) : .none
        if case .all = listed {
            parts.queryItems = nil
            return parts.url
        }
        let kept = items.filter { item in
            if ShieldRules.isTracking(parameter: item.name) { return false }
            if case .some(let removals) = listed { return !removals.contains { $0.removes(item) } }
            return true
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    /// A window a page asks to open onto a pop-up or pop-under network.
    func refusesPopup(to url: URL?, from opener: String?) -> Bool {
        guard enabled, listsOn, !isPaused(on: opener), let host = url?.host()?.lowercased() else { return false }
        return ShieldRules.host(host, isIn: ShieldRules.popups) || Shield.listed(host, in: Filters.shared.popupHosts)
    }

    /// The host is one of these, or under one.
    static func listed(_ host: String, in hosts: Set<String>) -> Bool {
        guard !hosts.isEmpty else { return false }
        var name = Substring(host)
        while true {
            if hosts.contains(String(name)) { return true }
            guard let dot = name.firstIndex(of: ".") else { return false }
            name = name[name.index(after: dot)...]
        }
    }

    /// Every tab asks for it; whoever asks before it is ready is remembered.
    func protect(_ controller: WKUserContentController) {
        if list == nil { waiting.append(controller) }
        put(enabled, on: controller)
    }

    /// Switched on or off, or new lists in, for every page already open.
    /// A site it is paused on stays paused.
    func apply(to controllers: [(WKUserContentController, String?)]) {
        for (controller, host) in controllers { put(enabled && !isPaused(on: host), on: controller) }
    }
}
