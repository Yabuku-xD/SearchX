import SwiftUI
import WebKit

// Containers, Brave's and Firefox's: tabs side by side in the same Space,
// each container with its own cookies, sign-ins and site storage — work and
// personal, or two accounts on one site, without a second window or Space.
//
// A container's store is WebKit's own, made the first time a tab is put in
// it, so a container nobody uses costs nothing. A tab opened from a
// container's page stays in the container. Private tabs have none: they
// keep nothing already.

struct Container: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tint: Tint
}

@MainActor
final class Containers: ObservableObject {
    static let shared = Containers()

    @Published private(set) var all: [Container]

    /// Firefox's four to start with; renamed, recoloured or deleted freely.
    private static let starters: [Container] = [
        Container(name: "Personal", tint: .blue),
        Container(name: "Work", tint: .orange),
        Container(name: "Banking", tint: .green),
        Container(name: "Shopping", tint: .purple),
    ]

    private init() {
        if let data = Store.settings.data(forKey: "containers"),
           let kept = try? JSONDecoder().decode([Container].self, from: data) {
            all = kept
        } else {
            all = Self.starters
        }
    }

    func container(_ id: UUID?) -> Container? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    @discardableResult
    func add(named name: String) -> Container {
        let made = Container(name: name, tint: Tint.next(after: all.count))
        all.append(made)
        save()
        return made
    }

    func update(_ container: Container) {
        guard let index = all.firstIndex(where: { $0.id == container.id }) else { return }
        all[index] = container
        save()
    }

    /// Gone, and everything it kept with it (see Spaces.erase for how a
    /// store WebKit is still holding is finished at the next launch).
    func remove(_ id: UUID, in browser: Browser) {
        for tab in browser.allTabs where tab.container == id { tab.enter(container: nil) }
        all.removeAll { $0.id == id }
        save()
        Self.stores[id] = nil
        let store = WKWebsiteDataStore(forIdentifier: id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Spaces.sweep() }
    }

    /// Each container's store, made once, when a tab first needs it.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func store(for id: UUID) -> WKWebsiteDataStore {
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }

    private func save() {
        Store.settings.set(try? JSONEncoder().encode(all), forKey: "containers")
    }
}

extension WindowModel {
    /// \`tab\` into a container, or out of one. Its page opens again with the
    /// container's sign-ins — asked about first when it holds something
    /// typed and not sent, as moving it to another Space is.
    func put(_ tab: Tab, inContainer id: UUID?) {
        guard !tab.shy, !tab.bench, tab.container != id, tabs.contains(where: { $0.id == tab.id }) else { return }
        let name = Containers.shared.container(id)?.name
        tab.unsaved { [weak self, weak tab] unsaved in
            guard let self, let tab else { return }
            let go = {
                tab.enter(container: id)
                if self.activeID == tab.id || self.visiblePair?.contains(tab.id) == true {
                    if !tab.wake() { tab.revive() }
                }
                self.profile.writeSession()
            }
            guard unsaved else { return go() }
            Ask.sure(
                "Move Tab?",
                detail: "This page has unsaved form entries. It will reopen \(name.map { "in \($0)" } ?? "without a container") with its own sign-ins, so the entries may be lost.",
                confirm: "Move",
                then: go
            )
        }
    }

    /// A new tab in \`id\`, in front, its field ready.
    func newTab(inContainer id: UUID) {
        guard !isPrivate, Containers.shared.container(id) != nil else { return }
        let tab = Tab(space: spaceID, store: Containers.store(for: id))
        tab.container = id
        adopt(tab)
        select(tab)
        edit()
        profile.rememberSession()
    }

    /// A container named on the spot, with \`tab\` put in it.
    func newContainer(for tab: Tab?) {
        Ask.name("New Container", placeholder: "Name", confirm: "Create") { [weak self] name in
            let made = Containers.shared.add(named: name)
            if let self, let tab { self.put(tab, inContainer: made.id) }
        }
    }
}

/// A tab's container items, in the tab's menu.
struct ContainerMenu: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var tab: Tab
    @ObservedObject private var containers = Containers.shared

    var body: some View {
        if !tab.shy, !tab.bench, !window.isPrivate {
            Menu("Open in Container") {
                Picker("Container", selection: Binding(get: { tab.container }, set: { window.put(tab, inContainer: $0) })) {
                    Text("No Container").tag(UUID?.none)
                    ForEach(containers.all) { container in
                        Text(container.name).tag(UUID?.some(container.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("New Container…") { window.newContainer(for: tab) }
            }
        }
    }
}

/// The dot before a tab's title when it is in a container.
struct ContainerDot: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var containers = Containers.shared

    var body: some View {
        if let container = containers.container(tab.container) {
            TintDot(tint: container.tint, size: 6)
                .help(container.name)
                .accessibilityLabel("In \(container.name)")
        }
    }
}

/// Settings › Privacy › Containers.
struct ContainersCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var containers = Containers.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Containers")
            Card {
                ForEach(Array(containers.all.enumerated()), id: \.element.id) { index, container in
                    if index > 0 { Rule() }
                    Line(container.name, "Its own cookies, sign-ins and site data") {
                        HStack(spacing: 8) {
                            Picker("", selection: Binding(get: { container.tint }, set: { tint in
                                var next = container
                                next.tint = tint
                                containers.update(next)
                            })) {
                                ForEach(Tint.allCases) { tint in Text(tint.title.said).tag(tint) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel("Colour of \(container.name)")
                            Quick("Rename") {
                                Ask.name("Rename Container", placeholder: container.name, initial: container.name, confirm: "Rename") { name in
                                    var next = container
                                    next.name = name
                                    containers.update(next)
                                }
                            }
                            Quick("Delete", tint: .red.opacity(0.75)) {
                                Ask.sure("Delete \(container.name)?",
                                         detail: "Its tabs stay open without a container, and its cookies, sign-ins and site data are erased.",
                                         confirm: "Delete") {
                                    containers.remove(container.id, in: browser)
                                }
                            }
                        }
                    }
                }
                if !containers.all.isEmpty { Rule() }
                Line("Keep sign-ins apart in one Space", "Right-click a tab and choose Open in Container") {
                    Pill("New container") {
                        Ask.name("New Container", placeholder: "Name", confirm: "Create") { containers.add(named: $0) }
                    }
                }
            }
        }
    }
}
