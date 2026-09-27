import SwiftUI

// Focus mode, Orion's: the page and nothing else. The column or the strip
// folds away and stays away — the edge no longer brings it out — for the
// tab you are reading; going to another tab, or ⌘S, brings it back as it
// was. The address is still ⌘L away.

extension WindowModel {
    func toggleFocus() {
        if focusing != nil { endFocus() } else { beginFocus() }
    }

    func beginFocus() {
        guard let tab = active, focusing == nil else { return }
        focusFolded = folded
        focusing = tab.id
        withAnimation(Motion.glide) {
            peeking = false
            folded = true
        }
        let key = profile.shortcuts.key(for: "view.focus")?.display
        profile.announce(key.map { "Focus mode · \($0) to leave" } ?? "Focus mode")
    }

    /// Back as it was before: folded if it was folded already.
    func endFocus() {
        guard focusing != nil else { return }
        focusing = nil
        withAnimation(Motion.glide) { folded = focusFolded }
    }
}
