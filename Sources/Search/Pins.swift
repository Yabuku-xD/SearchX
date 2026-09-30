import Foundation

// Pinned tabs are the same in every window: pinned, unpinned, moved,
// relettered or renamed in one, so they are in the others. Each window holds
// its own tab for each pin — its own page, wherever you took it — and only
// what makes the pin a pin is shared: its letter, its name, the page it was
// pinned at, its place among the pins. Per space, as the pins always were.
//
// pins.json holds them. Before there is one, a space's pins are whatever the
// first window restored there has; the session files keep each window's pins
// as they always did, so an older build still finds them there.

struct PinDef: Codable, Equatable {
    var id: UUID
    var letter: String
    /// The page it was pinned at (see WindowModel.goHome).
    var home: String
    /// For a tab made for this pin in a window that didn't have it. Not part
    /// of what the pin is: each window's tab has its own page and title.
    var title: String
    var name: String?

    /// What the other windows follow.
    func same(as other: PinDef) -> Bool {
        id == other.id && letter == other.letter && home == other.home && name == other.name
    }
}

@MainActor
enum Pins {
    /// Pins by space, in their order. A space missing here has never had its
    /// pins recorded: its rows are taken as they are, never emptied.
    private(set) static var bySpace: [UUID: [PinDef]] = [:]
    private static var loaded = false

    private static var file: URL { Store.file("pins.json") }

    static func defs(_ space: UUID) -> [PinDef]? {
        load()
        return bySpace[space]
    }

    static func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: [PinDef]].self, from: data)
        else { return }
        for (key, defs) in saved {
            if let space = UUID(uuidString: key) { bySpace[space] = defs }
        }
    }

    static func matches(_ space: UUID, _ defs: [PinDef]) -> Bool {
        guard let known = Pins.defs(space) else { return false }
        return known.count == defs.count && zip(known, defs).allSatisfy { $0.same(as: $1) }
    }

    /// A space's pins, as they now are. An empty list is kept as one, so a
    /// window that unpinned everything has the others follow.
    static func set(_ space: UUID, _ defs: [PinDef]) {
        load()
        bySpace[space] = defs
        save()
    }

    /// A space deleted: its pins go with it.
    static func forget(_ space: UUID) {
        load()
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    private static func save() {
        var out: [String: [PinDef]] = [:]
        for (space, defs) in bySpace { out[space.uuidString] = defs }
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension WindowModel {
    /// What makes this row's pinned tabs pins, in their order.
    func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            return PinDef(id: tab.pinID ?? UUID(), letter: letter,
                          home: (tab.pinHome ?? tab.pending ?? tab.address)?.absoluteString ?? "",
                          title: tab.title, name: tab.name)
        }
    }

    /// A row with the space's pins as they are now: this window's own tab
    /// for each, relettered and in order, one made asleep at its page for a
    /// pin new to this window, and the tab of a pin taken away closed. A
    /// pinned tab from before pins had ids is matched by letter and page,
    /// then by place. A space whose pins were never recorded keeps the row.
    func reconcilePins(_ row: [Tab], space: UUID) -> [Tab] {
        guard !isPrivate, let defs = Pins.defs(space) else { return row }
        var pinned = row.filter { $0.pin != nil }
        let loose = row.filter { $0.pin == nil }
        var out: [Tab] = []
        for def in defs {
            let found = pinned.first { $0.pinID == def.id }
                ?? pinned.first { $0.pinID == nil && $0.pin == def.letter && ($0.pinHome?.absoluteString ?? "") == def.home }
                ?? pinned.first { $0.pinID == nil }
            let tab: Tab
            if let found {
                pinned.removeAll { $0 === found }
                tab = found
            } else {
                tab = Tab(space: space)
                tab.enter(self)
                tab.restore(url: URL(string: def.home) ?? URL(string: "about:blank")!, title: def.title, name: def.name)
            }
            tab.pinID = def.id
            if tab.pin != def.letter { tab.pin = def.letter }
            if tab.name != def.name { tab.name = def.name }
            tab.pinHome = URL(string: def.home)
            tab.groupID = nil
            out.append(tab)
        }
        for gone in pinned {
            _ = removeFromSplit(gone.id)
            if profile.floating == gone.id { profile.land() }
            gone.close()
        }
        return out + loose
    }

    /// The space's pins changed in another window: this window's row there
    /// follows, on screen or parked.
    func pinsChanged(in space: UUID) {
        if space == spaceID {
            let row = reconcilePins(tabs, space: space)
            // Drawn again even when only a pin's letter or name changed.
            objectWillChange.send()
            guard row.map(\.id) != tabs.map(\.id) || zip(row, tabs).contains(where: { $0 !== $1 }) else { return }
            let front = tabs.contains(where: { $0.id == activeID }) && row.contains(where: { $0.id == activeID })
                ? activeID : row.first { $0.pin == nil }?.id ?? row.first?.id
            showRow(row, active: front, groups: tabGroups, splits: splitPairs.filter { pair in
                pair.members.allSatisfy { id in row.contains { $0.id == id } }
            })
            if activeID == nil { newTab() }
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
            if !row.tabs.contains(where: { $0.id == row.active }) { row.active = row.tabs.first { $0.pin == nil }?.id ?? row.tabs.first?.id }
            row.splits = row.splits.filter { pair in pair.members.allSatisfy { id in row.tabs.contains { $0.id == id } } }
            parked[space] = row
        }
    }
}

extension Browser {
    /// Before a session is written: a row whose pins differ from the space's
    /// recorded ones is the one that changed them — the window in front's,
    /// when several do — and the other windows follow.
    func syncPins() {
        var rows: [(window: WindowModel, space: UUID, tabs: [Tab])] = []
        for window in windows where !window.isPrivate {
            rows.append((window, window.spaceID, window.tabs))
            for (space, row) in window.parked { rows.append((window, space, row.tabs)) }
        }
        for space in Set(rows.map(\.space)) {
            let here = rows.filter { $0.space == space }
            // First time this space's pins are recorded: before, each window
            // kept pins of its own. Every window's are kept, the window in
            // front's first, one pin for the same letter at the same page.
            if Pins.defs(space) == nil {
                let ordered = here.sorted { a, _ in a.window === key }
                var union: [PinDef] = []
                for row in ordered {
                    for tab in row.tabs where tab.pin != nil {
                        let home = (tab.pinHome ?? tab.pending ?? tab.address)?.absoluteString ?? ""
                        if let same = union.first(where: { $0.letter == tab.pin && $0.home == home }) {
                            tab.pinID = same.id
                        } else if let def = row.window.pinDefs([tab]).first {
                            union.append(def)
                        }
                    }
                }
                Pins.set(space, union)
                for row in here { row.window.pinsChanged(in: space) }
                continue
            }
            let changed = here.filter { !Pins.matches(space, $0.window.pinDefs($0.tabs)) }
            guard !changed.isEmpty else { continue }
            let source = changed.first { $0.window === key } ?? changed[0]
            Pins.set(space, source.window.pinDefs(source.tabs))
            for other in here where other.window !== source.window {
                other.window.pinsChanged(in: space)
            }
        }
    }
}
