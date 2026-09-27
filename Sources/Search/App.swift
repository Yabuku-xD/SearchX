import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct SearchApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    init() {
        // A copy of Search started only to compile filter lists does that
        // and exits here, before any window or profile exists.
        FilterWorker.runIfAsked()
        Scrollers.float()
    }

    var body: some Scene {
        Window("SearchX", id: Store.world.map { "search (\($0))" } ?? "search") {
            if let model = browser.sceneModel {
                SceneRoot(model: model)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { SearchCommands(browser: browser) }
    }
}

private struct SearchCommands: Commands {
    @ObservedObject var browser: Browser

    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { browser.open() }
                    .shortcut("file.newWindow", browser.shortcuts)
                Button("New Private Window") { browser.open(shy: true) }
                    .shortcut("file.newPrivateWindow", browser.shortcuts)
                Button("New Tab") { browser.key?.newTab() }
                    .shortcut("file.newTab", browser.shortcuts)
                Button("New Private Tab") { browser.key?.newShyTab() }
                    .shortcut("file.newPrivateTab", browser.shortcuts)
                Button("Reopen Closed Tab") { browser.key?.reopen() }
                    .shortcut("file.reopen", browser.shortcuts)
                    .disabled(browser.key?.ghosts.isEmpty ?? true)
                Divider()
                Button("Open Address…") { browser.key?.edit() }
                    .shortcut("file.openAddress", browser.shortcuts)
                Divider()
                Button("Close Tab") { if let tab = browser.key?.active { browser.closeTab(tab) } }
                    .shortcut("file.closeTab", browser.shortcuts)
            }
            CommandGroup(replacing: .printItem) {
                Button("Share…") { browser.share() }
                    .disabled(browser.key?.active?.showsPage != true)
                Button("Print…") { browser.printPage() }
                    .shortcut("file.print", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find on Page…") { browser.key?.openFind() }
                    .shortcut("edit.find", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true)
                Button("Find Next") { browser.key?.look(forward: true) }
                    .shortcut("edit.findNext", browser.shortcuts)
                    .disabled(!(browser.key?.finding ?? false))
                Button("Find Previous") { browser.key?.look(forward: false) }
                    .shortcut("edit.findPrevious", browser.shortcuts)
                    .disabled(!(browser.key?.finding ?? false))
            }
            CommandGroup(replacing: .toolbar) {
                Toggle("Show Tabs in Sidebar", isOn: Binding(
                    get: { browser.prefs.sidebar },
                    set: { _ in browser.toggleSidebar() }
                ))
                .shortcut("view.sidebar", browser.shortcuts)
                // Folded away, not moved (see Fold.swift) — the column, or the
                // strip across the top.
                Button(browser.prefs.sidebar
                       ? ((browser.key?.folded ?? false) ? "Show Sidebar" : "Hide Sidebar")
                    : ((browser.key?.folded ?? false) ? "Show Tab Bar" : "Hide Tab Bar")) { browser.key?.toggleFold() }
                    .shortcut("view.fold", browser.shortcuts)
                Button(browser.key?.focusing == nil ? "Enter Focus Mode" : "Leave Focus Mode") { browser.key?.toggleFocus() }
                    .shortcut("view.focus", browser.shortcuts)
                    .disabled(browser.key?.active == nil)
                Picker("Tabs Wear", selection: Binding(
                    get: { browser.prefs.glyph },
                    set: { browser.prefs.glyph = $0 }
                )) {
                    ForEach(Glyph.allCases) { glyph in
                        Text(glyph.title).tag(glyph)
                    }
                }
                Divider()
                Button("Reload Page") { browser.key?.reload() }
                    .shortcut("view.reload", browser.shortcuts)
                Button("Reload Page From Origin") { browser.key?.reload(fromOrigin: true) }
                    .shortcut("view.reloadOrigin", browser.shortcuts)
                Button("Reading Mode") { browser.key?.toggleReader() }
                    .shortcut("view.reader", browser.shortcuts)
                TranslateCommand(browser: browser, prefs: browser.prefs)
                Button("Float Video") { browser.toggleFloat() }
                    .shortcut("view.float", browser.shortcuts)
                Divider()
                Button("Hide Elements…") { browser.toggleHiding() }
                    .shortcut("view.hide", browser.shortcuts)
                Button("Hidden on This Site…") { browser.reviewing.toggle() }
                    .shortcut("view.hidden", browser.shortcuts)
                Button("Colour…") { browser.theming.toggle() }
                Menu("Capture Element") {
                    Button("Copy Image…") { browser.key?.captureElement(to: .clipboard) }
                    Button("Save Image…") { browser.key?.captureElement(to: .file) }
                }
                .disabled(browser.key?.active?.showsPage != true)
                Divider()
                Button("Zoom In") { browser.key?.zoom(by: 1.1) }
                    .shortcut("view.zoomIn", browser.shortcuts)
                Button("Zoom Out") { browser.key?.zoom(by: 1 / 1.1) }
                    .shortcut("view.zoomOut", browser.shortcuts)
                Button("Actual Size") { browser.key?.resetZoom() }
                    .shortcut("view.actualSize", browser.shortcuts)
                Divider()
                // The Web Inspector, on the keys Chrome and Arc use (see Inspector.swift).
                Button("Web Inspector") { browser.toggleInspector() }
                    .shortcut("view.inspector", browser.shortcuts)
                Button("JavaScript Console") { browser.showConsole() }
                    .shortcut("view.console", browser.shortcuts)
                Button("Inspect Element") { browser.inspectElement() }
                    .shortcut("view.inspect", browser.shortcuts)
            }
            CommandMenu("Tabs") {
                if browser.prefs.usesDial {
                    Button("Speed Dial") { browser.key?.showDial() }
                }
                Button("Back") { browser.key?.back() }
                    .shortcut("tabs.back", browser.shortcuts)
                    .disabled(browser.key?.active?.canGoBackOrReturn != true)
                Button("Forward") { browser.key?.forward() }
                    .shortcut("tabs.forward", browser.shortcuts)
                    .disabled(browser.key?.active?.canGoForward != true)
                Divider()
                Button("Next Tab") { browser.key?.step(1) }
                    .shortcut("tabs.next", browser.shortcuts)
                Button("Previous Tab") { browser.key?.step(-1) }
                    .shortcut("tabs.previous", browser.shortcuts)
                Button("Search Tabs…") { browser.key?.summon() }
                    .shortcut("tabs.search", browser.shortcuts)
                Divider()
                if let tab = browser.key?.active {
                    if tab.pin == nil {
                        Button("Pin Tab") { browser.key?.pin(tab) }
                            .shortcut("tabs.pin", browser.shortcuts)
                            .disabled(!tab.showsPage)
                    } else {
                        Button("Change Letter") { browser.key?.editLetter(tab) }
                        Button("Unpin Tab") { browser.key?.unpin(tab) }
                            .shortcut("tabs.pin", browser.shortcuts)
                    }
                }
                if let window = browser.key, let tab = window.active {
                    if browser.prefs.usesTabGroups, tab.pin == nil, !tab.shy, !tab.bench {
                        Menu("Move to Group") {
                            Button("New Group") { window.addTabGroup(containing: tab) }
                            ForEach(window.tabGroups) { group in
                                Button(group.name) { window.move(tab, toGroup: group.id) }
                                    .disabled(tab.groupID == group.id)
                            }
                            if tab.groupID != nil {
                                Button("Remove from Group") { window.move(tab, toGroup: nil) }
                            }
                        }
                    }
                    ContainerMenu(window: window, tab: tab)
                    SplitMenuItems(window: window, tab: tab)
                    if browser.prefs.usesSpaces, !tab.bench,
                       tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil {
                        Menu("Move to Space") {
                            ForEach(browser.spaces.filter { $0.id != window.spaceID }) { space in
                                Button(space.name) { window.move(tab, toSpace: space.id) }
                            }
                        }
                    }
                }
                Button("Rename Tab") { if let tab = browser.key?.active { browser.key?.beginTabRename(tab) } }
                    .shortcut("tabs.rename", browser.shortcuts)
                    .disabled(browser.key?.active == nil)
                Button("Duplicate Tab") { browser.key?.duplicate() }
                    .shortcut("tabs.duplicate", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true)
                Button("Add to Dock…") { browser.addSiteApp() }
                    .disabled(!browser.canAddSiteApp)
                Button("Open in Web Panel") { if let window = browser.key, let tab = window.active { window.openInPanel(tab) } }
                    .shortcut("tabs.webPanel", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true || browser.key?.active?.shy == true)
                Button("Copy Address") { browser.key?.copyAddress() }
                    .shortcut("tabs.copyAddress", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true)
                Button("Copy URLs of Selected Tabs") { browser.key?.copySelectedAddresses() }
                    .disabled(browser.key?.canCopySelectedAddresses != true)
                Button("Unload Selected Tabs") { browser.key?.unloadSelectedTabs() }
                    .disabled(browser.key?.canUnloadSelected != true)
                Button("Unload Other Tabs") { browser.key?.unloadOtherTabs() }
                    .disabled(browser.key?.canUnloadOthers != true)
                Button("Copy as Markdown Link") { browser.key?.copyMarkdownLink() }
                    .disabled(browser.key?.active?.showsPage != true)
                Button("Paste and Go") { browser.key?.pasteAndGo() }
                    .shortcut("tabs.pasteAndGo", browser.shortcuts)
                Divider()
                Button("Close Other Tabs") { if let tab = browser.key?.active { browser.key?.closeOthers(but: tab) } }
                    .shortcut("tabs.closeOthers", browser.shortcuts)
                    .disabled((browser.key?.tabs.count ?? 0) < 2)
                Button("Stop Sound in Tab") { browser.key?.pauseMedia() }
                    .shortcut("tabs.mute", browser.shortcuts)
            }
            CommandMenu("Bookmarks") {
                Button(browser.pageKept ? "Edit Bookmark…" : "Add This Page") { browser.bookmarkCurrent() }
                    .shortcut("bookmarks.add", browser.shortcuts)
                    .disabled(browser.key?.active?.showsPage != true)
                if browser.prefs.usesDial {
                    Button("Add This Page to Speed Dial") { browser.key?.dialCurrent() }
                        .disabled(browser.key?.active.map { !SpeedDial.canCapture($0) } ?? true)
                }
                Button("Show Bookmarks…") { browser.bookmarking = true }
                    .shortcut("bookmarks.show", browser.shortcuts)
                Toggle("Show Bookmarks Bar", isOn: Binding(
                    get: { browser.prefs.bookmarksBar },
                    set: { on in withAnimation(Motion.glide) { browser.prefs.bookmarksBar = on } }
                ))
                // The bookmarks themselves follow, put in by AppKit (see
                // BookmarkMenu in Bookmarks.swift).
            }
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button {
                            browser.key?.open(trace.url, foreground: true)
                        } label: {
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                        }
                    }
                }
                if !(browser.key?.ghosts.isEmpty ?? true) {
                    Section("Recently Closed") {
                        ForEach((browser.key?.ghosts ?? []).reversed().prefix(10)) { ghost in
                            Button {
                                browser.key?.reopen(ghost)
                            } label: {
                                MenuLine(title: ghost.label, url: ghost.url)
                            }
                        }
                    }
                }
                Divider()
                Button("Show History…") { browser.recalling = true }
                    .shortcut("history.show", browser.shortcuts)
                Button("Downloads…") { browser.hoarding = true }
                    .shortcut("history.downloads", browser.shortcuts)
                Divider()
                Button("Clear Browsing Data…") { browser.recallMode = .clearing }
                    .shortcut("history.clearData", browser.shortcuts)
                Button("Clear History") { browser.clearHistory() }
                    .shortcut("history.clear", browser.shortcuts)
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") { browser.tuning = true }
                    .shortcut("app.settings", browser.shortcuts)
                Button("Welcome…") { browser.welcoming = true }
                    .shortcut("app.welcome", browser.shortcuts)
                Button("Passwords…") { browser.managing = true }
                    .shortcut("app.passwords", browser.shortcuts)
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Links.writeFeedback() }
            }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
private struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

/// The SwiftUI scene's window. It draws one model for its whole life.
/// `browser.key` moves when another window comes forward; following it here
/// made this window repaint the other one's row and drop its own tabs.
/// The model is not observed through `browser`, so a focus change in another
/// window does not rebuild this whole tree.
private struct SceneRoot: View {
    let model: WindowModel

    var body: some View {
        ContentView(window: model)
    }
}

struct ContentView: View {
    @ObservedObject var window: WindowModel
    /// Profile services this window draws from.
    var browser: Browser { window.profile }

    @State private var host: NSWindow?
    @State private var resting: RestingLights?
    @State private var touchBar: TouchBar?
    /// The room the page leaves for the column and the strip, set without
    /// animation (see `make(room:after:)`); nil only before the window is up.
    @State private var room: CGSize?
    @State private var roomTicket = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// How wide the window is, for what the panel may take (see panelWidth).
    @State private var span: CGFloat = 0

    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: sideOnRight ? .topTrailing : .topLeading) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            if window.active?.immersed == true { Color.black } else { ThemeGround(theme: window.space.theme) }

            // One stage, always, beside the column and under the strip. With
            // the chrome see-through, what shows through it is the desktop
            // behind the window, as in any Mac sidebar; only the column or
            // strip brought out over the page shows the page (see Fold).
            //
            // When the column or the strip comes or goes, the page slides with
            // it and is resized once, not on every frame of the slide: laid out
            // again thirty times a second, the page juddered along its right
            // edge and overshot the window with the spring (see `room`). The
            // column is the exception: the page narrows and widens with it.
            if let tab = window.active { WallpaperView(tab: tab) }
            stage
                .padding(.leading, sideOnRight ? 0 : roomed.width)
                .padding(.trailing, (sideOnRight ? roomed.width : 0) + panelWidth)
                .padding(.top, roomed.height)
                .offset(x: sideOnRight ? 0 : chrome.width - roomed.width,
                        y: chrome.height - roomed.height)

            // The column of tabs, in the way that has one. It takes the full
            // height, so the traffic lights sit in its own corner rather than
            // over the page.
            if sidebar {
                SideBar(window: window, prefs: browser.prefs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: sideOnRight ? .trailing : .leading))
            }

            if !browser.prefs.sidebar, !window.folded, window.active?.immersed != true {
                TabBar(window: window)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // An extension's side panel, docked on the right, the page's
            // height: under the strip, beside the column (see ExtensionPanel.swift).
            if let panel = window.panel, !window.panelHeld {
                PanelColumn(browser: browser, window: window, prefs: browser.prefs, panel: panel, width: panelWidth)
                    .padding(.top, chrome.height)
                    .padding(.trailing, sideOnRight ? chrome.width : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            // The bookmarks bar, under the strip or beside the column's top.
            if barShown {
                BookmarksBar(window: window, bookmarks: browser.bookmarks)
                    .padding(.leading, sideOnRight ? 0 : chrome.width)
                    .padding(.trailing, sideOnRight ? chrome.width : 0)
                    .padding(.top, band)
                    .transition(.opacity)
            }
        }
        .environment(\.chromeBacking, windowTinted ? .desktop : .own)
        .ignoresSafeArea()
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in span = width }
        })
        .animation(browser.foldMotion, value: browser.prefs.sidebar)
        .animation(Motion.easeOut(0.12), value: window.active?.immersed)
        .animation(browser.foldMotion, value: browser.prefs.sidePosition)
        .onAppear { if room == nil { room = chrome } }
        .onChange(of: chrome) { old, new in make(room: new, after: old) }
    }

    private var stage: some View {
        SplitStage(browser: window, overlay: pageOverlay)
        .overlay {
            if browser.prefs.showsLinks { LinkBubble(status: window.linkStatus) }
        }
        .overlay(alignment: .topTrailing) {
            if window.finding {
                FindBar(window: window)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if let asked = browser.suggesting, asked.tab == window.activeID {
                AccountList(browser: browser, asked: asked)
                    .transition(.opacity)
            }
        }
        // Whether the page is still loading, while nothing else says so.
        .overlay(alignment: .topLeading) { LoadingBadge(window: window) }
        .animation(Motion.quick, value: browser.suggesting)
        .clipShape(RoundedRectangle(cornerRadius: framed ? 10 : 0, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.black.opacity(framed ? 0.1 : 0), lineWidth: 1))
        .padding(framed ? 8 : 0)
    }

    /// The folded column or strip, brought out over the page, blurs the page
    /// under it when the chrome is see-through (see Fold.swift). Its edge and
    /// reach stay set while it goes back in, so the blur can go with it.
    private var pageOverlay: PageOverlay {
        let seeThrough = browser.prefs.chromeTransparency > 0 && !reduceTransparency
        let edge: PageOverlay.Edge = browser.prefs.sidebar
            ? (browser.prefs.sidePosition == .right ? .trailing : .leading) : .top
        return PageOverlay(
            edge: edge,
            extent: browser.prefs.sidebar ? browser.prefs.sideWidth : browser.prefs.topBarHeight,
            radius: seeThrough && window.folded ? browser.prefs.chromeBlur * 30 : 0,
            out: window.folded && window.peeking && window.active?.immersed != true,
            response: browser.prefs.sideSpeed
        )
    }

    /// The window itself is see-through behind its chrome: transparency on,
    /// Reduce Transparency off, and no space colour, which frosts the desktop
    /// its own way (see Theme.swift).
    private var windowTinted: Bool {
        browser.prefs.chromeTransparency > 0 && !reduceTransparency && !framed
    }

    /// The footprint of the visible chrome, whether reserved or overlaid.
    private var chrome: CGSize {
        CGSize(width: sidebar ? browser.prefs.sideWidth : 0, height: band + (barShown ? BookmarksBar.height : 0))
    }

    /// What the panel takes from the page: the width it was pulled to,
    /// unless the window can't leave the page 320 beside it — then less,
    /// but not under the panel's own minimum. Unless even that would run
    /// over the column or past the window's edge: a 640-point window with
    /// the column at its widest has 200 left, and there the panel gives way
    /// to the page's last 160 rather than draw over either. Nothing without
    /// a panel.
    private var panelWidth: CGFloat {
        guard window.panel != nil, !window.panelHeld else { return 0 }
        let room = span - chrome.width
        let wanted = min(browser.prefs.panelWidth, max(Metrics.panelMin, room - 320))
        return max(0, min(wanted, room - 160))
    }

    /// The bookmarks bar is up: asked for, there are bookmarks, and the tabs
    /// aren't folded away or under a video filling the screen.
    private var barShown: Bool {
        browser.prefs.bookmarksBar && !browser.bookmarks.isEmpty && !window.folded
            && window.active?.immersed != true
    }

    /// The room the page is laid out to leave them, which is not animated.
    private var roomed: CGSize { room ?? chrome }

    private var sideOnRight: Bool {
        browser.prefs.sidebar && browser.prefs.sidePosition == .right
    }

    /// The column coming or going gives or takes the page's room on the
    /// column's own spring, so the page narrows and widens with it rather
    /// than jumping before or after it has moved. The strip going away gives
    /// the page its room at once, the page sliding out from under it at its
    /// new size; the strip arriving slides over a page still at its old size,
    /// which gives up the room once the slide is over. A column being dragged
    /// wider or narrower is followed as it goes.
    private func make(room new: CGSize, after old: CGSize) {
        let now = roomed
        let arriving = old.height == 0 && new.height > 0
        let sliding = (old.width == 0) != (new.width == 0)
        var at = now
        if !sliding { at.width = new.width }
        if !arriving { at.height = new.height }
        roomTicket += 1
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { room = at }
        if sliding { withAnimation(browser.foldMotion) { room?.width = new.width } }
        guard arriving else { return }
        let ticket = roomTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard ticket == roomTicket else { return }
            withTransaction(still) { room = chrome }
        }
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            if let ask = browser.asking {
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.offering {
                keepAsking(offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
        .animation(Motion.settle, value: browser.offering)
    }

    /// The address field: raised over a page by ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if window.fieldShowing, window.active?.onDial != true {
            Omnibox(window: window, over: !(window.active?.isBlank ?? true))
                // Centred on the page, not on the window. The column of tabs
                // is not what the field is standing over, and dimming it along
                // with the page says otherwise.
                .padding(.leading, sidebar && !sideOnRight ? browser.prefs.sideWidth : 0)
                .padding(.trailing, sidebar && sideOnRight ? browser.prefs.sideWidth : 0)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser, window: window) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if browser.tuning {
            sheet { SettingsPanel(browser: browser, prefs: browser.prefs) }
                close: { browser.tuning = false }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser) } close: { browser.managing = false }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, browser.prefs.topBarHeight + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
        if browser.theming {
            // Nothing dimmed: the frame is what is being changed.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.theming = false }
                ThemePanel(browser: browser, prefs: browser.prefs)
                    .padding(.top, Metrics.strip + 8)
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// ⌃Tab's pictures of the tabs (see Switcher.swift). Up a beat after the
    /// press, so a quick ⌃Tab back to the last tab never flashes it; gone at
    /// once on letting go, with the page already switched underneath.
    @ViewBuilder
    private var switcher: some View {
        if let shown = window.switcher {
            SwitcherPanel(browser: window, shown: shown)
                .ignoresSafeArea()
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.easeOut(0.12)?.delay(0.08)),
                    removal: .identity
                ))
        }
    }

    var body: some View {
        window_
            .modifier(Translating(browser: browser, window: window))
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: sideOnRight ? .trailing : .leading) { Fold(window: window, prefs: browser.prefs) }
            .overlay(alignment: .bottom) { bars }
            .overlay {
                // Over the page only: the column, the strip and the bookmarks
                // bar stay as they are, uncovered and in reach.
                PeekLayer(window: window)
                    .padding(.leading, sideOnRight ? 0 : chrome.width)
                    .padding(.trailing, sideOnRight ? chrome.width : 0)
                    .padding(.top, chrome.height)
                    // From the window's own top edge, as the page is:
                    // the title bar's band is page too.
                    .ignoresSafeArea()
            }
            .overlay { field }
            .overlay { panels }
            .overlay { switcher }
            // The field comes on its spring, and goes quickly: once Return
            // is pressed the page is on its way, and the field is not what
            // there is to watch.
            .animation(window.fieldShowing ? Motion.settle : Motion.quick, value: window.fieldShowing)
            .background(WindowSetup { host = $0; dress($0) })
            .onChange(of: browser.prefs.topBarHeight) { _, _ in
                guard let host else { return }
                Lights.keep(host, height: browser.prefs.topBarHeight, centreX: {
                    browser.prefs.sidebar && browser.prefs.sidePosition == .right
                        ? host.frame.width - browser.prefs.sideWidth + Lights.centre.x
                        : Lights.centre.x
                }) { measureLights() }
            }
            .onChange(of: browser.prefs.sidebar) { _, _ in
                DispatchQueue.main.async { Lights.refresh(host); measureLights() }
            }
            .onChange(of: browser.prefs.sidePosition) { _, _ in
                DispatchQueue.main.async { Lights.refresh(host); measureLights() }
            }
            .onChange(of: browser.prefs.sideWidth) { _, _ in
                DispatchQueue.main.async { Lights.refresh(host); measureLights() }
            }
            // Stepping away to another app: macOS draws its own resting
            // buttons, and on a light window they come out nearly white. Ours
            // go on in their place until the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                measureLights()
                resting?.isHidden = false
                // Only from the window in front. Every window answering
                // lifted the video once per window.
                if browser.key === window { browser.appLeft() }
                window.switcher = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let host, (note.object as? NSWindow) === host { browser.becameKey(window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                if let host, (note.object as? NSWindow) === host { browser.close(window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                resting?.isHidden = true
                if browser.key === window { browser.appBack() }
            }
            .onChange(of: window.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { window.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: window.activeID) { _, _ in handBack() }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.tuning)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.reviewing)
            .animation(Motion.settle, value: browser.theming)
            .onChange(of: window.space.theme != nil) { _, _ in glaze(host) }
            .onChange(of: windowTinted) { _, _ in glaze(host) }
        .onAppear {
            watchKeys()
            window.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !window.fieldShowing, window.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard window.active?.onDial != true, let web = window.active?.built, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            Text(text.said)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Symbols.current(ask.wants == "microphone" ? "mic" : "video"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text("Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.denyCapture() } label: {
                Text("Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    /// Offered once, answered once. The password is never shown back to you —
    /// there is nothing to be learned from reading your own password.
    private func keepAsking(_ offer: Browser.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { browser.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { browser.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }


    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            // The floor owns the cursor; see CursorGround.
            CursorGround()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .padding(16)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    private var sidebar: Bool {
        browser.prefs.sidebar && !window.folded && window.active?.immersed != true
    }

    /// The page as a card in a coloured frame (see Theme.swift).
    private var framed: Bool {
        window.space.theme != nil && window.active?.immersed != true
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top; the strip needs a band.
    private var band: CGFloat {
        guard window.active?.immersed != true else { return 0 }
        // Folded, the strip is out of the window and the page has its height.
        return browser.prefs.sidebar || window.folded ? 0 : browser.prefs.topBarHeight
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    private func measureLights() {
        guard let host,
              let close = host.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { host.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    private func dress(_ host: NSWindow) {
        browser.claim(host, for: window)
        if let frame = window.frameRequest {
            window.frameRequest = nil
            host.setFrame(frame, display: false)
        }
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        host.titlebarAppearsTransparent = true
        host.titleVisibility = .hidden
        host.isExcludedFromWindowsMenu = false
        window.updateWindowTitle()
        glaze(host)
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        host.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead.
        host.isMovable = false
        // Back, forward, the tabs and the rest, on a Mac with a Touch Bar
        // (see TouchBar.swift). Nothing is made on one without.
        let bar = TouchBar(browser: window)
        touchBar = bar
        host.touchBar = bar.make()
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(host, height: browser.prefs.topBarHeight, centreX: {
            browser.prefs.sidebar && browser.prefs.sidePosition == .right
                ? host.frame.width - browser.prefs.sideWidth + Lights.centre.x
                : Lights.centre.x
        }) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = host.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = host.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    /// See-through where the frame is, when the space has a colour, or the
    /// chrome is see-through: the desktop shows, frosted, under it (see
    /// Theme.swift). Opaque otherwise, which costs the window server least.
    private func glaze(_ host: NSWindow?) {
        guard let host else { return }
        let clear = window.space.theme != nil || windowTinted
        host.isOpaque = !clear
        host.backgroundColor = clear ? .clear : Palette.NS.ground
    }

    // MARK: - keys

    /// One monitor for the whole app. Keys go to the window they were pressed in.
    private static var keys: Any?
    private static weak var appBrowser: Browser?

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        ContentView.appBrowser = browser
        ContentView.keyHook = { event in
            guard let browser = ContentView.appBrowser else { return event }
            let target = browser.model(owning: event.window ?? NSApp.keyWindow) ?? browser.key ?? window
            return ContentView.take(event, in: target) ? nil : event
        }
        guard ContentView.keys == nil else { return }
        ContentView.keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            guard let browser = ContentView.appBrowser else { return event }
            let target = browser.model(owning: event.window ?? NSApp.keyWindow) ?? browser.key ?? browser.windows.first
            guard let target else { return event }
            if event.type == .leftMouseDown {
                target.focusSplitPage(at: event)
                return event
            }
            guard event.type == .keyDown else {
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) {
                    target.landSummon()
                }
                if !event.modifierFlags.contains(.control) { target.landFlip(); target.landMRU() }
                return event
            }
            return ContentView.take(event, in: target) ? nil : event
        }
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path.
    static var keyHook: ((NSEvent) -> NSEvent?)?

    /// The last key handed to the page before Search acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is Search's.
    private static var passed: NSEvent?

    /// A key a page may want for itself — ⌘K in Slack, ⌘F in a Google Doc,
    /// ⌘S in an editor — goes to the page first, as it does in Chrome, and is
    /// Search's only if the page leaves it unused: WebKit then sends the same
    /// event back through the app, and it comes here a second time. Only
    /// while the page has the keyboard; in the address field or a panel,
    /// Search's keys are Search's. The keys that make and close tabs and move
    /// between them stay Search's first, as Chrome keeps them its own.
    private static func pageFirst(_ event: NSEvent, key: String, shifted: Bool, browser: Browser) -> Bool {
        let reserved = (key == "t") || (key == "w" && !shifted) || (key == "n")
            || ((key == "[" || key == "]" || key == "{" || key == "}") && shifted)
            || (key == "k" && shifted)
            || (key == "z" && browser.veiling)
        guard !reserved, event.window?.firstResponder is PageView else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    /// Keys go to the window they were pressed in, not whichever ContentView
    /// installed the monitor first.
    private static func take(_ event: NSEvent, in window: WindowModel) -> Bool {
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        let browser = window.profile
        guard !browser.shortcuts.recording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if window.switcher != nil {
                window.switcher = nil
                return true
            }
            if window.editingTab != nil {
                window.cancelTabEdit()
                return true
            }
            if window.pendingSplit != nil {
                window.pendingSplit = nil
                return true
            }
            if browser.editingBookmark != nil {
                browser.editingBookmark = nil
                return true
            }
            if window.peekTab != nil {
                window.closePeek()
                return true
            }
            if window.makingSpace {
                window.cancelSpaceCreation()
                withAnimation(Motion.glide) { window.makingSpace = false }
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.recalling {
                browser.recalling = false
                return true
            }
            if browser.hoarding {
                browser.hoarding = false
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.theming {
                browser.theming = false
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if window.finding {
                window.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if window.picked != nil {
                window.picked = nil
                return true
            }
            guard window.editing, window.active?.isBlank == false else { return false }
            window.dismiss()
            return true
        }

        // ⌘Return keeps a peek, as its other button does. Not while typing in
        // it: a comment box or a mail there sends with the same keys.
        if event.keyCode == 36 || event.keyCode == 76, flags == .command,
           let peek = window.peekTab, !peek.typing {
            window.keepPeek()
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the tabs and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that. Or, switched on, it brings up the tabs
        // as pictures, the one you were just on first (see Switcher.swift).
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option) {
            if flags.contains(.control) {
                let way = flags.contains(.shift) ? -1 : 1
                if browser.prefs.tabPictures { window.flip(way) }
                else if browser.prefs.mruTabs { window.stepMRU(way) }
                else { window.step(way) }
                return true
            }
            if window.editingTab != nil { return true }
            if window.fieldShowing, !window.offers.isEmpty {
                window.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // ⌃1–⌃9 go to that space, when there are spaces — by the key, as
        // ⌘1–⌘9 are below, so the top row works on every layout.
        if browser.prefs.usesSpaces, flags.contains(.control),
           flags.isDisjoint(with: [.command, .option, .shift]),
           let number = ContentView.digits[event.keyCode], number > 0 {
            window.switchSpace(index: number - 1)
            return true
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those.
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           Extensions.shared.take(event) {
            return true
        }

        // Your own keys (Settings › Shortcuts), before the ones below: a
        // command you moved runs on its new key, and a key you took off a
        // command goes on to the page.
        if let combo = KeyCombo(event: event) {
            if let command = browser.shortcuts.changedCommand(on: combo) {
                browser.run(command, in: window)
                return true
            }
            // A command chain's key (Settings › Shortcuts › Command chains).
            if let chain = Chains.shared.chain(on: combo) {
                Chains.shared.run(chain, browser: browser, window: window)
                return true
            }
            if browser.shortcuts.isFreed(combo) { return false }
        }

        guard flags.contains(.command) else { return false }
        let shifted = flags.contains(.shift)

        if flags.contains(.option), !shifted, !flags.contains(.control),
           event.characters(byApplyingModifiers: [])?.lowercased() == "r" {
            if pageFirst(event, key: "r", shifted: false, browser: browser) { return false }
            window.reload(fromOrigin: true)
            return true
        }

        // Other shortcuts with ⌥ or ⌃ on top are somebody else's.
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        // ⌘Return in the field ⌘L opened: the tab beside itself, its address
        // left alone, rather than whatever Return alone would do to it.
        if !shifted, event.keyCode == 36 || event.keyCode == 76, window.editing {
            window.duplicateFromField()
            return true
        }

        // ⌘1 through ⌘9, and ⌘0, by the key rather than the character it
        // types. On AZERTY and many other layouts the top row types &, é, "…
        // unless shift is held, so matching the character left these
        // shortcuts dead there; the shortcut belongs to the key, as it does
        // in every other browser. The ninth is the last tab, however many.
        if !shifted, let number = ContentView.digits[event.keyCode] {
            if number == 0 {
                window.resetZoom()
            } else {
                window.select(index: number == 9 ? window.tabs.count - 1 : number - 1)
            }
            return true
        }

        // Keep the clearing controls reachable from a focused page editor.
        if shifted, event.keyCode == 51 {
            browser.recallMode = .clearing
            return true
        }

        // The page's turn first, for the keys it may want (Refs #147).
        if pageFirst(event, key: key, shifted: shifted, browser: browser) { return false }

        switch key {
        case "t" where !shifted:
            window.newTab()
        case "t" where shifted:
            window.reopen()
        case "c" where shifted:
            window.copyAddress()
        case "d" where !shifted:
            window.duplicate()
        case "n" where !shifted:
            browser.open()
        case "n" where shifted:
            browser.open(shy: true)
        case "y" where !shifted:
            browser.recalling.toggle()
        case "j" where shifted:
            browser.hoarding.toggle()
        case "v" where shifted:
            // In a text field this key is paste without formatting — a Google
            // Doc, a form, the address field. It only means Paste and Go when
            // nothing is being typed. Passing the key on is not enough: WebKit
            // has no use for ⌘⇧V, hands it back, and the menu's Paste and Go
            // takes it. So the plain paste is done here, as Chrome does.
            // A web view has an input context only while the caret is in
            // something editable, in any frame — including frames the page's
            // own script can't look into, like the one a Google Doc types in.
            if window.active?.typing == true || window.active?.built?.inputContext != nil
                || window.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                window.pasteAndGo()
            }
        case "p" where !shifted:
            browser.printPage()
        case "f" where !shifted:
            window.openFind()
        case "g":
            window.look(forward: !shifted)
        case "m" where shifted:
            window.pauseMedia()
        case "p" where shifted:
            browser.toggleFloat()
        case "k" where shifted:
            if let tab = window.active { window.closeOthers(but: tab) }
        case "k" where !shifted:
            // Held down, ⌘K walks the list a step at a time; letting go of ⌘
            // takes wherever it stopped.
            if window.editing, !window.offers.isEmpty {
                window.stepSummon()
            } else {
                window.summon()
            }
        case "s" where shifted:
            browser.toggleSidebar()
        case "s" where !shifted:
            // The column or the strip, folded away (see Fold.swift).
            window.toggleFold()
        case "b" where shifted:
            browser.bookmarkCurrent()
        case "," where !shifted:
            browser.tuning.toggle()
        case "h" where shifted:
            browser.toggleHiding()
        case "u" where shifted:
            browser.reviewing.toggle()
        case "z" where !shifted:
            // Only while pointing. Everywhere else undo belongs to the page.
            guard browser.veiling else { return false }
            browser.undoHiding()
        // ⌘+ arrives as "=" or "+" depending on the keyboard; both mean bigger.
        case "=", "+":
            window.zoom(by: 1.1)
        case "-":
            window.zoom(by: 1 / 1.1)
        case "0":
            window.resetZoom()
        case "w" where !shifted:
            if window.peekTab != nil {
                window.closePeek()
            } else if let tab = window.active {
                window.close(tab)
            }
        case "l" where !shifted:
            window.edit()
        case "l" where shifted:
            guard browser.prefs.translates || window.active?.translated == true else { return false }
            window.toggleTranslation()
        case "r" where !shifted:
            window.reload()
        case "r" where shifted:
            window.toggleReader()
        case "[":
            shifted ? window.step(-1) : window.back()
        case "]":
            shifted ? window.step(1) : window.forward()
        default:
            // Moving or selecting text belongs to the editor, not the page's
            // history — in web forms and in the browser's own fields alike.
            // The page's own word on typing misses a click straight into a
            // frame, and never reaches into another site's, such as an
            // embedded comment box. The web view has an input context only
            // while the caret is in something editable, in any frame.
            guard !shifted, window.active?.typing != true,
                  window.active?.built?.inputContext == nil,
                  !(event.window?.firstResponder is NSTextView)
            else { return false }
            // ⌘← and ⌘→, for hands that never learned the brackets.
            if event.keyCode == 123 { window.back(); return true }
            if event.keyCode == 124 { window.forward(); return true }
            return false
        }
        return true
    }
}
