import SwiftUI

// Command chains, Vivaldi's: several commands under one name and one key,
// run in order — "new tab, then split it beside this one", "save power and
// go into focus". A step is any command the menus have (see
// ShortcutCommand), so a chain can do nothing the menus can't.
//
// Each step runs on the next turn of the main loop after the one before, so
// what a step changed — a new tab in front, a split on screen — is in place
// when the next one looks.

struct Chain: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// ShortcutCommand ids, in order.
    var steps: [String]
    var key: KeyCombo?

    /// The steps as the menus name them, joined by arrows.
    var summary: String {
        let names = steps.compactMap { ShortcutCommand.named($0)?.title.replacingOccurrences(of: "…", with: "") }
        return names.isEmpty ? "No steps yet" : names.joined(separator: " → ")
    }
}

@MainActor
final class Chains: ObservableObject {
    static let shared = Chains()

    /// A chain can't hold more than this: longer than a key's worth of
    /// intent is a script, not a shortcut.
    static let longest = 8

    @Published private(set) var all: [Chain]

    private init() {
        all = Store.settings.data(forKey: "chains")
            .flatMap { try? JSONDecoder().decode([Chain].self, from: $0) } ?? []
    }

    func chain(_ id: UUID) -> Chain? { all.first { $0.id == id } }

    /// The chain on \`combo\`, for the key monitor.
    func chain(on combo: KeyCombo) -> Chain? { all.first { $0.key == combo && !$0.steps.isEmpty } }

    @discardableResult
    func add() -> Chain {
        let made = Chain(name: "Chain \(all.count + 1)", steps: [])
        all.append(made)
        save()
        return made
    }

    func update(_ chain: Chain) {
        guard let index = all.firstIndex(where: { $0.id == chain.id }) else { return }
        var next = chain
        next.steps = Array(next.steps.prefix(Self.longest))
        all[index] = next
        save()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    /// The steps, one a turn, in the window the chain was asked in.
    func run(_ chain: Chain, browser: Browser, window: WindowModel) {
        let commands = chain.steps.compactMap(ShortcutCommand.named)
        func step(_ index: Int) {
            guard index < commands.count else { return }
            commands[index].run(browser, browser.key ?? window)
            DispatchQueue.main.async { step(index + 1) }
        }
        step(0)
    }

    private func save() {
        if all.isEmpty {
            Store.settings.removeObject(forKey: "chains")
        } else {
            Store.settings.set(try? JSONEncoder().encode(all), forKey: "chains")
        }
    }
}

/// Settings › Shortcuts › Command chains.
struct ChainsCard: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject private var chains = Chains.shared
    @State private var open: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Command chains")
            Card {
                if chains.all.isEmpty {
                    Line("Run several commands with one key", "A chain runs its steps in order, like New Tab then Split Side by Side") {
                        Pill("New chain") { open = chains.add().id }
                    }
                }
                ForEach(Array(chains.all.enumerated()), id: \.element.id) { index, chain in
                    if index > 0 { Rule() }
                    ChainRow(store: store, chain: chain, open: $open)
                }
            }
            if !chains.all.isEmpty {
                Pill("New chain") { open = chains.add().id }
                    .padding(.top, 2)
            }
        }
    }
}

private struct ChainRow: View {
    @ObservedObject var store: ShortcutStore
    let chain: Chain
    @Binding var open: UUID?
    @State private var taking: KeyCombo?

    private var editing: Bool { open == chain.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Line(chain.name, chain.summary) {
                HStack(spacing: 8) {
                    ShortcutRecorder(title: chain.name, key: chain.key, changed: chain.key != nil, store: store, accept: accept,
                                     clear: { set(key: nil) }, began: { taking = nil })
                    Quick(editing ? "Done" : "Edit") { open = editing ? nil : chain.id }
                }
            }
            if editing { editor }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: Binding(
                get: { chain.name },
                set: { name in
                    var next = chain
                    next.name = name
                    Chains.shared.update(next)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Chain name")
            ForEach(Array(chain.steps.enumerated()), id: \.offset) { index, id in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: 16, alignment: .trailing)
                    Text((ShortcutCommand.named(id)?.title ?? id).said)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Quick("Remove") {
                        var next = chain
                        next.steps.remove(at: index)
                        Chains.shared.update(next)
                    }
                }
            }
            HStack(spacing: 8) {
                Menu("Add step") {
                    ForEach(ShortcutCommand.Section.allCases, id: \.self) { section in
                        Menu(section.rawValue) {
                            ForEach(ShortcutCommand.all.filter { $0.section == section && $0.id != "tabs.search" }) { command in
                                Button(command.title) {
                                    var next = chain
                                    next.steps.append(command.id)
                                    Chains.shared.update(next)
                                }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(chain.steps.count >= Chains.longest)
                Spacer(minLength: 0)
                Quick("Delete chain", tint: .red) {
                    open = nil
                    Chains.shared.remove(chain.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// A key for the chain, as a command's is taken: not one an extension
    /// or a command already has without asking twice, and never one another
    /// chain has.
    private func accept(_ combo: KeyCombo) -> String? {
        if #available(macOS 15.4, *), let owner = ExtensionShortcuts.owner(of: combo) { return "Used by \(owner)" }
        if let other = Chains.shared.all.first(where: { $0.id != chain.id && $0.key == combo }) { return "Used by \(other.name)" }
        if let owner = store.owner(of: combo, except: ""), taking != combo {
            taking = combo
            return "Used by \(owner.title) — press again"
        }
        if let owner = store.owner(of: combo, except: "") { store.clear(owner.id) }
        set(key: combo)
        taking = nil
        return nil
    }

    private func set(key: KeyCombo?) {
        var next = chain
        next.key = key
        Chains.shared.update(next)
    }
}
