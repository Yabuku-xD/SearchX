import AppKit
import SwiftUI

/// Settings › Shortcuts: every menu command with its key, a card to a menu,
/// narrowed by name or key. Click a key and press the new one; right-click
/// to clear it or put the default back.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: ShortcutStore

    @State private var hunt = ""
    @FocusState private var hunting: Bool

    /// By name, or by key as the menus write it: "tab" and "⌘T" both find New Tab.
    private func shown(_ command: ShortcutCommand) -> Bool {
        let words = hunt.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        let key = store.key(for: command.id)?.display ?? ""
        return command.title.localizedCaseInsensitiveContains(words)
            || key.localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Hunt(text: $hunt, prompt: "Search commands or keys", focus: $hunting)
            if hunt.isEmpty { ChainsCard(store: store) }
            let found = ShortcutCommand.all.filter(shown)
            if found.isEmpty { Nothing("No command called that, or on that key") }
            ForEach(ShortcutCommand.Section.allCases, id: \.self) { section in
                let commands = found.filter { $0.section == section }
                if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(section.rawValue)
                    Card {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            if index > 0 { Rule() }
                            Line(command.title) {
                                KeyBox(store: store, command: command)
                            }
                            .contextMenu {
                                Button("Clear Shortcut") { store.clear(command.id) }
                                    .disabled(store.key(for: command.id) == nil)
                                Button("Reset to Default") { store.reset(command.id) }
                                    .disabled(!store.isChanged(command.id))
                            }
                        }
                    }
                }
                }
            }
            if store.anyChanged, hunt.isEmpty {
                Pill("Reset All to Defaults") { store.resetAll() }
            }
        }
    }
}

/// The key a command is on. Click it and press another: that key moves
/// here, from whichever command had it. Esc stops without changing it,
/// ⌫ takes it off.
private struct KeyBox: View {
    @ObservedObject var store: ShortcutStore
    let command: ShortcutCommand
    @State private var taking: KeyCombo?

    var body: some View {
        ShortcutRecorder(title: command.title, key: store.key(for: command.id),
                         changed: store.isChanged(command.id), store: store, accept: { combo in
            if #available(macOS 15.4, *), let owner = ExtensionShortcuts.owner(of: combo) {
                return "Used by \(owner)"
            }
            if let owner = store.owner(of: combo, except: command.id), taking != combo {
                taking = combo
                return "Used by \(owner.title) — press again"
            }
            if let chain = Chains.shared.all.first(where: { $0.key == combo }) {
                return "Used by \(chain.name)"
            }
            store.assign(combo, to: command.id)
            taking = nil
            return nil
        }, clear: { store.clear(command.id) }, began: { taking = nil })
    }
}

struct ShortcutRecorder: View {
    let title: String
    let key: KeyCombo?
    let changed: Bool
    @ObservedObject var store: ShortcutStore
    let accept: (KeyCombo) -> String?
    let clear: () -> Void
    var began: () -> Void = {}

    @State private var listening = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var hovering = false

    var body: some View {
        Button(action: listen) {
            Text(label)
                .font(.system(size: 12, weight: changed ? .semibold : .regular))
                .foregroundStyle(listening || key != nil ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 64, minHeight: 24)
                .background(listening ? Palette.hover : (hovering ? Palette.hover : Palette.ground),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(listening ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut for \(title)")
        .accessibilityValue(label)
        .onHover { hovering = $0 }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if let note { return note }
        if listening { return "Type a shortcut" }
        return key?.display ?? "None"
    }

    private func listen() {
        guard !listening else { return stop() }
        began()
        listening = true
        note = nil
        store.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            take(event)
            return nil
        }
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            clear()
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say("Add ⌘, ⌥ or ⌃") }
        guard !KeyCombo.isReserved(combo) else { return say("Can’t be changed") }
        if let reason = accept(combo) { return say(reason) }
        stop()
    }

    /// Why that key won't do, for a moment, still listening.
    private func say(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if note == text { note = nil } }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        note = nil
        store.recording = false
    }
}
