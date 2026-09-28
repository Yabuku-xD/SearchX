#if DEBUG
import AppKit
import ScreenCaptureKit

/// Native appearance checks in an isolated SEARCH_PROBE process only.
@MainActor
enum NativeProbe {
    static var scrollMessages = 0
    static var snapshotRequests = 0
    /// How many drag moves the last "drag" posted, once it has let go.
    static var dragSent = 0

    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "test process required"] }
        if request["action"] as? String == "save" {
            browser.flushSession()
            return ["saved": true]
        }
        let window = browser.keyHost
        switch request["action"] as? String ?? "nodes" {
        case "hitches":
            // The main thread against the display: every tick is a frame
            // this process could have drawn in, or handed a page's on.
            // "start" begins counting, anything else reads and stops.
            if request["start"] as? Bool == true {
                Hitches.shared.start(on: window?.screen ?? NSScreen.main)
                return ["started": true]
            }
            return Hitches.shared.stop()
        case "block":
            // The main thread kept busy for MS: what goes on moving meanwhile
            // doesn't depend on it.
            let until = CACurrentMediaTime() + (request["ms"] as? Double ?? 100) / 1000
            while CACurrentMediaTime() < until {}
            return ["blocked": true]
        case "live":
            // Pages still alive anywhere: a tab closed for good lets its go.
            let pages = Web.pages.allObjects
            return ["pages": pages.count, "inWindow": pages.filter { $0.window != nil }.count,
                    "tabs": browser.allTabs.count, "built": browser.allTabs.filter { $0.built != nil }.count]
        case "scripts":
            // What every page and frame of the tab on screen is given.
            guard let web = browser.key?.active?.built else { return ["error": "no page"] }
            return ["scripts": web.configuration.userContentController.userScripts.map { script in
                ["bytes": script.source.utf8.count, "mainOnly": script.isForMainFrameOnly,
                 "start": script.injectionTime == .atDocumentStart,
                 "head": String(script.source.prefix(90)).replacingOccurrences(of: "\n", with: " ")] as [String: Any]
            }]
        case "favicon":
            if request["evict"] as? Bool == true { Favicons.shared.evictForProbe() }
            guard let host = request["host"] as? String ?? browser.key?.active?.address?.host() else {
                return ["error": "host required"]
            }
            let icon = request["cached"] as? Bool == true ? Favicons.shared.cached(host) : browser.key?.active?.icon
            guard let icon, let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return ["available": false] }
            if let path = request["path"] as? String {
                do { try png.write(to: URL(fileURLWithPath: path), options: .atomic) }
                catch { return ["error": error.localizedDescription] }
            }
            return ["available": true, "pixels": [rep.pixelsWide, rep.pixelsHigh],
                    "verticalAlpha": [0, rep.pixelsHigh/2, rep.pixelsHigh-1].map {
                        rep.colorAt(x: rep.pixelsWide/2, y: $0)?.alphaComponent ?? -1
                    }]
        case "performance":
            if request["render"] as? Bool == true {
                // WindowServer can occlude automation windows between tool
                // calls. Ignore that only for the measured page, retaining
                // normal background scheduling for all other test tabs.
                let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                for tab in browser.allTabs {
                    guard let web = tab.built, web.responds(to: selector) else { continue }
                    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(web.method(for: selector), to: Setter.self)(web, selector, tab !== browser.key?.active)
                }
            }
            if request["front"] as? Bool == true {
                // Keep this disposable workload visible without changing any
                // system-wide throttling or display preferences.
                window?.level = .floating
                window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            if request["reset"] as? Bool == true {
                scrollMessages = 0
                snapshotRequests = 0
            }
            let selector = NSSelectorFromString("_webProcessIdentifier")
            let pids = browser.allTabs.compactMap { tab -> Int32? in
                guard let web = tab.built, web.responds(to: selector) else { return nil }
                typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
                let pid = unsafeBitCast(web.method(for: selector), to: Getter.self)(web, selector)
                return pid > 0 ? pid : nil
            }
            return ["scrollMessages": scrollMessages, "snapshotRequests": snapshotRequests,
                    "appActive": NSApp.isActive, "appHidden": NSApp.isHidden,
                    "windowVisible": window?.occlusionState.contains(.visible) ?? false,
                    "webPIDs": Array(Set(pids)).sorted(),
                    "reading": browser.key?.active?.reading.through ?? 0,
                    "thumbnails": browser.allTabs.filter { $0.thumb != nil }.count,
                    "screenHz": window?.screen?.maximumFramesPerSecond ?? 0,
                    "backdrops": window?.contentView.map { root in views(root).filter {
                        $0.identifier?.rawValue == "page-chrome-backdrop"
                    }.map { ["frame": NSStringFromRect($0.frame), "filters": $0.backgroundFilters.count] as [String: Any] } } ?? []]
        case "process":
            return ["pid": ProcessInfo.processInfo.processIdentifier,
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "executable": Bundle.main.executableURL?.path ?? "",
                    "hidden": NSApp.isHidden]
        case "startup":
            return Web.poolStartup
        case "menus", "menu":
            guard let main = NSApp.mainMenu else { return ["error": "no menu bar"] }
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
            defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: main) }
            if request["action"] as? String == "menus" {
                func list(_ menu: NSMenu, path: [String]) -> [[String: Any]] {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                    return menu.items.filter { !$0.isSeparatorItem }.flatMap { item in
                        let here = path + [item.title]
                        let row: [String: Any] = ["path": here, "enabled": item.isEnabled, "key": item.keyEquivalent]
                        return [row] + (item.submenu.map { list($0, path: here) } ?? [])
                    }
                }
                return ["items": list(main, path: [])]
            }
            guard let path = request["path"] as? [String], !path.isEmpty else { return ["error": "menu path required"] }
            var menu = main
            for (index, title) in path.enumerated() {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                guard let item = menu.items.first(where: { $0.title == title }) else {
                    return ["error": "menu item missing: \(title)", "available": menu.items.map(\.title)]
                }
                if index == path.count - 1 {
                    guard item.isEnabled, let action = item.action else { return ["error": "menu item is unavailable"] }
                    return ["sent": NSApp.sendAction(action, to: item.target, from: item)]
                }
                guard let next = item.submenu else { return ["error": "submenu missing: \(title)"] }
                menu = next
            }
            return ["error": "empty menu path"]
        case "click":
            guard let window, let x = request["x"] as? Double, let y = request["y"] as? Double else {
                return ["error": "window and screen coordinates required"]
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            var flags: NSEvent.ModifierFlags = []
            for flag in request["mods"] as? [String] ?? [] {
                if flag == "cmd" { flags.insert(.command) }
                if flag == "shift" { flags.insert(.shift) }
            }
            let point = window.convertPoint(fromScreen: NSPoint(x: x, y: y))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            return ["queued": true]
        case "drag":
            // A hand panning a canvas as fast as it goes: pressed at a point of
            // the page, dragged on two unrelated swings, let go. Posted through
            // AppKit's own queue into the window, so WebKit gets what a mouse
            // would give it, without the window server or the pointer.
            guard let window, let web = browser.key?.active?.built,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { return ["error": "window, page and page coordinates required"] }
            let rate = request["rate"] as? Double ?? 1000
            let seconds = request["seconds"] as? Double ?? 8
            let hz = request["hz"] as? Double ?? 6
            let dx = request["dx"] as? Double ?? 520
            let dy = request["dy"] as? Double ?? 330
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let origin = web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
            func post(_ type: NSEvent.EventType, _ point: NSPoint) {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            post(.leftMouseDown, origin)
            let start = ProcessInfo.processInfo.systemUptime
            var sent = 0
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1 / rate, leeway: .microseconds(100))
            timer.setEventHandler {
                let t = ProcessInfo.processInfo.systemUptime - start
                guard t < seconds else {
                    timer.cancel()
                    post(.leftMouseUp, origin)
                    NativeProbe.dragSent = sent
                    return
                }
                // Window coordinates grow upward; the swing is the same either way.
                post(.leftMouseDragged, NSPoint(x: origin.x + dx * sin(t * 2 * .pi * hz),
                                                y: origin.y + dy * sin(t * 2 * .pi * hz * 0.74)))
                sent += 1
            }
            timer.resume()
            NativeProbe.dragSent = 0
            return ["started": true]
        case "drag-sent":
            return ["sent": NativeProbe.dragSent]
        case "mouse":
            // A hand on the window itself: press at X, Y (points from the top
            // left of the window's content), move by DX, DY in STEPS, let go —
            // or, with clicks 2, a double-click where it is.
            guard let window, let content = window.contentView,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { return ["error": "window and x, y required"] }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let start = NSPoint(x: x, y: content.bounds.height - y)
            func post(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            if (request["clicks"] as? Int) == 2 {
                for clicks in [1, 2] {
                    post(.leftMouseDown, start, clicks: clicks)
                    post(.leftMouseUp, start, clicks: clicks)
                }
                return ["clicked": 2]
            }
            if let lines = request["scroll"] as? Int {
                // The scroll view under that point, moved to its end (or its
                // start, for a positive count) — the part of a panel below
                // the fold, to look at.
                guard let hit = content.hitTest(start) else { return ["error": "nothing there"] }
                var view: NSView? = hit
                while let here = view, !(here is NSScrollView) { view = here.superview }
                guard let scroller = view as? NSScrollView, let document = scroller.documentView
                else { return ["error": "no scroll view there"] }
                let bottom = document.isFlipped ? max(0, document.bounds.height - scroller.contentView.bounds.height) : 0
                scroller.contentView.scroll(to: NSPoint(x: 0, y: lines < 0 ? bottom : (document.isFlipped ? 0 : bottom)))
                scroller.reflectScrolledClipView(scroller.contentView)
                return ["scrolled": lines]
            }
            let dx = request["dx"] as? Double ?? 0, dy = request["dy"] as? Double ?? 0
            let steps = max(1, request["steps"] as? Int ?? 20)
            // A hand's pace, one move every 8 ms: posted all at once they
            // arrived as one lump, which no mouse sends.
            post(.leftMouseDown, start)
            for n in 1...steps {
                let t = Double(n) / Double(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008 * Double(n)) {
                    post(.leftMouseDragged, NSPoint(x: start.x + dx * t, y: start.y - dy * t))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008 * Double(steps + 2)) {
                post(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y - dy))
            }
            return ["dragged": [dx, dy]]
        case "fullscreen":
            guard let window else { return ["error": "no window"] }
            window.toggleFullScreen(nil)
            return ["requested": true]
        case "window-state":
            guard let window else { return ["error": "no window"] }
            return ["fullscreen": window.styleMask.contains(.fullScreen),
                    "buttons": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> [String: Any]? in
                        guard let button = window.standardWindowButton(type), let bar = button.superview else { return nil }
                        return ["hidden": bar.isHidden, "x": bar.layer?.value(forKeyPath: "transform.translation.x") ?? 0,
                                "y": bar.layer?.value(forKeyPath: "transform.translation.y") ?? 0]
                    }]
        case "clipboard-image":
            guard let path = request["path"] as? String,
                  let image = NSImage(pasteboard: .general),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return ["error": "clipboard image and output path required"] }
            do { try png.write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { return ["error": error.localizedDescription] }
            return ["path": path, "width": image.size.width, "height": image.size.height]
        case "accent":
            let color = (Wallpaper.shared.accent ?? .labelColor).usingColorSpace(.deviceRGB) ?? .black
            return ["mode": Wallpaper.shared.accent == nil ? "neutral" : "wallpaper",
                    "rgb": [color.redComponent, color.greenComponent, color.blueComponent]]
        case "nodes":
            guard let window else { return ["error": "no window"] }
            return ["modal": NSApp.modalWindow != nil, "nodes": nodes(window).enumerated().map { index, node in
                let frame = (property(node, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                return ["index": index, "role": text(node, "accessibilityRole"),
                        "label": text(node, "accessibilityLabel"), "title": text(node, "accessibilityTitle"),
                        "value": String(describing: property(node, "accessibilityValue") ?? ""),
                        "enabled": property(node, "isAccessibilityEnabled") as? Bool ?? false,
                        "focused": property(node, "isAccessibilityFocused") as? Bool ?? false,
                        "frame": [frame.minX, frame.minY, frame.width, frame.height]] as [String: Any]
            }]
        case "press":
            guard let window else { return ["error": "window required"] }
            let elements = nodes(window)
            let index: Int?
            if let label = request["label"] as? String {
                index = elements.firstIndex {
                    text($0, "accessibilityRole") != "AXStaticText"
                        && [text($0, "accessibilityLabel"), text($0, "accessibilityTitle")].contains(label)
                }
            } else { index = request["index"] as? Int }
            guard let index else { return ["error": "control required"] }
            guard elements.indices.contains(index) else { return ["error": "node missing"] }
            return ["pressed": property(elements[index], "accessibilityPerformPress") as? Bool ?? false]
        case "increment", "decrement":
            guard let window, let index = request["index"] as? Int else { return ["error": "index required"] }
            let elements = nodes(window)
            guard elements.indices.contains(index) else { return ["error": "node missing"] }
            let action = request["action"] as? String == "increment"
                ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement"
            guard elements[index].responds(to: NSSelectorFromString(action))
            else { return ["error": "control is not adjustable"] }
            // SwiftUI performs the adjustment but may return void rather than
            // AppKit's Bool. The caller verifies the value on the next turn.
            _ = property(elements[index], action)
            return ["requested": true]
        case "hit-test":
            guard let window, let root = window.contentView?.superview,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { return ["error": "window and point required"] }
            let point = NSPoint(x: x, y: window.frame.height - y)
            let hit = root.hitTest(root.convert(point, from: nil))
            return ["hit": hit.map { String(describing: type(of: $0)) } ?? "none",
                    "frame": hit.map { NSStringFromRect($0.frame) } ?? "",
                    "key": window.isKeyWindow, "visible": window.isVisible,
                    "active": NSApp.isActive,
                    "backdrops": views(root).filter { $0.identifier?.rawValue == "page-chrome-backdrop" }.map {
                        ["alpha": $0.alphaValue, "usesCoreImage": $0.layerUsesCoreImageFilters,
                         "layer": $0.layer.map { String(describing: type(of: $0)) } ?? "none",
                         "parent": $0.superview.map { String(describing: type(of: $0)) } ?? "none",
                         "layerFilters": ($0.layer?.backgroundFilters as? [CIFilter] ?? []).map { $0.name },
                         "filters": $0.backgroundFilters.map {
                            ["name": $0.name, "radius": $0.inputKeys.contains("inputRadius") ? ($0.value(forKey: "inputRadius") ?? 0) : 0] as [String: Any]
                        }] as [String: Any]
                    },
                    "effects": views(root).compactMap { $0 as? NSVisualEffectView }.map {
                        ["frame": NSStringFromRect($0.frame), "alpha": $0.alphaValue,
                         "identifier": $0.identifier?.rawValue ?? "", "hidden": $0.isHidden,
                         "mode": $0.blendingMode.rawValue, "material": $0.material.rawValue] as [String: Any]
                    }]
        case "composited-shot":
            guard #available(macOS 14.4, *), let window, let path = request["path"] as? String
            else { return ["error": "window, path and macOS 14.4 required"] }
            Task { @MainActor in
                var result: [String: Any]
                do {
                    // Only this process's windows; never request screen access.
                    let content = try await SCShareableContent.currentProcess
                    guard let source = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    }) else { throw NSError(domain: "SearchProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned window unavailable to compositor capture"]) }
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * window.backingScaleFactor)
                    config.height = Int(window.frame.height * window.backingScaleFactor)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { throw NSError(domain: "SearchProbe", code: 2) }
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    result = ["path": path, "width": image.width, "height": image.height]
                    if let rects = request["contrastRects"] as? [[Double]] {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let scale = Double(image.width) / window.frame.width
                        var means: [[Double]] = []
                        result["contrast"] = rects.map { rect -> Double in
                            guard rect.count == 4 else { return -1 }
                            let x0 = max(0, Int(rect[0] * scale)), y0 = max(0, Int(rect[1] * scale))
                            let x1 = min(image.width, Int((rect[0] + rect[2]) * scale))
                            let y1 = min(image.height, Int((rect[1] + rect[3]) * scale))
                            guard x1 > x0, y1 > y0 else { return -1 }
                            var sum = [Double](repeating: 0, count: 3), squares = sum
                            for y in y0..<y1 { for x in x0..<x1 {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                for (i, c) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                                    sum[i] += c; squares[i] += c * c
                                }
                            } }
                            let count = Double((x1 - x0) * (y1 - y0))
                            means.append(sum.map { $0 / count * 255 })
                            return (0..<3).reduce(0.0) { total, i in
                                total + sqrt(max(0, squares[i] / count - pow(sum[i] / count, 2))) * 255 / 3
                            }
                        }
                        result["colorMeans"] = means
                    }
                } catch { result = ["error": error.localizedDescription] }
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL(fileURLWithPath: path + ".json"), options: .atomic)
                }
            }
            return ["scheduled": true]
        case "shot":
            guard let view = window?.contentView, let path = request["path"] as? String,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return ["error": "window or path missing"] }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return ["error": "PNG failed"] }
            do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { return ["error": error.localizedDescription] }
            return ["path": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
        default:
            return ["error": "unknown native action"]
        }
    }

    private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    private static func property(_ node: NSObject, _ getter: String) -> Any? {
        guard node.responds(to: NSSelectorFromString(getter)) else { return nil }
        return node.value(forKey: getter)
    }

    private static func text(_ node: NSObject, _ getter: String) -> String {
        // SwiftUI can return attributed labels despite AppKit's NSString type.
        guard let value = property(node, getter) else { return "" }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 30, seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return [] }
            // SwiftUI's accessibility objects expose these Objective-C getters
            // without declaring NSAccessibilityProtocol conformance.
            return [node] + (property(node, "accessibilityChildren") as? [NSObject] ?? [])
                .flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
}

#endif
