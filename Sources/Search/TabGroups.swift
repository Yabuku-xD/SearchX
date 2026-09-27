import SwiftUI

// Named sections in a tab layout (Settings > Tabs). A group holds ordinary
// tabs: their own `Tab.groupID` says which, and pinned and private tabs stay
// out. The heading is the same in the column and in the bar across the top;
// only its children are laid out by whichever of the two is showing them.

/// Where each group heading sits in a layout’s own coordinate space, so that
/// layout’s existing reorder drag can land a tab on a group without a second
/// gesture. The name is the namespace the layout gives itself.
struct GroupDropFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct GroupHeading: View {
    @ObservedObject var window: WindowModel
    let group: TabGroup
    /// The bar across the top, which fixes the heading’s width so a row of
    /// them scrolls like tabs do. The column lets it fill.
    var horizontal = false
    /// The coordinate space to report this heading’s frame into, when the
    /// layout it is in wants it for drops.
    var dragSpace: String? = nil

    @State private var draft = ""
    @State private var hovering = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var editing: Bool { window.editingGroupID == group.id }

    var body: some View {
        HStack(spacing: 8) {
            // The first tab’s mark is the group’s face, so a section named by
            // the site in it reads at a glance. An empty one gets a stack.
            if let tab = window.tabs(in: group.id).first {
                GroupMark(tab: tab)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 12))
                    .frame(width: 15)
            }
            if let tint = group.tint { TintDot(tint: tint) }
            if editing {
                TextField("Group name", text: $draft)
                    .accessibilityLabel("Group name")
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { window.editingGroupID = nil }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !editing {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(group.collapsed ? -90 : 0))
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .frame(width: horizontal ? 126 : nil, height: 28)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(dropping ? Palette.wash : (hovering ? Palette.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if !editing { window.toggleTabGroup(group.id) } }
        .background {
            if let dragSpace {
                GeometryReader { geometry in
                    Color.clear.preference(key: GroupDropFrames.self,
                                           value: [group.id: geometry.frame(in: .named(dragSpace))])
                }
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: editing) { _, now in
            if now {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onAppear {
            if editing {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        // Still the tab’s own string being carried: the layouts already put a
        // tab’s id on the pasteboard, and the heading reads that here rather
        // than a second format.
        .onDrop(of: [.text], isTargeted: $dropping) { providers in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) })
            else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }
                DispatchQueue.main.async {
                    if value.hasPrefix("search-group:"),
                       let id = UUID(uuidString: String(value.dropFirst("search-group:".count))),
                       let index = window.tabGroups.firstIndex(where: { $0.id == group.id }) {
                        window.moveTabGroup(id, to: index)
                    }
                }
            }
            return true
        }
        .onDrag { NSItemProvider(object: "search-group:\(group.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Rename Group") { window.editingGroupID = group.id }
            Picker("Colour", selection: Binding(get: { group.tint }, set: { window.setTint($0, forGroup: group.id) })) {
                Text("None").tag(Tint?.none)
                ForEach(Tint.allCases) { tint in
                    Text(tint.title.said).tag(Tint?.some(tint))
                }
            }
            Button(group.collapsed ? "Expand Group" : "Collapse Group") {
                window.toggleTabGroup(group.id)
            }
            Divider()
            let count = window.tabs(in: group.id).count
            if window.profile.prefs.splitViews {
                Button("Show Group in Split View") { window.tileGroup(group.id) }
                    .disabled(count < 2)
            }
            Button("Put Group to Sleep") { window.sleepGroup(group.id) }
                .disabled(!window.tabs(in: group.id).contains { !$0.isBlank && !$0.asleep })
            Button("Bookmark Group") { window.bookmarkGroup(group.id) }
                .disabled(!window.tabs(in: group.id).contains(where: \.showsPage))
            Button("Pin Group") { window.pinGroup(group.id) }
                .disabled(!window.tabs(in: group.id).contains(where: \.showsPage))
            Button("Save and Close Group") { window.saveAndCloseGroup(group.id) }
                .disabled(!window.tabs(in: group.id).contains(where: \.showsPage))
            Divider()
            Button("Remove Group") { window.removeTabGroup(group.id) }
        }
    }

    private func commit() {
        window.renameTabGroup(group.id, to: draft)
        window.editingGroupID = nil
    }
}

private struct GroupMark: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Mark(icon: tab.icon, letter: tab.monogram, size: 15)
    }
}

// MARK: - a whole group at once (Vivaldi's tab stack actions)

extension WindowModel {
    /// Every page in the group on screen together, the first four in the
    /// row's order (see tile(_:)).
    func tileGroup(_ id: UUID) {
        let members = tabs(in: id).filter { !$0.bench }
        tile(members)
        if members.count > SplitPair.most { profile.announce("Showing the first \(SplitPair.most) tabs of the group") }
    }

    /// Every page in the group let go of, their places kept (see Sleep).
    func sleepGroup(_ id: UUID) {
        unload(tabs(in: id))
    }

    /// The group's pages as a bookmarks folder of the group's name. Pages
    /// already kept are kept again in the folder, so it is the whole group.
    func bookmarkGroup(_ id: UUID) {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return }
        let pages = tabs(in: id).compactMap { tab -> Bookmark? in
            guard tab.showsPage, let url = tab.address else { return nil }
            return Bookmark.site(tab.title, url)
        }
        guard !pages.isEmpty else { return }
        profile.bookmarks.insert(.folder(group.name, pages), into: nil)
        profile.announce("Bookmarked \(pages.count == 1 ? "1 page" : "\(pages.count) pages") in \(group.name)")
    }

    /// Every page in the group pinned; the empty group goes with them.
    func pinGroup(_ id: UUID) {
        for tab in tabs(in: id) where tab.showsPage { pin(tab) }
        if tabs(in: id).isEmpty { removeTabGroup(id) }
    }
}
