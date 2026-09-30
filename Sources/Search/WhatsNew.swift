import SwiftUI

// What's new, once, after an update.
//
// New features start off, so someone who never opens Settings never meets
// them. The first time a newer version opens, a small card shows its new
// switches, each with a line of what it does and the switch itself, and — so
// nothing gets lost — the switches from earlier versions that are still off.
// Closed, it doesn't come back for that version. Not after a fresh install:
// the welcome is for that. What each version brought is NOTES.md, published
// with every release; the card's link opens the releases page.
//
// A release that adds switches adds them to `toggles` with its version, and
// its version to `releases`.

enum WhatsNew {
    /// A switch the card offers: the same setting as in Settings.
    struct Toggle {
        let title: String
        let detail: String
        /// The version it came in.
        let since: String
        let get: @MainActor (Preferences) -> Bool
        let set: @MainActor (Preferences, Bool) -> Void
    }

    /// Every switch worth meeting, newest first. The card shows this
    /// version's, and the older ones still off.
    static let toggles: [Toggle] = [
        Toggle(title: "Videos wait for a click", detail: "Videos don't start by themselves, even without sound.",
               since: "1.1.9", get: { $0.waitsForPlay }, set: { $0.waitsForPlay = $1 }),
        Toggle(title: "Always show the Downloads button", detail: "Downloads one click away. Off, it comes while a file downloads.",
               since: "1.1.9", get: { $0.downloadButton }, set: { $0.downloadButton = $1 }),

        Toggle(title: "Split view", detail: "Up to four tabs side by side, stacked or in a grid.",
               since: "1.1.0", get: { $0.splitViews }, set: { $0.splitViews = $1 }),
        Toggle(title: "Tab groups", detail: "Named sections of tabs. Right-click a tab to start one.",
               since: "1.1.0", get: { $0.usesTabGroups }, set: { $0.usesTabGroups = $1 }),
        Toggle(title: "Spaces", detail: "Separate sets of tabs, each with its own sign-ins. ⌃1–⌃9 to switch.",
               since: "1.1.0", get: { $0.usesSpaces }, set: { $0.usesSpaces = $1 }),
        Toggle(title: "Hold a swipe to pick from history", detail: "Keep your fingers down after a back or forward swipe to choose a page.",
               since: "1.1.0", get: { $0.holdsHistory }, set: { $0.holdsHistory = $1 }),
        Toggle(title: "Load tabs when you first see them", detail: "Tabs opened in the background wait until they're on screen.",
               since: "1.1.0", get: { $0.lazyTabs }, set: { $0.lazyTabs = $1 }),
        Toggle(title: "Bookmarks bar", detail: "Your bookmarks in a row above the page.",
               since: "1.1.0", get: { $0.bookmarksBar }, set: { $0.bookmarksBar = $1 }),
        Toggle(title: "Scroll with the middle button", detail: "Click the wheel, then move the mouse to scroll, as on Windows.",
               since: "1.1.0", get: { $0.autoScroll }, set: { $0.autoScroll = $1 }),
    ]

    /// Versions that have a card.
    static let releases: [String] = ["1.1.9"]

    /// This version's card, when it has one. A test world names the version
    /// it plays (SEARCH_WHATSNEW), since a build from the tree is "dev".
    static var current: String? {
        let playing = Store.testing ? ProcessInfo.processInfo.environment["SEARCH_WHATSNEW"] : nil
        return releases.first { $0 == (playing ?? Updater.version) }
    }

    /// Version strings in order: 1.0.10 after 1.0.9.
    static func older(_ one: String, than other: String) -> Bool {
        let a = one.split(separator: ".").compactMap { Int($0) }
        let b = other.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static let seenKey = "whatsnew.seen"

    /// At launch, once: whether the card is due. Not on a fresh install (the
    /// welcome is up, and this version counts as seen), nor in a test world
    /// unless it says it wants one (SEARCH_WHATSNEW); otherwise once per
    /// version that has a card.
    @MainActor static func due(welcoming: Bool) -> Bool {
        let store = Store.settings
        guard let current else { return false }
        if welcoming {
            store.set(current, forKey: seenKey)
            return false
        }
        guard store.string(forKey: seenKey) != current else { return false }
        store.set(current, forKey: seenKey)
        return true
    }

    /// Every version's notes, as published with each release.
    static let releasesPage = URL(string: "https://github.com/Yabuku-xD/SearchX/releases")!
}

/// The card: what's new in this version, its switches right there, and the
/// earlier ones still off.
struct WhatsNewCard: View {
    let version: String
    @ObservedObject var prefs: Preferences
    let close: () -> Void
    let notes: () -> Void

    /// Read once, as the card opens: a switch turned on here stays in the
    /// list rather than vanishing under the hand.
    @State private var earlier: [WhatsNew.Toggle]?

    private var fresh: [WhatsNew.Toggle] { WhatsNew.toggles.filter { $0.since == version } }

    var body: some View {
        Plate("New in SearchX \(version)", width: 460, close: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rows(fresh)
                    if let earlier, !earlier.isEmpty {
                        Caption("From earlier versions, in case you missed them")
                            .padding(.top, 6)
                        rows(earlier)
                    }
                }
            }
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            HStack {
                Button(action: notes) {
                    Text("Everything that's new…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Pill("Close", filled: true, action: close)
            }
        }
        .onAppear {
            if earlier == nil {
                earlier = WhatsNew.toggles.filter { WhatsNew.older($0.since, than: version) && !$0.get(prefs) }
            }
        }
    }

    private func rows(_ toggles: [WhatsNew.Toggle]) -> some View {
        Card {
            ForEach(Array(toggles.enumerated()), id: \.offset) { index, toggle in
                if index > 0 { Rule() }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toggle.title.said)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                        Text(toggle.detail.said)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Switch(on: Binding(get: { toggle.get(prefs) }, set: { toggle.set(prefs, $0) }))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}
