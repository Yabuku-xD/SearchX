import AppKit
import SwiftUI
import WebKit
import Combine

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract — which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how — plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift, ExtensionSocket.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter kept here. A tab can be in the
// row with no web view at all — asleep, or put down — and is reported with
// none; `built` is read, never `web`, which would make one.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome Web Store id, or "local-…" for one loaded from a folder.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
    /// Kept in the row beside the menu rather than only in it. Optional, so
    /// a list written before there was pinning still reads.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload can
    /// bring the author's latest edits in.
    var source: String? = nil
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    static let shared = Extensions()

    /// Every page view built for a tab is handed the controller at birth —
    /// it can't be given one later.
    static func attach(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = shared.controller
    }

    let controller: WKWebExtensionController
    let commandShortcuts = ExtensionShortcuts()
    @Published private(set) var installed: [Installed] = [] {
        // Whether a password manager's page script is in, for the pages
        // built from now on (see PasskeyRelay.extensionKeeps).
        didSet {
            PasskeyRelay.extensionKeeps = installed.contains { $0.enabled && ExtensionShims.carriesPasskeys(Extensions.folder(for: $0.id)) }
        }
    }
    /// The loaded ones, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes — icon, badge, enabled.
    @Published private(set) var actionsChanged = 0
    @Published private(set) var busy: String?
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published private(set) var errors: [String: [String]] = [:]

    func noteError(_ text: String, for id: String) {
        var list = errors[id] ?? []
        list.append(text)
        errors[id] = Array(list.suffix(40))
    }

    weak var browser: Browser?
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    private var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    /// One ExtensionWindow per real window. A single shared object answered
    /// every tab window(for:) call and listed every tab row, which collapsed
    /// all of them into one Chrome window.
    private var windowAdapters: [WindowID: ExtensionWindow] = [:]

    /// The model behind an NSWindow, for a page that belongs to one window
    /// rather than to a tab: a popup hanging from a button, a docked panel.
    func resolve(_ host: NSWindow?) -> WindowModel? {
        guard let host, let browser else { return nil }
        return browser.model(owning: host)
    }

    /// The window a request names, by the id WebKit gives it.
    func model(for id: WindowID) -> ExtensionWindow {
        if let known = windowAdapters[id] { return known }
        let made = ExtensionWindow(owner: self, id: id)
        windowAdapters[id] = made
        return made
    }

    func windowAdapters(for windows: [WindowModel]) -> [ExtensionWindow] {
        windows.map { model(for: $0.id) }
    }
    /// Where each extension's button is on screen, for its popup to hang from.
    var anchors: [String: WeakView] = [:]

    static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome — Search uses the same ids. Servers allow
    /// their own extension in by that origin (Raindrop's refuses any other),
    /// and sites look for an extension at it. WebKit's own
    /// webkit-extension:// is what Search used before; addresses kept from
    /// then are read as the new ones.
    static let scheme = "chrome-extension"
    static let formerScheme = "webkit-extension"

    static func current(_ url: URL) -> URL {
        guard url.scheme == formerScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = scheme
        return parts.url ?? url
    }
    private static var list: URL { folder.appendingPathComponent("installed.json") }
    static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords.
        let configuration: WKWebExtensionController.Configuration = Store.testing && !Store.ownContainer
            ? .init(identifier: Store.probeStore(2))
            : .default()
        configuration.defaultWebsiteDataStore = Store.websites
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // Its own configuration starts with WebKit's default store; an
        // extension's pages keep what they store where the browser does —
        // and a test run's apart from the real one's.
        views.websiteDataStore = Store.websites
        // The same user agent as the web tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it — and extension
        // workers it then never starts again: every page that opened killed
        // the extensions. Extensions are told they run in Chrome by the shim
        // instead (navigator.userAgent in their pages and workers).
        views.applicationNameForUserAgent = Web.userAgentName
        // A test run sits behind other windows, where WebKit slows its views
        // to a crawl and messages between an extension's popup and its
        // worker stop arriving. Not what anyone is testing.
        if Store.testing, !Store.measuring { views.preferences.inactiveSchedulingPolicy = .none }
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: Extensions.list))) ?? []
        // Set in init, the list's own didSet doesn't run.
        PasskeyRelay.extensionKeeps = installed.contains { $0.enabled && ExtensionShims.carriesPasskeys(Extensions.folder(for: $0.id)) }
    }

    // MARK: - starting

    private var startupTask: Task<Void, Never>?
    private var startupFinished = false
    private var startupWaiters: [UUID: () -> Void] = [:]

    func start(for browser: Browser) {
        self.browser = browser
        browser.$key
            .sink { [weak self] _ in self?.scheduleReconciliation() }
            .store(in: &bag)
        browser.$windows
            .sink { [weak self] _ in self?.scheduleReconciliation() }
            .store(in: &bag)
        reconcile()
        // Once the window is up: loading one takes the main thread for tens
        // of milliseconds (uBlock Origin Lite, 45), and the first frame
        // waited behind it.
        Links.onceShown { [weak self] in self?.startEnabledIfNeeded() }
    }

    private func startEnabledIfNeeded() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            await forgetWorkersIfChanged()
            // Keep the existing spacing: starting all workers together makes
            // WebKit fail some without retrying them.
            for item in installed where item.enabled {
                await load(item)
                if contexts[item.id]?.webExtension.hasBackgroundContent == true {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            startupFinished = true
            let waiting = Array(startupWaiters.values)
            startupWaiters = [:]
            for ready in waiting { ready() }
            checkForUpdates()
        }
    }

    /// A hidden launch can restore a page before onceShown starts extensions.
    /// Its first navigation must give document_start scripts the same chance
    /// as a visible launch. A broken extension cannot hold the page forever.
    func afterStartup(_ ready: @escaping () -> Void) {
        guard installed.contains(where: \.enabled) else { ready(); return }
        startEnabledIfNeeded()
        if startupFinished { ready(); return }
        let id = UUID()
        startupWaiters[id] = ready
        // The measured large-package rewrite is 450 ms; workers are spaced
        // by 400 ms. Allow that per package plus five seconds of startup
        // grace. This is a fallback budget, not a normal navigation delay.
        let budget = 5 + 0.85 * Double(installed.filter(\.enabled).count)
        DispatchQueue.main.asyncAfter(deadline: .now() + budget) { [weak self] in
            guard let self, let waiting = startupWaiters.removeValue(forKey: id) else { return }
            browser?.announce("Extensions exceeded their \(Int(budget.rounded(.up))) s startup budget. Reload this page for their scripts.")
            waiting()
        }
    }

    // MARK: - workers WebKit remembers

    /// WebKit keeps each extension's service worker registered from one
    /// launch to the next, with the scripts it fetched then, and may start
    /// that copy rather than what is on disk now. A copy from another build
    /// of the shim or another version of the extension can leave the worker
    /// dead for good — reinstalling, reloading and restarting all bring the
    /// same stale copy back (Vimium's keys stopped working, for one). WebKit
    /// lists no records for extension origins, so there is no clearing one
    /// extension's alone; clearing them all stops the workers that run. So
    /// it is done at launch, before any extension loads, and only when what
    /// they would run has changed since. Websites' workers go with them and
    /// are registered again on the next visit.
    private static let workersKey = "extensions.workers"

    private var workers: String {
        ([ExtensionShims.version] + installed.map { "\($0.id) \($0.version)" }.sorted()).joined(separator: "\n")
    }

    private func forgetWorkersIfChanged() async {
        guard Store.settings.string(forKey: Extensions.workersKey) != workers else { return }
        await Store.websites.removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
        Store.settings.set(workers, forKey: Extensions.workersKey)
    }

    /// An extension put in again, reloaded or found with its worker dead:
    /// the version alone doesn't tell, so the next launch clears regardless.
    private func workersChanged() {
        Store.settings.removeObject(forKey: Extensions.workersKey)
    }

    // MARK: - the row, as WebKit sees it

    func adapter(for tab: Tab, in model: WindowModel) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    func window(of tab: Tab) -> WindowModel? {
        browser?.windows.first { $0.tabs.contains { $0.id == tab.id } }
    }

    private func seen(_ tab: Tab) -> Bool { !tab.shy || tab.carriesExtensions }

    var visibleTabs: [Tab] { browser?.windows.flatMap { tabs(in: $0) } ?? [] }
    func tabs(in window: WindowModel) -> [Tab] { window.tabs.filter(seen) }

    var activeAdapter: ExtensionTab? {
        guard let key = browser?.key, let tab = key.active, seen(tab) else { return nil }
        return adapter(for: tab, in: key)
    }

    private struct Seat: Equatable {
        let window: WindowID
        let index: Int
    }
    private var rows: [WindowID: Set<AnyCancellable>] = [:]
    private var seats: [Tab.ID: Seat] = [:]
    private var active: [WindowID: Tab.ID] = [:]
    private var focused: WindowID?
    private var reconciliationPending = false

    private func scheduleReconciliation() {
        guard !reconciliationPending else { return }
        reconciliationPending = true
        // A transfer removes and inserts synchronously. Observe the completed
        // operation, so a live tab keeps its extension ID across windows.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationPending = false
            self.reconcile()
        }
    }

    private func reconcile() {
        guard let browser else { return }
        let windows = browser.windows
        let live = Set(windows.map(\.id))
        let closed = Set(rows.keys).subtracting(live)
        for window in windows where rows[window.id] == nil {
            var subscriptions = Set<AnyCancellable>()
            window.$tabs.sink { [weak self] _ in self?.scheduleReconciliation() }
                .store(in: &subscriptions)
            window.$activeID.sink { [weak self] _ in self?.scheduleReconciliation() }
                .store(in: &subscriptions)
            rows[window.id] = subscriptions
            controller.didOpenWindow(model(for: window.id))
        }

        var current: [Tab.ID: Seat] = [:]
        for window in windows {
            for (index, tab) in tabs(in: window).enumerated() {
                current[tab.id] = Seat(window: window.id, index: index)
                let adapter = adapter(for: tab, in: window)
                if let previous = seats[tab.id] {
                    if previous != current[tab.id] {
                        controller.didMoveTab(adapter, from: previous.index, in: model(for: previous.window))
                    }
                } else {
                    controller.didOpenTab(adapter)
                    watch(tab)
                }
            }
        }
        for (id, previous) in seats where current[id] == nil {
            if let adapter = adapters[id] {
                controller.didCloseTab(adapter, windowIsClosing: closed.contains(previous.window))
            }
            adapters[id] = nil
            watching[id] = nil
        }
        seats = current
        for window in windows {
            let next = window.active.flatMap { seen($0) ? $0 : nil }
            if active[window.id] != next?.id, let next {
                let previous = active[window.id].flatMap { adapters[$0] }
                controller.didActivateTab(adapter(for: next, in: window), previousActiveTab: previous)
                actionsChanged += 1
            }
            active[window.id] = next?.id
        }
        for id in closed {
            controller.didCloseWindow(model(for: id))
            rows[id] = nil
            active[id] = nil
            windowAdapters[id] = nil
            ExtensionShims.panelFronts[id] = nil
            ExtensionShims.openPanels[id] = nil
        }
        if focused != browser.key?.id {
            focused = browser.key?.id
            controller.didFocusWindow(focused.map { model(for: $0) })
            actionsChanged += 1
        }
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        let changed: (WKWebExtension.TabChangedProperties) -> Void = { [weak self] properties in
            guard let self, let adapter = self.adapters[id] else { return }
            self.controller.didChangeTabProperties(properties, for: adapter)
        }
        watching[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
    }

    // MARK: - loading

    @discardableResult
    private func load(_ item: Installed) async -> Bool {
        // The shim this build of Search carries, in place of whatever the
        // build that installed it carried — away from the main thread: the
        // first launch after an update reads and rewrites every script and
        // page each extension ships (Grammarly: 450 ms).
        let folder = Extensions.folder(for: item.id)
        try? await Task.detached(priority: .userInitiated) { try ExtensionShims.prepare(folder) }.value
        do {
            let found = try await WKWebExtension(resourceBaseURL: Extensions.folder(for: item.id))
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // — localStorage, IndexedDB — is filed under its origin.
            if let stable = URL(string: "\(Extensions.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            for pattern in found.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            // Sites in compatibility mode are kept from every extension.
            for site in Protections.compatibleSites { Extensions.spare(site, true, in: context) }
            try controller.load(context)
            commandShortcuts.loaded(context, id: item.id)
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            loadsThisRun.insert(item.id)
            contexts[item.id] = context
            actionsChanged += 1
            return true
        } catch {
            NSLog("Extensions: couldn't load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    private func unload(_ id: String) {
        ExtensionOffscreen.close(for: id)
        guard let context = contexts[id] else { return }
        // Its panel first: a view built from a context that is gone is a
        // page whose worker will never answer.
        if browser?.key?.panel?.id == id { browser?.key?.closePanel(immediately: true) }
        try? controller.unload(context)
        // Its ports read as gone only once WebKit has had a turn.
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
        contexts[id] = nil
        actionsChanged += 1
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: Extensions.list, options: .atomic)
    }

    // MARK: - installing

    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only — there is no
    /// way to reach it from the real browser.
    func install(from text: String, confirm: Bool = true) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription)
            return
        }
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed")
            return
        }
        Task { await add(id, confirm: confirm) }
    }

    /// Every Web Store extension another browser has that this one doesn't,
    /// one after the other. Each still asks, as any install does.
    func installAll(from source: Chromium.Source) {
        let ids = Chromium.extensions(in: source).filter { id in !installed.contains { $0.id == id } }
        guard !ids.isEmpty else {
            browser?.announce("No extensions in \(source.name) that aren't here already")
            return
        }
        Task { for id in ids { await add(id, confirm: true) } }
    }

    private func add(_ id: String, confirm: Bool) async {
        busy = id
        defer { busy = nil }
        do {
            let crx = try await Crx.fetch(id)
            let zip = try Crx.verifiedZip(crx, id: id)
            let target = Extensions.folder(for: id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing)
        } catch {
            browser?.announce(error.localizedDescription)
        }
    }

    /// An unpacked extension from disk — a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        installFolder(at: source)
    }

    func installFolder(at source: URL, confirm: Bool = true) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json")
            return
        }
        let id = "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged, fresh: true)
        } catch {
            browser?.announce("Couldn't copy the extension")
            return
        }
        Task { try? await admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id), confirm: confirm || !Store.testing, source: source) }
    }

    /// Takes the extension up again — the way Chrome's reload button does
    /// in developer mode. One loaded from a folder is copied in afresh from
    /// that folder first, so what its author just saved is what runs.
    func reload(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), reloading.insert(id).inserted else { return }
        let target = Extensions.folder(for: id)
        let files = FileManager.default
        var staged: URL?
        if let path = installed[index].source {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                reloading.remove(id)
                browser?.announce("The folder \(installed[index].name) was loaded from is gone")
                return
            }
            let copy = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            do {
                try? files.removeItem(at: copy)
                try files.copyItem(at: source, to: copy)
                try ExtensionShims.prepare(copy, fresh: true)
            } catch {
                try? files.removeItem(at: copy)
                reloading.remove(id)
                browser?.announce("Couldn't copy \(installed[index].name) again")
                return
            }
            staged = copy
        }
        Task {
            defer { reloading.remove(id) }
            guard let item = installed.first(where: { $0.id == id }) else { return }
            let found = try? await WKWebExtension(resourceBaseURL: staged ?? target)
            if found == nil, let staged {
                try? files.removeItem(at: staged)
                browser?.announce("\(item.name) wasn't reloaded because its manifest couldn't be read")
                return
            }
            if let found {
                let wants = Set(Extensions.grants(found, in: staged ?? target))
                if !wants.isSubset(of: Set(item.permissions)) {
                    let name = [found.displayName ?? item.name, found.version].compactMap { $0 }.joined(separator: " ")
                    guard await ask(install: name, wants: Extensions.describe(found, in: staged ?? target), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
                        if let staged { try? files.removeItem(at: staged) }
                        browser?.announce("\(item.name) wasn't reloaded because it now asks for more than before")
                        return
                    }
                }
            }
            unload(id)
            errors[id] = nil
            workersChanged()
            if let staged {
                do {
                    try? files.removeItem(at: target)
                    try files.moveItem(at: staged, to: target)
                } catch {
                    try? files.removeItem(at: staged)
                    browser?.announce("Couldn't copy \(item.name) again")
                    return
                }
            }
            if let found, let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = Extensions.grants(found, in: target)
                save()
            }
            guard let item = installed.first(where: { $0.id == id }), item.enabled else { return }
            browser?.announce(await load(item) ? "\(item.name) reloaded" : "\(item.name) couldn't start. See Settings › Extensions")
        }
    }

    /// An extension whose worker won't start again: unloaded and loaded,
    /// as a relaunch would — at most once a minute, so one that can never
    /// start doesn't go round in circles.
    private var revived: [String: Date] = [:]
    private var reloading: Set<String> = []
    /// Recent failed native messages, per extension and host.
    private var failures: [String: [Date]] = [:]

    /// Loaded at least once since the browser started, and loaded again.
    private var loadsThisRun: Set<String> = []
    private(set) var loadedBefore: Set<String> = []

    func revive(_ id: String, because reason: String) {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        workersChanged()
        noteError("restarted the extension: \(reason)", for: id)
        // Its popup goes with it; it is opened again once the extension is back.
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        let anchor = anchors[id]?.view?.window != nil ? anchors[id]?.view : anchors[Extensions.menuAnchor]?.view
        unload(id)
        Task {
            guard await load(item), let popup, let context = contexts[id] else { return }
            ExtensionPopup.shared.show(popup, for: context, from: anchor)
        }
    }

    /// WebKit does not restart extension workers after relaunch. This also
    /// removes sites' registrations, so do it only when extensions are enabled.
    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    private func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.contexts[id] === context else { return }
                    self.revive(id, because: "its worker failed to start")
                }
            }
        }
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
        actionsChanged += 1
    }

    /// Reads what was unpacked, asks, and — on yes — moves it into place and
    /// loads it. On no, nothing is left behind.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true, source: URL? = nil) async throws {
        let files = FileManager.default
        let found: WKWebExtension
        do {
            found = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        let name = found.displayName ?? id
        let wants = Extensions.describe(found, in: staged)
        let accepted = confirm ? await ask(install: name, wants: wants, icon: found.icon(for: CGSize(width: 64, height: 64))) : true
        guard accepted else {
            try? files.removeItem(at: staged)
            return
        }
        try? files.removeItem(at: finalFolder)
        try files.moveItem(at: staged, to: finalFolder)
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: true, fromStore: fromStore,
            permissions: Extensions.grants(found, in: finalFolder),
            source: source?.path
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        workersChanged()
        if await load(item) {
            browser?.announce("\(name) is installed")
        } else {
            browser?.announce("\(name) is installed, but WebKit couldn't start it")
        }
    }

    func remove(_ id: String) {
        unload(id)
        errors[id] = nil
        Extensions.setSettings([:], for: id)
        Store.settings.removeObject(forKey: "extensions.granted.\(id)")
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        Store.settings.removeObject(forKey: "extensions.newtab.\(id)")
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
    }

    // MARK: - new tab pages

    /// The page an extension asks to show in new tabs, from the one added
    /// last — once you've said yes to it. Nil while nobody asks, or you
    /// said no.
    var newTabPage: URL? {
        guard let (id, url) = newTabCandidate else { return nil }
        return Store.settings.object(forKey: "extensions.newtab.\(id)") as? Bool == true ? url : nil
    }

    private var newTabCandidate: (String, URL)? {
        for item in installed.reversed() where item.enabled {
            if let url = contexts[item.id]?.overrideNewTabPageURL { return (item.id, url) }
        }
        return nil
    }

    /// Chrome asks the first time an extension's page takes the place of
    /// the new tab — an extension that did it quietly could be anything.
    /// So does Search, and then shows the page in the tab just opened.
    func offerNewTabPage(into tab: Tab) {
        guard let (id, url) = newTabCandidate, Store.settings.object(forKey: "extensions.newtab.\(id)") == nil,
              let name = installed.first(where: { $0.id == id })?.name else { return }
        Task {
            let yes = await ask("Show “\(name)” in new tabs?", detail: "It asked to replace the new tab page. You can change this later in Settings › Extensions.",
                                icon: contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Keep It", no: "Don't Allow")
            Store.settings.set(yes, forKey: "extensions.newtab.\(id)")
            if yes, tab.isBlank { tab.owner?.replaceBlank(tab, with: url) }
        }
    }

    /// What an extension set through chrome.privacy and chrome.proxy.
    static func settings(for id: String) -> [String: Any] {
        Store.settings.dictionary(forKey: "extensions.settings.\(id)") ?? [:]
    }

    static func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { Store.settings.removeObject(forKey: "extensions.settings.\(id)") }
        else { Store.settings.set(values, forKey: "extensions.settings.\(id)") }
    }

    /// The extension, on and running, that asked the browser not to offer to
    /// save passwords — a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        installed.first { $0.enabled && Extensions.settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false }?.name
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.key?.open(url, foreground: true)
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = "extensions.checked"
        let last = Store.settings.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        Store.settings.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { await update(item) }
        }
    }

    private func update(_ item: Installed) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              // The answer is the <updatecheck> element alone: status="ok"
              // with a version when there is a newer one, "noupdate" when
              // not. Read across the whole reply, the first version="" is
              // the XML declaration's "1.0", and status="ok" is on <app>
              // either way — which took every reply for an update.
              let check = xml.range(of: #"<updatecheck\b[^>]*>"#, options: .regularExpression)
                .map({ String(xml[$0]) }),
              check.contains("status=\"ok\""),
              let version = check.range(of: #"\bversion="([^"]+)""#, options: .regularExpression)
                .map({ String(check[$0].dropFirst(9).dropLast()) }),
              version != item.version
        else { return }
        do {
            let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            // Everything it could do, sites included, against what it was
            // allowed when it was added or last asked about.
            let wants = Set(Extensions.grants(found, in: staged))
            if !wants.isSubset(of: Set(item.permissions)) {
                guard await ask(install: "An update to \(item.name)", wants: Extensions.describe(found, in: staged), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
            }
            unload(item.id)
            let target = Extensions.folder(for: item.id)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            if let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = found.version ?? version
                installed[index].permissions = wants.sorted()
                save()
                if installed[index].enabled { await load(installed[index]) }
            }
        } catch {
            NSLog("Extensions: update of %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// The copy an extension's popup page is loaded from, beside it.
    ///
    /// WebKit takes any page at the path of an extension's popup for its own
    /// popup, and a popup that isn't in WebKit's own view (Search's is its
    /// own, see ExtensionPopup) is sent no events: no storage.onChanged, no
    /// tabs.onUpdated. Bitwarden's popup never heard that its server had
    /// changed to a self-hosted one, and signed in to bitwarden.com, where
    /// that account doesn't exist. Its "pop out" tab had the same trouble.
    /// So the page is loaded from a copy under another name, in the same
    /// folder: the same file, the same files around it, and none of WebKit's
    /// rules for popups. Anything else is loaded as it is.
    static let popupCopy = ".search-popup"

    static func unpopped(_ url: URL) -> URL {
        guard url.scheme == scheme, let id = url.host, let context = shared.contexts[id],
              !url.lastPathComponent.contains(popupCopy)
        else { return url }
        let named = [popupURL(for: context)] + (ExtensionShims.popups[id]?.values.map { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL } ?? [])
        guard named.contains(where: { $0?.path == url.path }) else { return url }
        let folder = Extensions.folder(for: id)
        guard let original = ExtensionShims.inside(url.path, of: folder),
              let data = try? Data(contentsOf: original)
        else { return url }
        let ext = original.pathExtension
        let name = original.deletingPathExtension().lastPathComponent + popupCopy + (ext.isEmpty ? "" : "." + ext)
        let copy = original.deletingLastPathComponent().appendingPathComponent(name)
        if (try? Data(contentsOf: copy)) != data {
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return url }
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = (url.path as NSString).deletingLastPathComponent.appending("/" + name).replacingOccurrences(of: "//", with: "/")
        return parts.url ?? url
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        // Relative to the extension, and keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    // MARK: - asking

    /// What an extension was allowed, as it is written down and compared on
    /// every update: WebKit's permissions, the sites it reaches, and the
    /// APIs Search answers for it (history, bookmarks…) — an update that
    /// adds any of them is asked about again.
    static func grants(_ found: WKWebExtension, in folder: URL) -> [String] {
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? [])
        let declared = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? []
        let ours = Set(Extensions.searchAnswered.map(\.0))
        var out = Set(found.requestedPermissions.map(\.rawValue).filter { !added.contains($0) })
        out.formUnion(found.allRequestedMatchPatterns.map { "site:" + $0.string })
        out.formUnion(declared.filter { ours.contains($0) && !added.contains($0) }.map { "search:" + $0 })
        return out.sorted()
    }

    /// Chrome's own APIs, which Search answers itself, and what each lets an
    /// extension do.
    static let searchAnswered: [(String, String)] = [
        ("userScripts", "Run scripts you add to it on websites"), ("history", "Read and change your history"),
        ("bookmarks", "Read and change your bookmarks"), ("downloads", "Manage your downloads"),
        ("privacy", "Change your privacy settings"), ("browsingData", "Clear your browsing data"),
        ("management", "See your other extensions"), ("notifications", "Show notifications"),
        ("sessions", "See your recently closed tabs"), ("topSites", "See your most visited sites"),
        ("readingList", "Read and change your reading list"),
    ]

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension, in folder: URL) -> [String] {
        var out: [String] = []
        // Leaving out what Search itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? [])
        let declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        // Chrome's own, which Search answers itself.
        for (name, sentence) in Extensions.searchAnswered where declared.contains(name) { out.append(sentence) }
        return out
    }

    private func ask(install name: String, wants: [String], icon: NSImage?) async -> Bool {
        await ask(
            "Add “\(name)” to SearchX?",
            detail: wants.isEmpty ? "It doesn't ask for anything special." : "It will be able to:\n• " + wants.joined(separator: "\n• "),
            icon: icon, yes: "Add Extension", no: "Cancel"
        )
    }

    /// An extension asking, through permissions.request, for one of the
    /// permissions Search answers itself.
    func ask(more names: String, context: WKWebExtensionContext) async -> Bool {
        await ask("asks for more access", detail: names, context: context)
    }

    private func ask(_ question: String, detail: String, context: WKWebExtensionContext) async -> Bool {
        await ask(
            "\(context.webExtension.displayName ?? "An extension") \(question)",
            detail: detail, icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            yes: "Allow", no: "Don't Allow"
        )
    }

    /// The last question asked, so the next waits for its answer.
    private var question: Task<Bool, Never>?
    /// For the bench, in a test run only: answer every question this way
    /// instead of asking. Nil asks.
    var answerForTests: Bool?
    /// What was asked, for the bench.
    private(set) var asked: [String] = []

    /// One question at a time, as a sheet on the browser's window. An alert
    /// run modally would stop the whole browser — pages, downloads, every
    /// other extension — for as long as it waits, and an extension can ask
    /// when nobody is looking.
    private func ask(_ title: String, detail: String, icon: NSImage?, yes: String, no: String) async -> Bool {
        let before = question
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await before?.value
            self?.asked.append(title)
            if Store.testing, let answer = self?.answerForTests { return answer }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: yes)
            alert.addButton(withTitle: no)
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        question = task
        return await task.value
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
    }

    /// The list behind the puzzle button.
    @Published var menuOpen = false
    /// Where a popup hangs when its extension isn't pinned: the puzzle button.
    static let menuAnchor = "__menu"

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id,
                name: item.name,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText,
                enabled: action.isEnabled,
                pinned: item.pinned ?? false
            )
        }
    }

    func press(_ id: String) {
        guard let context = contexts[id], !ExtensionPopup.shared.closes(id) else { return }
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel:
        // up if it isn't, away if it is, as Chrome's. Remembered across
        // launches, so this is known before the worker says it again.
        ExtensionShims.ensurePanels()
        if ExtensionShims.panelOnClick.contains(id), context.action(for: activeAdapter)?.presentsPopup != true {
            _ = try? browser?.key?.togglePanel(for: context)
            return
        }
        // A popup is opened here, straight away. Left to WebKit, it builds
        // a popup of its own first, and closing that one in favour of
        // Search's lost the new popup's first messages to its worker.
        if context.action(for: activeAdapter)?.presentsPopup == true, let url = popupURL(for: context) {
            let own = anchors[id]?.view
            ExtensionPopup.shared.show(url, for: context, from: own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view)
            return
        }
        context.performAction(for: activeAdapter)
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        let set = ExtensionShims.popups[context.uniqueIdentifier] ?? [:]
        let path = browser?.key?.active.flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Extensions.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// A keystroke an extension registered for.
    func take(_ event: NSEvent) -> Bool {
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }

    /// Right-click items an extension added, for the page's menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard seen(tab) else { return [] }
        guard let adapter = window(of: tab).map({ adapter(for: tab, in: $0) }) else { return [] }
        return contexts.values.flatMap { $0.menuItems(for: adapter) }
    }
}

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windowAdapters(for: browser?.windows ?? [])
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let key = browser?.key else { return nil }
        return model(for: key.id)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        try Extensions.mayOpen(url)
        let model: WindowModel
        if let requested = configuration.window as? ExtensionWindow {
            guard let existing = requested.model else { return nil }
            model = existing
        } else {
            model = browser.key ?? browser.open()
        }
        let tab = model.open(url, foreground: configuration.shouldBeActive, atEnd: true)
        if configuration.index != NSNotFound { model.move(tab, to: configuration.index) }
        if configuration.shouldBePinned { model.pin(tab) }
        return adapter(for: tab, in: model)
    }

    /// A window of its own, as Chrome makes one: the pages go where they were
    /// asked to go, and the model that was made is answered.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser else { return nil }
        // A private window isn't something an extension can have here: its
        // pages would be the extension's to watch while you believed them
        // private. Refused, as Chrome refuses when incognito isn't allowed.
        if configuration.shouldBePrivate {
            throw NSError(domain: "SearchX", code: 2, userInfo: [NSLocalizedDescriptionKey: "Private windows can't be opened by extensions."])
        }
        for url in configuration.tabURLs { try Extensions.mayOpen(url) }
        let front = browser.key
        // A window of its own, as Chrome would: the model that was made is the
        // one the caller is told about, and the pages land in it.
        let made = browser.open()
        for (index, url) in configuration.tabURLs.enumerated() {
            made.open(url, foreground: index == 0, atEnd: true)
        }
        // The empty tab a new window starts with goes once there are pages.
        if !configuration.tabURLs.isEmpty {
            for blank in made.tabs where blank.isBlank && !blank.bench { made.close(blank) }
        }
        // The frame asked for, when it is one: parts left unset come as
        // numbers that aren't (NaN), and AppKit traps on a frame made of them.
        let asked = configuration.frame
        if !asked.isNull, [asked.minX, asked.minY, asked.width, asked.height].allSatisfy(\.isFinite),
           asked.width >= 200, asked.height >= 150 {
            DispatchQueue.main.async { browser.host(of: made)?.setFrame(asked, display: true) }
        }
        if !configuration.shouldBeFocused, let front, front !== made {
            DispatchQueue.main.async { browser.host(of: front)?.makeKeyAndOrderFront(nil) }
        }
        return model(for: made.id)
    }

    /// Where an extension may send a tab. Not to javascript:, which would run
    /// its code in whatever page the tab shows — an extension with no access
    /// to that site at all — nor to a file on this Mac. Chrome refuses both.
    static func mayOpen(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme != "javascript", scheme != "file" else {
            throw NSError(domain: "SearchX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot navigate to a \(scheme): URL."])
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        browser?.key?.open(url, foreground: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return await ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        // WebKit asks this the way Safari does: whenever an extension reaches
        // for a page it has no host permission for — listing tabs, running a
        // script in one — often with nobody having touched anything. Chrome
        // never asks there: the extension has the sites its manifest named,
        // the page it was clicked on (activeTab), and the ones it asked for
        // through permissions.request. So neither does Search.
        asked.append("(refused) \(extensionContext.webExtension.displayName ?? "?") → \(Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", "))")
        return ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : matchPatterns.map(\.string).sorted().joined(separator: ", ")
        return await ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) ? (matchPatterns, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        guard let url else { return }
        let own = anchors[context.uniqueIdentifier]?.view
        let anchor = own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view
        ExtensionPopup.shared.show(url, for: context, from: anchor)
    }

    /// `runtime.sendNativeMessage`. To "search" — the APIs WebKit doesn't
    /// have, answered by this app. To anything else — a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        let id = extensionContext.uniqueIdentifier, host = applicationIdentifier!
        do {
            return try await ExtensionNative.send(message, to: host, from: id)
        } catch {
            // An extension asking an app that isn't there, over and over —
            // a retry loop — is answered slowly once it has asked a dozen
            // times in a second, so it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        // The port a worker's shim opens only to find what ports share; it
        // lets go at once.
        if port.applicationIdentifier == ExtensionShims.application { return }
        try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
    }
}

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    private var browser: Browser? { owner.browser }
    /// The window to act through: this tab's own while it has one.
    private var mine: WindowModel? { tab.flatMap { owner.window(of: $0) } }

    /// The window this tab row is in, as its own ExtensionWindow: a tab in a
    /// window behind answers for that window, not whichever is in front.
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let mine else { return nil }
        return owner.model(for: mine.id)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let mine else { return NSNotFound }
        return owner.tabs(in: mine).firstIndex { $0.id == tab.id } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.built }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let mine else { return false }
        return tab.id == mine.activeID
    }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.built?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.built?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let mine else { return }
        if pinned, tab.pin == nil { mine.pin(tab) }
        if !pinned, tab.pin != nil { mine.unpin(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        try Extensions.mayOpen(url)
        // A website's tab sent to one of an extension's own pages — 1Password
        // does, once a sign-in in its tab has added the account. The page
        // can only be served to a view built from that extension's
        // configuration, so the tab is swapped for one that is, as an
        // extension's page sent to a website is (see Browser.replace).
        let url = Extensions.current(url)
        let here = tab.built?.url ?? tab.address
        if url.scheme == Extensions.scheme, here?.scheme != Extensions.scheme || here?.host != url.host, let mine {
            mine.replace(tab, going: url)
            return
        }
        tab.go(to: url)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload(fromOrigin: fromOrigin) }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab, let mine else { return }
        mine.select(tab)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        browser.closeTab(tab)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.built else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    private let id: WindowID
    private let privateWindow: Bool
    var model: WindowModel? { owner.browser?.windows.first { $0.id == id } }

    init(owner: Extensions, id: WindowID) {
        self.owner = owner
        self.id = id
        self.privateWindow = owner.browser?.windows.first { $0.id == id }?.isPrivate ?? false
    }

    private var nsWindow: NSWindow? {
        model.flatMap { owner.browser?.host(of: $0) }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let model else { return [] }
        return owner.tabs(in: model).map { owner.adapter(for: $0, in: model) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let model, let tab = model.active, !tab.shy || tab.carriesExtensions else { return nil }
        return owner.adapter(for: tab, in: model)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { privateWindow }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        guard let model, let host = owner.browser?.host(of: model) else { return }
        NSApp.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
    }

}

// MARK: - the buttons in the row

/// The extensions, behind one puzzle button — a list to press them from,
/// pin them out of, reload or remove them. The pinned ones also sit in the
/// row beside it, the way Chrome does it. Nothing at all below macOS 15.4
/// or with nothing installed.
struct ExtensionSlot: View {
    /// The side the list opens toward: down from the top row, out to the
    /// right from the sidebar.
    var edge: Edge = .bottom
    var showMenu = true

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionButtons(extensions: .shared, edge: edge, showMenu: showMenu)
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButtons: View {
    @ObservedObject var extensions: Extensions
    let edge: Edge
    let showMenu: Bool

    var body: some View {
        if !extensions.installed.isEmpty {
            HStack(spacing: 2) {
                ForEach(extensions.buttons.filter(\.pinned)) { button in
                    ActionButton(button: button) { extensions.press(button.id) }
                        .background(Anchor(id: button.id))
                        .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
                }
                if showMenu {
                    Door(icon: "puzzlepiece.extension", on: extensions.menuOpen, help: "Extensions") {
                        extensions.menuOpen.toggle()
                    }
                    .background(Anchor(id: Extensions.menuAnchor))
                    .popover(isPresented: $extensions.menuOpen, arrowEdge: edge) {
                        ExtensionMenu(extensions: extensions)
                    }
                }
            }
        }
    }

    private struct ActionButton: View {
        let button: Extensions.Button
        let press: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: press) {
                ExtensionIcon(button: button, size: 15)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hovering ? Palette.hover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(button.label)
        }
    }

    /// A real view under the button, so the popup has something to hang from.
    private struct Anchor: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            Extensions.shared.anchors[id] = WeakView(view)
            return view
        }
        // The outgoing layout can still update during a transition. It must
        // not replace the new layout's anchor with a view about to disappear.
        func updateNSView(_ view: NSView, context: Context) {}
    }
}

/// An extension's icon with its badge in the corner.
@available(macOS 15.4, *)
private struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    let plated = IconTone.needsPlate(icon, dark: scheme == .dark)
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: plated ? size - 3 : size, height: plated ? size - 3 : size)
                        // An icon drawn in the chrome's own colour — a black
                        // logo on the dark column — vanished until hovered.
                        // It gets a plate of the opposite tone, as Chrome
                        // gives a dark site icon in dark mode.
                        .frame(width: size, height: size)
                        .background {
                            if plated {
                                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                                    .fill(scheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.78))
                            }
                        }
                } else {
                    // Its initial, rather than a puzzle piece that would
                    // pass for the button the list opens from.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.wash))
                }
            }
            .frame(width: size + 4, height: size + 4)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

/// What a right-click on an extension offers, in the row and in the list.
@available(macOS 15.4, *)
private struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        let pinned = extensions.installed.first { $0.id == id }?.pinned ?? false
        SwiftUI.Button(pinned ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(id, !pinned) }
        if extensions.contexts[id]?.optionsPageURL != nil {
            SwiftUI.Button("Options…") { extensions.openOptions(id) }
        }
        SwiftUI.Button("Reload") { extensions.reload(id) }
        Divider()
        SwiftUI.Button("Remove “\(name)”…") { ExtensionActions.confirmRemove(id, name: name, extensions) }
    }

    static func confirmRemove(_ id: String, name: String, _ extensions: Extensions) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { extensions.remove(id) }
    }
}

/// The list, drawn off screen — for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@available(macOS 15.4, *)
@MainActor
func extensionMenuPicture() -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: ExtensionMenu(extensions: .shared))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

/// The list behind the puzzle button: every running extension, a pin for
/// each, and the way to Settings.
@available(macOS 15.4, *)
private struct ExtensionMenu: View {
    @ObservedObject var extensions: Extensions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let buttons = extensions.buttons
            if buttons.isEmpty {
                Text("None of your extensions is on")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(buttons) { button in
                            Row(button: button, extensions: extensions)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("storefront", "Chrome Web Store…") {
                    extensions.menuOpen = false
                    extensions.browser?.key?.open(Browser.webStore, foreground: true)
                }
                Foot("folder", "Load Unpacked…") {
                    extensions.menuOpen = false
                    DispatchQueue.main.async { extensions.installFolder() }
                }
                Foot("gearshape", "Manage Extensions…") {
                    extensions.menuOpen = false
                    Store.settings.set("extensions", forKey: "settings.page")
                    extensions.browser?.tuning = true
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Palette.ground)
    }

    private struct Row: View {
        let button: Extensions.Button
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ExtensionIcon(button: button, size: 16)
                Text(button.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, extensions.installed.first(where: { $0.id == button.id })?.source != nil {
                    Tool(symbol: "arrow.clockwise", help: "Reload from its folder") { extensions.reload(button.id) }
                }
                if hovering || button.pinned {
                    Tool(symbol: button.pinned ? "pin.fill" : "pin", help: button.pinned ? "Unpin" : "Pin to toolbar", on: button.pinned) {
                        extensions.setPinned(button.id, !button.pinned)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                // The list goes first; the popup, if there is one, then
                // hangs from the puzzle button it came out of.
                extensions.menuOpen = false
                let id = button.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.press(id) }
            }
            .onHover { hovering = $0 }
            .help(button.label)
            .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
    }

    /// A small icon button at the end of a row.
    private struct Tool: View {
        let symbol: String
        let help: String
        var on = false
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: act) {
                Image(systemName: Symbols.current(symbol))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: Symbols.current(symbol)).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// How an icon sits on the chrome: mostly the chrome's own tone, and so lost
/// on it. Measured once per image at 16 points, over its opaque pixels only.
enum IconTone {
    private static let cache = NSCache<NSImage, NSNumber>()

    static func needsPlate(_ icon: NSImage, dark: Bool) -> Bool {
        let luminance = self.luminance(icon)
        guard luminance >= 0 else { return false }
        // Dark chrome loses icons below about a quarter lightness; light
        // chrome loses nearly white ones.
        return dark ? luminance < 0.24 : luminance > 0.9
    }

    /// Mean relative luminance of the opaque pixels, or -1 when too few are.
    private static func luminance(_ icon: NSImage) -> Double {
        if let known = cache.object(forKey: icon) { return known.doubleValue }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var value = -1.0
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var sum = 0.0, count = 0.0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(pixels[index + 3]) / 255
                guard alpha > 0.5 else { continue }
                let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                count += 1
            }
            if count >= Double(side * side) / 10 { value = sum / count }
        }
        cache.setObject(NSNumber(value: value), forKey: icon)
        return value
    }
}

@available(macOS 15.4, *)
extension Extensions {
    /// A site in compatibility mode (see Protections): kept from every
    /// extension, or given back to what each was granted when it loaded.
    func spare(_ site: String, _ on: Bool) {
        for context in contexts.values { Extensions.spare(site, on, in: context) }
    }

    static func spare(_ site: String, _ on: Bool, in context: WKWebExtensionContext) {
        for address in ["https://\(site)/", "http://\(site)/", "https://www.\(site)/", "http://www.\(site)/"] {
            guard let url = URL(string: address) else { continue }
            context.setPermissionStatus(on ? .deniedExplicitly : .unknown, for: url)
        }
    }
}
