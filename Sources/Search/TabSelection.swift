import AppKit
import SwiftUI

/// Active pins reserve a plain double-click for renaming. Selection still
/// responds to a single modified click, without waiting for that gesture.
struct ModifiedTabClick: NSViewRepresentable {
    let act: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView { Catch() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Catch)?.act = act }

    private final class Catch: NSView {
        var act: (NSEvent.ModifierFlags) -> Void = { _ in }
        private var pressed: NSEvent.ModifierFlags?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  [.leftMouseDown, .leftMouseUp].contains(event.type),
                  !event.modifierFlags.intersection([.command, .shift]).isEmpty else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) { pressed = event.modifierFlags }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = nil }
            guard let pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            act(pressed)
        }
    }
}

extension WindowModel {
    private var chosenTabs: [Tab] {
        let ids = selectedTabs.isEmpty ? Set(activeID.map { [$0] } ?? []) : selectedTabs
        return tabs.filter { ids.contains($0.id) }
    }

    var canCopySelectedAddresses: Bool { chosenTabs.contains { $0.showsPage && $0.address != nil } }
    var canUnloadSelected: Bool { chosenTabs.contains { !$0.isBlank && !$0.asleep } }
    var canUnloadOthers: Bool {
        tabs.contains { $0.id != activeID && !selectedTabs.contains($0.id) && !$0.isBlank && !$0.asleep }
    }

    func pickTab(_ tab: Tab, modifiers supplied: NSEvent.ModifierFlags? = nil) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if pendingSplit != nil { finishSplit(with: tab.id); return }
        let modifiers = supplied ?? NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift),
           let anchor = selectionAnchor ?? activeID,
           let from = tabs.firstIndex(where: { $0.id == anchor }),
           let to = tabs.firstIndex(where: { $0.id == tab.id }) {
            let range = Set(tabs[min(from, to)...max(from, to)].map(\.id))
            selectedTabs = modifiers.contains(.command) ? selectedTabs.union(range) : range
        } else if modifiers.contains(.command) {
            if selectedTabs.isEmpty, let activeID { selectedTabs.insert(activeID) }
            if selectedTabs.contains(tab.id) { selectedTabs.remove(tab.id) }
            else { selectedTabs.insert(tab.id) }
            selectionAnchor = tab.id
        } else {
            selectedTabs = []
            selectionAnchor = tab.id
            select(tab)
        }
    }

    /// What a tab's menu acts on: the tab it was opened on — or, when that
    /// tab is one of several chosen, all of them, as the Finder does. Never
    /// some other tab that happens to be on screen.
    func menuTabs(for tab: Tab) -> [Tab] {
        guard selectedTabs.count > 1, selectedTabs.contains(tab.id) else { return [tab] }
        return tabs.filter { selectedTabs.contains($0.id) }
    }

    /// Every tab but these, and the one on screen, let go of.
    func unloadTabs(besides kept: [Tab]) {
        let ids = Set(kept.map(\.id)).union(activeID.map { [$0] } ?? [])
        unload(tabs.filter { !ids.contains($0.id) })
    }

    func canUnload(besides kept: [Tab]) -> Bool {
        let ids = Set(kept.map(\.id)).union(activeID.map { [$0] } ?? [])
        return tabs.contains { !ids.contains($0.id) && !$0.isBlank && !$0.asleep }
    }

    func copySelectedAddresses() { copyAddresses(of: chosenTabs) }

    func copyAddresses(of chosen: [Tab]) {
        let addresses = chosen.filter { $0.showsPage }.compactMap { $0.address?.absoluteString }
        guard !addresses.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses.joined(separator: "\n"), forType: .string)
        profile.announce(addresses.count == 1 ? "Address copied" : "\(addresses.count) addresses copied")
    }

    func unloadSelectedTabs() {
        unload(chosenTabs)
    }

    func unloadOtherTabs() {
        let kept = selectedTabs.union(activeID.map { [$0] } ?? [])
        unload(tabs.filter { !kept.contains($0.id) })
    }

    /// Pages let go of, their places kept; the one on screen gives way first.
    func unload(_ candidates: [Tab]) {
        let targets = candidates.filter { !$0.isBlank && !$0.asleep }
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        if let activeID, ids.contains(activeID) {
            if let next = tabs.first(where: { !ids.contains($0.id) }) {
                select(next, floatPrevious: false)
            } else {
                let blank = makeTab()
                adopt(blank)
                select(blank, floatPrevious: false)
            }
        }
        for tab in targets {
            profile.sleep(tab, manually: true) { [weak self] result in
                guard result != "asleep" else { return }
                self?.profile.announce("Kept \(tab.label) awake: \(result)")
            }
        }
    }
}
