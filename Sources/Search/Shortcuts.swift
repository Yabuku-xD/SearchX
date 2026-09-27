import AppKit
import SwiftUI

// Your own keys for the menu commands (Settings › Shortcuts). Only what you
// change is kept, on top of the keys the menus already have, so a browser
// nobody has customised behaves exactly as it always did — and a default
// that changes later still reaches everyone who never touched it.

/// A key and the modifiers held with it.
struct KeyCombo: Codable, Hashable {
    /// A lowercased character, or the name of a key that has none:
    /// left, right, up, down, return, delete, space, f1…f12.
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        // ⌘+ is ⇧⌘= on some keyboards and a key of its own on others; both
        // mean the same thing, so both are kept as "+" with nothing about ⇧.
        let plus = key == "=" || key == "+"
        self.key = plus ? "+" : key.lowercased()
        self.shift = plus ? false : shift
        self.command = command
        self.option = option
        self.control = control
    }

    /// The key an event pressed, read the way the keyboard's own layout
    /// names it with nothing held — so ⇧⌘] is "]" with shift, not "}" —
    /// and the top row by where it sits, as ⌘1–⌘9 are.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named = KeyCombo.names[event.keyCode] ?? ContentView.digits[event.keyCode].map(String.init)
        guard let key = named ?? event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return nil }
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    private static let names: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return",
        51: "delete", 117: "delete", 49: "space", 48: "tab",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "delete": "⌫", "space": "Space", "tab": "⇥",
    ]

    /// As a menu shows it: ⌃⌥⇧⌘ then the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (KeyCombo.symbols[key] ?? key.uppercased())
    }

    private var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// A key alone, or with only ⇧, is typing — never a shortcut.
    var isUsable: Bool { command || option || control || isFunctionKey }

    var swiftUI: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "return": equivalent = .return
        case "delete": equivalent = .delete
        case "space": equivalent = .space
        case "tab": equivalent = .tab
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                equivalent = KeyEquivalent(Character(scalar))
            } else if key.count == 1, let character = key.first {
                equivalent = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// macOS's own, the ones every text field relies on, and the ones Search
    /// keeps for itself (⌘1–⌘9 and ⌘0, ⌃1–⌃9 for spaces). Not ours to give.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        let system: Set<KeyCombo> = [
            KeyCombo("q"), KeyCombo("h"), KeyCombo("m"), KeyCombo("c"), KeyCombo("v"), KeyCombo("x"),
            KeyCombo("a"), KeyCombo("z"), KeyCombo("z", shift: true), KeyCombo("`"), KeyCombo("h", option: true),
            KeyCombo("return"), KeyCombo("left"), KeyCombo("right"),
            KeyCombo("left", shift: true), KeyCombo("right", shift: true),
            KeyCombo("tab", command: false, control: true),
            KeyCombo("tab", command: false, shift: true, control: true),
        ]
        if system.contains(combo) { return true }
        let digit = combo.key.count == 1 && combo.key.first?.isNumber == true
        return digit && !combo.option && !combo.shift && (combo.command != combo.control)
    }
}

/// A menu command, and the key it has unless you give it another.
///
/// What a command does is a closure over the window it was pressed in, with
/// the profile beside it: a per-tab command (new tab, reload, zoom) is the
/// window's, a profile command (settings, the history panel) is the
/// browser's. The monitor hands the run the window the key arrived in, so
/// a second window's key runs there rather than in whichever window is in
/// front. `Commands.swift` has an enum of the same name for the words
/// typed into the address field, so the keyboard's one is spelled out.
struct ShortcutCommand: Identifiable {
    enum Section: String, CaseIterable {
        case app = "SearchX", file = "File", edit = "Edit", view = "View", tabs = "Tabs", bookmarks = "Bookmarks", history = "History"
    }

    let id: String
    let title: String
    let section: Section
    let defaultKey: KeyCombo?
    let run: @MainActor (Browser, WindowModel) -> Void

    init(_ id: String, _ title: String, _ section: Section, _ key: KeyCombo?,
         _ run: @escaping @MainActor (Browser, WindowModel) -> Void) {
        self.id = id
        self.title = title
        self.section = section
        self.defaultKey = key
        self.run = run
    }

    static func named(_ id: String) -> ShortcutCommand? { byID[id] }
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The same commands, keys and order as the menus (see App.swift).
    static let all: [ShortcutCommand] = [
        ShortcutCommand("app.settings", "Settings…", .app, KeyCombo(",")) { browser, _ in browser.tuning.toggle() },
        ShortcutCommand("app.welcome", "Welcome…", .app, nil) { browser, _ in browser.welcoming = true },
        ShortcutCommand("app.passwords", "Passwords…", .app, KeyCombo("l", option: true)) { browser, _ in browser.managing = true },

        ShortcutCommand("file.newWindow", "New Window", .file, KeyCombo("n")) { browser, _ in browser.open() },
        ShortcutCommand("file.newPrivateWindow", "New Private Window", .file, KeyCombo("n", shift: true)) { browser, _ in browser.open(shy: true) },
        ShortcutCommand("file.newTab", "New Tab", .file, KeyCombo("t")) { _, window in window.newTab() },
        // The private tab gives up ⌘⇧N: the private window has a menu of its
        // own now, and one key cannot answer two commands. A private tab
        // still follows the window it is opened from, so ⌘T in a private
        // window stays private.
        ShortcutCommand("file.newPrivateTab", "New Private Tab", .file, nil) { _, window in window.newShyTab() },
        ShortcutCommand("file.reopen", "Reopen Closed Tab", .file, KeyCombo("t", shift: true)) { _, window in window.reopen() },
        ShortcutCommand("file.openAddress", "Open Address…", .file, KeyCombo("l")) { _, window in window.edit() },
        ShortcutCommand("file.closeTab", "Close Tab", .file, KeyCombo("w")) { browser, window in
            if let tab = window.active { browser.closeTab(tab) }
        },
        ShortcutCommand("file.print", "Print…", .file, KeyCombo("p")) { browser, _ in browser.printPage() },

        ShortcutCommand("edit.find", "Find on Page…", .edit, KeyCombo("f")) { _, window in window.openFind() },
        ShortcutCommand("edit.findNext", "Find Next", .edit, KeyCombo("g")) { _, window in window.look(forward: true) },
        ShortcutCommand("edit.findPrevious", "Find Previous", .edit, KeyCombo("g", shift: true)) { _, window in window.look(forward: false) },

        ShortcutCommand("view.sidebar", "Show Tabs in Sidebar", .view, KeyCombo("s", shift: true)) { browser, _ in browser.toggleSidebar() },
        ShortcutCommand("view.fold", "Hide Sidebar or Tab Bar", .view, KeyCombo("s")) { _, window in window.toggleFold() },
        ShortcutCommand("view.focus", "Focus Mode", .view, KeyCombo("f", shift: true)) { _, window in window.toggleFocus() },
        ShortcutCommand("view.savePower", "Save Power", .view, nil) { _, _ in Power.shared.toggle() },
        ShortcutCommand("view.splitColumns", "Split Side by Side", .view, nil) { _, window in window.setSplitLayout(.columns) },
        ShortcutCommand("view.splitRows", "Split Stacked", .view, nil) { _, window in window.setSplitLayout(.rows) },
        ShortcutCommand("view.splitGrid", "Split in a Grid", .view, nil) { _, window in window.setSplitLayout(.grid) },
        ShortcutCommand("view.reload", "Reload Page", .view, KeyCombo("r")) { _, window in window.reload() },
        ShortcutCommand("view.reloadOrigin", "Reload Page From Origin", .view, KeyCombo("r", option: true)) { _, window in window.reload(fromOrigin: true) },
        ShortcutCommand("view.reader", "Reading Mode", .view, KeyCombo("r", shift: true)) { _, window in window.toggleReader() },
        ShortcutCommand("view.translate", "Translate Page", .view, KeyCombo("l", shift: true)) { _, window in window.toggleTranslation() },
        ShortcutCommand("view.float", "Float Video", .view, KeyCombo("p", shift: true)) { browser, _ in browser.toggleFloat() },
        ShortcutCommand("view.hide", "Hide Elements…", .view, KeyCombo("h", shift: true)) { browser, _ in browser.toggleHiding() },
        ShortcutCommand("view.hidden", "Hidden on This Site…", .view, KeyCombo("u", shift: true)) { browser, _ in browser.reviewing.toggle() },
        ShortcutCommand("view.zoomIn", "Zoom In", .view, KeyCombo("+")) { _, window in window.zoom(by: 1.1) },
        ShortcutCommand("view.zoomOut", "Zoom Out", .view, KeyCombo("-")) { _, window in window.zoom(by: 1 / 1.1) },
        ShortcutCommand("view.actualSize", "Actual Size", .view, KeyCombo("0")) { _, window in window.resetZoom() },
        ShortcutCommand("view.inspector", "Web Inspector", .view, KeyCombo("i", option: true)) { browser, _ in browser.toggleInspector() },
        ShortcutCommand("view.console", "JavaScript Console", .view, KeyCombo("j", option: true)) { browser, _ in browser.showConsole() },
        ShortcutCommand("view.inspect", "Inspect Element", .view, KeyCombo("c", option: true)) { browser, _ in browser.inspectElement() },

        ShortcutCommand("tabs.back", "Back", .tabs, KeyCombo("[")) { _, window in window.back() },
        ShortcutCommand("tabs.forward", "Forward", .tabs, KeyCombo("]")) { _, window in window.forward() },
        ShortcutCommand("tabs.next", "Next Tab", .tabs, KeyCombo("]", shift: true)) { _, window in window.step(1) },
        ShortcutCommand("tabs.previous", "Previous Tab", .tabs, KeyCombo("[", shift: true)) { _, window in window.step(-1) },
        ShortcutCommand("tabs.search", "Search Tabs…", .tabs, KeyCombo("k")) { _, window in window.summon() },
        ShortcutCommand("tabs.rename", "Rename Tab", .tabs, nil) { _, window in
            if let tab = window.active { window.beginTabRename(tab) }
        },
        ShortcutCommand("tabs.pin", "Pin or Unpin Tab", .tabs, nil) { _, window in
            guard let tab = window.active, tab.showsPage else { return }
            if tab.pin == nil { window.pin(tab) } else { window.unpin(tab) }
        },
        ShortcutCommand("tabs.duplicate", "Duplicate Tab", .tabs, KeyCombo("d")) { _, window in window.duplicate() },
        ShortcutCommand("tabs.copyAddress", "Copy Address", .tabs, KeyCombo("c", shift: true)) { _, window in window.copyAddress() },
        ShortcutCommand("tabs.pasteAndGo", "Paste and Go", .tabs, KeyCombo("v", shift: true)) { _, window in window.pasteAndGo() },
        // ⌘⇧K, which the tab switcher laid claim to first. ⌘K alone is still
        // the switcher's; ⌘⇧K is this, and nothing else wants it.
        ShortcutCommand("tabs.closeOthers", "Close Other Tabs", .tabs, KeyCombo("k", shift: true)) { _, window in
            if let tab = window.active { window.closeOthers(but: tab) }
        },
        ShortcutCommand("tabs.mute", "Stop Sound in Tab", .tabs, KeyCombo("m", shift: true)) { _, window in window.pauseMedia() },
        ShortcutCommand("tabs.webPanel", "Open in Web Panel", .tabs, nil) { _, window in
            if let tab = window.active { window.openInPanel(tab) }
        },

        ShortcutCommand("bookmarks.add", "Add This Page", .bookmarks, KeyCombo("b", shift: true)) { browser, _ in browser.bookmarkCurrent() },
        ShortcutCommand("bookmarks.show", "Show Bookmarks…", .bookmarks, nil) { browser, _ in browser.bookmarking = true },

        ShortcutCommand("history.show", "Show History…", .history, KeyCombo("y")) { browser, _ in browser.recalling.toggle() },
        ShortcutCommand("history.downloads", "Downloads…", .history, KeyCombo("j", shift: true)) { browser, _ in browser.hoarding.toggle() },
        ShortcutCommand("history.clearData", "Clear Browsing Data…", .history, KeyCombo("delete", shift: true)) { browser, _ in browser.recallMode = .clearing },
        ShortcutCommand("history.clear", "Clear History", .history, nil) { browser, _ in browser.clearHistory() },
    ]
}

extension Browser {
    /// Runs a command in the window it belongs to: the one the key was
    /// pressed in, or the one in front when the key arrived from nowhere in
    /// particular (a menu, the bench). The App layer calls this from the key
    /// monitor, so what a shortcut does lives here in one place.
    @MainActor
    func run(_ command: ShortcutCommand, in window: WindowModel?) {
        command.run(self, window ?? ordinary)
    }
}

/// What you've changed, on top of the defaults: a new key, or none.
@MainActor
final class ShortcutStore: ObservableObject {
    private struct Override: Codable, Equatable { var key: KeyCombo? }

    @Published private var changed: [String: Override]
    /// A key is being typed into Settings; the app's own keys stand aside.
    @Published var recording = false

    init() {
        changed = Store.settings.data(forKey: "shortcuts")
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }

    func key(for id: String) -> KeyCombo? {
        if let override = changed[id] { return override.key }
        return ShortcutCommand.named(id)?.defaultKey
    }

    func isChanged(_ id: String) -> Bool { changed[id] != nil }
    var anyChanged: Bool { !changed.isEmpty }

    /// A command you gave `combo`, for the key monitor to run. Only a
    /// command whose key you actually changed is here: the defaults the
    /// menus had are handled below this one, on the keys they always had.
    func changedCommand(on combo: KeyCombo) -> ShortcutCommand? {
        ShortcutCommand.all.first { changed[$0.id] != nil && key(for: $0.id) == combo }
    }

    /// A key the menus had that no command has now: the page's again.
    func isFreed(_ combo: KeyCombo) -> Bool {
        ShortcutCommand.all.contains { $0.defaultKey == combo && changed[$0.id] != nil }
            && !ShortcutCommand.all.contains { key(for: $0.id) == combo }
    }

    /// The command already on `combo`, other than `id`.
    func owner(of combo: KeyCombo, except id: String) -> ShortcutCommand? {
        ShortcutCommand.all.first { $0.id != id && key(for: $0.id) == combo }
    }

    /// `combo` for `id`, taken from whichever command had it.
    func assign(_ combo: KeyCombo, to id: String) {
        guard !extensionOwns([combo]) else { return }
        if let other = owner(of: combo, except: id) { set(nil, for: other.id) }
        set(combo, for: id)
    }

    func clear(_ id: String) { set(nil, for: id) }

    func reset(_ id: String) {
        if let key = ShortcutCommand.named(id)?.defaultKey {
            guard !extensionOwns([key]) else { return }
            if let other = owner(of: key, except: id) { set(nil, for: other.id) }
        }
        changed[id] = nil
        save()
    }

    func resetAll() {
        guard !extensionOwns(ShortcutCommand.all.compactMap(\.defaultKey)) else { return }
        changed = [:]
        save()
    }

    /// Only a difference from the default is kept.
    private func extensionOwns(_ keys: [KeyCombo]) -> Bool {
        if #available(macOS 15.4, *) {
            for key in keys {
                if let owner = ExtensionShortcuts.owner(of: key) {
                    Extensions.shared.browser?.announce("\(key.display) is used by \(owner). Change that extension shortcut first.")
                    return true
                }
            }
        }
        return false
    }

    private func set(_ combo: KeyCombo?, for id: String) {
        changed[id] = combo == ShortcutCommand.named(id)?.defaultKey ? nil : Override(key: combo)
        save()
    }

    private func save() {
        if changed.isEmpty {
            Store.settings.removeObject(forKey: "shortcuts")
        } else {
            Store.settings.set(try? JSONEncoder().encode(changed), forKey: "shortcuts")
        }
    }
}

extension View {
    /// The command's key as it stands, or none (see ShortcutStore).
    func shortcut(_ id: String, _ store: ShortcutStore) -> some View {
        keyboardShortcut(store.key(for: id)?.swiftUI)
    }
}
