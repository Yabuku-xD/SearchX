import AppKit
import WebKit

// \`./bench audit step=port104\`: windows, shared pins, held dialogs and the
// small switches brought over from upstream 1.0.4. Only on a SEARCH_PROBE run
// (AuditProbe checks).

@MainActor
enum Port104Probe {
    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        func window(_ key: String = "window") -> WindowModel? {
            let index = request[key] as? Int ?? 0
            return browser.windows.indices.contains(index) ? browser.windows[index] : nil
        }
        func tab(in model: WindowModel?, _ key: String = "id") -> Tab? {
            guard let ref = (request[key] as? String)?.lowercased(), !ref.isEmpty else { return nil }
            return model?.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
        }
        switch request["act"] as? String ?? "state" {
        case "state":
            break
        case "newWindow":
            _ = browser.open()
        case "closeWindow":
            guard let model = window() else { return ["error": "no such window"] }
            browser.close(model)
        case "reopen":
            window()?.reopen()
        case "open":
            guard let model = window(), let url = (request["url"] as? String).flatMap(URL.init(string:)) else { return ["error": "open needs a url"] }
            let made = model.open(url, foreground: request["front"] as? Bool ?? true, atEnd: true)
            return ["id": Bench.short(made)] as [String: Any]
        case "select":
            guard let model = window(), let target = tab(in: model) else { return ["error": "no such tab"] }
            model.select(target)
        case "pin":
            guard let model = window(), let target = tab(in: model) else { return ["error": "no such tab"] }
            model.pin(target)
        case "unpin":
            guard let model = window(), let target = tab(in: model) else { return ["error": "no such tab"] }
            model.unpin(target)
        case "moveToWindow":
            guard let from = window(), let to = window("to"), let target = tab(in: from) else { return ["error": "moveToWindow needs window, to and id"] }
            from.move(target, to: to, at: to.tabs.count)
        case "write":
            browser.writeSession()
        case "escape":
            // Escape, as the key monitor has it.
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: browser.keyHost?.windowNumber ?? 0, context: nil,
                                            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                            isARepeat: false, keyCode: 53) {
                _ = ContentView.keyHook?(event)
            }
        case "prefs":
            if let on = request["tracking"] as? Bool { browser.prefs.keepsSignIns = !on }
            if let on = request["waits"] as? Bool { browser.prefs.waitsForPlay = on }
            if let on = request["sidebar"] as? Bool { browser.prefs.sidebar = on }
            if let width = request["sideWidth"] as? Double { browser.prefs.sideWidth = CGFloat(width) }
            if let columns = request["pinColumns"] as? Int { browser.prefs.pinColumns = columns }
            if let rows = request["pinRows"] as? Bool { browser.prefs.pinRows = rows }
        case "autoplay":
            guard let host = request["host"] as? String else { return ["error": "autoplay needs a host"] }
            Autoplay.set(request["on"] as? Bool ?? true, for: host)
        case "mayOpen":
            guard #available(macOS 15.4, *) else { return ["error": "needs macOS 15.4"] }
            let url = (request["url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
            do { try Extensions.mayOpen(url); return ["allowed": true] } catch { return ["allowed": false] }
        default:
            return ["error": "unknown act"]
        }
        return state(browser)
    }

    static func state(_ browser: Browser) -> [String: Any] {
        [
            "windows": browser.windows.map { model -> [String: Any] in
                [
                    "private": model.isPrivate,
                    "space": model.spaceID.uuidString,
                    "active": model.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "movable": browser.host(of: model)?.isMovable ?? false,
                    "frame": browser.host(of: model).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                    "tabs": model.tabs.map { tab in
                        ["id": Bench.short(tab), "url": tab.address?.absoluteString ?? tab.pending?.absoluteString ?? "",
                         "pin": tab.pin ?? "", "pinID": tab.pinID?.uuidString ?? "",
                         "home": tab.pinHome?.absoluteString ?? ""] as [String: Any]
                    },
                ]
            },
            "closedWindows": browser.closedWindows.count,
            "held": browser.heldDialogs.map { [String($0.key.uuidString.prefix(8)).lowercased(): $0.value.count] },
            "pins": (Pins.defs(browser.key?.spaceID ?? Space.firstID) ?? []).map { ["letter": $0.letter, "home": $0.home] },
            "tracking": !browser.prefs.keepsSignIns,
            "waits": browser.prefs.waitsForPlay,
            // Which media need a click before they play. Not the raw value:
            // .all is UInt.max, which no Int holds.
            "clickFor": [
                Web.playback.contains(.audio) ? "audio" : nil,
                Web.playback.contains(.video) ? "video" : nil,
            ].compactMap { $0 },
            "unlisted": browser.unlisted.count,
            "news": browser.newsShowing,
            "newsSeen": Store.settings.string(forKey: WhatsNew.seenKey) ?? "",
            "fetching": browser.fetches.showing,
        ]
    }
}
