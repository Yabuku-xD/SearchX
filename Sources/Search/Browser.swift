import SwiftUI
import WebKit
import Combine

// The profile: everything the windows share — preferences, history, bookmarks,
// passwords, downloads, extensions, spaces — and the registry of windows
// themselves. What is on screen in one window lives on WindowModel.

@MainActor
final class Browser: NSObject, ObservableObject {
    /// Every open window. Starts with one; ⌘N and tear-off add more.
    @Published private(set) var windows: [WindowModel] = []
    /// The model the SwiftUI scene window draws. Extra windows are
    /// BrowserHosts. Commands use `key`, which moves; this does not.
    private(set) var sceneModel: WindowModel?
    /// The window that receives ⌘T and links from other apps. Set on
    /// didBecomeKey; replaces Browser.front and Links.window as the answer
    /// to "which window".
    @Published private(set) var key: WindowModel?

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Preferences()
    /// The settings panel.
    @Published var tuning = false
    /// A Settings page asked for by name (see QuickCommands), taken by the
    /// panel whether it is opening or already open.
    @Published var tuningPage: String?
    /// Your own keys for the menu commands (see Shortcuts.swift).
    let shortcuts = ShortcutStore()
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false
    /// The card after an update (see WhatsNew.swift).
    @Published var newsShowing = false

    // MARK: - bookmarks

    let bookmarks = Bookmarks()
    lazy var speedDial = SpeedDial(bookmarks: bookmarks)
    /// The full list, for taking things out.
    @Published var bookmarking = false
    /// The dropdown off the button.
    @Published var bookmarksOpen = false

    @Published var bookmarkCard: Bookmark.ID?
    @Published var editingBookmark: Bookmark.ID?
    var pageKept: Bool { key?.active?.address.map(bookmarks.contains) ?? false }

    func bookmarkCurrent() {
        guard let model = key, let tab = model.active, tab.showsPage, let url = tab.address else { return }
        let kept = bookmarks.bookmark(for: url)
        guard let id = (kept ?? bookmarks.add(url, title: tab.title))?.id else { return }
        guard !model.folded else {
            announce(kept == nil ? "Bookmarked" : "Already a bookmark")
            return
        }
        bookmarkCard = id
        bookmarksOpen = true
    }

    func toggleBookmarks() {
        if !bookmarksOpen { bookmarkCard = nil }
        bookmarksOpen.toggle()
    }

    /// Another browser's bookmarks, folders and all — and, behind them, the
    /// icons it had for those sites, so the menu wears them from the start
    /// instead of a letter each. Returns how many pages came over.
    @discardableResult
    func takeBookmarks(from source: Chromium.Source) -> Int {
        let found = Chromium.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }

    @discardableResult
    func takeBookmarks(from source: Mozilla.Source) -> Int {
        let found = Mozilla.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = Mozilla.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }

    @discardableResult
    func takeBookmarks(from source: ImportSource) -> Int {
        switch source {
        case .chromium(let c): return takeBookmarks(from: c)
        case .mozilla(let m): return takeBookmarks(from: m)
        }
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.fold(prefs.sideSpeed)) { prefs.sidebar.toggle() }
    }

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        if let url = Address.url(from: typed) { return url }
        if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
           let url = Engine.url(for: rest, template: keyword.template) {
            return url
        }
        return searchURL(for: typed)
    }

    let history = History()

    // MARK: - taking things off pages

    let curtain = Curtain()
    let loot = Loot()
    let floater = Float()
    /// True while the pointer is picking things to hide.
    @Published var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var theming = false
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }
    /// The blocker's panel — its log, your filters, your rules — when it is up.
    @Published var blockering: BlockerPage?

    var hereHost: String? { curtain.host(of: key?.active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = key?.active, tab.showsPage else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = key?.active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        key?.active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = key?.active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published var offering: Offer?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published var suggesting: Suggesting?

    struct Suggesting: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let logins: [Login]
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    var lowering: DispatchWorkItem?

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Login) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tab(for: list.tab) else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.address) == list.host,
              (tab.address?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        tab.fill(user: login.user, password: login.password) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the sign-in fields anymore") }
        }
        Vault.touch(login)
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    @Published var managing = false { didSet { if managing { relist() } } }
    /// The list, without secrets: see `Kept` and `Vault.all()`.
    @Published private(set) var saved: [Kept] = []
    @Published var hunting = ""

    struct SiteRow {
        let host: String
        let logins: [Kept]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all() }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce("Kept for \(host)")
    }

    func forget(_ login: Kept) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Kept) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            // Read here, once the Mac has said who this is: what the panel
            // drew its list from holds no secrets.
            guard let password = Vault.secret(of: login) else {
                self.announce("The keychain refused it")
                return
            }
            let board = NSPasteboard.general
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(password, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if board.changeCount == copied { board.clearContents() }
            }
            announce("Password copied")
        }
    }

    /// What came back from another browser's store, put in the keychain.
    func took(_ outcome: Result<Chromium.Found, Error>, from source: Chromium.Source) {
        switch outcome {
        case .success(let found):
            var kept = 0
            for login in found.logins
            where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
                kept += 1
            }
            var never = Vault.never
            found.never.forEach { never.insert($0) }
            Vault.never = never
            relist()
            announce(kept == 0 ? "Nothing new in \(source.name)" : "\(kept) passwords from \(source.name)")
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(source.name) didn't give up its keychain key")
        case .failure:
            announce("Nothing readable in \(source.name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: Chromium.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Chromium.places(in: source)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                done(places.count)
            }
        }
    }

    func takePlaces(from source: Mozilla.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Mozilla.places(in: source)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                done(places.count)
            }
        }
    }

    func takePlaces(from source: ImportSource, then done: @escaping (Int) -> Void) {
        switch source {
        case .chromium(let c): takePlaces(from: c, then: done)
        case .mozilla(let m): takePlaces(from: m, then: done)
        }
    }

    /// Takes in a CSV as Google Password Manager exports one. The file is read
    /// once and never copied.
    func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A passwords export, as Chrome, Dia or Google Password Manager write it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            announce("Couldn't read that file as text")
            return
        }
        let result = Vault.take(csv: text)
        relist()
        announce(
            result.skipped == 0
                ? "\(result.kept) passwords in the keychain"
                : "\(result.kept) in the keychain, \(result.skipped) skipped"
        )
    }

    // MARK: - what is kept, and getting rid of it

    enum RecallMode {
        case history, clearing
    }

    // One state keeps closing History from leaving its clearing controls open.
    @Published var recallMode: RecallMode?
    var recalling: Bool {
        get { recallMode != nil }
        set { recallMode = newValue ? .history : nil }
    }
    @Published var hoarding = false
    @Published var recallHunt = ""

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Signed out of everything")
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared")
    }

    func clearHistory() {
        history.forget()
        // A tile's preview is a picture of where you have been: it goes with
        // the history, though the tiles stay.
        if prefs.usesDial || FileManager.default.fileExists(atPath: SpeedDial.folder.path) {
            speedDial.forgetPreviews()
        }
        announce("History cleared")
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func denyCapture() { answerCapture(.deny) }

    private func answerCapture(_ decision: WKPermissionDecision) {
        guard let decide else { return }
        // Remembered per site, so a call you take every week asks once.
        Store.settings.set(decision == .grant, forKey: "capture." + askedAbout)
        decide(decision)
        self.decide = nil
        askedAbout = ""
        asking = nil
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
        announce("Camera and microphone choices forgotten")
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?
    /// The file a "Saved …" line is about (see announce).
    @Published private(set) var announcedFile: URL?


    /// `file`: one just saved. The line then shows it in the Finder when
    /// clicked, and stays long enough to be clicked.
    func announce(_ text: String, file: URL? = nil) {
        announcement = text
        announcedFile = file
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.announcement = nil
            self?.announcedFile = nil
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (file == nil ? 1.7 : 4), execute: work)
    }

    /// Downloads while they happen (see Fetching.swift).
    let fetches = Fetches()

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    lazy var sleepQueue = SleepQueue(browser: self)
    /// Downloads still under way. See `keep(_:)`.
    @Published private(set) var downloading: [WKDownload] = []
    /// alert(), confirm() and prompt() from tabs that weren't on screen,
    /// waiting for them to be (see Dialogs.swift).
    var heldDialogs: [Tab.ID: [HeldQuestion]] = [:]
    /// Downloads from private tabs, which the Downloads list never shows.
    var unlisted: Set<ObjectIdentifier> = []
    /// A page being translated, while it is (see Translate.swift).
    @Published var translating: TranslationAsk?
    /// Where translated pages' later text goes while a session can take it.
    var translationFeed: (owner: UUID, into: AsyncStream<(UUID, Translate.Found)>.Continuation)?
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var hush: DispatchWorkItem?
    private var remembering = false
    /// Spaces (see Spaces.swift): every one this profile knows. Which one a
    /// window is in lives on the window.
    @Published var spaces = Spaces.read() {
        didSet { Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id)) }
    }

    // MARK: - beginning and ending

    override init() {
        super.init()
        Shield.shared.enabled = prefs.shielded
        Shield.shared.listsOn = prefs.filterLists
        Shield.shared.compile()
        Filters.shared.start()
        OwnFilters.shared.start()
        // uBO's lists, the moment they are compiled or updated: every open
        // page is given them, rather than the pages opened from then on.
        Filters.shared.$generation.combineLatest(OwnFilters.shared.$generation)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Shield.shared.forgetExtras()
                Shield.shared.apply(to: allTabs.compactMap { tab in
                    tab.built.map { ($0.configuration.userContentController, tab.address?.host()?.lowercased()) }
                })
            }
            .store(in: &bag)
        if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
        if prefs.bench {
            Bench.shared.start(for: self)
        } else if prefs.benchRefused {
            announce("“Let a script drive SearchX” was turned on outside Settings, and stays off")
        }
        welcoming = !prefs.welcomed
        // The switches this version brought, once, after an update.
        if WhatsNew.due(welcoming: welcoming) { newsShowing = true }
        // Once a day, quietly: is there a newer one?
        Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
        FormRelay.passkeysOffered = prefs.passkeys

        // The History menu lists what the history holds, and the menu is drawn
        // from this object's changes — so the history's are passed on.
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it.
        Favicons.shared.arrived = { [weak self] host, image in
            guard let self else { return }
            let lower = host.lowercased()
            for tab in allTabs {
                guard let tabHost = tab.address?.host()?.lowercased() else { continue }
                if tabHost == lower || tabHost == "www." + lower || lower == "www." + tabHost {
                    // An alias can finish later than this host's own icon.
                    tab.icon = Favicons.shared.cached(tabHost) ?? image
                }
            }
        }
        // The little window's own three buttons.
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came, let tab = self.tab(for: came), let owner = tab.owner {
                owner.select(tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.where_) { found in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.toggle) { playing in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onClose = { [weak self] in self?.land() }

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            watchForSleep()
        }

        // What a deleted space left behind, if WebKit wouldn't let it go then.
        Spaces.sweep()
        Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))
        // The space you were in, when there are spaces (see Spaces.swift).
        var space = Space.firstID
        if prefs.usesSpaces, let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            space = last
            Spaces.current = last
        }
        let home = Session.read()
        let locations: [Session.WindowLocation]
        if let layout = home.layout, !layout.isEmpty {
            locations = layout.map { location in
                let valid = prefs.usesSpaces && spaces.contains { $0.id == location.space }
                return Session.WindowLocation(id: location.id, space: valid ? location.space : Space.firstID)
            }
        } else {
            let saved = Session.read(space: space)
            locations = saved.windows.isEmpty
                ? [.init(id: UUID(), space: space)]
                : saved.windows.map { .init(id: $0.id ?? UUID(), space: space) }
        }
        var made: [WindowModel] = []
        for location in locations {
            let model = WindowModel(
                id: WindowID(rawValue: location.id),
                profile: self,
                spaceID: location.space
            )
            model.folded = prefs.sidebar && prefs.sideHides
            model.frameRequest = WindowModel.row(in: Session.read(space: location.space), for: model.id)?.frame
            made.append(model)
        }
        windows = made
        sceneModel = made.first
        key = made.first
        for model in made {
            model.restoreSession()
            if prefs.usesSpaces { model.preloadSpaces() }
        }
        // The first row goes in the scene's window; any the session also
        // kept need a window of their own.
        Links.onceShown { [weak self] in
            guard let self else { return }
            for model in self.windows where model !== self.sceneModel && self.host(of: model) == nil {
                BrowserHost.show(model)
            }
        }
    }

    // MARK: - the window registry

    /// Every tab in every window, live and parked — for the sleep timer,
    /// favicons, and prefs sweeps that must reach every page.
    var allTabs: [Tab] { windows.flatMap { $0.tabs + $0.parkedTabs } }

    /// A tab by id, wherever it lives.
    func tab(for id: Tab.ID) -> Tab? {
        windows.lazy.compactMap { $0.tab(id) }.first
    }

    /// The model behind a window id. Nil between a close and the scene noticing.
    func window(for id: WindowID) -> WindowModel? {
        windows.first { $0.id == id }
    }

    /// The NSWindow hosting a model, once dress() has claimed it.
    private var hosts: [WindowID: NSWindow] = [:]

    func claim(_ window: NSWindow, for model: WindowModel) {
        hosts[model.id] = window
    }

    func host(of model: WindowModel) -> NSWindow? {
        hosts[model.id]
    }

    /// The model whose own window this is, and none for any other.
    func model(owningExactly host: NSWindow) -> WindowModel? {
        windows.first { self.host(of: $0) === host }
    }

    /// The model behind an NSWindow, for a key event or a notification.
    /// Falls back to the window in front, which is where unclaimed keys go.
    func model(owning host: NSWindow?) -> WindowModel? {
        guard let host else { return key }
        if let direct = windows.first(where: { self.host(of: $0) === host }) {
            return direct
        }
        if let parent = host.parent, let parentModel = windows.first(where: { self.host(of: $0) === parent }) {
            return parentModel
        }
        return key
    }

    /// Which window sits under a point on the screen.
    func window(at screenPoint: NSPoint) -> WindowModel? {
        let hit = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        if hit > 0, let nsWindow = NSApp.window(withWindowNumber: hit), let model = model(owning: nsWindow) {
            return model
        }
        return windows.first { model in
            guard let host = host(of: model) else { return false }
            return host.frame.contains(screenPoint)
        }
    }

    /// The window in front, as AppKit sees it.
    var keyHost: NSWindow? {
        key.flatMap { host(of: $0) }
    }

    /// A window came forward: it is the one ⌘T and links from other apps
    /// belong to. Replaces tracking this through didBecomeKey notifications
    /// and a static of whichever window was last in front.
    func becameKey(_ model: WindowModel) {
        key = model
    }

    /// External links always use a persistent browsing window.
    var ordinary: WindowModel {
        if let key, !key.isPrivate { return key }
        return windows.first { !$0.isPrivate } ?? open()
    }

    /// A new window with one blank tab. ⌘N. The App layer turns the returned
    /// model into a real NSWindow.
    @discardableResult
    func open(space: Space.ID? = nil, shy: Bool = false) -> WindowModel {
        open(space: space, privateStore: shy ? .nonPersistent() : nil)
    }

    func open(space: Space.ID?, privateStore: WKWebsiteDataStore?) -> WindowModel {
        // The last window was closed with the app still running: the next
        // one is that window again, pins and all, as a relaunch would be.
        if privateStore == nil, let retired, !windows.contains(where: { !$0.isPrivate }) {
            self.retired = nil
            let model = WindowModel(id: retired.id, profile: self, spaceID: retired.space)
            model.folded = prefs.sidebar && prefs.sideHides
            model.frameRequest = WindowModel.row(in: Session.read(space: retired.space), for: model.id)?.frame
            adopt(model)
            model.restoreSession()
            if prefs.usesSpaces { model.preloadSpaces() }
            BrowserHost.show(model)
            writeSession()
            return model
        }
        let model = WindowModel(
            profile: self,
            spaceID: space ?? key?.spaceID ?? Space.firstID,
            privateStore: privateStore
        )
        model.folded = prefs.sidebar && prefs.sideHides
        adopt(model)
        // The space's pins are every window's (see Pins.swift); a private
        // window keeps none.
        if privateStore == nil {
            let pins = model.reconcilePins([], space: model.spaceID)
            if !pins.isEmpty { model.showRow(pins, active: nil) }
        }
        model.newTab()
        if prefs.usesSpaces, privateStore == nil { model.preloadSpaces() }
        BrowserHost.show(model)
        writeSession()
        return model
    }

    private func adopt(_ model: WindowModel) {
        windows.append(model)
        if key == nil { key = model }
    }

    /// ⌘W on a tab: through the window that holds it (or the key window).
    func closeTab(_ tab: Tab) {
        (tab.owner ?? key)?.close(tab)
    }

    /// Remove the model before closing the host: AppKit's close notification
    /// comes back through this method, and must be an idempotent operation.
    func close(_ window: WindowModel) {
        guard windows.contains(where: { $0 === window }) else { return }
        // The last ordinary window going is not the same as its tabs going.
        // Writing the session without it is how pinned tabs vanished: the
        // app stays open with no window, the file says there was nothing,
        // and the next launch believes it. Its rows are kept as they stood.
        if !window.isPrivate, !windows.contains(where: { $0 !== window && !$0.isPrivate }) {
            var rows = [window.spaceID: window.sessionShape(tabs: window.tabs, active: window.activeID)]
            for (space, row) in window.parked {
                rows[space] = window.sessionShape(tabs: row.tabs, active: row.active, groups: row.groups, splits: row.splits)
            }
            retired = Retired(id: window.id, space: window.spaceID, rows: rows)
        }
        // One closed while others stay open goes, tabs and all, and ⇧⌘T
        // brings it back; quitting is not closing.
        if !window.isPrivate, !quitting, retired == nil {
            var rows = [window.spaceID: window.sessionShape(tabs: window.tabs, active: window.activeID)]
            for (space, row) in window.parked {
                rows[space] = window.sessionShape(tabs: row.tabs, active: row.active, groups: row.groups, splits: row.splits)
            }
            if rows.values.contains(where: { !$0.tabs.isEmpty }) {
                closedWindows.append(ClosedWindow(space: window.spaceID, rows: rows, frame: host(of: window)?.frame, at: Date()))
                if closedWindows.count > 10 { closedWindows.removeFirst(closedWindows.count - 10) }
            }
        }
        if floating.map({ id in (window.tabs + window.parkedTabs).contains { $0.id == id } }) == true { land() }
        window.closePanel(immediately: true)
        if sceneModel === window { sceneModel = nil }
        windows.removeAll { $0 === window }
        for tab in window.tabs + window.parkedTabs { tab.enter(nil); tab.close() }
        if key === window { key = windows.first }
        let host = hosts.removeValue(forKey: window.id)
        host?.close()
        if let key { self.host(of: key)?.makeKeyAndOrderFront(nil) }
        writeSession()
        if !window.isPrivate, retired == nil {
            let closedSpaces = Set(window.parked.keys).union([window.spaceID])
            for space in closedSpaces where space != Space.firstID && !windows.contains(where: { !$0.isPrivate && ($0.spaceID == space || $0.parked[space] != nil) }) {
                Session.write(space: space, Session.Shape(windows: []))
            }
        }
    }

    /// Windows closed while others were open, newest last, for ⇧⌘T.
    struct ClosedWindow {
        let space: UUID
        let rows: [UUID: Session.WindowShape]
        let frame: CGRect?
        let at: Date
    }
    private(set) var closedWindows: [ClosedWindow] = []
    /// Set once the app is quitting: windows closing then are not windows closed.
    var quitting = false

    /// ⇧⌘T, when the last thing closed was a window: it comes back with its
    /// rows, in a new window of its own.
    @discardableResult
    func reopenWindow() -> Bool {
        guard let last = closedWindows.popLast() else { return false }
        let model = WindowModel(profile: self, spaceID: last.space, privateStore: nil)
        model.folded = prefs.sidebar && prefs.sideHides
        model.frameRequest = last.frame
        adopt(model)
        model.restore(rows: last.rows)
        BrowserHost.show(model)
        writeSession()
        return true
    }

    /// The last ordinary window, closed while the app kept running: what it
    /// held, per space, until a window takes it back (see open and close).
    private struct Retired {
        let id: WindowID
        let space: UUID
        let rows: [UUID: Session.WindowShape]
    }
    private var retired: Retired?

    func appLeft() {
        guard prefs.floatsAway else { return }
        liftedAway = !floater.showing
        lift(key?.active, quietly: true)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = floating, id == key?.activeID { land() }
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Search
    /// comes back.
    private var liftedAway = false

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private var commandWindowBag = Set<AnyCancellable>()
    /// The menu bar's own signal (see MenuState).
    let menu = MenuState()
    private var commandTabBag = Set<AnyCancellable>()

    private func followCommands(in window: WindowModel?) {
        commandWindowBag.removeAll()
        commandTabBag.removeAll()
        // Another window in front: rare, and whatever reads the one in
        // front is told.
        objectWillChange.send()
        guard let window else { return }
        Publishers.MergeMany([
            window.$folded.map { _ in () }.eraseToAnyPublisher(),
            window.$finding.map { _ in () }.eraseToAnyPublisher(),
            window.$ghosts.map { _ in () }.eraseToAnyPublisher(),
            window.$selectedTabs.map { _ in () }.eraseToAnyPublisher(),
            window.$tabGroups.map { _ in () }.eraseToAnyPublisher(),
            window.$splitPairs.map { _ in () }.eraseToAnyPublisher(),
            window.$pendingSplit.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.menu.changed() }
        .store(in: &commandWindowBag)
        Publishers.Merge(
            window.$activeID.map { _ in () }, window.$tabs.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak window] in self?.followCommandTab(window?.active) }
        .store(in: &commandWindowBag)
    }

    private func followCommandTab(_ tab: Tab?) {
        commandTabBag.removeAll()
        menu.changed()
        guard let tab else { return }
        // Menu validation depends on page state as well as window selection.
        // Watching specific publishers avoids the profile/window redraw cycle.
        Publishers.MergeMany([
            tab.$address.map { _ in () }.eraseToAnyPublisher(),
            tab.$pin.map { _ in () }.eraseToAnyPublisher(),
            tab.$groupID.map { _ in () }.eraseToAnyPublisher(),
            tab.$canGoBack.map { _ in () }.eraseToAnyPublisher(),
            tab.$canGoForward.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.menu.changed() }
        .store(in: &commandTabBag)
    }

    private func follow() {
        $key.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.followCommands(in: $0) }
            .store(in: &bag)
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.$usesSpaces
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on {
                    for window in windows { window.preloadSpaces() }
                } else {
                    leaveSpaces()
                }
            }
            .store(in: &bag)
        // Videos waiting for a click, or audible autoplay: every tab's next
        // page view follows.
        Publishers.Merge(prefs.$waitsForPlay.dropFirst(), prefs.$audibleAutoplay.dropFirst())
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { for tab in self.allTabs { tab.playbackChanged() } }
            }
            .store(in: &bag)
        prefs.$usesTabGroups
            .dropFirst()
            .sink { [weak self] on in
                guard let self, on else { return }
                for window in windows { window.arrangeGroupedTabs() }
                writeSession()
            }
            .store(in: &bag)
        prefs.$splitViews
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for window in windows {
                    if on { window.wakeSplitPartner() } else { window.pendingSplit = nil }
                }
            }
            .store(in: &bag)
        // Turned off, no tab a link opened goes back to its page any more,
        // however long it has been open.
        prefs.$returnsFromLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self, !on else { return }
                for tab in allTabs { tab.returnTo = nil }
            }
            .store(in: &bag)
        prefs.$tabPictures
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self else { return }
                for window in windows { window.switcher = nil }
                for tab in allTabs { tab.discardThumbnail() }
            }
            .store(in: &bag)

        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: allTabs.compactMap { tab in
                    tab.built.map { ($0.configuration.userContentController, tab.address?.host()?.lowercased()) }
                })
                announce(on ? "Ads and trackers blocked" : "Blocking off. Reload to see the difference")
            }
            .store(in: &bag)

        // The lists alone off: the checks on what pages do stay.
        prefs.$filterLists
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.listsOn = on
                Shield.shared.apply(to: allTabs.compactMap { tab in
                    tab.built.map { ($0.configuration.userContentController, tab.address?.host()?.lowercased()) }
                })
                announce(on ? "Filter lists on" : "Filter lists off. Reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        // The menus are drawn from this object's changes, and show the keys.
        shortcuts.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive SearchX. See ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now.
        prefs.$showsLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { for window in windows { window.linkStatus.dismiss() } }
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        // Every open page that hasn't a size of its own takes the new one.
        // Asleep, a tab has no page to resize; it takes it on waking.
        prefs.$pageZoom
            .dropFirst()
            .sink { [weak self] _ in
                // Published before it is stored; the tabs read the stored one.
                DispatchQueue.main.async {
                    guard let self else { return }
                    for tab in self.allTabs where tab.built != nil { tab.applyRememberedZoom() }
                }
            }
            .store(in: &bag)

        prefs.$floatBlockedSites
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let id = self.floating,
                          let tab = self.tab(for: id), self.prefs.blocksFloating(on: tab.address) else { return }
                    self.land()
                }
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again. Reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.$autocorrect
            .dropFirst()
            .sink { [weak self] on in
                guard let self, let web = key?.active?.web else { return }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    private func relook() {
        Favicons.shared.relook(allTabs.filter { !$0.asleep })
    }

    func writeSession() {
        // The pins as they are now, for every window (see Pins.swift).
        syncPins()
        // One file per space, every window's row in it (see Session.swift) —
        // the ones on screen now, and the ones parked while their window is
        // in another space.
        var shapes: [UUID: [Session.WindowShape]] = [:]
        for window in windows where !window.isPrivate {
            shapes[window.spaceID, default: []].append(
                window.sessionShape(tabs: window.tabs, active: window.activeID)
            )
            for (space, row) in window.parked {
                shapes[space, default: []].append(
                    window.sessionShape(tabs: row.tabs, active: row.active, groups: row.groups, splits: row.splits)
                )
            }
        }
        // No window on screen, but the last one's tabs are still owed a
        // place: it is written as though it were open.
        let keeping = windows.contains { !$0.isPrivate } ? nil : retired
        for (space, row) in keeping?.rows ?? [:] { shapes[space, default: []].append(row) }
        for (space, list) in shapes where space != Space.firstID {
            Session.write(space: space, Session.Shape(windows: list))
        }
        // Write the window locations last, after all their rows. Private
        // windows never appear in this launch layout or in a space file.
        var layout = windows.filter { !$0.isPrivate }.map {
            Session.WindowLocation(id: $0.id.rawValue, space: $0.spaceID)
        }
        if let keeping { layout.append(.init(id: keeping.id.rawValue, space: keeping.space)) }
        Session.write(Session.Shape(windows: shapes[Space.firstID] ?? [], layout: layout))
    }

    func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession()
        Spaces.write(spaces)
        Session.settle()
        history.flush()
    }


    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.unpopped(Extensions.current(url)) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }


    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        guard let tab = key?.active, tab.showsPage, let window = NSApp.keyWindow else { return }
        Browser.printing(tab.web).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job for a page, or for one frame of it when WebKit names
    /// one: a page's own print() in a frame prints that frame, as in Safari.
    /// The frame's printing is outside the public framework, so it is asked
    /// for first, and a WebKit without it prints the whole page.
    static func printing(_ web: WKWebView, frame: AnyObject? = nil) -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: forFrame) {
            typealias Make = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation
            job = unsafeBitCast(web.method(for: forFrame), to: Make.self)(web, forFrame, info, frame)
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        return job
    }

    /// A page's own print(): the Print… item in a page's own menu, or ⌘P in
    /// an editor that keeps the key for itself. WebKit hands it to a delegate
    /// that answers this name, outside the public framework, and to nobody
    /// otherwise: the button did nothing at all.
    ///
    /// The page waits while the sheet is up, as in Safari. Only a page on
    /// screen in the window you are in may ask, one sheet at a time; and a
    /// site that asks again each time the sheet is cancelled asks no more
    /// after the second cancel within ten seconds, until the tab goes to
    /// another site (see PrintSheet).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: NSObject,
        pdfFirstPageSize: CGSize,
        completionHandler done: @escaping () -> Void
    ) {
        guard let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
              let tab = tab(for: webView), tab.showsPage,
              let owner = windows.first(where: { $0.tab(tab.id) != nil }), owner.shows(tab.id),
              PrintSheet.allows(tab)
        else { done(); return }
        let sheet = PrintSheet(tab) { done() }
        Browser.printing(webView, frame: frame).runModal(
            for: window, delegate: sheet,
            didRun: #selector(PrintSheet.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(sheet).toOpaque()
        )
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        lift(key?.active, quietly: false)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    func lift(_ tab: Tab?, quietly: Bool) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else { return }
        guard !prefs.blocksFloating(on: tab.address) else {
            if !quietly { announce("Floating video is disabled for this site") }
            return
        }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) { return }
        tab.web.evaluateInSearch(Isolate.on) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
                    if !quietly { self.announce("Nothing is playing here") }
                    return
                }
                self.floating = tab.id
                tab.floating = true
                self.floater.lift(tab.web)
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        guard let id = floating, let tab = tab(for: id) else { return }
        floating = nil
        tab.floating = false
        tab.web.evaluateInSearch(Isolate.off)
    }

}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// The page's own settings, before the decision below: whether WebKit
    /// guards it against fingerprinting (see Protections). WebKit asks this
    /// form in place of the one without preferences, so everything else is
    /// handed on to that one as it was.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if action.targetFrame?.isMainFrame != false {
            let privately = tab(for: webView)?.shy ?? !webView.configuration.websiteDataStore.isPersistent
            Protections.guardFingerprints(Protections.guards(action.request.url?.host(), privately: privately), in: preferences)
            // A site allowed to play sound by itself (see Autoplay).
            if let url = action.request.url { Autoplay.apply(to: preferences, for: url, shy: privately) }
        }
        self.webView(webView, decidePolicyFor: action) { decisionHandler($0, preferences) }
    }

    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // Speed Dial is the browser's to open, never a page's: a link, a
        // script or a window.open to its marker would show the dial over a
        // live document the page still holds. WebKit gives a load of ours
        // and a page's the same source frame, so ours carries a ticket (see
        // Tab.dialing); Back and Forward are the tab's own history.
        if SpeedDial.at(url), action.navigationType != .backForward {
            let tab = tab(for: webView)
            let ours = tab?.dialing == true
            tab?.dialing = false
            guard ours else {
                decisionHandler(.cancel)
                return
            }
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // A website returning to a public extension page needs another view.
        if #available(macOS 15.4, *), routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { tab.owner?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // Shift-click, when Settings says so: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
           let from = tab(for: webView), from.owner?.peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { from.owner?.peek(url, from: from) }
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            let from = tab(for: webView)
            if let from { from.owner?.openFromPage(url, foreground: action.modifierFlags.contains(.shift), from: from) }
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            if ["http", "https"].contains(scheme), refuses(action, to: url, in: tab, on: webView) {
                decisionHandler(.cancel)
                return
            }
            // The address without its click-tracking parameters, loaded in
            // its place: the page never sees where the click came from.
            // Links and pages opened only; a form's own fields, a reload or
            // Back are left as they are.
            if ["http", "https"].contains(scheme), action.request.httpMethod ?? "GET" == "GET",
               [.linkActivated, .other].contains(action.navigationType),
               let clean = Shield.shared.cleaned(url) {
                decisionHandler(.cancel)
                tab.blockLog.add(.init(kind: .cleaned, url: url, source: "Parameters taken off"))
                webView.load(URLRequest(url: clean))
                return
            }
            let host = curtain.host(of: url)
            tab.scriptlets(forPage: url)
            tab.arm(hiding: curtain.css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
            let nextHost = url.host()?.lowercased()
            let currentHost = tab.address?.host()?.lowercased()
            if let nextHost, nextHost != currentHost {
                tab.icon = Favicons.shared.cached(nextHost)
            }
        } else if ["http", "https"].contains(scheme), let tab = tab(for: webView) {
            // A frame: a video player on another site is where the pop-ups
            // usually are, and the lists have patches for those sites too.
            tab.scriptlets(forFrame: url)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    @available(macOS 15.4, *)
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    @available(macOS 15.4, *)
    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab) -> Bool {
        guard !tab.shy,
              let context = Extensions.shared.controller.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            tab.owner?.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        tab.owner?.cancelElementCapture(tab)
        tab.extensionReturn.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect, #available(macOS 15.4, *),
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. Only the page
    /// itself may ask, or a click inside one of its frames; a frame that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    /// An extension's side panel hands its own off here too (see ExtensionPanel).
    func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        guard action.targetFrame?.isMainFrame ?? true || clicked else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// A link that asks for a new window gets a new tab in the opener's
    /// window. The configuration WebKit hands over has to be the one the new
    /// view is built with, or the opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, SpeedDial.at(url) { return nil }
        let opener = tab(for: webView)
        // A sign-in with another site opens, whatever asked for it (see Intent.signIn).
        let signIn = Intent.signIn(action.request.url)
        // A window onto a pop-up or pop-under network never opens (uBO's
        // $popup). WebKit's blocker stops most before they get here; this
        // catches one a click on the page asked for by name.
        if !signIn, Shield.shared.refusesPopup(to: action.request.url, from: webView.url?.host()?.lowercased()) { return nil }
        // And by what the click that asked for it landed on (see Intent).
        let page = webView.url?.host()?.lowercased()
        var watched: String?
        if let opener, !signIn, Shield.shared.judges(page) {
            let now = ProcessInfo.processInfo.systemUptime
            switch Intent.window(to: action.request.url, page: page, press: opener.press, now: now) {
            case .block(let why):
                stopped(why, in: opener)
                return nil
            case .watch:
                watched = page
            case .allow:
                break
            }
            if let press = opener.press, now - press.at < Intent.reach { opener.press?.opened += 1 }
            opener.openedWindowAt = now
        }
        let from = opener?.id
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        let tab = Tab(shy: opener?.shy ?? false, configuration: configuration)
        tab.watchedFrom = watched
        tab.popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        // The tab belongs in the window that asked for it, not whatever
        // window happens to be key.
        let home = opener?.owner ?? key
        // A window the page sized for itself — a sign-in, a payment — is a
        // small window over the page (see LittleWindow.popup), unless it is
        // one being watched, which goes on as a tab (see refuses).
        if tab.popup, watched == nil, let home {
            home.prepare(tab)
            tab.opener = from
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let size = windowFeatures.width.flatMap { width in
                windowFeatures.height.map { CGSize(width: width.doubleValue, height: $0.doubleValue) }
            }
            let parked = Store.testing && ProcessInfo.processInfo.environment["SEARCH_PARK"] != nil
            LittleWindow.popup(tab, for: self, over: host(of: home), size: size, front: !parked)
            return tab.web
        }
        home?.adopt(tab)
        tab.opener = from
        if prefs.returnsFromLinks { tab.returnTo = from }
        home?.activeID = tab.id
        home?.editing = false
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A document or frame the filters refuse for a header it carries.
        if let http = response.response as? HTTPURLResponse,
           Shield.shared.refuses(http, top: response.isForMainFrame ? nil : webView.url) {
            if let tab = tab(for: webView), let url = http.url { tab.blockLog.add(.init(kind: .header, url: url, source: "Filters")) }
            decisionHandler(.cancel)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
        dropEmpty(webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It closes, as in Safari and
    /// Chrome, and you are back on the page whose link it was.
    private func dropEmpty(_ webView: WKWebView) {
        let shown = webView.backForwardList.currentItem?.url.absoluteString
        guard shown == nil || shown == "about:blank",
              let tab = tab(for: webView), tab.pin == nil
        else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        // A window's only tab stays, as a new tab: closing it would close
        // the window.
        guard let owner = tab.owner, owner.tabs.count > 1 else { return }
        if tab.id == owner.activeID, let opener = tab.opener, let home = owner.tabs.first(where: { $0.id == opener }) {
            owner.select(home)
        }
        owner.close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        if !downloading.contains(where: { $0 === download }) { downloading.append(download) }
        // Noted now, while its page is still there to ask: a private tab's
        // download is saved where you say, and left out of the list.
        if let web = download.webView, tab(for: web)?.shy == true { unlisted.insert(ObjectIdentifier(download)) }
        fetches.start(download)
    }

    func cancelDownload(_ download: WKDownload) {
        download.cancel { [weak self, weak download] _ in
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.downloading.removeAll { $0 === download }
                self.unlisted.remove(ObjectIdentifier(download))
                self.fetches.fail(download)
                self.announce("Download cancelled")
            }
        }
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        let key = "\(host)|\(type.rawValue)"

        if let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type))
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    /// A page bringing a window of its own forward — the sign-in window a
    /// "Continue with Google" opened, asked for again with a second click.
    /// Here that window is a tab, and a tab behind is one that does nothing
    /// you can see: it comes to the front.
    @objc(_focusWebView:)
    func focusWebView(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if let little = LittleWindow.holding(tab) { return little.forward() }
        guard let owner = tab.owner, owner.activeID != tab.id else { return }
        owner.select(tab)
        host(of: owner)?.makeKeyAndOrderFront(nil)
    }

    /// What a rule list did to a load, for the tab's log. WebKit tells a
    /// browser this (Safari's privacy report reads the same); it names the
    /// list, not the line of it.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard let tab = tab(for: webView) else { return }
        let did = { (key: String) in (action.value(forKey: key) as? Bool) == true }
        let kind: BlockLog.Kind = did("blockedLoad") ? .blocked : did("blockedCookies") ? .cookies
            : did("madeHTTPS") ? .upgraded : did("redirected") ? .redirected : did("modifiedHeaders") ? .headers : .blocked
        // A css-display-none rule reports nothing worth a line.
        guard did("blockedLoad") || did("blockedCookies") || did("madeHTTPS") || did("redirected") || did("modifiedHeaders") else { return }
        tab.blockLog.add(.init(kind: kind, url: url, source: BlockLog.name(of: identifier)))
    }

    func webViewDidClose(_ webView: WKWebView) {
        // A page's small window closes with it (see LittleWindow.popup).
        if let tab = tab(for: webView), let little = LittleWindow.holding(tab) { return little.close() }
        guard let tab = tab(for: webView), let owner = tab.owner else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = owner.tab(opener) {
            owner.select(home)
        }
        tab.pin = nil
        owner.close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        #if DEBUG
        NativeProbe.navigation("commit", tab: tab)
        #endif
        tab.extensionReturn.finished(navigation)
        if let owner = tab.owner, tab.id == owner.activeID { owner.linkStatus.dismiss() }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        #if DEBUG
        if let tab = tab(for: webView) { NativeProbe.navigation("firstFrame", tab: tab) }
        #endif
        let tab = tab(for: webView)
        // The cover supplies the fade. Fading the page too exposes the
        // window background between the old picture and the live document.
        (webView as? PageView)?.showFirstFrame(animated: tab?.cover == nil)
        tab?.uncover()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame(animated: tab(for: webView)?.cover == nil)
        guard let tab = tab(for: webView), let url = tab.address else { return }
        tab.uncover()
        guard !tab.onDial else { return }
        // The store's "Add to SearchX" only on the store, and only where
        // SearchX can add extensions: before macOS 15.4 pressing it did
        // nothing at all. Given to that page alone rather than parsed by
        // every page there is.
        if #available(macOS 15.4, *), url.host()?.lowercased() == "chromewebstore.google.com" {
            webView.evaluateInSearch(StoreRelay.script)
        }
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
        if prefs.newTabDial || prefs.dialButton {
            speedDial.captureMissing(from: tab)
        }
    }

    // MARK: - what a page does (see Intent)

    /// A trip of the whole tab the page's behaviour gives away: a frame
    /// taking the tab over, a tab-under behind a pop-up, an invisible
    /// layer's click; or a blank window opened from nothing that asked for
    /// one, on its way somewhere else — which goes again.
    fileprivate func refuses(_ action: WKNavigationAction, to url: URL, in tab: Tab, on webView: WKWebView) -> Bool {
        if let from = tab.watchedFrom {
            tab.watchedFrom = nil
            if Shield.shared.judges(from), !Intent.sameSite(url.host()?.lowercased(), from), !Intent.signIn(url) {
                stopped("a blank window sent to another site", in: tab.opener.flatMap { tab.owner?.tab($0) } ?? tab)
                if let owner = tab.owner {
                    if let opener = tab.opener, let home = owner.tab(opener) { owner.select(home) }
                    DispatchQueue.main.async { owner.close(tab) }
                }
                return true
            }
        }
        guard [.linkActivated, .other].contains(action.navigationType) else { return false }
        if (action.value(forKey: "_isRedirect") as? Bool) == true { return false }
        let page = webView.url?.host()?.lowercased()
        guard Shield.shared.judges(page) else { return false }
        // The frame that asked, read without Swift's promise that it and its
        // request are there: WebKit leaves either empty for some navigations
        // (a load Search starts itself, a frame being torn down), and taken
        // at its word that crashed the browser on its first page.
        let source = action.value(forKey: "sourceFrame") as? WKFrameInfo
        let frameHost = (source?.value(forKey: "request") as? URLRequest)?.url?.host()?.lowercased()
            ?? source?.securityOrigin.host.lowercased()
        // The page going to sign in with another site (a sign-in done by
        // redirect rather than in a window) is never a page taken over.
        if Intent.signIn(url) { return false }
        let verdict = Intent.navigation(
            to: url, from: page,
            frame: frameHost,
            mainFrame: source?.isMainFrame ?? true, link: action.navigationType == .linkActivated,
            press: tab.press, openedAt: tab.openedWindowAt, now: ProcessInfo.processInfo.systemUptime)
        guard case .block(let why) = verdict else { return false }
        stopped(why, in: tab)
        return true
    }

    /// Said once a few seconds at most, however many a page tries: two words
    /// in the moment, and why in the log for whoever wants to know.
    fileprivate func stopped(_ why: String, in tab: Tab) {
        NSLog("SearchX blocked a pop-up on %@: %@", tab.address?.host() ?? "?", why)
        let now = ProcessInfo.processInfo.systemUptime
        if let last = tab.lastStopNotice, now - last < 5 { return }
        tab.lastStopNotice = now
        guard !tab.bench else { return }
        announce("Pop-up blocked")
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        tab(for: webView)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        // A window a page opened, sent straight to a server the blocker
        // refuses — a pop-up that opened blank and then went to its ad: gone
        // again, and you are back where you were (uBO's popup handling).
        if nsError.domain == "WebKitErrorDomain", code == 104, let tab = tab(for: webView),
           let opener = tab.opener, !webView.canGoBack, let owner = tab.owner {
            if let home = owner.tab(opener) { owner.select(home) }
            owner.close(tab)
            return
        }
        tab(for: webView)?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case 104:
            return "The blocker stopped this page: it belongs to an ad or tracking server."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        (allTabs + windows.compactMap(\.peekTab) + LittleWindow.all.map(\.tab)).first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let file = whereToSave(asked ?? suggestedFilename)
        completionHandler(file)
        if let file {
            fetches.going(download, to: file)
            announce("Downloading \(file.lastPathComponent)")
        } else {
            downloading.removeAll { $0 === download }
            unlisted.remove(ObjectIdentifier(download))
            fetches.fail(download)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        let listed = unlisted.remove(ObjectIdentifier(download)) == nil
        fetches.finish(download, file: download.progress.fileURL, quietly: !listed)
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)", file: file)
            return
        }
        saved(file, from: download.originalRequest?.url)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let file = whereToSave(suggestedFilename ?? "") else { return }
        do {
            try data.write(to: file)
            saved(file, from: originatingURL)
        } catch {
            announce("Download failed")
        }
    }

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled.
    private func whereToSave(_ name: String) -> URL? {
        let name = name.isEmpty ? "download" : name
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func saved(_ file: URL, from source: URL?) {
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date()))
        announce("Saved \(file.lastPathComponent)", file: file)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
        fetches.fail(download)
        let failure = error as NSError
        announce(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
                 ? "Download cancelled" : "Download failed")
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// The menu bar's say on the window and tab in front: which items are on,
/// which are greyed. Told on its own, once changes have paused for a moment,
/// so a run of tab switches rebuilds the menu bar once, after them — and
/// redraws nothing else, where borrowing the browser's own signal redrew
/// every view that watches the browser, in every window, on every switch.
/// Keyboard shortcuts don't wait on it: they are taken before the menus.
@MainActor
final class MenuState: ObservableObject {
    private var pending: DispatchWorkItem?

    func changed() {
        pending?.cancel()
        let tell = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.objectWillChange.send()
        }
        pending = tell
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: tell)
    }
}

/// What a page's print() is waiting on: told when the sheet has gone,
/// printed or cancelled, so WebKit can let the page's script go on. The
/// sheet's context keeps it alive until then.
@MainActor
final class PrintSheet: NSObject {
    private let done: () -> Void
    private let tab: Tab.ID
    private let site: String?

    init(_ tab: Tab, _ done: @escaping () -> Void) {
        self.tab = tab.id
        self.site = PrintSheet.site(of: tab)
        self.done = done
    }

    /// The sheets a page's print() had cancelled, by tab, on the site it was
    /// on: its origin, not its address, which the page can change itself
    /// with history.pushState between two print()s. Two cancels within ten
    /// seconds and the site asks no more, until the tab goes to another site
    /// or closes.
    private struct Cancels {
        var site: String?
        var when: [Date] = []
        var blocked = false
    }
    private static var cancelled: [Tab.ID: Cancels] = [:]

    private static func site(of tab: Tab) -> String? {
        guard let page = tab.address else { return nil }
        return "\(page.scheme ?? "")://\(page.host() ?? ""):\(page.port.map(String.init) ?? "")"
    }

    /// Whether this tab's site may bring the sheet up again.
    static func allows(_ tab: Tab) -> Bool {
        guard let seen = cancelled[tab.id], seen.site == site(of: tab) else {
            cancelled[tab.id] = nil
            return true
        }
        return !seen.blocked
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheet>.fromOpaque(contextInfo).release() }
        if !success {
            var seen = PrintSheet.cancelled[tab].flatMap { $0.site == site ? $0 : nil } ?? Cancels(site: site)
            let now = Date()
            seen.when = seen.when.filter { now.timeIntervalSince($0) < 10 } + [now]
            if seen.when.count >= 2 { seen.blocked = true }
            PrintSheet.cancelled[tab] = seen
        }
        done()
    }
}
