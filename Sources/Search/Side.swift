import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var window: WindowModel
    /// Profile services this window draws from.
    var browser: Browser { window.profile }
    @ObservedObject var prefs: Preferences
    @ObservedObject private var bookmarks: Bookmarks
    /// Out over the page from the fold, where its edge is the shadow it
    /// casts rather than a line.
    var floating = false

    init(window: WindowModel, prefs: Preferences, floating: Bool = false) {
        self.window = window
        self.prefs = prefs
        self.floating = floating
        self.bookmarks = window.profile.bookmarks
    }

    @Namespace private var pill

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false
    @State private var groupFrames: [UUID: CGRect] = [:]
    @State private var expandedBookmarks: Set<Bookmark.ID> = []

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero

    private static let row: CGFloat = 28
    private static let gap: CGFloat = 2
    private static let square: CGFloat = 34
    private static let pinGap: CGFloat = 4

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: window.makingSpace ? .greatestFiniteMagnitude : rowsEnd)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + Metrics.sideLights)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                DragStrip()
            }
            .frame(height: prefs.topBarHeight)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: Metrics.sideLights)
                    Helm(window: window)
                    Spacer(minLength: 0)
                }
                .frame(height: prefs.topBarHeight)

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background(landing ? Palette.hover : .clear)
        .background { ChromeBackground(prefs: prefs) }
        .overlay(alignment: prefs.sidePosition == .right ? .leading : .trailing) {
            if !floating { Rectangle().fill(Palette.hairline).frame(width: 1) }
        }
        .overlay(alignment: prefs.sidePosition == .right ? .leading : .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            window.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(nil, value: window.activeID)
        .animation(Motion.glide, value: window.editingTab)
        .animation(Motion.settle, value: window.tabs.map(\.id))
        .animation(Motion.settle, value: window.pinnedCount)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let direction: CGFloat = prefs.sidePosition == .right ? -1 : 1
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width * direction
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        window.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == window.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swipe = window.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(window: window)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == window.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if window.pinnedCount > 0 {
                        pinned
                            .padding(.bottom, 10)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollViewReader { proxy in
                            // The scroll view reaches into the margin on
                            // the right and the rows keep it inside, so the
                            // system's bar lands in the margin beside them
                            // rather than over the cross on the tab under the
                            // pointer. The column's edge lies over that margin
                            // and answers first, so the bar never fights the
                            // resize; the wheel and the trackpad still scroll.
                            ScrollView(.vertical) {
                                rows.padding(.trailing, 10)
                            }
                            .padding(.trailing, -10)
                            // The tab you go to is the tab you see — ⌘1–⌘9,
                            // ⇧⌘], a link opening beside the one on screen.
                            .onChange(of: window.activeID) { _, id in
                                guard let id else { return }
                                proxy.scrollTo(id)
                            }
                            .onAppear {
                                if let id = window.activeID { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            } else {
                preview(window.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil }
        let rest = row.tabs.filter { $0.pin == nil }
        let cols = pinColumns(pins.count)
        let width = pinWidth(for: pins.count)
        let height = prefs.pinRows ? SideBar.row : min(SideBar.square, width)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
                        ForEach(pins) { tab in
                            if prefs.pinRows {
                                SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                            } else {
                                PinSquare(window: window, prefs: prefs, tab: tab, live: tab.id == row.active,
                                          pill: pill, width: width, height: height)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            VStack(spacing: SideBar.gap) {
                if prefs.usesTabGroups {
                    ForEach(row.groups) { group in
                        GroupHeading(window: window, group: group)
                        ForEach(rest.filter { $0.groupID == group.id && (!group.collapsed || $0.id == row.active) }) { tab in
                            SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                        }
                    }
                }
                ForEach(rest.filter { !prefs.usesTabGroups || $0.groupID == nil }) { tab in
                    SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                }
            }
            newTab
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let pins = window.pinnedCount
        let cols = pinColumns(pins)
        let pinRows = pins == 0 ? 0 : (pins + cols - 1) / cols
        let pinBlock = pinRows == 0 ? 0
            : CGFloat(pinRows) * pinHeight + CGFloat(pinRows - 1) * SideBar.pinGap + 10
        let visible = prefs.usesTabGroups
            ? window.tabGroups.reduce(0) { $0 + window.visibleTabs(in: $1).count + 1 } + window.tabs(in: nil).count
            : window.tabs.count - pins
        let loose = CGFloat(visible) * (SideBar.row + SideBar.gap)
        let bookmarkBlock = showsBookmarks ? CGFloat(visibleBookmarkCount(bookmarks.roots)) * 31 + 42 : 0
        return prefs.topBarHeight + pinBlock + bookmarkBlock + loose + SideBar.row + 8
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { window.tabs.filter { $0.pin != nil } }
    private var looseTabs: [Tab] { window.tabs.filter { $0.pin == nil } }
    private var showsBookmarks: Bool { prefs.bookmarksInSidebar && !bookmarks.isEmpty }

    private func visibleBookmarkCount(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + 1 + (expandedBookmarks.contains($1.id) ? visibleBookmarkCount($1.children ?? []) : 0) }
    }

    /// Three columns is the block's own shape — up to six pins, that's two
    /// full rows, and one or two is just those same three places with a
    /// couple of them empty rather than a lonely row of its own width. Only
    /// past six does the block widen, one column at a time, to stay at two
    /// rows for as long as that's a reasonable shape at all.
    private func pinColumns(_ count: Int) -> Int {
        if prefs.pinRows { return 1 }
        let fitting = max(1, Int((prefs.sideWidth - 20 + SideBar.pinGap) / (20 + SideBar.pinGap)))
        return min(fitting, prefs.pinColumns > 0 ? prefs.pinColumns : max(3, (count + 1) / 2))
    }

    /// However many columns the count calls for, they split the row's own
    /// width between them — the row is what fills edge to edge, not each
    /// cell on its own, so this grows past 34 just as readily as it shrinks
    /// below it.
    private var pinWidth: CGFloat { pinWidth(for: window.pinnedCount) }

    private func pinWidth(for count: Int) -> CGFloat {
        let cols = pinColumns(count)
        guard cols > 0 else { return SideBar.square }
        let available = prefs.sideWidth - 20 - CGFloat(cols - 1) * SideBar.pinGap
        return max(20, available / CGFloat(cols))
    }

    /// The one dimension that doesn't chase the sidebar's width: past three
    /// columns' worth of room a cell would otherwise turn into a big square
    /// rather than the wide, short button pinned tabs actually look like
    /// everywhere else in this app. It only shrinks below 34 alongside the
    /// width, once a narrow column leaves no other choice.
    private var pinHeight: CGFloat {
        prefs.pinRows ? SideBar.row : min(SideBar.square, pinWidth)
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = pinColumns(tabs.count)
        let width = pinWidth
        let height = pinHeight
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let held = pinDragging == tab.id
                Group {
                    if prefs.pinRows {
                        SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == window.activeID,
                                pill: pill, close: { window.close(tab) })
                    } else {
                PinSquare(
                    window: window,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == window.activeID,
                    pill: pill,
                    width: width,
                    height: height
                )
                    }
                }
                .offset(pinOffset(held: held, index: index, columns: cols))
                // Under the hand exactly, as a row is (see the rows below).
                .transaction { if held { $0.animation = nil } }
                .zIndex(held ? 1 : 0)
                .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, columns: cols, width: width, height: height))
            }
        } }
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `window.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, columns: Int) -> CGSize {
        guard held else { return .zero }
        let stepX = pinWidth + SideBar.pinGap
        let stepY = pinHeight + SideBar.pinGap
        let from = (row: pinFrom / columns, col: pinFrom % columns)
        let now = (row: index / columns, col: index % columns)
        return CGSize(
            width: pinTravel.width - CGFloat(now.col - from.col) * stepX,
            height: pinTravel.height - CGFloat(now.row - from.row) * stepY
        )
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// — a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int) -> Int {
        min(max(0, from + moved), max(0, pinnedTabs.count - 1))
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                }
                pinTravel = value.translation
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                let target = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY))
                if target != index {
                    withAnimation(Motion.settle) {
                        window.move(tab, to: target)
                    }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    pinDragging = nil
                    pinTravel = .zero
                }
            }
    }

    // MARK: - the rows

    private var loose: some View {
        VStack(spacing: SideBar.gap) {
            if prefs.usesTabGroups {
                ForEach(window.tabGroups) { group in
                    GroupHeading(window: window, group: group, dragSpace: "rows")
                    tabRows(window.visibleTabs(in: group), group: group.id)
                }
                tabRows(window.tabs(in: nil), group: nil)
            } else {
                tabRows(looseTabs, group: nil)
            }
        }
        .coordinateSpace(name: "rows")
        .onPreferenceChange(GroupDropFrames.self) { groupFrames = $0 }
    }

    private func tabRows(_ tabs: [Tab], group: UUID?) -> some View {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let step = SideBar.row + SideBar.gap
                SideRow(
                    window: window,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == window.activeID,
                    pill: pill,
                    close: { window.close(tab) }
                )
                // Positions here are among the loose rows; the pinned block
                // sits in front of them in the real list.
                .modifier(Carried(
                    index: index,
                    count: tabs.count,
                    step: step,
                    vertical: true,
                    space: "rows",
                    move: {
                        if prefs.usesTabGroups { window.move(tab, within: group, to: $0) }
                        else { window.move(tab, to: $0 + window.pinnedCount) }
                    },
                    tab: tab,
                    window: window,
                    groupAt: { point in groupFrames.first { $0.value.contains(point) }?.key }
                ))
                .modifier(SplitSource(browser: window, tab: tab))
                .id(tab.id)
            }
    }

    /// The loose tabs and the row that makes another, which scroll as one.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBookmarks {
                Text("Bookmarks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                BookmarkOutline(bookmarks: bookmarks, expanded: $expandedBookmarks,
                                editing: $window.editingSidebarBookmarkID,
                                open: { window.pickBookmark($0) },
                                openInNewTab: { window.pickBookmark($0, inNewTab: true) })
            }
            loose
            newTab
        }
    }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row) { window.newTab() }
            .padding(.top, SideBar.gap)
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        HStack(spacing: 2) {
            if browser.prefs.usesSpaces { SpaceDot(window: window) }
            ExtensionSlot(edge: .trailing, showMenu: prefs.extensionButton)
            if prefs.bookmarkButton {
                BookmarkDoor(browser: browser, arrowEdge: .trailing)
            }
            if prefs.dialButton {
                Door(icon: "square.grid.2x2", help: "Speed Dial") { window.showDial() }
                    .accessibilityLabel("Speed Dial")
            }
            if prefs.downloadButton {
                Door(icon: "arrow.down.circle", help: "Downloads") { browser.hoarding = true }
                    .accessibilityLabel("Downloads")
            }
            PanelDoors(window: window)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(
            width: CGFloat(columns) * width + CGFloat(max(0, columns - 1)) * spacing,
            height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                    y: bounds.minY + CGFloat(index / columns) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false
    /// A plain click, with no modifier held.
    private var plain: Bool {
        (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .shift]).isEmpty
    }
    private var selected: Bool { window.selectedTabs.contains(tab.id) }

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if window.editingPin == tab.id {
                PinField(window: window, tab: tab)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                SelectionGround(radius: scale * 9 / 34)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else if selected {
                SelectionGround(radius: scale * 9 / 34)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(hovering ? Palette.hover : Palette.wash.opacity(0.55))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            if live && plain { window.editLetter(tab) } else { window.pickTab(tab) }
        })
        .overlay {
            if live { ModifiedTabClick { window.pickTab(tab, modifiers: $0) } }
        }
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { window.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(window: window, tab: tab, close: { window.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    /// One of a chosen set of tabs, lit wherever the pointer is.
    private var selected: Bool { window.selectedTabs.contains(tab.id) }
    /// A plain click, with no modifier held: command and shift are
    /// selection gestures, and the row answers them as such.
    private var plain: Bool { (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .shift]).isEmpty }

    private var editing: Bool { window.editingTab == tab.id }

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TabAddressField(window: window)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                ContainerDot(tab: tab)
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            if status {
                Spacer(minLength: 2)

                ZStack {
                    if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                // The cross takes this place while the pointer is here; the
                // speaker moves one place in, clear of the cross's reach.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 23 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, status ? 7 : 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)

        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: 26)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                .overlay {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            if live && plain { window.beginTabEdit(tab) } else { window.pickTab(tab) }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(window: window, tab: tab, close: close) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: window.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(Motion.easeOut(0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                SelectionGround()
                if selected {
                    // One of a chosen set: the accent over the wash, so
                    // the row reads as picked wherever the pointer is.
                    Rectangle().fill(Palette.ink.opacity(0.055))
                }
                if prefs.showsReading {
                    GeometryReader { geo in
                        // A view of its own, watching the tab's own reading:
                        // a frame of a scroll redraws this and nothing else.
                        ReadingFill(reading: tab.reading, span: geo.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if selected {
            // One of a chosen set but not the tab on screen: the accent
            // wash, lit wherever the pointer is.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: Symbols.current(icon))
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title.said)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The speaker at the end of a tab that plays sound, or that was muted and
/// so says it is: a press mutes the tab or lets it be heard again. Drawn as
/// it was before it could be pressed, with the cross's faint disc behind
/// it only while the pointer is on it.
struct Speaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: act) {
            Image(systemName: Symbols.current(icon))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(ChromeButtonStyle())
        .focused($focused)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel((help.isEmpty ? icon : help).said)
        .onHover { hovering = $0 }
        .help(help.said)
    }
}
