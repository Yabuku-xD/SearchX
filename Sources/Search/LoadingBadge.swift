import SwiftUI

// With the column or the strip folded away there is nothing on screen to say
// a page is still loading. A small spinner on a dark disc says it, in the
// page's top-left corner, only then: not while the column is out over the
// page (it has its own), and not for a page that loads in a blink — it waits
// a quarter of a second before it shows, so a fast page never flashes it.
// It fades in quickly and out a little more gently, and never takes a click.

struct LoadingBadge: View {
    @ObservedObject var window: WindowModel

    var body: some View {
        if let tab = window.active {
            Badge(tab: tab, folded: window.folded && !window.peeking)
        }
    }

    private struct Badge: View {
        @ObservedObject var tab: Tab
        /// The chrome is away and not out over the page.
        let folded: Bool
        /// The page has been loading long enough to be worth saying so.
        @State private var due = false

        var body: some View {
            let on = folded && tab.loading && due && !tab.isBlank
            ZStack {
                if on {
                    Ring(size: 12, tint: .white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .transition(.opacity)
                        .accessibilityLabel("Loading")
                }
            }
            .padding(12)
            .animation(Motion.easeOut(on ? 0.15 : 0.25), value: on)
            .allowsHitTesting(false)
            .task(id: tab.loading) {
                due = false
                guard tab.loading else { return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { due = true }
            }
        }
    }
}
