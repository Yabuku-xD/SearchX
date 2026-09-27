import AppKit

// How scrolling looks and moves, set for this app only, for this run only:
// the argument domain is never written to disk and sits above the user's own
// defaults, so System Settings is untouched and nothing is left behind.
enum Scrollers {
    static func float() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)

        // Scroll bars that take no room: drawn over the content, hidden until
        // it scrolls, whatever is plugged in. With a mouse attached, macOS's
        // automatic setting gives every scroll view — and every page, whose
        // web process is told this app's style when it starts and whenever it
        // changes — a bar with its own gutter, narrowing the page by its width.
        // A launch argument naming a style still wins.
        if arguments["AppleShowScrollBars"] == nil {
            arguments["AppleShowScrollBars"] = "WhenScrolling"
        }

        // Eased scrolling, on unless someone turned it off or asked macOS to
        // reduce motion. AppKit's own scroll views follow this key, and so
        // does WheelGlide, which eases a page's mouse wheel steps: WebKit
        // itself still jumps a wheel step in one frame with it on. A
        // trackpad already scrolls by the pixel and is not touched.
        if arguments["NSScrollAnimationEnabled"] == nil,
           defaults.persistentDomain(forName: UserDefaults.globalDomain)?["NSScrollAnimationEnabled"] == nil,
           defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["NSScrollAnimationEnabled"] == nil,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            arguments["NSScrollAnimationEnabled"] = true
        }

        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
