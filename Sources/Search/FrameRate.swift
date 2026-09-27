import WebKit

// Opt into the display's faster page-rendering cadence. WebKit still owns
// scheduling, power/thermal throttling and the website's rendering cost.
// The guarded feature flag is private SPI; unsupported engines keep their
// own policy. Turning the preference off restores the policy found before it.

enum FrameRate {
    /// Settings › General › Pages at 120 Hz.
    ///
    /// Told to every open page at once, but WebKit reads the flag as a page
    /// is made: an open tab is sure to follow only once it is reloaded
    /// (going up, it often does at the next switch to it). Reloading them
    /// all here would lose whatever is typed in them, so it is left.
    @MainActor static var fast = false {
        didSet { settle(was: oldValue && !saving) }
    }

    /// Saving power (see Power): pages keep to 60 whatever `fast` says.
    @MainActor static var saving = false {
        didSet { settle(was: fast && !oldValue) }
    }

    /// Whether pages are to draw past 60 right now.
    @MainActor private static var wanted: Bool { fast && !saving }

    @MainActor private static func settle(was: Bool) {
        guard wanted != was else { return }
        if wanted {
            for page in Web.pages.allObjects { apply(to: page.configuration.preferences) }
        } else {
            // Only the pages this changed are given WebKit's own rate
            // back; the rest were never touched.
            for case let preferences as WKPreferences in changed.keyEnumerator() {
                if let previous = changed.object(forKey: preferences) {
                    set(previous.boolValue, in: preferences)
                }
            }
            changed.removeAllObjects()
        }
    }

    /// The preferences this has taken past 60, so switching off can undo
    /// exactly those and nothing else.
    @MainActor private static let changed = NSMapTable<WKPreferences, NSNumber>.weakToStrongObjects()

    /// Before a page's view is made, which is when WebKit reads the flag:
    /// a new tab, one opened by a site, and one woken from sleep.
    @MainActor static func apply(to preferences: WKPreferences) {
        guard wanted, let previous = prefersNear60(preferences) else { return }
        if changed.object(forKey: preferences) == nil {
            changed.setObject(NSNumber(value: previous), forKey: preferences)
        }
        set(false, in: preferences)
    }

    /// Whether the page holds itself near 60, as its WebKit has it — nil
    /// where this WebKit has no such flag. For the bench.
    static func prefersNear60(_ preferences: WKPreferences) -> Bool? {
        let get = NSSelectorFromString("_isEnabledForFeature:")
        guard let flag = near60, preferences.responds(to: get) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(preferences.method(for: get), to: Getter.self)(preferences, get, flag)
    }

    // MARK: - WebKit's switch

    /// The switch is one of WebKit's feature flags, the list Safari shows
    /// under Develop › Feature Flags. It isn't in the public framework, so
    /// each step is asked first, and a WebKit without it is left alone.
    /// Looked up once: the list has a few hundred entries, and walking it
    /// for every tab would be for nothing.
    private static let near60: NSObject? = {
        let list = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: list),
              let all = type.perform(list)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return all.first { $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled" }
    }()

    private static func set(_ on: Bool, in preferences: WKPreferences) {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard let flag = near60, preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on, flag)
    }
}
