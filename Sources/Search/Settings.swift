import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @ObservedObject private var filters = Filters.shared
    @ObservedObject private var wallpaper = Wallpaper.shared
    @State private var isDefault = Links.isDefault
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general

    enum Page: String, CaseIterable, Identifiable {
        case general, appearance, tabs, shortcuts, extensions, passwords, downloads, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .tabs: return "Tabs"
            case .shortcuts: return "Shortcuts"
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .appearance: return "paintpalette"
            case .tabs: return "rectangle.split.3x1"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 168
    /// Wide enough that a line's small buttons — Rename and Delete beside a
    /// colour — sit on one line each.
    private static let width: CGFloat = 740
    private static let height: CGFloat = 500

    /// Where the panel has been pulled to by its title bar, from the middle.
    /// Each opening starts in the middle again.
    @State private var moved: CGSize = .zero
    @GestureState private var pulling: CGSize = .zero

    var body: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(maxWidth: SettingsPanel.width, maxHeight: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .offset(x: moved.width + pulling.width, y: moved.height + pulling.height)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
        .onAppear(perform: takeAskedPage)
        .onChange(of: browser.tuningPage) { _, _ in takeAskedPage() }
    }

    /// The title bar, to move the panel by: it follows the pointer as it is
    /// pulled, with nothing eased in between, and lets go wherever the
    /// pointer stops — unless that is so far out that the title bar would be
    /// out of reach, when it springs back until it isn't. A double-click
    /// puts it back in the middle.
    private var handle: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($pulling) { value, pulling, _ in pulling = value.translation }
            .onEnded { value in
                let wanted = CGSize(width: moved.width + value.translation.width,
                                    height: moved.height + value.translation.height)
                moved = wanted
                let kept = Self.inReach(wanted)
                if kept != wanted { withAnimation(Motion.settle) { moved = kept } }
            }
    }

    private func recentre() {
        withAnimation(Motion.settle) { moved = .zero }
    }

    /// An offset that leaves at least a hand's width of the title bar inside
    /// the window, whatever size the window is.
    private static func inReach(_ offset: CGSize) -> CGSize {
        guard let room = NSApp.keyWindow?.contentView?.bounds.size else { return offset }
        let across = max(0, room.width / 2 + width / 2 - 120)
        let down = max(0, room.height / 2 + height / 2 - 60)
        let up = max(0, room.height / 2 - 40)
        return CGSize(width: min(across, max(-across, offset.width)),
                      height: min(down, max(-up, offset.height)))
    }

    /// The page ⌘K asked for, if it asked (see QuickCommands).
    private func takeAskedPage() {
        guard let asked = browser.tuningPage.flatMap(Page.init) else { return }
        page = asked
        browser.tuningPage = nil
    }

    // MARK: - the rail

    private var pages: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(handle)
                .onTapGesture(count: 2, perform: recentre)
                .padding(.bottom, 12)
            ForEach(Page.allCases) { item in
                PageRow(page: item, on: page == item) { page = item }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: Symbols.current(page.icon))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title.said)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.ground : (hovering ? Palette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.title.said)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
            }
            .contentShape(Rectangle())
            .gesture(handle)
            .onTapGesture(count: 2, perform: recentre)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .appearance: appearance
                    case .tabs:
                        tabs
                        SavedGroupsCard(browser: browser)
                        toolbar
                        speedDial
                    case .shortcuts: ShortcutsPage(browser: browser, store: browser.shortcuts)
                    case .extensions: ExtensionsPage(browser: browser)
                    case .passwords: passwords
                    case .downloads: downloads
                    case .privacy:
                        privacy
                        ContainersCard(browser: browser)
                    case .about: about
                    }
                    if page == .tabs { WallpaperSettings() }
                }
                .padding(.bottom, 4)
                .background(SettingsScrollTuning())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - general

    private var general: some View {
        Card {
            Line(
                "Open links from other apps",
                isDefault ? "SearchX is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
            ) {
                if isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)
                } else {
                    Pill("Make default", filled: true) {
                        Links.becomeDefault { worked in
                            isDefault = Links.isDefault
                            browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                        }
                    }
                }
            }
            Rule()
            Line("Search with", searchDetail) {
                Picker("", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if prefs.engine == .custom {
                ZStack(alignment: .leading) {
                    if prefs.customEngine.isEmpty {
                        Text("https://example.com/search?q=%s")
                            .foregroundStyle(Palette.muted.opacity(0.8))
                    }
                    TextField("", text: $prefs.customEngine)
                        .accessibilityLabel("Search address, with %s where your words go")
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
            Rule()
            Line("Search suggestions", SearchSuggestions.template(for: prefs.engine) == nil
                 ? "This search engine has no supported suggestion service. History suggestions still appear"
                 : "Send typed searches to \(prefs.engine.title) for suggestions. Off in private windows") {
                Switch(on: $prefs.searchSuggestions)
                    .disabled(SearchSuggestions.template(for: prefs.engine) == nil)
            }
            Rule()
            Line("Site shortcuts", "A word before your search goes straight to that site, whatever engine you've picked. \"yt cats\" searches YouTube") {
                Pill("Add") { prefs.keywords.append(Keyword()) }
            }
            ForEach($prefs.keywords) { $entry in
                HStack(spacing: 8) {
                    TextField("yt", text: $entry.keyword)
                        .accessibilityLabel("Shortcut word")
                        .textFieldStyle(.plain)
                        .frame(width: 50)
                    Text("→").foregroundStyle(Palette.muted)
                    TextField("https://www.youtube.com/results?search_query=%s", text: $entry.template)
                        .accessibilityLabel("Site search address, with %s where your words go")
                        .textFieldStyle(.plain)
                    Button {
                        prefs.keywords.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.faint)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            Rule()
            Line("Colour", "A gradient for the frame around the page, as faint or strong as you like. Each space has its own") {
                Pill("Choose…") {
                    browser.tuning = false
                    browser.theming = true
                }
            }
            Rule()
            Line("Page zoom", "Where every site starts. ⌘+ and ⌘− are still remembered for each site.") {
                HStack(spacing: 8) {
                    if prefs.pageZoom != 1 {
                        Pill("Reset") { prefs.pageZoom = 1 }
                    }
                    Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
                }
            }
            Rule()
            Line("Correct spelling as you type", "macOS's autocorrect inside pages, the one that capitalises for you") {
                Switch(on: $prefs.autocorrect)
            }
            Rule()
            Line("Peek at a link with a shift-click", "Its page opens in a panel over the one you're reading. Escape puts it away; the other button keeps it as a tab") {
                Switch(on: $prefs.peeksLinks)
            }
            Rule()
            Line("Back from a link's tab returns to its page", "A link opened in a new tab closes when you go back from its first page, and you are where you clicked it") {
                Switch(on: $prefs.returnsFromLinks)
            }
            Rule()
            Line("Open links from other apps in a small window", "To read and close, or keep with Open in SearchX (⌘O)") {
                Switch(on: $prefs.littleLinks)
            }
            if #available(macOS 15, *) {
                Rule()
                Line("Translate pages and pictures", "⇧⌘L puts a page in your language; right-click a picture to translate its words. Done on this Mac, never sent anywhere") {
                    Switch(on: $prefs.translates)
                }
            }
            Rule()
            Line("Address bar commands", "A word like \"settings\" or \"new tab\" in the address field reaches that instead of a search for it") {
                Switch(on: $prefs.commandBar)
            }
            Rule()
            Line("Show where links go", "Point at a link and its address shows at the bottom of the page") {
                Switch(on: $prefs.showsLinks)
            }
            Rule()
            Line("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop") {
                Switch(on: $prefs.autoScroll)
            }
            Rule()
            Line("Pages at 120 Hz", "Use the display’s higher refresh rate for page rendering when supported. Uses more power. Reload existing tabs to apply") {
                Switch(on: $prefs.fastPages)
            }
            Rule()
            PowerLine()
            Rule()
            Line("Hold a swipe to pick from history", "Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one to go to") {
                Switch(on: $prefs.holdsHistory)
            }
            Rule()
            Line("Allow audible autoplay", "New tabs may start media with sound without waiting for a click.") {
                Switch(on: $prefs.audibleAutoplay)
            }
            Rule()
            Line("Never float video on", "Comma-separated domains, such as youtube.com. Includes their subdomains.") {
                TextField("example.com", text: $prefs.floatBlockedSites)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            Rule()
            Line("Flick the floating video to a corner", "Two fingers on it send it to the corner or edge they point at, instead of pushing it along. Dragging still puts it anywhere") {
                Switch(on: $prefs.floatFlicks)
            }
            Rule()
            Line("Float the video when you switch tabs", "A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand") {
                Switch(on: $prefs.floatsOnLeave)
            }
            Rule()
            Line("Float the video when you switch apps", "A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return") {
                Switch(on: $prefs.floatsAway)
            }
            Rule()
            Line("Let a script drive SearchX", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over. See ./bench") {
                Switch(on: $prefs.bench)
            }
        }
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - appearance

    private var appearance: some View {
        Card {
            Line("Theme", "Light, dark, or follow your Mac") {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line("Bar height", "From almost no padding to extra breathing room.") {
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { Double(prefs.topBarHeight) },
                        set: { prefs.topBarHeight = CGFloat($0.rounded()) }
                    ), in: 30...Double(Metrics.strip)) { Text("Bar height") }
                        .labelsHidden()
                        .frame(width: 100)
                        .tint(wallpaper.accentColor)
                    Text("\(Int(prefs.topBarHeight)) pt")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Rule()
            Line("Transparency", "See through the bars and the sidebar, to the desktop beside the page or to the page under a sidebar that slides out.") {
                chromeSlider("Transparency", value: $prefs.chromeTransparency)
                    .disabled(reduceTransparency)
            }
            Rule()
            Line("Blur strength", "Soften whatever shows through them, the same amount docked or slid out.") {
                chromeSlider("Blur strength", value: $prefs.chromeBlur)
                    .disabled(reduceTransparency || prefs.chromeTransparency == 0)
            }
            Rule()
            Line("Address field glow", "A light travels the edge of the address field on an empty tab: white, or in the colors of your new tab picture.") {
                Switch(on: $prefs.fieldBeam)
            }
            if reduceTransparency {
                Rule()
                Text("Reduce Transparency is enabled in macOS Accessibility settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            }
        }
    }

    private func chromeSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = ($0 * 100).rounded() / 100 }
            ), in: 0...1) { Text(title) }
                .labelsHidden()
                .frame(width: 100)
                .tint(wallpaper.accentColor)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - tabs

    /// What sits in the bar besides the tabs. With the sidebar, back, forward
    /// and reload are already beside the window's buttons: nothing to move.
    private var toolbar: some View {
        Card {
            if !prefs.sidebar {
                Line("Back, forward and reload on the left", "Beside the window's buttons, before the tabs") {
                    Switch(on: $prefs.navigationLeft)
                }
                Rule()
            }
            Line("Show the Bookmarks button", "The Bookmarks menu has them either way") {
                Switch(on: $prefs.bookmarkButton)
            }
            Rule()
            Line("Show the Extensions button", "Pinned extensions stay where they are") {
                Switch(on: $prefs.extensionButton)
            }
            Rule()
            Line("Show the Downloads button", "Progress, completed files and cancellation are also in History › Downloads") {
                Switch(on: $prefs.downloadButton)
            }
        }
    }

    /// Speed Dial: a button for it, and whether new tabs open on it.
    private var speedDial: some View {
        Card {
            Line("Show the Speed Dial button", "Beside reload: your bookmarked sites as tiles, in the tab you're on") {
                Switch(on: $prefs.dialButton)
            }
            Rule()
            Line("New tabs open Speed Dial", "Instead of the address field. This takes the place of an extension's new tab page") {
                Switch(on: $prefs.newTabDial)
            }
        }
    }

    private var tabs: some View {
        Card {
            Line("Tabs in a sidebar", "Down the \(prefs.sidePosition.rawValue) instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.fold(prefs.sideSpeed)) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line("Sidebar position", "Tabs down the \(prefs.sidePosition.rawValue) edge of the window") {
                    Segmented(options: SidebarPosition.allCases.map { ($0, $0.title) }, selection: $prefs.sidePosition)
                }
                Rule()
                Line("Hide the sidebar until the pointer reaches the edge", "The page takes the whole window; push against its \(prefs.sidePosition.rawValue) edge for the tabs.\(browser.shortcuts.key(for: "view.fold").map { " \($0.display) keeps them out." } ?? "")") {
                    Switch(on: $prefs.sideHides)
                }
                if prefs.sideHides {
                    Rule()
                    Line("Sidebar opening delay", "Wait at the edge before revealing the tabs.") {
                        Picker("Sidebar opening delay", selection: $prefs.sideDelay) {
                            Text("None").tag(0.0)
                            Text("Normal").tag(0.15)
                            Text("Long").tag(0.4)
                        }.labelsHidden().frame(width: 130)
                    }
                }
                Rule()
                Line("Bookmarks in the sidebar", "Show bookmark folders above the tabs.") {
                    Switch(on: $prefs.bookmarksInSidebar)
                }
                Rule()
                Line("Sidebar speed", "How long it takes to open and close.") {
                    HStack(spacing: 10) {
                        // No `step`: on the Mac that draws a tick for every
                        // one. Rounded to hundredths here instead.
                        Slider(value: Binding(
                            get: { prefs.sideSpeed },
                            set: { prefs.sideSpeed = ($0 * 100).rounded() / 100 }
                        ), in: Preferences.sideSpeeds)
                            .controlSize(.small)
                            .tint(Palette.ink)
                            .frame(width: 140)
                        Text(prefs.sideSpeed > 0 ? String(format: "%.2f s", prefs.sideSpeed) : "Instant")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Rule()
            Line("Tabs show", "Beside the title, and on a pinned square") {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line("Pins return to their original page", "Closing a pinned tab puts it back at the address where you pinned it") {
                Switch(on: $prefs.pinsReturnHome)
            }
            Rule()
            Line("Show sidebar pins as rows", "Keep each pinned page's title above the other tabs") {
                Switch(on: $prefs.pinRows)
            }
            if !prefs.pinRows {
                Rule()
                Line("Pinned icons per row", "Automatic grows the grid with the number of pins") {
                    Picker("Columns", selection: $prefs.pinColumns) {
                        Text("Automatic").tag(0)
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: 120)
                }
            }
            Rule()
            Line("Show the bookmarks bar", "Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs") {
                Switch(on: $prefs.bookmarksBar)
            }
            Rule()
            Line("Show how far you've read", "The tab you're on fills with grey as you scroll down the page") {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line("Split view", "Show two tabs side by side. Start from a tab's menu, then drag or choose a second tab.") {
                Switch(on: $prefs.splitViews)
            }
            Rule()
            Line("Sleep tabs you aren't using", "After half an hour away they come back where you left them. Sound, calls and anything typed stay awake.") {
                Switch(on: $prefs.sleepsTabs)
            }
            if prefs.sleepsTabs {
                Rule()
                Line("Let pinned tabs sleep too", "They keep their place and letter, and load again when you open them") {
                    Switch(on: $prefs.pinsSleep)
                }
            }
            Rule()
            Line("Load tabs when you first see them", "Tabs opened in the background, or many at once, wait until they're on screen") {
                Switch(on: $prefs.lazyTabs)
            }
            Rule()
            Line("Ctrl+Tab walks recent tabs", "Most recently looked at first, like switching apps. Hold it and press Tab again for the one before that. Off, it walks the row in order.") {
                Switch(on: $prefs.mruTabs)
            }
            Rule()
            Line("Spaces", "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1 to ⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1 to ⌃9, if you turned them on, take those keys first.") {
                Switch(on: $prefs.usesSpaces)
            }
            Rule()
            Line("Tab groups", "Named sections in the sidebar. Right-click a tab to start a group; click its heading to hide or show its tabs.") {
                Switch(on: $prefs.usesTabGroups)
            }
            Rule()
            Line("⌃Tab shows the tabs as pictures", "The one you were just on first, as in Arc and Dia: tap for the last tab, or hold ⌃ and keep pressing Tab, then let go. Off, ⌃Tab walks along the row.") {
                Switch(on: $prefs.tabPictures)
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving. It asked SearchX not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have. Off, sites ask for the password"
                        : Passkeys.access == .denied
                        ? "macOS said no. Allow it in System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or an iCloud passkey, on sites that offer one"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Bring yours in", "From another browser on this Mac. Nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        Card {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            Rule()
            Line("Ask where to save each file") {
                Switch(on: $prefs.asksWhereToSave)
            }
        }
    }

    // MARK: - privacy

    /// uBlock Origin's default lists: how many rules, and how fresh.
    private var filterDetail: String {
        let status = filters.status
        if let trouble = status.trouble { return trouble }
        if status.working && status.updated == nil { return "Getting uBlock Origin’s lists. The built-in list works meanwhile" }
        guard let updated = status.updated else { return "uBlock Origin’s lists, checked every four days" }
        let rules = status.rules.formatted(.number)
        return "uBlock Origin’s lists · \(rules) rules · updated \(updated.formatted(.relative(presentation: .named)))"
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is blocked until this clears. Try again, or restart SearchX") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if prefs.shielded {
                    Rule()
                    Line("Use filter lists", "uBlock Origin’s lists and the built-in one. Off, pop-ups are still judged by what the click landed on") {
                        Switch(on: $prefs.filterLists)
                    }
                }
                if prefs.shielded && prefs.filterLists {
                    Rule()
                    Line("Filter lists", filterDetail) {
                        if filters.status.working {
                            ProgressView().controlSize(.small)
                        } else {
                            Pill("Update now") { Task { await filters.update(force: false) } }
                        }
                    }
                    Rule()
                    Line("My filters", "Your own, in uBlock Origin’s syntax, procedural ones included. They never act on sign-in, passkey or payment pages") {
                        Pill("Edit filters") { browser.tuning = false; browser.blockering = .filters }
                    }
                    Rule()
                    Line("My rules", "Block or allow a site’s scripts, frames or third parties, as uBlock Origin’s dynamic filtering does") {
                        Pill("Edit rules") { browser.tuning = false; browser.blockering = .rules }
                    }
                    Rule()
                    Line("Blocker log", "What was blocked on the page in front, and what it loaded") {
                        Pill("Open log") { browser.tuning = false; browser.blockering = .log }
                    }
                }
                if Protections.available {
                    Rule()
                    Line("Fingerprinting protection", "Makes this Mac harder to recognise from what pages can measure. Always on in private windows. Some sign-ins may ask for a captcha more often.") {
                        Switch(on: $prefs.fingerprinting)
                    }
                }
                Rule()
                Line("Camera and microphone", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
            }
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                let sources = ImportSource.installed()
                if !sources.isEmpty {
                    Rule()
                    Line("Bring in from", "History from another browser on this Mac") {
                        ForEach(sources) { source in
                            Pill(source.name) { browser.takePlaces(from: source) { _ in } }
                        }
                    }
                }
                if prefs.usesDial {
                    Rule()
                    Line("Speed Dial", "Its tiles and previews; the bookmarks stay") {
                        Pill("Clear") {
                            browser.speedDial.reset()
                            browser.announce(browser.speedDial.error ?? "Speed Dial cleared")
                        }
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    // MARK: - about

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Logomark()
                    .fill(Palette.ink, style: FillStyle(eoFill: true))
                    .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                    .frame(height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SearchX")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Search, extended · version \(Updater.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Text("Built by Shyamalan Kannan")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                Line("Install updates on its own", "Off, SearchX still looks once a day and tells you, and installs only when you press Install") {
                    Switch(on: $prefs.installsUpdates)
                }
                Rule()
                Line("Found something wrong?", "Opens a new issue with the version already in it") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
            }

            Card {
                Shortcut("⌘L", "Address")
                Rule()
                Shortcut("⌘K", "Switch tab")
                Rule()
                Shortcut("⌘T  ⌘W  ⇧⌘T", "New, close, reopen tab")
                Rule()
                Shortcut("⌘D  ⇧⌘D", "Bookmark the page, duplicate the tab")
                Rule()
                Shortcut("⇧⌘K", "Close every other tab")
                Rule()
                Shortcut("⇧⌘V", "Paste and go")
                Rule()
                Shortcut("⇧⌘C", "Copy address")
                Rule()
                Shortcut("⌃⇥  ⌥⌘→  ⌘1–9", "Next tab, a tab by its place")
                Rule()
                Shortcut("⇧⌘S", "Tabs in a sidebar")
                Rule()
                Shortcut("⌘S", "Fold the sidebar away")
                Rule()
                Shortcut("⇧⌘R", "Reading mode")
                Rule()
                Shortcut("⇧⌘H", "Hide something on this site")
                Rule()
                Shortcut("⇧⌘P", "Float the video")
                Rule()
                Shortcut("⇧⌘⌫", "Clear browsing data")
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "SearchX \(next.version) is downloading…"
        case .ready(let next): return "SearchX \(next.version) is ready"
        case .offered(let next), .waiting(let next): return "SearchX \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))). SearchX checks once a day on its own" }
                ?? "Checked once a day on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background. Nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open SearchX"
        case .offered(let next), .waiting(let next):
            return next.notes ?? "Update replaces this copy and reopens it. Tabs, sign-ins and settings stay"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready, .offered, .waiting:
            Pill("Update", filled: true) { updater.update() }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

    // MARK: - pieces

    /// A keystroke and what it does.
    private struct Shortcut: View {
        let keys: String
        let does: String
        init(_ keys: String, _ does: String) { self.keys = keys; self.does = does }

        var body: some View {
            HStack {
                Text(does.said)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(keys)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// SwiftUI's default ten-point wheel line barely moves a Settings row.
/// Three lines now move about a row and a half; precise trackpad input,
/// momentum and controls inside the scroll view keep AppKit's behavior.
private struct SettingsScrollTuning: NSViewRepresentable {
    func makeNSView(context: Context) -> TuningView { TuningView() }
    func updateNSView(_ view: TuningView, context: Context) { view.tune() }

    final class TuningView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tune() }
        override func layout() { super.layout(); tune() }
        func tune() { enclosingScrollView?.verticalLineScroll = 30 }
    }
}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide
    @FocusState private var focused: Option?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Button {
                    withAnimation(Motion.settle) { selection = option }
                } label: {
                    Text(title.said)
                        .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                        .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                        .fixedSize(horizontal: !wide, vertical: false)
                        .frame(maxWidth: wide ? .infinity : nil)
                        .padding(.horizontal, wide ? 4 : 10)
                        .padding(.vertical, 5)
                        .background {
                            if option == selection {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Palette.ground)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "chosen", in: slide)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(focused == option ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(ChromeButtonStyle())
                .focused($focused, equals: option)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool
    @Environment(\.settingsControlTitle) private var title

    var body: some View {
        Toggle(title, isOn: $on)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Palette.ink)
            .controlSize(.small)
            .frame(minWidth: 30, minHeight: 24)
    }
}

/// A value moved one stop at a time: − and + either side of it, in the same
/// outlined capsule as a pill. Pressing the value itself takes it home.
struct Steps: View {
    let stops: [Double]
    @Binding var value: Double
    let home: Double
    let label: (Double) -> String

    /// The nearest stop either way — a value between stops, from before
    /// there were stops, still moves to a round one.
    private var below: Double? { stops.last { $0 < value - 0.001 } }
    private var above: Double? { stops.first { $0 > value + 0.001 } }

    var body: some View {
        HStack(spacing: 0) {
            Step(icon: "minus", to: below) { value = $0 }
            Button { value = home } label: {
                Text(label(value))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 36, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to \(label(home))")
            Step(icon: "plus", to: above) { value = $0 }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Step: View {
        let icon: String
        let to: Double?
        let act: (Double) -> Void
        @State private var hovering = false
        @FocusState private var focused: Bool

        var body: some View {
            Button { if let to { act(to) } } label: {
                Image(systemName: Symbols.current(icon))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(to == nil ? Palette.faint : Palette.ink)
                    .frame(width: 24, height: 24)
                    .background(hovering && to != nil ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
                    .overlay(Circle().strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(ChromeButtonStyle())
            .focused($focused)
            .accessibilityLabel((icon == "minus" ? "Decrease" : "Increase").said)
            .disabled(to == nil)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title.said)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? Palette.ground : tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 24, minHeight: 26)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .overlay(Capsule().strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
        }
        // Pressed, it gives a little under the pointer (see Press).
        .buttonStyle(Press())
        .focused($focused)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}
