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
    /// False for the column's first frame on screen. Whatever is in it
    /// arrives with it, on its slide; a row or a pin makes its own entrance
    /// only when it is added to a column already there. Each running its own
    /// as the folded column came out made them drift apart as it slid.
    @State private var settled = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false
    /// A row or a heading picked up in the column, and where each one is.
    @State private var carrying: Carrying?
    @State private var itemFrames: [UUID: CGRect] = [:]
    /// How tall the rows are, so their scroll view is no taller than they
    /// are while they fit; nil until first measured.
    @State private var rowsHeight: CGFloat?
    /// The lifted copy's own pill, apart from the one the live row wears.
    @Namespace private var lifted
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
                    // Settings › Tabs › Hide the sidebar until the pointer
                    // reaches the edge, and ⌘S: beside the lights, where
                    // Safari and Arc keep theirs.
                    Door(icon: prefs.sidePosition == .right ? "sidebar.right" : "sidebar.left",
                         help: window.profile.shortcuts.tip(window.folded ? "Keep the sidebar open" : "Hide the sidebar", "view.fold")) {
                        window.toggleFold()
                    }
                    .padding(.trailing, 4)
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
        .environment(\.columnSettled, settled)
        .onAppear { DispatchQueue.main.async { settled = true } }
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
                    // end and the foot at the other. While it fits the scroll
                    // view is only as tall as the rows, and the space under it
                    // is still the window's to be dragged by. Inside the page:
                    // the swipe between spaces moves the page, scroll and all.
                    //
                    // One scroll view, sized to its rows: a ViewThatFits
                    // choosing between the rows and the rows in a scroll view
                    // kept both, and laid a long column out twice on every
                    // pass — a hundred and fifty tabs, three hundred rows.
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
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowsHeight = $0 }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: rowsHeight ?? .infinity, alignment: .top)
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
        let cells = pinCells(pins.count)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(cells: cells) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                            if prefs.pinRows {
                                SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                            } else {
                                PinSquare(window: window, prefs: prefs, tab: tab, live: tab.id == row.active,
                                          pill: pill, width: cells[index].width, height: cells[index].height)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            VStack(spacing: SideBar.gap) {
                if prefs.usesTabGroups {
                    ForEach(Array(row.groups.enumerated()), id: \.element.id) { index, group in
                        GroupHeading(window: window, group: group, members: rest.filter { $0.groupID == group.id })
                            .padding(.top, index > 0 ? SideItem.sectionGap : 0)
                        let shown = rest.filter { $0.groupID == group.id && (!group.collapsed || $0.id == row.active) }
                        ForEach(shown) { tab in
                            SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                                .padding(.leading, SideItem.indent)
                                .background(alignment: .topLeading) { GroupLine(last: tab.id == shown.last?.id) }
                        }
                    }
                }
                let ungrouped = rest.filter { !prefs.usesTabGroups || $0.groupID == nil }
                ForEach(ungrouped) { tab in
                    SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                        .padding(.top, prefs.usesTabGroups && !row.groups.isEmpty && tab.id == ungrouped.first?.id ? SideItem.sectionGap : 0)
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
        let pinBlock = pins == 0 ? 0 : (pinCells(pins).map(\.maxY).max() ?? 0) + 10
        let sections = prefs.usesTabGroups ? window.sections() : [:]
        let visible = prefs.usesTabGroups ? visibleCount(sections) : window.tabs.count - pins
        // The space each section after the first starts with (see Nesting).
        let groups = prefs.usesTabGroups ? window.tabGroups.count : 0
        let openings = max(0, groups - 1) + (groups > 0 && !(sections[nil] ?? []).isEmpty ? 1 : 0)
        let loose = CGFloat(visible) * (SideBar.row + SideBar.gap) + CGFloat(openings) * SideItem.sectionGap
        let bookmarkBlock = showsBookmarks ? CGFloat(visibleBookmarkCount(bookmarks.roots)) * 31 + 42 : 0
        return prefs.topBarHeight + pinBlock + bookmarkBlock + loose + SideBar.row + 8
    }

    /// Headings and the rows under them that show, and the tabs in no group.
    private func visibleCount(_ sections: [UUID?: [Tab]]) -> Int {
        window.tabGroups.reduce(0) { count, group in
            let members = sections[group.id] ?? []
            return count + 1 + (group.collapsed ? members.filter { $0.id == window.activeID }.count : members.count)
        } + (sections[nil]?.count ?? 0)
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { window.tabs.filter { $0.pin != nil } }
    private var looseTabs: [Tab] { window.tabs.filter { $0.pin == nil } }
    private var showsBookmarks: Bool { prefs.bookmarksInSidebar && !bookmarks.isEmpty }

    private func visibleBookmarkCount(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + 1 + (expandedBookmarks.contains($1.id) ? visibleBookmarkCount($1.children ?? []) : 0) }
    }

    /// How many squares go in each row, when the columns are Automatic: at
    /// most four — fewer only when the column is too narrow for four of the
    /// classic width — and as even as they go, the fuller rows first. Five
    /// are three and two, seven four and three, nine three, three and three,
    /// ten four, three and three.
    static func pinRows(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let rows = (count + most - 1) / most
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Where each pin goes, in the order of the row. As rows (Settings ›
    /// Show sidebar pins as rows), one to a line. With a number of columns
    /// set, that many to a row, as many as fit. Automatic, the rows as even
    /// as they go (see pinRows); up to three stay the one row of three places
    /// they always were, with a place or two empty rather than a lonely
    /// button the column's width. Each row splits the column's width between
    /// its own cells, and every row is as tall as the narrowest cell allows,
    /// never taller than the classic square.
    private func pinCells(_ count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let room = prefs.sideWidth - 20
        let gap = SideBar.pinGap
        let rows: [Int]
        var slots: [Int]
        if prefs.pinRows {
            rows = Array(repeating: 1, count: count)
            slots = rows
        } else if prefs.pinColumns > 0 {
            let fitting = max(1, Int((room + gap) / (20 + gap)))
            let cols = min(fitting, prefs.pinColumns)
            rows = stride(from: 0, to: count, by: cols).map { min(cols, count - $0) }
            slots = rows.map { _ in cols }
        } else {
            let fits = max(1, Int((room + gap) / (SideBar.square + gap)))
            rows = SideBar.pinRows(count, most: min(4, fits))
            slots = rows.map { rows.count == 1 ? max($0, min(3, fits)) : $0 }
        }
        let widths = slots.map { max(20, (room - CGFloat($0 - 1) * gap) / CGFloat($0)) }
        let height = prefs.pinRows ? SideBar.row : min(SideBar.square, widths.min() ?? SideBar.square)
        var cells: [CGRect] = []
        for (row, n) in rows.enumerated() {
            for col in 0..<n {
                cells.append(CGRect(x: CGFloat(col) * (widths[row] + gap),
                                    y: CGFloat(row) * (height + gap),
                                    width: widths[row], height: height))
            }
        }
        return cells
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cells = pinCells(tabs.count)
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(cells: cells) {
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
                    width: cells[index].width,
                    height: cells[index].height
                )
                    }
                }
                .offset(pinOffset(held: held, index: index, cells: cells))
                // Under the hand exactly, as a row is (see the rows below).
                .transaction { if held { $0.animation = nil } }
                .zIndex(held ? 1 : 0)
                .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, cells: cells))
            }
        } }
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `window.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, cells: [CGRect]) -> CGSize {
        guard held, cells.indices.contains(pinFrom), cells.indices.contains(index) else { return .zero }
        let from = cells[pinFrom], now = cells[index]
        return CGSize(
            width: pinTravel.width - (now.midX - from.midX),
            height: pinTravel.height - (now.midY - from.midY)
        )
    }

    /// The cell the held pin is over: the one whose centre is nearest to where
    /// the fingers have taken the pin's own centre. Rows of different lengths
    /// have cells of different widths, so a count of steps along one axis
    /// would land in the wrong one.
    private func pinTarget(cells: [CGRect]) -> Int {
        guard cells.indices.contains(pinFrom) else { return 0 }
        let start = cells[pinFrom]
        let point = CGPoint(x: start.midX + pinTravel.width, y: start.midY + pinTravel.height)
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? pinFrom
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, cells: [CGRect]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                }
                pinTravel = value.translation
                let target = pinTarget(cells: cells)
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

    /// Headings and rows as one list, so a tab carried from one group into
    /// another stays the same view the whole way — two lists, and SwiftUI
    /// made it anew in the second, ending the drag under the hand.
    private var sideItems: [SideItem] {
        guard prefs.usesTabGroups else { return looseTabs.map { .row($0, .loose) } }
        var items: [SideItem] = []
        let held: UUID? = carrying?.id
        let sections = window.sections()
        for group in window.tabGroups {
            let members = sections[group.id] ?? []
            items.append(.heading(group, members, opens: !items.isEmpty))
            // A group being carried folds its tabs under its heading.
            if held == group.id { continue }
            // Folded, it still shows the tab on screen, and the one in hand.
            let shown = group.collapsed ? members.filter { $0.id == window.activeID || $0.id == held } : members
            items += shown.enumerated().map { index, tab in
                .row(tab, Nesting(grouped: true, last: index == shown.count - 1))
            }
        }
        // The tabs in no group start a section of their own under the last group.
        items += (sections[nil] ?? []).enumerated().map { index, tab in
            .row(tab, Nesting(opens: index == 0 && !items.isEmpty))
        }
        return items
    }

    private var loose: some View {
        // Lazy: a long column builds, lays out and draws the rows near
        // where it's scrolled to, not all of them on every slide and switch.
        // A row it hasn't built has no frame; see `firstBelow`.
        LazyVStack(spacing: SideBar.gap) {
            ForEach(sideItems) { item in
                item.view(window: window, prefs: prefs, pill: pill)
                    // Its place, kept open while it is in the hand.
                    .opacity(carrying?.id == item.id ? 0 : 1)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SideItemFrames.self,
                                                   value: [item.id: geometry.frame(in: .named("rows"))])
                        }
                    }
                    .gesture(carry(item), including: window.visiblePair == nil ? .all : .subviews)
            }
        }
        .coordinateSpace(name: "rows")
        .onPreferenceChange(SideItemFrames.self) { itemFrames = $0 }
        .overlay(alignment: .topLeading) { liftedItem }
    }

    /// The row or heading in the hand: a copy, over the list, exactly under
    /// the pointer, while the list makes room for it underneath.
    @ViewBuilder
    private var liftedItem: some View {
        if let carrying, let item = carrying.item {
            item.view(window: window, prefs: prefs, pill: lifted)
                .frame(width: carrying.width)
                .offset(y: carrying.top + carrying.travel)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }

    private func carry(_ item: SideItem) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .onChanged { value in
                if carrying == nil {
                    guard let frame = itemFrames[item.id] else { return }
                    carrying = Carrying(item: item, top: frame.minY, width: frame.width, height: frame.height)
                }
                carrying?.travel = value.translation.height
                guard let carrying else { return }
                let centre = carrying.top + carrying.travel + carrying.height / 2
                withAnimation(Motion.settle) {
                    switch item {
                    case .row(let tab, _): place(tab, at: centre)
                    case .heading(let group, _, _): place(group.id, at: centre)
                    }
                }
            }
            .onEnded { value in
                let across = value.translation.width
                withAnimation(Motion.settle) { carrying = nil }
                guard case .row(let tab, _) = item, abs(across) > 40 else { return }
                // Off the column's side: into another window, or a window
                // of its own, as the strip's tabs go.
                let mouse = NSEvent.mouseLocation
                if let target = browser.window(at: mouse), target !== window {
                    window.move(tab, to: target, at: target.insertionIndex(at: mouse))
                    browser.host(of: target)?.makeKeyAndOrderFront(nil)
                } else if let host = browser.host(of: window), !host.frame.contains(mouse) {
                    window.detach(tab, at: mouse)
                }
            }
    }

    /// Where a carried tab's middle has reached: before the first thing in
    /// the list whose middle is still below it. Before a tab, into that
    /// tab's section. Before a heading, onto the end of the section above
    /// it — or, above the first heading, the top of the first group. Below
    /// everything, the end of the tabs in no group.
    private func place(_ tab: Tab, at centre: CGFloat) {
        let items = sideItems.filter { $0.id != tab.id }
        let next = firstBelow(centre, in: items.map(\.id))
        var group: UUID?
        var before: Tab?
        if let next {
            switch items[next] {
            case .row(let other, _):
                group = other.groupID
                before = other
            case .heading(let heading, let members, _):
                let above = window.tabGroups.firstIndex { $0.id == heading.id }.flatMap { $0 > 0 ? window.tabGroups[$0 - 1] : nil }
                group = above?.id ?? heading.id
                before = above == nil ? members.first { $0.id != tab.id } : nil
            }
        }
        if !prefs.usesTabGroups { group = tab.groupID }
        // Already there: nothing to move.
        let section = window.tabs(in: group)
        if tab.groupID == group, let index = section.firstIndex(where: { $0.id == tab.id }) {
            let following = section.indices.contains(index + 1) ? section[index + 1] : nil
            if following?.id == before?.id { return }
        }
        window.place(tab, inGroup: group, before: before)
        // A folded group it lands in opens, so it is there to be seen.
        if let group, let at = window.tabGroups.firstIndex(where: { $0.id == group }), window.tabGroups[at].collapsed {
            window.toggleTabGroup(group)
        }
    }

    /// The first of `ids`, in the list's order, whose middle is below
    /// `centre`. The lazy list has frames only for the rows it has built,
    /// a run from somewhere above the view to somewhere below it; the ones
    /// before that run are higher than anything in hand can reach, and the
    /// ones after it lower.
    private func firstBelow(_ centre: CGFloat, in ids: [UUID]) -> Int? {
        guard let first = ids.firstIndex(where: { itemFrames[$0] != nil }),
              let last = ids.lastIndex(where: { itemFrames[$0] != nil }) else { return nil }
        if let hit = ids[first...last].firstIndex(where: { (itemFrames[$0]?.midY ?? -.infinity) > centre }) {
            return hit
        }
        return last + 1 < ids.count ? last + 1 : nil
    }

    /// Where a carried heading's middle has reached: past the middle of
    /// each other group, heading and tabs together, it goes below that one.
    private func place(_ id: UUID, at centre: CGFloat) {
        // A group the lazy list hasn't built lies wholly above the rows it
        // has, or wholly below them (see `firstBelow`).
        let order = sideItems.map(\.id)
        let built = order.firstIndex { itemFrames[$0] != nil } ?? order.count
        let sections = window.sections()
        let others = window.tabGroups.filter { $0.id != id }
        let target = others.filter { group in
            let members = sections[group.id] ?? []
            let parts = [group.id] + (group.collapsed ? members.filter { $0.id == window.activeID } : members).map(\.id)
            let frames = parts.compactMap { itemFrames[$0] }
            guard let first = frames.first else { return (order.firstIndex(of: group.id) ?? order.count) < built }
            return frames.dropFirst().reduce(first) { $0.union($1) }.midY < centre
        }.count
        guard window.tabGroups.firstIndex(where: { $0.id == id }) != target else { return }
        window.moveTabGroup(id, to: target)
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
                BookmarkDoor(browser: browser, window: window, arrowEdge: .trailing)
            }
            if prefs.dialButton {
                Door(icon: "square.grid.2x2", help: "Speed Dial") { window.showDial() }
                    .accessibilityLabel("Speed Dial")
            }
            FetchDoor(browser: browser, fetches: browser.fetches, always: prefs.downloadButton)
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
    /// Each cell's place and size, in the order of the pins (see pinCells).
    let cells: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: cells.map(\.maxX).max() ?? 0, height: cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where cells.indices.contains(index) {
            let cell = cells[index]
            subview.place(
                at: CGPoint(x: bounds.minX + cell.minX, y: bounds.minY + cell.minY),
                proposal: ProposedViewSize(width: cell.width, height: cell.height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @Environment(\.columnSettled) private var settled
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
        // A pinned tab says which page it is, not only its letter.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pinned: " + tab.label)
        .accessibilityAddTraits(live ? [.isButton, .isSelected] : .isButton)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.asleep)
        .transition(settled ? .scale(scale: 0.8).combined(with: .opacity) : .identity)
    }
}

/// One tab, as a line in the column.
private struct SideRow: View, Equatable {
    @Environment(\.columnSettled) private var settled
    /// For what the row does. Not watched: every row watching the window
    /// had all of them worked out again whenever anything in it changed —
    /// a tab switch redrew a hundred and fifty rows to move one highlight.
    /// What the row shows of the window is handed in below instead, and the
    /// row is only drawn again when that, or its own tab, changes.
    let window: WindowModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    /// One of a chosen set of tabs, lit wherever the pointer is.
    let selected: Bool
    let editing: Bool
    /// Refused edits, for the shake — only counted while this row is edited.
    let refusals: Int

    init(window: WindowModel, prefs: Preferences, tab: Tab, live: Bool, pill: Namespace.ID, close: @escaping () -> Void) {
        self.window = window
        _prefs = ObservedObject(wrappedValue: prefs)
        _tab = ObservedObject(wrappedValue: tab)
        self.live = live
        self.pill = pill
        self.close = close
        selected = window.selectedTabs.contains(tab.id)
        editing = window.editingTab == tab.id
        refusals = window.editingTab == tab.id ? window.refusals : 0
    }

    static func == (a: SideRow, b: SideRow) -> Bool {
        a.tab === b.tab && a.live == b.live && a.selected == b.selected
            && a.editing == b.editing && a.refusals == b.refusals && a.pill == b.pill
    }

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    /// A plain click, with no modifier held: command and shift are
    /// selection gestures, and the row answers them as such.
    private var plain: Bool { (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .shift]).isEmpty }

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
        // Put to sleep or woken: the icon dims or brightens, not blinks.
        .animation(Motion.quick, value: tab.asleep)
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
        .onChange(of: refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(Motion.easeOut(0.5)) { shake = 1 }
        }
        .transition(settled ? .scale(scale: 0.94, anchor: .leading).combined(with: .opacity) : .identity)
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
                // One icon becoming another — reload to stop, an empty
                // bookmark to a kept one — as the system's own symbols do it.
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.quick, value: icon)
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

private struct ColumnSettledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the column holding a row has been on screen for a frame (see
    /// SideBar.settled). Elsewhere a row is always settled.
    var columnSettled: Bool {
        get { self[ColumnSettledKey.self] }
        set { self[ColumnSettledKey.self] = newValue }
    }
}

/// Where a tab's row sits among the groups, which it shows: a tab in a group
/// is set in under the group's heading, on a line that runs down from the
/// heading's icon to the group's last tab; each section — a group, or the
/// tabs in none — starts a little further down than rows follow each other.
private struct Nesting {
    var grouped = false
    var last = false
    var opens = false
    static let loose = Nesting()
}

/// One line of the column's list: a group's heading, or a tab.
private enum SideItem: Identifiable {
    /// A group's heading, with its tabs as they were when the list was made;
    /// `opens` when a section comes before it.
    case heading(TabGroup, [Tab], opens: Bool)
    case row(Tab, Nesting)

    var id: UUID {
        switch self {
        case .heading(let group, _, _): group.id
        case .row(let tab, _): tab.id
        }
    }

    /// A section's extra space above it: twice and more the gap between rows.
    static let sectionGap: CGFloat = 10
    /// How far a group's tabs are set in, clear of the line beside them.
    static let indent: CGFloat = 22

    @MainActor @ViewBuilder
    func view(window: WindowModel, prefs: Preferences, pill: Namespace.ID) -> some View {
        switch self {
        case .heading(let group, let members, let opens):
            GroupHeading(window: window, group: group, carried: true, members: members)
                .padding(.top, opens ? SideItem.sectionGap : 0)
        case .row(let tab, let nesting):
            SideRow(window: window, prefs: prefs, tab: tab, live: tab.id == window.activeID,
                    pill: pill, close: { window.close(tab) })
                .equatable()
                .modifier(SplitSource(browser: window, tab: tab))
                .padding(.leading, nesting.grouped ? SideItem.indent : 0)
                .background(alignment: .topLeading) {
                    if nesting.grouped { GroupLine(last: nesting.last) }
                }
                .padding(.top, nesting.opens ? SideItem.sectionGap : 0)
                .modifier(Arrival(grouped: nesting.grouped))
        }
    }
}

/// How a row comes and goes. A group's tabs fold up under its heading and
/// come back down out of it; any other row grows in from where its title
/// starts, as a new tab does. Nothing moves while the column first draws.
private struct Arrival: ViewModifier {
    @Environment(\.columnSettled) private var settled
    let grouped: Bool

    func body(content: Content) -> some View {
        content.transition(!settled ? .identity
            : grouped ? .tuck
            : .scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }
}

/// A group's line beside one of its tabs: under the centre of the heading's
/// icon, reaching up across the gap to the row above so the pieces meet, and
/// stopping short on the group's last tab.
private struct GroupLine: View {
    let last: Bool

    var body: some View {
        Capsule()
            .fill(Palette.faint)
            .frame(width: 1.5, height: last ? 28 - 6 + 2 : 28 + 2)
            .offset(x: 10 + 7.5 - 0.75, y: -2)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// What the column's drag has in hand, and how far it has come.
private struct Carrying {
    let item: SideItem?
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat
    var travel: CGFloat = 0
    var id: UUID? { item?.id }
}

/// Where each heading and row of the column is, in the list's own space.
private struct SideItemFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
