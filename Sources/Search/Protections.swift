import WebKit

// Two things a site can be given or spared.
//
// Fingerprinting protection is WebKit's own, the one Safari uses in private
// browsing: canvas, audio and screen readings made to vary, and known
// fingerprinting scripts held back. It is switched per page, through a
// setting WebKit has had since macOS 13.3 but hasn't made public; a WebKit
// without it is left alone. On in private windows, as in Safari; for
// everything else, Settings › Privacy. Reading the machine differently is
// also what bot checks look for, which is why it starts off there.
//
// Compatibility mode is for a site that breaks: blocking, uBO's scriptlets,
// pop-up judging, fingerprinting protection and extensions all stand aside
// for that site alone, until switched back (the site's card, under its name).

@MainActor
enum Protections {
    /// WebKit's baseline protections and, with them, its fingerprinting ones
    /// (_WKWebsiteNetworkConnectionIntegrityPolicyEnabled | EnhancedTelemetry).
    private static let fingerprinting: UInt = 1 | (1 << 6)
    private static let getter = NSSelectorFromString("_networkConnectionIntegrityPolicy")
    private static let setter = NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")

    /// Whether this Mac's WebKit can do it at all.
    static var available: Bool {
        WKWebpagePreferences.instancesRespond(to: getter) && WKWebpagePreferences.instancesRespond(to: setter)
    }

    /// Before each page: on or off for it, leaving WebKit's other bits as
    /// they were.
    static func guardFingerprints(_ on: Bool, in preferences: WKWebpagePreferences) {
        guard available else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> UInt
        typealias Set = @convention(c) (AnyObject, Selector, UInt) -> Void
        let now = unsafeBitCast(preferences.method(for: getter), to: Get.self)(preferences, getter)
        let wanted = on ? now | fingerprinting : now & ~fingerprinting
        guard wanted != now else { return }
        unsafeBitCast(preferences.method(for: setter), to: Set.self)(preferences, setter, wanted)
    }

    /// Whether a page on `host` is guarded, in a private window or not.
    static func guards(_ host: String?, privately: Bool) -> Bool {
        guard !compatible(host) else { return false }
        return privately || Store.settings.bool(forKey: "privacy.fingerprinting")
    }

    // MARK: - compatibility mode

    private(set) static var compatibleSites: Set<String> = {
        var sites = Set(Store.settings.stringArray(forKey: "compat.sites") ?? [])
        // Sites turned off with the per-site blocker switch Settings once
        // had carry over, once, into the one per-site switch there is now.
        if let paused = Store.settings.stringArray(forKey: "shield.paused") {
            sites.formUnion(paused.map(key))
            Store.settings.set(Array(sites).sorted(), forKey: "compat.sites")
            Store.settings.removeObject(forKey: "shield.paused")
        }
        return sites
    }()

    private static func key(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func compatible(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return compatibleSites.contains(key(host))
    }

    /// On or off for a site; its pages reload so the change is the whole
    /// page's, not the rest of it.
    static func setCompatible(_ host: String, _ on: Bool, in browser: Browser) {
        let site = key(host)
        if on { compatibleSites.insert(site) } else { compatibleSites.remove(site) }
        Store.settings.set(Array(compatibleSites).sorted(), forKey: "compat.sites")
        if #available(macOS 15.4, *) { Extensions.shared.spare(site, on) }
        for tab in browser.allTabs where tab.built != nil && tab.address?.host().map(key) == site {
            tab.reload()
        }
    }
}
