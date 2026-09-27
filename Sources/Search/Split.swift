import SwiftUI

/// Two to four existing tabs shown together. The order is the page order,
/// not the order of their titles in the tab row: `left` and `right` are the
/// first two panes, `extra` the third and fourth.
struct SplitPair: Identifiable, Equatable {
    let id = UUID()
    var left: Tab.ID
    var right: Tab.ID
    var extra: [Tab.ID] = []
    var layout: SplitLayout = .columns
    var fraction: Double

    /// The most pages one split shows: four live pages is already a lot
    /// of memory, and a pane narrower than a phone reads nothing.
    static let most = 4

    init(left: Tab.ID, right: Tab.ID, extra: [Tab.ID] = [], layout: SplitLayout = .columns, fraction: Double = 0.5) {
        self.left = left
        self.right = right
        self.extra = Array(extra.filter { $0 != left && $0 != right }.prefix(Self.most - 2))
        self.layout = layout
        self.fraction = min(0.75, max(0.25, fraction))
    }

    var members: [Tab.ID] { [left, right] + extra }
    var isFull: Bool { members.count >= Self.most }

    func contains(_ id: Tab.ID) -> Bool { members.contains(id) }
    /// A partner of `id`: the other of two, or the first of the rest.
    func other(than id: Tab.ID) -> Tab.ID? {
        guard contains(id) else { return nil }
        return members.first { $0 != id }
    }
    func others(than id: Tab.ID) -> [Tab.ID] { members.filter { $0 != id } }

    /// `id` out of a split of three or four: the rest close up, in order.
    /// Nil when only one would be left, which is no split at all.
    func without(_ id: Tab.ID) -> SplitPair? {
        let rest = members.filter { $0 != id }
        guard rest.count >= 2 else { return nil }
        var next = self
        next.left = rest[0]
        next.right = rest[1]
        next.extra = Array(rest.dropFirst(2))
        if rest.count == 2, next.layout == .grid { next.layout = .columns }
        return next
    }
}

/// How the panes of a split share the stage.
enum SplitLayout: String, Codable, CaseIterable {
    /// Side by side, as columns.
    case columns
    /// One above another, as rows.
    case rows
    /// Two by two; three fill the top row and the whole bottom row.
    case grid

    var title: String {
        switch self {
        case .columns: return "Side by Side"
        case .rows: return "Stacked"
        case .grid: return "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .columns: return "rectangle.split.3x1"
        case .rows: return "rectangle.split.1x2"
        case .grid: return "rectangle.split.2x2"
        }
    }
}

enum SplitSide: Equatable { case left, right }

extension WindowModel {
    var activePair: SplitPair? {
        guard profile.prefs.splitViews, let activeID else { return nil }
        return splitPairs.first { $0.contains(activeID) }
    }

    var visiblePair: SplitPair? {
        splitCanShow && pendingSplit == nil ? activePair : nil
    }

    func pair(for tab: Tab) -> SplitPair? { splitPairs.first { $0.contains(tab.id) } }

    func startSplit(_ tab: Tab) {
        guard profile.prefs.splitViews, pair(for: tab) == nil, tabs.contains(where: { $0.id == tab.id }) else { return }
        select(tab)
        pendingSplit = tab.id
    }

    func finishSplit(with id: Tab.ID) {
        guard let right = pendingSplit, right != id,
              tabs.contains(where: { $0.id == right }), tabs.contains(where: { $0.id == id }) else { return }
        if profile.floating == right || profile.floating == id { profile.land() }
        splitPairs.removeAll { $0.contains(id) || $0.contains(right) }
        splitPairs.append(SplitPair(left: id, right: right))
        pendingSplit = nil
        activeID = right
        wakeSplitPartner()
        profile.writeSession()
    }

    func put(_ id: Tab.ID, on side: SplitSide, of pairID: UUID) {
        guard let target = splitPairs.firstIndex(where: { $0.id == pairID }),
              tabs.contains(where: { $0.id == id }) else { return }
        let old = side == .left ? splitPairs[target].left : splitPairs[target].right
        guard id != old, !splitPairs[target].contains(id) else { return }
        if profile.floating == id { profile.land() }
        splitPairs.removeAll { $0.id != pairID && $0.contains(id) }
        guard let index = splitPairs.firstIndex(where: { $0.id == pairID }) else { return }
        if side == .left { splitPairs[index].left = id } else { splitPairs[index].right = id }
        activeID = id
        if let tab = tabs.first(where: { $0.id == id }) { if !tab.wake() { tab.revive() } }
        profile.writeSession()
    }

    func unsplit(_ tab: Tab) {
        guard let pair = pair(for: tab) else { return }
        let mostRecent = tabs.filter { pair.contains($0.id) }.max { $0.touched < $1.touched }
        let fill = activeID.flatMap { id in pair.contains(id) ? tabs.first(where: { $0.id == id }) : nil }
        splitPairs.removeAll { $0.id == pair.id }
        if let fill = fill ?? mostRecent { select(fill) }
        profile.writeSession()
    }

    /// `tab` into the split on screen, as its next pane, up to four.
    func addToSplit(_ tab: Tab) {
        guard profile.prefs.splitViews, let pair = activePair, !pair.isFull, !pair.contains(tab.id),
              tabs.contains(where: { $0.id == tab.id }) else { return }
        if profile.floating == tab.id { profile.land() }
        splitPairs.removeAll { $0.id != pair.id && $0.contains(tab.id) }
        guard let at = splitPairs.firstIndex(where: { $0.id == pair.id }) else { return }
        // At once, not animated: every frame of a glide would lay out as
        // many live pages again, and the change was asked for from a menu.
        splitPairs[at].extra.append(tab.id)
        // Three or four side by side is three or four slivers; a grid
        // keeps each page wide enough to read.
        if splitPairs[at].members.count >= 3, splitPairs[at].layout == .columns { splitPairs[at].layout = .grid }
        activeID = tab.id
        tab.touch()
        if !tab.wake() { tab.revive() }
        profile.writeSession()
    }

    /// Tabs shown together as a new split, the first two to four of them,
    /// in the order given. Any split they were in is let go.
    func tile(_ group: [Tab]) {
        let ids = Array(group.map(\.id).filter { id in tabs.contains { $0.id == id } }.prefix(SplitPair.most))
        guard profile.prefs.splitViews, ids.count >= 2 else { return }
        for tab in group where profile.floating == tab.id { profile.land() }
        splitPairs.removeAll { pair in ids.contains { pair.contains($0) } }
        pendingSplit = nil
        let layout: SplitLayout = ids.count > 2 ? .grid : .columns
        splitPairs.append(SplitPair(left: ids[0], right: ids[1], extra: Array(ids.dropFirst(2)), layout: layout))
        if let first = tabs.first(where: { $0.id == ids[0] }) {
            activeID = first.id
            first.touch()
            if !first.wake() { first.revive() }
        }
        wakeSplitPartner()
        profile.writeSession()
    }

    /// The split on screen, laid out another way.
    func setSplitLayout(_ layout: SplitLayout) {
        guard let pair = activePair, let index = splitPairs.firstIndex(where: { $0.id == pair.id }) else { return }
        splitPairs[index].layout = layout
        profile.writeSession()
    }

    /// Returns a surviving member, for Close Tab and the pinned tab's rest.
    /// A split of three or four goes on without the tab; two part.
    @discardableResult
    func removeFromSplit(_ id: Tab.ID) -> Tab.ID? {
        if pendingSplit == id { pendingSplit = nil }
        guard let index = splitPairs.firstIndex(where: { $0.contains(id) }) else { return nil }
        let pair = splitPairs[index]
        if let rest = pair.without(id) {
            splitPairs[index] = rest
        } else {
            splitPairs.remove(at: index)
        }
        return pair.other(than: id)
    }

    func replaceSplitTab(_ old: Tab.ID, with new: Tab.ID) {
        if pendingSplit == old { pendingSplit = new }
        for index in splitPairs.indices {
            if splitPairs[index].left == old { splitPairs[index].left = new }
            if splitPairs[index].right == old { splitPairs[index].right = new }
            splitPairs[index].extra = splitPairs[index].extra.map { $0 == old ? new : $0 }
        }
    }

    func wakeSplitPartner() {
        guard let pair = activePair, let activeID else { return }
        for other in pair.others(than: activeID) {
            guard let tab = tabs.first(where: { $0.id == other }) else { continue }
            if !tab.wake() { tab.revive() }
        }
    }

    func setSplitFraction(_ fraction: Double, for id: UUID, save: Bool = false) {
        guard let index = splitPairs.firstIndex(where: { $0.id == id }) else { return }
        splitPairs[index].fraction = min(0.75, max(0.25, fraction))
        if save { profile.writeSession() }
    }

    func focusSplitPage(at event: NSEvent) {
        guard let pair = visiblePair, let window = event.window else { return }
        for id in pair.members {
            guard let tab = tabs.first(where: { $0.id == id }), let web = tab.built,
                  web.window === window else { continue }
            if web.bounds.contains(web.convert(event.locationInWindow, from: nil)) {
                select(tab)
                return
            }
        }
    }
}

/// A tab drag carries its identity, never its address or private page data.
enum SplitDrag {
    static let type = "public.utf8-plain-text"

    static func provider(_ id: Tab.ID) -> NSItemProvider {
        return NSItemProvider(object: id.uuidString as NSString)
    }

    static func receive(_ providers: [NSItemProvider], use: @escaping (Tab.ID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { use(id) }
        }
        return true
    }
}

struct SplitSource: ViewModifier {
    @ObservedObject var browser: WindowModel
    let tab: Tab

    func body(content: Content) -> some View {
        if browser.visiblePair != nil && !tab.bench {
            content.onDrag { SplitDrag.provider(tab.id) }
        } else {
            content
        }
    }
}

/// A tab's split items, the same in the Tabs menu and the tab's own menu:
/// into the split on screen while it has room, its layout, or out of it.
struct SplitMenuItems: View {
    @ObservedObject var window: WindowModel
    let tab: Tab

    var body: some View {
        if window.profile.prefs.splitViews, !tab.bench {
            if let pair = window.pair(for: tab) {
                Menu("Split Layout") {
                    ForEach(SplitLayout.allCases, id: \.self) { layout in
                        Button {
                            if window.activeID != tab.id { window.select(tab) }
                            window.setSplitLayout(layout)
                        } label: {
                            Label(layout.title, systemImage: Symbols.current(layout.symbol))
                        }
                        // Two pages in a grid are two side by side.
                        .disabled(pair.layout == layout || (layout == .grid && pair.members.count < 3))
                    }
                }
                Button("Unsplit") { window.unsplit(tab) }
            } else {
                if let shown = window.activePair, !shown.isFull {
                    Button("Add to Split View") { window.addToSplit(tab) }
                }
                Button("Split Tab") { window.startSplit(tab) }
                    .disabled(!window.tabs.contains { $0.id != tab.id && !$0.bench })
            }
        }
    }
}
