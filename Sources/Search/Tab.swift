import ImageIO
import SwiftUI
import WebKit
import Combine

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in — the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.
//
// Kept alive, that is, while it is worth what it costs. A tab nobody has
// looked at for half an hour gives its view back (see `sleep(picture:)`) and
// keeps what it takes to come back exactly where it was.

enum Web {
    /// Where Search's own page scripts run, and where their messages come
    /// from: a world of their own beside the page's. They see the same page,
    /// and the page sees none of them — no variable of theirs, and no
    /// `window.webkit`, which Safari never shows a page and which sites read
    /// as an app's embedded web view rather than a browser. Google answered
    /// that with a CAPTCHA every few searches, and refused sign-ins as "not
    /// secure" (24 Sep 2026). Only Search's passkey patch has to stand in
    /// the page's own world, and nothing there leads back to it.
    @MainActor static let world = WKContentWorld.world(name: "Search")

    /// Every handler of Search's taken off a controller: in its own world,
    /// and in the page's, where they all were before 24 Sep 2026 — a tab
    /// opened by a link inherits its opener's configuration, handlers
    /// included, and registering a name twice is a hard crash.
    @MainActor static func release(_ controller: WKUserContentController) {
        for name in [ScrollRelay.name, VeilRelay.name, FormRelay.name, ImageRelay.name,
                     StoreRelay.name, PasskeyRelay.name, MiddleRelay.name, TranslateRelay.name, ShotRelay.name, Intent.name] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
    }

    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// — web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids.
        //
        // This hardly ever runs. Safari can't be removed from modern macOS,
        // so reading the installed Safari above should always work. The
        // formula only matters if that read fails.
        //
        // From macOS 26 Safari shares its number; before, it was 3 ahead (14 -> 17, 15 -> 18).
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return os >= 26 ? "\(os).0" : "\(os + 3).0"
    }

    /// One pool for every tab. The property is deprecated and said to do
    /// nothing now, but a configuration without it gets a pool of its own
    /// when its view is made — so every new tab started a web process from
    /// cold, fonts registered and all, on the main thread, before its page
    /// could begin: 41 to 59 ms from a bookmark or Return to the load
    /// starting, the window stuck meanwhile. Sharing one lets WebKit have
    /// the next process ready: 9 to 10 ms, for the same memory and the same
    /// number of processes (measured with ./bench bookmark URL new, 24 Sep 2026).
    /// Measured again on 27 Sep 2026: 4.9 ms with it, 52 ms without.
    ///
    /// Made and handed over by name rather than through the deprecated Swift
    /// API, so the build stays free of warnings while WebKit gets the same
    /// object it always did.
    #if DEBUG
    static var poolStartup: [String: Any] = ["created": false]
    #endif
    static let pool: NSObject? = {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let visible = NSApp.windows.contains { $0.isVisible }
        #endif
        let pool = (NSClassFromString("WKProcessPool") as? NSObject.Type)?.init()
        #if DEBUG
        poolStartup = ["created": pool != nil, "windowVisible": visible,
                       "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000]
        #endif
        return pool
    }()

    /// `space`: the space the tab belongs to, when it is not the one on
    /// screen — a parked row made ahead of time (see Spaces.swift).
    /// `store`: a shy tab's own, for one opened from it — a link followed
    /// out of a private page is still signed in to whatever that page was.
    static func configuration(shy: Bool = false, space: UUID? = nil, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces on, each space's tabs share a store of that space's.
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: space ?? Spaces.current) })
        if let pool = Web.pool { config.setValue(pool, forKey: "processPool") }
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions says they may. The controller has to be there when the
        // view is made; it can't be added after.
        if #available(macOS 15.4, *), !shy || Store.settings.bool(forKey: "extensions.private") {
            MainActor.assumeIsolated { Extensions.attach(config) }
        }
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = Web.userAgentName
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        // On by default on macOS: a page could open a new tab, and take you
        // to it, whenever it liked — on load, on a timer. Off, window.open
        // works only from a click or a key, as Safari's pop-up blocking has
        // it; a sign-in window opened by its button still opens.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Saving power, nothing plays until it is clicked (see Power).
        config.mediaTypesRequiringUserActionForPlayback = Web.playback
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        inspector(config.preferences)
        return config
    }

    /// What a page may not play until it is clicked or a key pressed: sound,
    /// unless Settings allows audible autoplay; everything while saving power
    /// (see Power) or with Settings › Videos wait for a click (Safari's Never
    /// Auto-Play).
    static var playback: WKAudiovisualMediaTypes {
        if Power.savingNow || Store.settings.bool(forKey: Preferences.waitsKey) { return .all }
        return Store.settings.bool(forKey: "media.audibleAutoplay") ? [] : .audio
    }

    /// Every page view there is, for the bench.
    @MainActor static let pages = NSHashTable<PageView>.weakObjects()

    /// WebKit's "developer extras": Inspect Element in a page's right-click
    /// menu, and the Web Inspector the View menu opens (see Inspector.swift).
    /// isInspectable alone only lets Safari's Develop menu reach the page.
    /// The name is outside the public framework, so it is asked first.
    static func inspector(_ preferences: WKPreferences, on: Bool = true) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }
}

/// Sites you let play sound by themselves, from the site card: Safari's
/// per-site Allow All Auto-Play. Every other site keeps the default, sound
/// waiting for a click. Remembered for the site, as its zoom is, and never
/// from a private tab. Settings › Videos wait for a click wins: with it on,
/// no site plays by itself.
///
/// WebKit takes it for each page as it loads, through the page's own
/// preferences, under a name outside the public framework — asked for first,
/// so a WebKit without it only leaves the site waiting for a click. Values,
/// checked on macOS 26: 0 the default, 1 allow, 2 allow without sound, 3 deny.
enum Autoplay {
    private static func key(_ host: String) -> String { "autoplay." + host }

    static func allowed(_ host: String) -> Bool {
        Store.settings.bool(forKey: key(host))
    }

    /// Off keeps nothing, as a site at the usual zoom keeps nothing.
    static func set(_ on: Bool, for host: String) {
        if on {
            Store.settings.set(true, forKey: key(host))
        } else {
            Store.settings.removeObject(forKey: key(host))
        }
    }

    /// For a page about to load at `url`: allowed to play, or left alone.
    static func apply(to preferences: WKWebpagePreferences, for url: URL, shy: Bool) {
        guard !shy, let host = url.host(), allowed(host),
              !Store.settings.bool(forKey: Preferences.waitsKey), !Power.savingNow else { return }
        let set = NSSelectorFromString("_setAutoplayPolicy:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, 1)
    }
}

/// WKWebView can pause a page's media, but not mute it and let it keep
/// playing, the one thing a tab's own speaker does everywhere else. WebKit
/// has that mute one call down from the public framework: the one Safari's
/// own tabs use, the page's JavaScript none the wiser. The names are asked
/// for first, the way `inspector(_:on:)` above asks, and a WebKit without
/// them leaves the tab heard rather than falling over.
enum Muter {
    /// `_mediaMutedState` is a bitmask. Its low bit is the page's own
    /// sound, the only one a tab's speaker should touch: the others are the
    /// camera and the microphone, someone else's to turn off.
    static func set(_ muted: Bool, on web: WKWebView) {
        let get = NSSelectorFromString("_mediaMutedState")
        let set = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: get), web.responds(to: set) else { return }
        typealias Read = @convention(c) (AnyObject, Selector) -> UInt
        typealias Write = @convention(c) (AnyObject, Selector, UInt) -> Void
        let state = unsafeBitCast(web.method(for: get), to: Read.self)(web, get)
        unsafeBitCast(web.method(for: set), to: Write.self)(web, set, muted ? state | 1 : state & ~UInt(1))
    }
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is — a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var web: PageView {
        if let built { return built }
        let view = build()
        built = view
        return view
    }
    /// The web view if there is one yet, for the callers that must not be
    /// the reason there is.
    private(set) var built: PageView?
    private var preparedConfiguration: WKWebViewConfiguration?
    private let configurationSpace: UUID
    private let configurationStore: WKWebsiteDataStore?
    private var configuration: WKWebViewConfiguration {
        get {
            if let preparedConfiguration { return preparedConfiguration }
            let prepared = Web.configuration(shy: shy, space: configurationSpace, store: configurationStore)
            preparedConfiguration = prepared
            return prepared
        }
        set { preparedConfiguration = newValue }
    }
    let extensionReturn = ExtensionReturnNavigation()

    /// Whether its page was made with the extension controller in it — every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    @available(macOS 15.4, *)
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { configuration.websiteDataStore }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = delegate
        }
    }
    /// The window whose row holds this tab. Set only through `enter(_:)`.
    private(set) weak var owner: WindowModel?

    /// Called by WindowModel when this tab enters or leaves a row.
    var windowBag = Set<AnyCancellable>()

    func enter(_ window: WindowModel?) {
        guard owner !== window else { return }
        owner = window
        windowBag.removeAll()
        window?.prepare(self)
    }
    /// The stylesheet a page not yet built is to be armed with.
    private var veils = ""
    /// uBO's scriptlets for the page coming in and the frames on it, by
    /// host, filled in as each is navigated to (see the navigation policy).
    private var scriptletHosts: [String: [[String]]] = [:]
    private var scriptletTop: String?
    /// What the blocker did here (see BlockLog).
    let blockLog = BlockLog()
    /// What SearchX's own filters do in the page and its frames, by host (see
    /// PageFilters), and the policies the page itself is given.
    private var pageWork: [String: PageFilters.Work] = [:]
    private var pagePolicies: [String] = []
    private var pageShared = false
    private var workTop: URL?

    @Published private(set) var title = ""
    @Published private(set) var address: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    @Published var failure: String?
    /// How far down the page you are, nought to one.
    let reading = Reading()

    /// True while the page has been stripped back to its article.
    @Published private(set) var reader = false

    /// True while the page's words are in your language (see Translate.swift).
    @Published var translated = false {
        didSet { if !translated { translatedFrom = nil } }
    }
    /// The language they were in.
    var translatedFrom: Locale.Language?

    /// Leaving reading mode reloads rather than putting the old markup back:
    /// restoring the HTML gives you a page that looks right and does nothing,
    /// because every listener the page had was thrown away with it.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard !isBlank else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            web.reload()
            done(true)
            return
        }
        web.evaluateJavaScript(Reader.script) { [weak self] answer, _ in
            let worked = (answer as? String) == "read"
            if worked { self?.reader = true }
            done(worked)
        }
    }

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    @Published var icon: NSImage?

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        let host = address?.host()?.lowercased() ?? ""
        let domain = Vault.registrable(host)
        return domain.first.map { String($0).uppercased() } ?? "•"
    }

    private func adoptIcon() {
        guard let host = address?.host()?.lowercased() else {
            icon = nil
            return
        }
        icon = Favicons.shared.cached(host)
    }

    /// True while the caret is in something on the page that takes typing.
    @Published var typing = false
    /// True while the page has taken over the screen.
    @Published var immersed = false

    /// True while this tab's page is out in the little window.
    @Published var floating = false

    /// A sideways swipe in progress, for the drop that shows it.
    let pulling = Pulling()

    /// What a site opens at until you zoom it yourself: Settings › General ›
    /// Page zoom. Read from the file, not from the one object the window holds.
    static var defaultZoom: CGFloat {
        CGFloat(Store.settings.object(forKey: "pageZoom") as? Double ?? 1)
    }

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it. A site at the
    /// size every site starts at keeps nothing, and follows that size.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        if abs(zoom - Tab.defaultZoom) < 0.01 {
            Store.settings.removeObject(forKey: "zoom." + host)
        } else {
            Store.settings.set(Double(zoom), forKey: "zoom." + host)
        }
    }

    func applyRememberedZoom() {
        guard let host = address?.host() else { return }
        let kept = (Store.settings.object(forKey: "zoom." + host) as? Double).map { CGFloat($0) }
            ?? Tab.defaultZoom
        guard abs(kept - web.pageZoom) > 0.004 else { return }
        web.pageZoom = kept
        zoom = kept
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    @Published private(set) var zoom: CGFloat = 1

    var onZoom: ((Tab, CGFloat) -> Void)?
    /// The resolved address under the pointer, or nil when it leaves a link.
    var onLink: ((Tab, String?) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    @Published var noisy = false
    /// Silenced by hand from its speaker or its menu: the page plays on and
    /// is not heard. WebKit keeps the mute on the view from one page to the
    /// next, so it is only set again on a view built new, as a sleeping tab
    /// wakes (see build()).
    @Published var muted = false

    /// Not `web`: a tab asleep is muted without being woken, and hears of
    /// it when its page is built again.
    func toggleMute() {
        muted.toggle()
        if let built { Muter.set(muted, on: built) }
    }

    /// What the page hands back when you point at something and click it.
    var onPick: ((Tab, String, String, String) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left.
    var onField: ((Tab, CGRect?) -> Void)?
    /// The site the sign-in was sent from — not the one it landed on —
    /// then the name and the password, and whether that page came over
    /// plain http.
    var onCredentials: ((Tab, String, String, String, Bool) -> Void)?
    var onPickEnd: ((Tab) -> Void)?
    var onPickTrouble: ((Tab, String) -> Void)?
    var captureDestination: ElementCapture.Destination?
    var capturePicked: ((Tab, CGRect) -> Void)?
    var captureCancelled: ((Tab) -> Void)?
    var captureFailed: ((Tab, String) -> Void)?
    /// Right-click landed on an image. WebKit's own menu offers to copy or
    /// download it and then, on at least some sites, does neither — see
    /// ImageMenu.swift for why this is built rather than patched.
    var onImageMenu: ((Tab, URL, WKFrameInfo, Bool) -> Void)?
    var searchName: (() -> String?)?
    var onSearch: ((Tab, String) -> Void)?
    /// "Add to Search" was pressed on the Chrome Web Store page this tab shows.
    var onStoreAdd: ((Tab) -> Void)?
    /// The middle button was let go over a link. The browser opens it in a
    /// tab of its own beside this one, without leaving the page you are on.
    var onMiddleClick: ((Tab, URL) -> Void)?
    /// A translated page added or changed some text (see Translate.swift).
    var onMoreToTranslate: ((Tab, Translate.Found) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps each kind of view to its own pages, so the tab has to be
    /// swapped for one built for the address (see Browser.replace).
    var onCross: ((Tab, URL) -> Void)?
    /// The extension whose store page has its own "Add to Search" button in
    /// place — so the bar at the bottom of the window doesn't offer it twice.
    @Published var storePlaced: String?

    private let relay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    private let images = ImageRelay()
    private let shop = StoreRelay()
    private let middles = MiddleRelay()
    private let intents = IntentRelay()
    /// The last trusted press on the page, what it landed on (see Intent).
    var press: Intent.Press?
    /// When this tab last opened a window, for the tab-under rule.
    var openedWindowAt: TimeInterval?
    /// A blank window opened from something that did not ask for one, as its
    /// opener's site: closed if its first trip goes elsewhere.
    var watchedFrom: String?
    /// When the blocker last said what it stopped here.
    var lastStopNotice: TimeInterval?
    private let translations = TranslateRelay()
    private let shots = ShotRelay()
    private let passkeyRelay = PasskeyRelay()
    private let hovered = HoveredLink()
    private let ears = AudioWatch()

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    let bench: Bool

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    var opener: Tab.ID?

    /// The tab whose page sent you here — a link opened into a tab of its
    /// own, by the page or by ⌘ or the middle button — while it is still
    /// open. Back from this tab's first page closes it and returns there,
    /// the way a link opened on a phone does.
    @Published var returnTo: Tab.ID? {
        didSet { built?.leave = leave }
    }
    /// Asked to close this tab for the one it returns to.
    var onReturn: ((Tab) -> Void)?

    /// Whether back does anything: a page to go back to, or a tab to return to.
    var canGoBackOrReturn: Bool { canGoBack || returnTo != nil }

    /// Back past the first page, for the page's view: nil when there is
    /// nowhere to return to.
    private var leave: (() -> Void)? {
        guard returnTo != nil else { return nil }
        return { [weak self] in
            guard let self else { return }
            onReturn?(self)
        }
    }

    /// A window a page opened at a size of its own, or without a toolbar:
    /// a pop-up, not a link. It is named by its site, never by its title — a
    /// page that opens one can call it anything, "Sign in with Google" over
    /// somebody else's address included.
    var popup = false

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter — which
    /// is all you need for the five or six pages you keep open all day.
    @Published var pin: String?
    var pinHome: URL?
    /// Which pin this is, the same in every window (see Pins.swift).
    var pinID: UUID?

    /// The group that holds this ordinary tab in the sidebar.
    @Published var groupID: UUID?
    /// The container whose cookies and sign-ins it uses, if any (see
    /// Containers.swift). Changed through enter(container:) once it has a page.
    @Published var container: UUID?

    /// A name you gave it, in place of whatever the page calls itself. It
    /// stays through navigation: a tab you named is a tab you are keeping for
    /// a job, not for a page.
    @Published var name: String?

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    private(set) var touched = Date()

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL?

    /// For a tab put to sleep for not being looked at: the page's own history
    /// — the back list, the page, where it was scrolled to — handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    private var memory: Any?
    /// The last picture of that page, compressed, for the moment it wakes.
    private var picture: Data?
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    @Published private(set) var cover: NSImage?
    /// The page as it last looked, small, for the ⌃Tab switcher (see
    /// Switcher.swift). Kept through sleep, so a tab that gave its view back
    /// is still pictured.
    @Published private(set) var thumb: NSImage?
    private var thumbCapture = 0
    private var thumbInFlight = false

    private var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil }
    /// Showing Speed Dial, which is drawn natively rather than by the web view.
    var onDial: Bool { address.map(SpeedDial.at) == true }
    /// A page of the web's in the tab: something to copy the address of,
    /// bookmark, find in, print or pin. Speed Dial's marker is none of those.
    var showsPage: Bool { !isBlank && !onDial }
    /// Set when the browser itself sends this tab to Speed Dial, and taken
    /// by the navigation policy: a page's own way there has no ticket.
    var dialing = false

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if let name, !name.isEmpty { return name }
        if onDial { return "Speed Dial" }
        if popup, let host = address?.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab".saidNow
    }

    init(shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil,
         space: UUID? = nil, store: WKWebsiteDataStore? = nil) {
        self.shy = shy
        self.bench = bench
        preparedConfiguration = configuration
        // A lazy tab must retain its original Space and private cookie jar,
        // even if another window or Space is selected before its first load.
        configurationSpace = space ?? Spaces.current
        configurationStore = store
    }

    private func build() -> PageView {
        // Here rather than in Web.configuration: a tab's configuration is
        // made with the tab, often long before its page, and a site or an
        // extension can hand over one of its own.
        FrameRate.apply(to: configuration.preferences)
        let web = PageView(frame: .zero, configuration: configuration)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a drop.
        web.allowsBackForwardNavigationGestures = false
        Swipe.calm(web)
        web.onPull = { [weak self] pull in self?.pulling.pull = pull }
        web.leave = leave
        web.onTouch = { [weak self] in
            guard let self, self.built?.unpainted == false else { return }
            self.uncover()
        }
        web.searchName = { [weak self] in self?.searchName?() }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.holdForFirstFrame()
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Safari's Develop menu can reach it, and so can the page's own
        // Inspect Element — a configuration handed over by an opener included.
        if #available(macOS 13.3, *) { web.isInspectable = true }
        Web.pages.add(web)
        Web.inspector(web.configuration.preferences)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate

        // Each name is cleared before being claimed — registering one twice is
        // a hard crash rather than an error. A tab opened by a link gets a
        // controller of its own (Browser's createWebViewWith), never its
        // opener's.
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.add(relay, contentWorld: Web.world, name: ScrollRelay.name)
        controller.add(veils_, contentWorld: Web.world, name: VeilRelay.name)
        controller.add(images, contentWorld: Web.world, name: ImageRelay.name)
        controller.add(shop, contentWorld: Web.world, name: StoreRelay.name)
        controller.add(forms, contentWorld: Web.world, name: FormRelay.name)
        controller.addScriptMessageHandler(passkeyRelay, contentWorld: Web.world, name: PasskeyRelay.name)
        hovered.tab = self
        controller.add(hovered, contentWorld: .defaultClient, name: HoveredLink.name)
        controller.add(middles, contentWorld: Web.world, name: MiddleRelay.name)
        controller.add(intents, contentWorld: Web.world, name: Intent.name)
        controller.add(translations, contentWorld: Web.world, name: TranslateRelay.name)
        controller.add(shots, contentWorld: Web.world, name: ShotRelay.name)
        Shield.shared.protect(controller)
        built = web
        // A tab muted before it went to sleep wakes muted.
        if muted { Muter.set(true, on: web) }
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.built?.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    let freshHost = fresh.host()?.lowercased()
                    let currentHost = self.address?.host()?.lowercased()
                    let moved = freshHost != currentHost
                    self.address = fresh
                    if moved { self.adoptIcon() }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.built?.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.built?.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.built?.canGoForward ?? false }
            },
        ]

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        images.tab = self
        shop.tab = self
        middles.tab = self
        intents.tab = self
        translations.tab = self
        shots.tab = self
        ears.watch(web) { [weak self] on in self?.noisy = on }
        return web
    }

    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - web.pageZoom) > 0.004 else { return }
        web.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        onZoom?(self, wanted)
    }

    func magnify(by factor: CGFloat) { magnify(to: web.pageZoom * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for —
    /// back to the size every site starts at.
    func resetZoom() {
        magnify(to: Tab.defaultZoom)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    func arm(hiding css: String) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: ScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        if AutoScroll.on {
            controller.addUserScript(
                WKUserScript(source: AutoScroll.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Only while Settings says so: off, pages get nothing at all.
        if HoveredLink.on {
            controller.addUserScript(WKUserScript(
                source: HoveredLink.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient
            ))
        }
        // The main frame only: a middle-click on a link inside an ad iframe is
        // that frame's own business, and its link is not this tab's to open.
        controller.addUserScript(
            WKUserScript(source: MiddleRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        // Every frame: what each trusted press landed on, for the judgment
        // of the windows and trips that follow it (see Intent).
        controller.addUserScript(
            WKUserScript(source: Intent.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Only inside an identity provider's sign-in frame (see SignInPrompts).
        controller.addUserScript(
            WKUserScript(source: SignInPrompts.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Passkeys, when on, stand in the page's own world — they replace the
        // page's functions — and reach SearchX through a bridge in its own.
        // The bridge stays either way: an extension's page script can carry
        // the patch (see Passkeys.swift and ExtensionShims.passkeys).
        if FormRelay.passkeysOffered || PasskeyRelay.extensionKeeps {
            controller.addUserScript(
                WKUserScript(source: FormRelay.passkeysOffered ? PasskeyRelay.page : PasskeyRelay.pageForKeeper,
                             injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        controller.addUserScript(
            WKUserScript(source: PasskeyRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // uBO's scriptlets stand in the page's own world before its scripts:
        // they replace the functions its pop-ups and anti-adblock use.
        if let scriptlets = Scriptlets.source(byHost: scriptletHosts) {
            controller.addUserScript(
                WKUserScript(source: scriptlets, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        // SearchX's own filters (see PageFilters): procedural ones and
        // redirect stand-ins in its own world, the page's policies before
        // its head, and response rewriting in the page's world — each only
        // where a rule asks.
        if let procedural = PageFilters.proceduralSource(byHost: pageWork.mapValues(\.procedural)) {
            controller.addUserScript(
                WKUserScript(source: procedural, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
            )
        }
        if let policies = PageFilters.cspSource(pagePolicies) {
            controller.addUserScript(
                WKUserScript(source: policies, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
            )
        }
        if let redirects = PageFilters.redirectSource(byHost: pageWork.mapValues(\.redirect),
                                                      shared: pageShared ? Shield.shared.sharedRedirects : []) {
            controller.addUserScript(
                WKUserScript(source: redirects, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
            )
        }
        if let replacing = PageFilters.replaceSource(byHost: pageWork.mapValues(\.replace)) {
            controller.addUserScript(
                WKUserScript(source: replacing, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateInSearch(Veiling.style(css))
    }

    /// A page is about to load: its own scriptlets, and none of the last
    /// page's frames'. Call before `arm`.
    func scriptlets(forPage url: URL) {
        let host = url.host()?.lowercased() ?? ""
        scriptletTop = host
        scriptletHosts = host.isEmpty ? [:] : [host: Shield.shared.scriptlets(for: host, top: host)]
        workTop = url
        let work = Shield.shared.work(for: url, top: nil)
        pageWork = host.isEmpty || work.isEmpty ? [:] : [host: work]
        pagePolicies = work.csp
        pageShared = work.shared
    }

    /// A frame on the page is about to load: its scriptlets join the page's,
    /// and the page's scripts are armed again when that adds any.
    func scriptlets(forFrame url: URL) {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return }
        var changed = false
        if pageWork[host] == nil {
            let work = Shield.shared.work(for: url, top: workTop)
            if !work.isEmpty { pageWork[host] = work; changed = true }
        }
        guard scriptletHosts[host] == nil else {
            if changed { arm(hiding: veils) }
            return
        }
        let calls = Shield.shared.scriptlets(for: host, top: scriptletTop)
        scriptletHosts[host] = calls
        if !calls.isEmpty || changed { arm(hiding: veils) }
    }

    /// The pointing mode, handed to the page only when it is asked for:
    /// parsed on every page load, it was 8 KB nobody used on most of them.
    /// Every use brings it along; a page that has it already keeps its own.
    func startPicking() { web.evaluateInSearch(Veiling.picker + ";window.__officeVeil && window.__officeVeil.on()") }
    func stopPicking() { web.evaluateInSearch("window.__officeVeil && window.__officeVeil.off()") }

    /// A scroll reports this once a frame; only a real change is worth the redraw.
    func setTyping(_ typing: Bool) { if self.typing != typing { self.typing = typing } }

    func foundSignIn() { onSignIn?(self) }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    func fieldFocused(_ rect: CGRect?) {
        guard let rect else {
            onField?(self, nil)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ))
    }

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    private var sent: (host: String, user: String, password: String, clear: Bool, at: Date)?

    func sentSignIn(user: String, password: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = address?.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        sent = (bare, user, password, address?.scheme?.lowercased() == "http", Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        web.evaluateInSearch("!!(window.__officeForms && window.__officeForms.hasPassword())") { [weak self] still in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password, sent.clear)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` for the one case worth saying
    /// something about: the sign-in fields that were there a moment ago,
    /// when this was offered, are gone by the time it actually runs.
    func fill(user: String, password: String, done: ((Bool) -> Void)? = nil) {
        web.evaluateInSearch(
            "window.__officeForms && window.__officeForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateInSearch(
            Veiling.picker + ";window.__officeVeil && window.__officeVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateInSearch("window.__officeVeil && window.__officeVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    /// The relay sends only changes visible in the hundred-step reading fill.
    func scrolled(to y: Double, of ceiling: Double) {
        guard y.isFinite, ceiling.isFinite else { return }
        let fraction = ceiling > 0 ? (min(1, max(0, y / ceiling)) * 100).rounded() / 100 : 0
        if fraction != reading.through { reading.through = fraction }
    }

    func go(to url: URL) {
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened with window.open is built from that
        // extension's configuration too. A tab with no page yet was just
        // built for where it is going, so it goes there.
        if let onCross, let here = built?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        title = ""
        failure = nil
        // Somewhere Search itself sent the tab: nothing the page did before
        // counts against where it goes next (see Intent).
        press = nil
        openedWindowAt = nil
        watchedFrom = nil
        reading.through = 0
        reader = false
        translated = false
        typing = false
        immersed = false
        // Sent somewhere new, a sleeping tab is simply awake again — with
        // nothing of where it was before to bring back.
        pending = nil
        memory = nil
        picture = nil
        cover = nil
        adoptIcon()
        // Speed Dial is drawn natively and needs no web view. In an existing web
        // view the local marker becomes a real back/forward history entry.
        // The one navigation to it a page didn't start: see Browser's policy.
        if SpeedDial.at(url) { dialing = true }
        if !SpeedDial.at(url) || built != nil { web.open(url) }
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String, name: String? = nil) {
        address = url
        self.title = title
        self.name = name
        pending = SpeedDial.at(url) ? nil : url
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    func rest() {
        guard let url = (owner?.profile.prefs.pinsReturnHome == true ? pinHome : nil) ?? address else { return }
        address = url
        pending = url
        memory = nil
        picture = nil
        reading.through = 0
        noisy = false
        stale = false
        pulling.pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache — alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?) {
        guard let url = address, let built else { return }
        memory = built.interactionState
        self.picture = picture
        pending = url
        stale = false
        pulling.pull = nil
        discard()
    }

    /// A page moved to another space must use that space's cookies. WebKit
    /// binds the store when the view is made, so keep its restorable state
    /// and build the view again with the destination's store.
    func rehome(in space: UUID) {
        // A tab in a container keeps the container's sign-ins in any Space.
        guard !shy, !bench, container == nil, store !== Spaces.store(for: space) else { return }
        if let built {
            memory = built.isLoading ? nil : built.interactionState
            pending = address ?? built.url
            picture = nil
            cover = nil
            discard()
        }
        configuration = Web.configuration(space: space)
    }

    /// Settings › Videos wait for a click, changed: the page's next view is
    /// made the new way. One already made keeps what it was made with —
    /// WebKit fixes it then — until the tab closes or sleeps.
    func playbackChanged() {
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
    }

    /// Into a container's store, or out to its Space's, the same way a page
    /// moves between Spaces: what it can bring back is kept, and the view is
    /// built again, with the other store, the next time it is shown.
    func enter(container id: UUID?) {
        guard !shy, !bench, container != id else { return }
        container = id
        if let built {
            memory = built.isLoading ? nil : built.interactionState
            pending = address ?? built.url
            picture = nil
            cover = nil
            discard()
        }
        let space = owner?.spaceID ?? Spaces.current
        configuration = Web.configuration(space: space, store: id.map(Containers.store(for:)))
    }

    /// Whether the page holds something typed and not yet sent — a draft, a
    /// half-filled form. A page that can't answer is treated as holding
    /// nothing: a PDF, an image, a page whose process has already gone.
    func unsaved(_ done: @escaping (Bool) -> Void) {
        guard let built else { return done(false) }
        built.evaluateInSearch(
            "!!(window.__officeForms && window.__officeForms.unsaved && window.__officeForms.unsaved())"
        ) { value in
            MainActor.assumeIsolated { done((value as? Bool) == true) }
        }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen — every tab but the one you are
    /// on — can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard let built else { return done(nil) }
        built.takeSnapshot(with: nil) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
    }

    /// A fresh `thumb`, when there is a page to picture. Drawn by the page's
    /// own process, off screen or not, at a width a card needs and no more.
    /// A page opened behind the one on screen has never been laid out and
    /// pictures as nothing; given the stage's size first, it can be.
    func capture(stage: CGSize? = nil) {
        guard let built, !isBlank, !thumbInFlight else { return }
        if built.window == nil, built.frame.isEmpty, let stage, !stage.equalTo(.zero) {
            built.frame.size = stage
        }
        let capture = thumbCapture
        thumbInFlight = true
        let small = WKSnapshotConfiguration()
        small.snapshotWidth = 320
        #if DEBUG
        NativeProbe.snapshotRequests += 1
        #endif
        built.takeSnapshot(with: small) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbInFlight = false
                guard let image, self.thumbCapture == capture else { return }
                self.thumb = image
            }
        }
    }

    func discardThumbnail() {
        thumbCapture += 1
        thumb = nil
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.evaluateInSearch("window.__officeStore && window.__officeStore.state(\(json))")
    }

    /// The picture comes off the moment there is something better under it
    /// — the page, painted — or you reach for the page yourself.
    func uncover(after delay: TimeInterval = 0) {
        guard let shown = cover else { return }
        guard delay > 0 else {
            #if DEBUG
            NativeProbe.navigation("uncover", tab: self)
            #endif
            cover = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak shown] in
            guard let self, let shown, self.cover === shown, self.built?.unpainted != true else { return }
            // Legacy WebKit without a first-frame signal starts opaque.
            // A supported view still awaiting paint must keep its picture.
            self.uncover()
        }
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil, attached: Bool = false, extensionsReady: Bool = false) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        let view = web
        if view.window == nil, !attached {
            view.afterAttachment { [weak self, weak view] in
                guard let self, let view, self.built === view, self.address == url, self.pending == nil else { return }
                self.loadAndVerify(url, state: state, attached: true, extensionsReady: extensionsReady)
            }
            return
        }
        if #available(macOS 15.4, *), !extensionsReady, carriesExtensions {
            Extensions.shared.afterStartup { [weak self, weak view] in
                guard let self, let view, self.built === view,
                      self.address == url, self.pending == nil else { return }
                self.loadAndVerify(url, state: state, attached: attached, extensionsReady: true)
            }
            return
        }
        // A tab that slept has its own history to go back to — the page, its
        // back list and its scroll position, in one. Anything else starts
        // from the address.
        if let state {
            view.interactionState = state
        } else {
            view.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.built === view, self.address == url, self.pending == nil else { return }
            guard built?.url?.absoluteString != "about:blank" else {
                web.open(url)
                return
            }
            web.evaluateJavaScript("document.readyState") { [weak self] _, error in
                MainActor.assumeIsolated {
                    guard let self, self.built === view, self.address == url, self.pending == nil,
                          let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    self.web.open(url)
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        guard !onDial else { return }
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard !isBlank, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.open(address)
            return
        }
        web.evaluateJavaScript("document.readyState") { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        #if DEBUG
        NativeProbe.navigation("wake", tab: self)
        #endif
        pending = nil
        if SpeedDial.at(url) { return true }
        failure = nil
        reading.through = 0
        reader = false
        translated = false
        typing = false
        immersed = false
        let state = memory
        memory = nil
        if let picture, let image = NSImage(data: picture) {
            cover = image
            // Whatever happens to the page, the picture doesn't outstay it.
            uncover(after: 4)
        }
        picture = nil
        loadAndVerify(url, state: state)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    /// A new tab again: where it was going turned out to be a file, not a
    /// page, and an address kept for it downloads the file once more
    /// whenever the tab is opened (see Browser.dropEmpty).
    func forget() {
        address = nil
        icon = nil
    }

    func touch() { touched = Date() }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// A view that has lost its document is given the address back instead:
    /// there is nothing else for it to reload.
    func reload(fromOrigin: Bool = false) {
        guard !onDial else { return }
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake() else { return }
        reader = false
        if hollow, let address {
            web.open(address)
        } else if fromOrigin {
            web.reloadFromOrigin()
        } else {
            web.reload()
        }
    }
    func stop() { web.stopLoading() }
    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() { web.goBackOrLeave() }
    func forward() { web.goForward() }

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        enter(nil)
        onZoom = nil
        onLink = nil
        onPick = nil
        onPickEnd = nil
        captureDestination = nil
        capturePicked = nil
        captureCancelled = nil
        captureFailed = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        discard()
    }

    /// The view and everything listening to it, gone — timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    private func discard() {
        captureDestination = nil
        watch = []
        ears.stop()
        guard let web = built else { return }
        built = nil
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.removeAllUserScripts()
        web.onPull = nil
        web.onTouch = nil
        web.searchName = nil
        web.onSearch = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// The middle button on a link, as the page reports it.
///
/// A middle-click on a link opens it beside the tab you are on, in every
/// other browser, and WebKit leaves that to the browser: it tells the page
/// about the click and hands this app no navigation action for it at all, the
/// way it does for ⌘-click (and where it does report a button, it answers
/// with a mask — 1 left, 2 right, 4 middle — so a check for the middle button
/// as 2 would catch the right one). The page can see the click, though, so
/// the page is asked: its own `auxclick` for the middle button names the link
/// under the pointer, and from there it is an ordinary address to open.
///
/// Only the main frame, only a real link to somewhere this browser
/// would go, and only the middle button. A page's own handler runs as it
/// always did — this says where to, and changes nothing about the click.
///
/// Two things are checked before anything is opened. The event has to carry a
/// real click: a synthesized `auxclick` is not one, so a page that dispatches
/// its own does not get a tab per dispatch. And it has to be unclaimed — a
/// click a page has called `preventDefault` on is a click it has dealt with,
/// which is why this listens as the event comes back up rather than on the
/// way down, where nothing has answered yet.
final class MiddleRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeMiddle"

    weak var tab: Tab?

    static let watch = """
    (function () {
      if (window.__officeMiddle) return;
      window.__officeMiddle = true;
      document.addEventListener('auxclick', function (e) {
        if (e.button !== 1 || !e.isTrusted || e.defaultPrevented) return;
        // The path, not the parents: a link inside an open shadow root is
        // on it too. An <area> of an image map is a link, and so is an SVG
        // <a>, whose href is an object that holds the address as written.
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          var tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag !== 'a' && tag !== 'area') continue;
          var href = el.href;
          if (href && typeof href === 'object') {
            try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
          }
          if (!href) continue;
          window.webkit.messageHandlers.officeMiddle.postMessage({ href: href });
          return;
        }
      });
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onMiddleClick?(tab, url)
        }
    }
}

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    /// A parked test window (SEARCH_PARK) never becomes key, since the app
    /// isn't brought forward over whoever is working; AppKit then spends a
    /// page's first press on making it key and the page never sees it. Only
    /// there does the page take that press as a click.
    private static let parked = Store.testing && ProcessInfo.processInfo.environment["SEARCH_PARK"] != nil
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PageView.parked || super.acceptsFirstMouse(for: event)
    }

    /// What extensions added to the right-click menu, at the end of it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit names it for a window, but a new window's page arrives here
        // as a new tab (Browser's createWebViewWith), so it says so.
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            item.title = "Open Link in New Tab"
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
           let name = searchName?() {
            webSearch = (item.target, item.action)
            selection = nil
            evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            item.title = "Search with \(name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        }
        guard #available(macOS 15.4, *),
              let tab = Extensions.shared.browser?.allTabs.first(where: { $0.built === self })
        else { return }
        let items = Extensions.shared.menuItems(for: tab)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach { menu.addItem($0) }
    }

    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    private var selection: String?

    /// The words selected where the right-click was, read when the menu
    /// opens. The selection of a text field is its own, not the page's, so a
    /// field with the caret in it is asked first; a frame with the caret in it
    /// is looked into when it is of the same site. One of another site can't
    /// be, and gives nothing, so WebKit's own action takes the click, as it
    /// always did. A password field gives nothing either.
    static let selected = """
    (function read(doc) {
      var el = doc.activeElement;
      if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
        try { return el.contentDocument ? read(el.contentDocument) : ''; } catch (e) { return ''; }
      }
      if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
        try {
          var from = el.selectionStart, to = el.selectionEnd;
          if (typeof from === 'number' && typeof to === 'number' && to > from) return el.value.slice(from, to);
        } catch (e) {}
      }
      if (el && el.tagName === 'INPUT' && el.type === 'password') return '';
      var s = doc.getSelection();
      return s ? s.toString() : '';
    })(document)
    """
    private var webSearch: (target: AnyObject?, action: Selector?) = (nil, nil)

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        guard let selection, !selection.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    /// Back from the first page, when the tab was opened from another to
    /// return to (see Tab.returnTo). Every way back goes through here.
    var leave: (() -> Void)?

    var canGoBackOrLeave: Bool { canGoBack || leave != nil }

    func goBackOrLeave() {
        if canGoBack { goBack() } else { leave?() }
    }
    /// Told the moment the page is reached for — a click, a scroll — so the
    /// picture of a tab waking up never stands between you and the page.
    var onTouch: (() -> Void)?

    /// A mouse wheel's steps as a glide (see WheelGlide).
    private lazy var glide = WheelGlide(view: self) { [weak self] event in self?.page(event) }

    /// A glide's events, straight to the page, past the swipe below.
    private func page(_ event: NSEvent) {
        super.scrollWheel(with: event)
    }

    private var attachment: (id: UUID, load: () -> Void)?

    /// A foreground wake loads on attachment instead of polling every 20 ms.
    /// Background callers still get the previous one-second fallback.
    func afterAttachment(_ load: @escaping () -> Void) {
        let id = UUID()
        attachment = (id, load)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finishAttachment(id, allowDetached: true)
        }
    }

    private func finishAttachment(_ id: UUID, allowDetached: Bool = false) {
        guard let pending = attachment, pending.id == id, window != nil || allowDetached else { return }
        attachment = nil
        pending.load()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { glide.stop() }
        else if let id = attachment?.id {
            // Leave AppKit's view insertion before starting WebKit navigation.
            DispatchQueue.main.async { [weak self] in self?.finishAttachment(id) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        onTouch?()
        super.mouseDown(with: event)
    }

    /// The side buttons a mouse has for back and forward — button 3 and 4.
    /// No standard hands out that numbering; it's the X11 button order
    /// (0 left, 1 right, 2 middle, 3 back, 4 forward) that most mouse
    /// drivers settled on regardless, so it's what a mouse's own firmware
    /// is tuned to send.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBackOrLeave: goBackOrLeave()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Logi Options+ sends its Back/Forward buttons as a swipe, not buttons
    /// 3 and 4 — deltaX 1 for back, -1 for forward, as Safari reads it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBackOrLeave { goBackOrLeave() }
        else if event.deltaX < 0, canGoForward { goForward() }
        else { super.swipe(with: event) }
    }

    // MARK: - keys the page didn't use

    /// The last key handed to the page. WebKit sends a key the page didn't
    /// use back up the responder chain — the same event, a second time —
    /// where nothing takes it and macOS plays its "can't do that" sound.
    /// Editors that put the text in themselves (X's reply box, anything built
    /// on Draft.js) leave WebKit thinking their keys unused, so typing into
    /// them beeped. Safari keeps those quiet, and so does this view. The
    /// app's own shortcuts never get this far: its key monitor takes them
    /// before the page sees the key.
    private var handed: NSEvent?
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let handed, PageView.same(handed, event) {
            self.handed = nil
            PageView.quieted += 1
            return
        }
        handed = event
        super.keyDown(with: event)
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - the first frame

    /// A web view that has never drawn is opaque white. In a dark window that
    /// is a flash of it between a link that opens a tab and the page arriving,
    /// so a fresh view starts unseen, over the window's own ground, and comes
    /// in once WebKit says there is something on it worth seeing.
    private(set) var unpainted = false

    /// WebKit says when the first frame is only through names outside the
    /// public framework, so it is asked whether it answers to them first. One
    /// that doesn't gets a view shown straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, PageView.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    /// In, quickly: the page is there, and the fade only covers the frame
    /// between WebKit laying it out and putting it on screen.
    func showFirstFrame(animated: Bool = true) {
        guard unpainted else { return }
        unpainted = false
        guard animated, !Motion.reduced else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout — the moment
    /// Safari takes down the picture it shows while a page comes back.
    static let firstFrame: UInt = 1 << 1

    // MARK: - two fingers sideways

    /// One gesture, from the fingers going down to their lifting.
    private struct Gesture {
        enum Axis { case across, down }

        /// How far the fingers have gone, rightwards positive.
        var sideways: CGFloat = 0
        /// Both ways at once, only until the axis is decided.
        var gathered = CGSize.zero
        var axis: Axis?
        /// Which way it set off, decided once and kept. Turning round takes
        /// the drop back in; it never becomes the other drop.
        var back = true
        /// The page's word on whether this swipe is its own. Nil until it says.
        var free: Bool?
        var asked: Date?
        /// Already went somewhere, or was refused: nothing more this gesture.
        var spent = false
        var armed = false
        var showing = false

        /// Only the distance in the direction it set off in. Past the origin
        /// the other way is just nought.
        var travel: CGFloat { max(0, back ? sideways : -sideways) }
    }

    private var gesture = Gesture()
    /// The last drop is on its way out with the page.
    private var going = false
    /// Counts gestures and goings, so a late clean-up knows it is stale.
    private var pulls = 0
    /// Armed and held there: in a moment the disc becomes the list of pages
    /// that way, and moving the fingers up or down picks one (as in Dia).
    private var holding: DispatchWorkItem?
    private var stops: [Stop]?
    private var items: [WKBackForwardListItem] = []
    private var picked = 0
    /// How far the fingers have gone up (or down, below nought) since the
    /// last step through the list.
    private var climbed: CGFloat = 0
    /// Settings › General › Hold a swipe to pick from history. Off unless
    /// asked for; off, a held swipe is a swipe like any other.
    static var holdsHistory = false
    /// How long armed before the list, and how far up or down a step is.
    private static let hold: TimeInterval = 0.45
    private static let step: CGFloat = 22

    /// How far the fingers travel before letting go means it. It was 110,
    /// and going back took a long reach across the trackpad — "too far",
    /// people said; Safari goes on less. It is also where the drop comes
    /// away from the edge (see Drop in Stage.swift): its width, and the
    /// short neck the edge holds on by.
    static let arm: CGFloat = 82
    /// A quick flick goes too, short of that, as it does in Safari: at least
    /// this far, within `flickTime` of setting off.
    private static let flick: CGFloat = 30
    private static let flickTime: TimeInterval = 0.25
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    // MARK: - two fingers together

    // The pinch itself is WebKit's own: during the gesture it scales the
    // rendered layers on the GPU around the fingers and only lays the page
    // out again once they lift. Doing the same from here — a real change of
    // scale on every event — was measured at a few frames a second, and the
    // public `setMagnification(_:centeredAt:)` ignores its point and resets
    // the scroll besides, so the pinch stays with WebKit. What is handled
    // here is the one-shot gesture WebKit does not do well on its own.

    /// Two fingers, tapped twice: the block under them fills the width, the
    /// way Safari's smart zoom does; tapped again, the page is back at its
    /// own size with the same spot still under the fingers. The page picks
    /// the block — it is the only one that knows where a column ends.
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification else {
            super.smartMagnify(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let js = PageView.smart(x: point.x, y: point.y, scale: magnification, width: bounds.width)
        evaluateJavaScript(js) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let text = value as? String, let data = text.data(using: .utf8),
                      let zoom = try? JSONDecoder().decode(SmartZoom.self, from: data)
                else { return }
                self.setMagnification(zoom.scale, centeredAt: point)
                self.evaluateJavaScript("window.scrollTo(\(zoom.x), \(zoom.y))")
            }
        }
    }

    private struct SmartZoom: Decodable {
        var scale: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// Where a smart zoom should land: the scale that fits the block under
    /// the fingers to the width, and the scroll that puts it there with the
    /// tapped spot at the same height. Zoomed in already, it is the way back.
    /// Scroll positions are CSS pixels of the whole page — `window.scrollTo`
    /// moves the magnified view here even on a page whose own overflow is
    /// hidden — and they are read before the scale changes, since the
    /// change itself sends the scroll to the corner.
    static func smart(x: CGFloat, y: CGFloat, scale: CGFloat, width: CGFloat) -> String {
        """
        (function (x, y, s, W) {
          var ox = window.scrollX, oy = window.scrollY;
          var cx = x / s, cy = y / s;
          if (s > 1.05) {
            return JSON.stringify({ scale: 1, x: Math.max(0, ox + cx - x), y: Math.max(0, oy + cy - y) });
          }
          var el = document.elementFromPoint(cx, cy);
          if (!el) return null;
          // The innermost block wide enough to be a column of something — a
          // paragraph's column, a card, a feed — rather than the whole page's
          // layout, which is what walking up to a wide ancestor finds.
          var vw = W / s, best = null, enough = Math.max(240, vw * 0.2);
          for (var e = el; e && e !== document.documentElement; e = e.parentElement) {
            var r = e.getBoundingClientRect();
            if (r.width < 80 || r.height < 16) continue;
            var d = getComputedStyle(e).display;
            if (d === 'inline' || d === 'contents') continue;
            if (!best) best = r;
            if (r.width >= enough) { best = r; break; }
          }
          if (!best) best = el.getBoundingClientRect();
          var pad = 12;
          var target = Math.max(1, Math.min(3, W / (best.width + 2 * pad)));
          if (target < 1.15) target = Math.min(3, s * 2);
          return JSON.stringify({
            scale: target,
            x: Math.max(0, ox + best.left - pad),
            y: Math.max(0, oy + cy - y / target)
          });
        })(\(x), \(y), \(scale), \(width))
        """
    }

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        if stops == nil, glide.take(event) { return }
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken — except while its list is open,
        // when up and down are picking a page, not scrolling this one.
        if stops == nil { super.scrollWheel(with: event) }
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            gesture = Gesture()
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
            // A drop still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !gesture.spent else { return }
            gesture.sideways += PageView.fingers(event)
            if gesture.axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gesture.gathered.width += abs(event.scrollingDeltaX)
                gesture.gathered.height += abs(event.scrollingDeltaY)
                let gathered = gesture.gathered
                guard gathered.width + gathered.height > 6 else { return }
                gesture.axis = gathered.width > gathered.height * 1.3 ? .across : .down
                gesture.back = gesture.sideways > 0
                // Up and down, or nowhere to go that way: nothing to show,
                // and nothing more to read from this gesture.
                if gesture.axis == .down || (gesture.back ? !canGoBackOrLeave : !canGoForward) {
                    gesture.spent = true
                    return
                }
                gesture.asked = Date()
            }
            if stops != nil { climb(event) }
            tell()
        case .ended:
            release()
        case .cancelled:
            gesture.spent = true
            settle(nil)
        default:
            break
        }
    }

    /// How far the fingers themselves went, rightwards positive. The scroll
    /// delta is the content's movement, which only matches the fingers with
    /// natural scrolling on; with it off, a swipe to the right read as
    /// forward. Safari goes back on a swipe to the right either way.
    static func fingers(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }

    /// The page has said whether the swipe would scroll something. Only
    /// its first word counts: once the drop is out the gesture is the
    /// drop's, and fingers turning back to take it in again would otherwise
    /// be read as a scroll on any page with somewhere to go that way.
    func answer(free yes: Bool) {
        guard gesture.axis != .down, !gesture.spent, gesture.free == nil else { return }
        gesture.free = yes
        if yes { tell() } else { gesture.spent = true }
    }

    private func tell() {
        if gesture.free == nil, let asked = gesture.asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            gesture.free = true
        }
        guard gesture.free == true else { return }

        let travel = gesture.travel
        // Drawn all the way back, the drop goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if gesture.showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if PageView.holdsHistory, stops == nil, armed != gesture.armed {
            holding?.cancel()
            holding = nil
            if armed {
                let hold = DispatchWorkItem { [weak self] in self?.openList() }
                holding = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + PageView.hold, execute: hold)
            }
        }
        if armed != gesture.armed, stops == nil {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        gesture.armed = armed
        settle(Pull(back: gesture.back, travel: gesture.travel, armed: armed, going: false, stops: stops, picked: picked))
    }

    /// Held long enough: the pages that way, nearest to the fingers — at the
    /// bottom going back, at the top going forward — and that one picked.
    private func openList() {
        holding = nil
        guard !gesture.spent, gesture.armed, stops == nil else { return }
        let list = gesture.back ? Array(backForwardList.backList.suffix(8)) : Array(backForwardList.forwardList.prefix(8))
        guard list.count >= 2 else { return }
        items = list
        stops = list.map { Stop(title: $0.title ?? "", url: $0.url) }
        picked = gesture.back ? list.count - 1 : 0
        climbed = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        tell()
    }

    /// Through the list a step at a time, the list sliding with the fingers
    /// under a light that stays put, as in Dia: down brings the row above
    /// under it — further back, or nearer going forward — and up the row
    /// below. With natural scrolling the deltas run with the fingers,
    /// without it against them.
    private func climb(_ event: NSEvent) {
        guard let stops else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        climbed += -sign * event.scrollingDeltaY
        var moved = false
        while climbed >= PageView.step, picked < stops.count - 1 {
            picked += 1
            climbed -= PageView.step
            moved = true
        }
        while climbed <= -PageView.step, picked > 0 {
            picked -= 1
            climbed += PageView.step
            moved = true
        }
        // At either end, the fingers going on further count for nothing.
        climbed = max(-PageView.step, min(PageView.step, climbed))
        if moved { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func release() {
        defer { gesture.spent = true }
        let flicked = gesture.travel >= PageView.flick
            && (gesture.asked.map { Date().timeIntervalSince($0) <= PageView.flickTime } ?? false)
        guard !gesture.spent, gesture.free == true, gesture.armed || flicked || stops != nil else {
            settle(nil)
            return
        }
        going = true
        settle(Pull(back: gesture.back, travel: gesture.travel, armed: true, going: true, stops: stops, picked: picked))
        if stops != nil, items.indices.contains(picked) {
            go(to: items[picked])
        } else if gesture.back {
            goBackOrLeave()
        } else {
            goForward()
        }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        if pull == nil {
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
        }
        gesture.showing = pull != nil
        onPull?(pull)
    }

}

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let side = body["side"] as? String {
            MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        MainActor.assumeIsolated {
            #if DEBUG
            NativeProbe.scrollMessages += 1
            #endif
            tab?.scrolled(to: y, of: ceiling)
        }
    }

    /// Coalesce DOM reads to a frame and cross into the app only when the
    /// displayed percentage changes. Gesture messages use a separate path.
    static let script = """
    (function () {
      var waiting = false;
      var previous = -1;
      function tell() {
        var root = document.documentElement;
        var y = window.scrollY || root.scrollTop || 0;
        var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
        var percent = Math.round(Math.min(1, Math.max(0, y / ceiling)) * 100);
        if (percent === previous) return;
        previous = percent;
        window.webkit.messageHandlers.\(name).postMessage({ y: y, max: ceiling });
      }
      function schedule() {
        if (waiting) return;
        waiting = true;
        requestAnimationFrame(function () { waiting = false; tell(); });
      }
      window.addEventListener('scroll', schedule, { passive: true });
      window.addEventListener('resize', schedule, { passive: true });
      tell();
    })();
    """
}

/// How far down the page you are, nought to one, for the tab's own fill.
///
/// An object of its own, not a property of the tab: a tab is watched by its row,
/// by its helm and by its page's own host, and this changes every frame.
@MainActor
final class Reading: ObservableObject {
    @Published var through: Double = 0
}

/// The grey that fills a row as you read down the page — a view of its own, so a
/// frame of a scroll redraws this and nothing else.
struct ReadingFill: View {
    @ObservedObject var reading: Reading
    let span: CGFloat
    var body: some View {
        Rectangle()
            .fill(Palette.ink.opacity(0.055))
            .frame(width: span * reading.through)
            .transaction { $0.animation = nil }
    }
}



extension WKWebView {
    /// An address, or a file on this Mac. WebKit reads a file only when told
    /// which folder the page may read from, and loads nothing at all
    /// otherwise: an .html double-clicked in the Finder, once Search is the
    /// Mac's browser, opened a tab that stayed empty.
    func open(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    /// JavaScript run in Search's own world (see Web.world), where its page
    /// scripts are, answered the way `evaluateJavaScript` answers: the value,
    /// or nil for none or an error.
    func evaluateInSearch(_ js: String, then: ((Any?) -> Void)? = nil) {
        evaluateJavaScript(js, in: nil, in: Web.world) { result in
            then?(try? result.get())
        }
    }
}

/// Hands each press to its tab.
final class IntentRelay: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let raw = body["kind"] as? String, let kind = Intent.Press.Kind(rawValue: raw) else { return }
        let href = (body["href"] as? String).flatMap(URL.init(string:))
        let host = (body["host"] as? String)?.lowercased() ?? message.frameInfo.securityOrigin.host.lowercased()
        MainActor.assumeIsolated {
            tab?.press = Intent.Press(kind: kind, href: href, host: host, main: message.frameInfo.isMainFrame,
                                      at: ProcessInfo.processInfo.systemUptime)
        }
    }
}
