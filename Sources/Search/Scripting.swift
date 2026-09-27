import AppKit

// AppleScript in Safari's words: the tabs of a window, which one is current,
// and each tab's address and name (see Search.sdef). Every window answers
// for itself, so the front window is what a script sees. A private window
// is left out: what is in it is nobody else's business, and a script that
// can name every window in the app should not be able to name that one.

@MainActor
@objc(ScriptTab)
final class ScriptTab: NSObject {
    private let tab: Tab
    private let index: Int
    private weak var window: NSWindow?

    /// Cocoa specifiers use zero-based indices; AppleScript displays them
    /// starting at one.
    init(_ tab: Tab, index: Int, in window: NSWindow) {
        self.tab = tab
        self.index = index
        self.window = window
    }

    @objc var url: String { tab.address?.absoluteString ?? "" }
    @objc var name: String { tab.title }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window, let container = window.objectSpecifier,
              let description = container.keyClassDescription
        else { return nil }
        return NSIndexSpecifier(
            containerClassDescription: description,
            containerSpecifier: container, key: "scriptTabs", index: index
        )
    }
}

extension NSWindow {
    /// This window's tabs, in order. A private window has none to give.
    @MainActor @objc var scriptTabs: [ScriptTab] {
        guard let model = Links.browser?.model(owning: self), !model.isPrivate else { return [] }
        return model.tabs.enumerated().map { ScriptTab($0.element, index: $0.offset, in: self) }
    }

    /// The tab showing in this window. Private: nothing is showing.
    @MainActor @objc var scriptCurrentTab: ScriptTab? {
        guard let model = Links.browser?.model(owning: self), !model.isPrivate,
              let active = model.active,
              let index = model.tabs.firstIndex(where: { $0 === active })
        else { return nil }
        return ScriptTab(active, index: index, in: self)
    }
}
