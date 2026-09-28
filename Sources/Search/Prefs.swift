import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

/// Which edge the tab column sits on when tabs are arranged in a sidebar.
enum SidebarPosition: String, CaseIterable, Identifiable {
    case left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// Back, forward and reload before the tabs rather than after them, with
    /// the tabs across the top. Off unless asked for.
    @Published var navigationLeft: Bool {
        didSet { store.set(navigationLeft, forKey: "toolbar.left") }
    }
    /// The bookmarks' door at the end of the row; the Bookmarks menu stays.
    @Published var bookmarkButton: Bool {
        didSet { store.set(bookmarkButton, forKey: "toolbar.bookmarks") }
    }
    /// The Extensions menu's door; pinned extensions show either way.
    @Published var extensionButton: Bool {
        didSet { store.set(extensionButton, forKey: "toolbar.extensions") }
    }
    @Published var downloadButton: Bool {
        didSet { store.set(downloadButton, forKey: "toolbar.downloads") }
    }
    /// A door beside reload that opens Speed Dial in the tab you're on.
    /// Off unless asked for.
    @Published var dialButton: Bool {
        didSet { store.set(dialButton, forKey: "dial.button"); fit() }
    }
    /// Every new tab opens on Speed Dial rather than the address field.
    /// Off unless asked for.
    @Published var newTabDial: Bool {
        didSet { store.set(newTabDial, forKey: "dial.newtab") }
    }
    /// Speed Dial is turned on one way or the other; until it is, nothing of
    /// it shows anywhere — no menu item, no Privacy row.
    var usesDial: Bool { dialButton || newTabDial }
    /// The narrowest the column goes. With the grid door beside the lights,
    /// that is the column's padding either side, the lights and four doors.
    var sideFloor: CGFloat { dialButton ? Self.dialFloor : Metrics.sideMin }
    private static let dialFloor = max(Metrics.sideMin, 10 + Metrics.sideLights + 4 * 26 + 3 * 4 + 10)
    private func fit() { if sideWidth < sideFloor { sideWidth = sideFloor } }

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for — in Settings, which is also what leaves
    /// the mark it needs at launch (see Bench.Consent).
    @Published var bench: Bool {
        didSet {
            store.set(bench, forKey: "bench")
            bench ? Bench.Consent.grant() : Bench.Consent.revoke()
        }
    }
    /// The setting said on at launch with no mark from the switch behind it,
    /// and was put back to off.
    private(set) var benchRefused = false
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// Titles down a side instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// Which side the column is on when it is shown vertically.
    @Published var sidePosition: SidebarPosition {
        didSet { store.set(sidePosition.rawValue, forKey: "sidebar.position") }
    }
    /// The column folded away whenever the pointer isn't at its edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    @Published var sideDelay: Double {
        didSet { store.set(sideDelay, forKey: "sidebar.delay") }
    }
    @Published var bookmarksInSidebar: Bool {
        didSet { store.set(bookmarksInSidebar, forKey: "bookmarks.sidebar") }
    }
    /// Less vertical space around the top controls, in either tab layout.
    @Published var topBarHeight: CGFloat {
        didSet { store.set(Double(topBarHeight), forKey: "bars.height") }
    }
    @Published var chromeTransparency: Double {
        didSet { store.set(chromeTransparency, forKey: "chrome.transparency") }
    }
    @Published var chromeBlur: Double {
        didSet { store.set(chromeBlur, forKey: "chrome.blur") }
    }
    /// A light travelling the address field's edge on an empty tab.
    @Published var fieldBeam: Bool {
        didSet { store.set(fieldBeam, forKey: "chrome.fieldBeam") }
    }
    @Published var splitViews: Bool {
        didSet { store.set(splitViews, forKey: "tabs.split") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    /// How long the column takes to come and go, in seconds: the response of
    /// its spring (see Motion.fold). Zero is no slide at all.
    @Published var sideSpeed: Double {
        didSet { store.set(sideSpeed, forKey: "sidebar.speed") }
    }
    static let sideSpeeds: ClosedRange<Double> = 0...0.6
    /// Motion.glide's own response, which the column always had.
    static let sideSpeedDefault = 0.34
    /// How wide an extension's side panel is. Pulled by its edge, and remembered.
    @Published var panelWidth: CGFloat {
        didSet { store.set(Double(panelWidth), forKey: "panel.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var searchSuggestions: Bool {
        didSet { store.set(searchSuggestions, forKey: "search.suggestions") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Shortcuts to a site's own search, ahead of the default engine (see
    /// Keyword.swift). Empty until someone adds one.
    @Published var keywords: [Keyword] {
        didSet { store.set((try? JSONEncoder().encode(keywords)) ?? Data(), forKey: "search.keywords") }
    }
    /// Tabs nobody has looked at for half an hour give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// Pinned tabs sleep on the same clock as the rest, keeping their place
    /// and their letter (Orion's users asked for this of Orion). Off unless
    /// turned on: a pin is often a page kept warm on purpose.
    @Published var pinsSleep: Bool {
        didSet { store.set(pinsSleep, forKey: "pins.sleep") }
    }
    /// WebKit's fingerprinting protection on every page, not only private
    /// ones (see Protections). Off unless turned on.
    @Published var fingerprinting: Bool {
        didSet { store.set(fingerprinting, forKey: "privacy.fingerprinting") }
    }
    /// tabs load when they're first on screen, not when they're opened. off unless turned on.
    @Published var lazyTabs: Bool {
        didSet { store.set(lazyTabs, forKey: "tabs.lazy") }
    }
    /// ⌃⇥ walks the tabs in the order they were last looked at, most recent
    /// first — like switching apps — instead of walking the row in order.
    /// Off unless asked for.
    @Published var mruTabs: Bool {
        didSet { store.set(mruTabs, forKey: "tabs.mru") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var pinsReturnHome: Bool {
        didSet { store.set(pinsReturnHome, forKey: "pins.returnHome") }
    }
    @Published var pinRows: Bool {
        didSet { store.set(pinRows, forKey: "pins.rows") }
    }
    @Published var pinColumns: Int {
        didSet { store.set(pinColumns, forKey: "pins.columns") }
    }

    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// The blocker's lists — uBlock Origin's and the built-in one. Off, the
    /// blocker is its behaviour checks alone (see Intent).
    @Published var filterLists: Bool {
        didSet { store.set(filterLists, forKey: "shield.lists") }
    }
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. Off unless asked for.
    @Published var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
        }
    }
    /// How big every site is drawn until it has been zoomed on its own.
    @Published var pageZoom: Double {
        didSet { store.set(pageZoom, forKey: "pageZoom") }
    }
    /// The stops the setting steps through — every 5%, from as small as
    /// anyone reads to as big as a page is worth.
    static let zooms: [Double] = stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// On unless turned off: a 120 Hz screen held to 60 reads as choppy.
    @Published var fastPages: Bool {
        didSet {
            store.set(fastPages, forKey: "pages.120")
            FrameRate.fast = fastPages
        }
    }
    /// Where a link goes, at the bottom of the page while the pointer is on
    /// it (see StatusLine.swift). Off unless asked for.
    /// Shift-click on a link opens it in a panel over the page (see
    /// Peek.swift). Off unless asked for.
    @Published var peeksLinks: Bool {
        didSet { store.set(peeksLinks, forKey: "links.peek") }
    }
    /// Translate Page (⇧⌘L) and Translate Image, on the Mac itself (see
    /// Translate.swift). Off unless asked for.
    @Published var translates: Bool {
        didSet { store.set(translates, forKey: "translate") }
    }
    /// Back from the first page of a tab a link opened closes it and
    /// returns to the page (see Tab.returnTo). On unless turned off.
    @Published var returnsFromLinks: Bool {
        didSet { store.set(returnsFromLinks, forKey: "links.return") }
    }
    /// A link from another app opens in a small window of its own (see
    /// Little.swift). Off unless asked for.
    @Published var littleLinks: Bool {
        didSet { store.set(littleLinks, forKey: "links.little") }
    }
    /// The bookmarks bar above the page (see BookmarksBar.swift). Off
    /// unless asked for.
    @Published var bookmarksBar: Bool {
        didSet { store.set(bookmarksBar, forKey: "bookmarks.bar") }
    }
    @Published var showsLinks: Bool {
        didSet {
            store.set(showsLinks, forKey: "links.show")
            HoveredLink.on = showsLinks
        }
    }
    /// A back or forward swipe held once armed shows the pages that way to
    /// pick from (see PageView.openList). Off unless asked for.
    @Published var holdsHistory: Bool {
        didSet {
            store.set(holdsHistory, forKey: "swipe.history")
            PageView.holdsHistory = holdsHistory
        }
    }
    @Published var audibleAutoplay: Bool {
        didSet { store.set(audibleAutoplay, forKey: "media.audibleAutoplay") }
    }
    @Published var floatBlockedSites: String {
        didSet { store.set(floatBlockedSites, forKey: "float.blockedSites") }
    }

    func blocksFloating(on url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return floatBlockedSites.split(separator: ",").contains { entry in
            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let blocked = URL(string: text.contains("://") ? text : "https://" + text)?.host?.lowercased() else { return false }
            return host == blocked || host.hasSuffix("." + blocked)
        }
    }

    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// Off unless asked for.
    @Published var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    /// A video playing floats out when another app comes to the front, and
    /// back when Search does (see Browser.appLeft). Off unless asked for.
    @Published var floatsAway: Bool {
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On, as it always was;
    /// the switch is for turning it off.
    @Published var floatsOnLeave: Bool {
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
    }
    /// A newer build is fetched, checked and put in place on its own, as it
    /// always was. Off, Search still looks once a day and says so, and waits
    /// for Install in Settings (see Updater.installsOnItsOwn).
    @Published var installsUpdates: Bool {
        didSet {
            store.set(installsUpdates, forKey: Updater.installKey)
            // Switched back on with one waiting: it goes in now.
            if installsUpdates { Updater.shared.install() }
        }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }
    /// "settings", "new tab" and the like in the address field reach that
    /// part of the app instead of asking a search engine for the word (see
    /// Commands.swift). Off unless asked for.
    @Published var commandBar: Bool {
        didSet { store.set(commandBar, forKey: "commandbar") }
    }
    /// Named, collapsible sections in the sidebar. Off unless asked for.
    @Published var usesTabGroups: Bool {
        didSet { store.set(usesTabGroups, forKey: "tabs.groups") }
    }
    /// ⌃Tab as pictures of the tabs, most recent first, as in Arc and Dia
    /// (see Switcher.swift). Off: ⌃Tab walks the row, as it always has.
    @Published var tabPictures: Bool {
        didSet { store.set(tabPictures, forKey: "tabs.pictures") }
    }

    init() {
        navigationLeft = store.bool(forKey: "toolbar.left")
        bookmarkButton = store.object(forKey: "toolbar.bookmarks") as? Bool ?? true
        extensionButton = store.object(forKey: "toolbar.extensions") as? Bool ?? true
        downloadButton = store.bool(forKey: "toolbar.downloads")
        dialButton = store.bool(forKey: "dial.button")
        newTabDial = store.bool(forKey: "dial.newtab")
        // The Mac's language, always: an override an older version wrote
        // into this app's own defaults is taken away, so the next launch
        // speaks whatever System Settings says.
        Tongue.followMac(store)
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        let scripted = store.bool(forKey: "bench")
        let allowed = scripted && (Store.testing || Bench.Consent.given)
        bench = allowed
        if scripted, !allowed {
            benchRefused = true
            store.set(false, forKey: "bench")
        }
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sidePosition = store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init) ?? .left
        sideHides = store.bool(forKey: "sidebar.hides")
        let delay = store.object(forKey: "sidebar.delay") as? Double ?? 0.15
        sideDelay = [0, 0.15, 0.4].contains(delay) ? delay : 0.15
        bookmarksInSidebar = store.bool(forKey: "bookmarks.sidebar")
        let barHeight = store.object(forKey: "bars.height") as? Double
            ?? (store.bool(forKey: "bars.compact") ? 30 : Double(Metrics.strip))
        topBarHeight = CGFloat(min(Double(Metrics.strip), max(30, barHeight)).rounded())
        chromeTransparency = (min(1, max(0, store.double(forKey: "chrome.transparency"))) * 100).rounded() / 100
        chromeBlur = (min(1, max(0, store.object(forKey: "chrome.blur") as? Double ?? 0.65)) * 100).rounded() / 100
        fieldBeam = store.object(forKey: "chrome.fieldBeam") as? Bool ?? true
        splitViews = store.bool(forKey: "tabs.split")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(store.bool(forKey: "dial.button") ? Self.dialFloor : Metrics.sideMin, CGFloat(width)))
        let speed = store.object(forKey: "sidebar.speed") as? Double ?? Preferences.sideSpeedDefault
        sideSpeed = min(Preferences.sideSpeeds.upperBound, max(Preferences.sideSpeeds.lowerBound, speed))
        let panel = store.object(forKey: "panel.width") as? Double ?? Double(Metrics.panel)
        panelWidth = min(Metrics.panelMax, max(Metrics.panelMin, CGFloat(panel)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        searchSuggestions = store.object(forKey: "search.suggestions") as? Bool ?? true
        customEngine = store.string(forKey: "search.custom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        pinsSleep = store.bool(forKey: "pins.sleep")
        fingerprinting = store.bool(forKey: "privacy.fingerprinting")
        lazyTabs = store.bool(forKey: "tabs.lazy")
        mruTabs = store.bool(forKey: "tabs.mru")
        showsReading = store.object(forKey: "tabs.reading") as? Bool ?? true
        pinsReturnHome = store.bool(forKey: "pins.returnHome")
        pinRows = store.bool(forKey: "pins.rows")
        pinColumns = max(0, min(8, store.integer(forKey: "pins.columns")))
        shielded = store.object(forKey: "shield") as? Bool ?? true
        filterLists = store.object(forKey: "shield.lists") as? Bool ?? true
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.bool(forKey: "spaces")
        let history = store.bool(forKey: "swipe.history")
        holdsHistory = history
        PageView.holdsHistory = history
        commandBar = store.bool(forKey: "commandbar")
        usesTabGroups = store.bool(forKey: "tabs.groups")
        tabPictures = store.bool(forKey: "tabs.pictures")
        audibleAutoplay = store.bool(forKey: "media.audibleAutoplay")
        floatBlockedSites = store.string(forKey: "float.blockedSites") ?? ""
        let flicks = store.bool(forKey: "float.flicks")
        floatFlicks = flicks
        Float.flicks = flicks
        floatsAway = store.bool(forKey: "float.away")
        floatsOnLeave = store.object(forKey: "float.leave") as? Bool ?? true
        installsUpdates = store.object(forKey: Updater.installKey) as? Bool ?? true
        peeksLinks = store.bool(forKey: "links.peek")
        littleLinks = store.bool(forKey: "links.little")
        translates = store.bool(forKey: "translate")
        returnsFromLinks = store.object(forKey: "links.return") as? Bool ?? true
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        let links = store.bool(forKey: "links.show")
        showsLinks = links
        HoveredLink.on = links
        let scrolls = store.bool(forKey: "autoscroll")
        autoScroll = scrolls
        AutoScroll.on = scrolls
        let fast = store.object(forKey: "pages.120") == nil ? true : store.bool(forKey: "pages.120")
        fastPages = fast
        FrameRate.fast = fast
        // Before the first page is made, so it is made at the right rate.
        _ = Power.shared
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.bool(forKey: "autocorrect")
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Smart quotes and dashes go off outright: in a
    /// browser they are wrong in every code field and wanted in almost none.
    static func tellWebKit(autocorrect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
