import SwiftUI

// A group saved and closed for later, Firefox's: its tabs close — nothing of
// their pages stays in memory, as it would asleep — and its name, colour and
// addresses are kept in a short list. Opening it again brings the group back
// as it was, its tabs waiting to load until they are looked at. From ⌘K, and
// from Settings › Tabs.

struct SavedGroup: Codable, Identifiable, Equatable {
    struct Page: Codable, Equatable {
        var url: String
        var title: String
    }

    var id = UUID()
    var name: String
    var tint: Tint?
    var pages: [Page]
    var saved = Date()
}

@MainActor
final class SavedGroups: ObservableObject {
    static let shared = SavedGroups()

    @Published private(set) var all: [SavedGroup]

    private init() {
        all = Store.settings.data(forKey: "groups.saved")
            .flatMap { try? JSONDecoder().decode([SavedGroup].self, from: $0) } ?? []
    }

    func group(_ id: UUID) -> SavedGroup? { all.first { $0.id == id } }

    func add(_ group: SavedGroup) {
        all.insert(group, at: 0)
        save()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if all.isEmpty {
            Store.settings.removeObject(forKey: "groups.saved")
        } else {
            Store.settings.set(try? JSONEncoder().encode(all), forKey: "groups.saved")
        }
    }
}

extension WindowModel {
    /// The group's pages kept, its tabs closed, the group gone from the row.
    func saveAndCloseGroup(_ id: UUID) {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return }
        let members = tabs(in: id)
        let pages = members.compactMap { tab -> SavedGroup.Page? in
            guard let url = tab.pending ?? tab.address, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return SavedGroup.Page(url: url.absoluteString, title: tab.title)
        }
        guard !pages.isEmpty else { return }
        SavedGroups.shared.add(SavedGroup(name: group.name, tint: group.tint, pages: pages))
        for tab in members { close(tab) }
        removeTabGroup(id)
        profile.announce("Saved \(group.name) · ⌘K opens it again")
    }

    /// A saved group back in the row, as it was: the first of its tabs in
    /// front and loading, the rest waiting until they are looked at.
    func reopenSavedGroup(_ id: UUID) {
        guard let saved = SavedGroups.shared.group(id) else { return }
        let group = UUID()
        tabGroups.append(TabGroup(id: group, name: saved.name, collapsed: false, tint: saved.tint))
        var first: Tab?
        for page in saved.pages {
            guard let url = URL(string: page.url) else { continue }
            let tab = makeTab()
            tab.restore(url: url, title: page.title)
            tab.groupID = group
            adopt(tab)
            if first == nil { first = tab }
        }
        if profile.prefs.usesTabGroups { arrangeGroupedTabs() }
        SavedGroups.shared.remove(id)
        if let first { select(first) }
        profile.writeSession()
    }
}

/// Settings › Tabs › Saved groups, when there are any.
struct SavedGroupsCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var saved = SavedGroups.shared

    var body: some View {
        if !saved.all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Saved groups")
                Card {
                    ForEach(Array(saved.all.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Rule() }
                        Line(group.name, group.pages.count == 1 ? "1 tab" : "\(group.pages.count) tabs") {
                            HStack(spacing: 8) {
                                if let tint = group.tint { TintDot(tint: tint) }
                                Quick("Open") { browser.key?.reopenSavedGroup(group.id) }
                                Quick("Delete", tint: .red.opacity(0.75)) { saved.remove(group.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}
