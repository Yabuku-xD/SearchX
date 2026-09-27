import SwiftUI
import WebKit
import CoreGraphics
import ImageIO

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?

    private var busy: Set<String> = []
    private var missing: Set<String> = []
    /// Keys with no file on disk, as far as `known` has looked.
    private var absent: Set<String> = []

    // 8 MiB of decoded pixels holds 512 64px icons, over twice the synthetic
    // 200-host benchmark working set. A provisional budget, not a total RAM cap:
    // active tabs retain their own images and NSCache may evict under pressure.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// What an icon costs to hold: the pixels in its bitmap. Counted from the
    /// bitmap itself rather than from its side, because a bitmap can carry row
    /// padding that a square of the same dimensions does not.
    private static func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep,
           rep.pixelsHigh > 0 {
            return rep.bytesPerRow * rep.pixelsHigh
        }
        return 64 * 64 * 4
    }

    /// A newly fetched icon invalidates a previous miss, including after eviction.
    private func remember(_ image: NSImage, for key: String) {
        absent.remove(key)
        Self.cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    /// Whether the chrome is dark right now. A site that declares an icon
    /// for `prefers-color-scheme: dark` is asked for that one, and it is
    /// kept apart from the light one, so switching looks switches icons.
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The name an icon is kept under: the host, with a suffix for the dark
    /// variant a site offered. Sites without one keep one file for both.
    private static func key(_ host: String, dark: Bool) -> String { dark ? host + "@dark" : host }

    /// What is already known, and nothing fetched. In the dark, the dark
    /// variant when there is one, the ordinary icon otherwise.
    func cached(_ host: String) -> NSImage? {
        let normalized = host.lowercased()
        if let hit = match(normalized) { return hit }
        if normalized.hasPrefix("www.") {
            let bare = String(normalized.dropFirst(4))
            if let hit = match(bare) { return hit }
        } else {
            let www = "www." + normalized
            if let hit = match(www) { return hit }
        }
        return nil
    }

    private func match(_ key: String) -> NSImage? {
        if Favicons.dark, let hit = known(Favicons.key(key, dark: true)) { return hit }
        return known(key)
    }

    private func known(_ key: String) -> NSImage? {
        if let hit = Self.cache.object(forKey: key as NSString) { return hit }
        // A host with no icon on disk is looked for there once, not on every
        // line of every list that shows it: the History panel asked for two
        // thousand of them each time it drew. One that arrives later goes
        // into the cache, which is asked first.
        if absent.contains(key) { return nil }
        guard let image = Favicons.square(from: Favicons.file(key)) else {
            absent.insert(key)
            return nil
        }
        remember(image, for: key)
        return image
    }

    private static func fresh(_ key: String) -> Bool {
        guard let stamp = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missing = []
        for tab in tabs {
            guard let host = tab.address?.host()?.lowercased() else { continue }
            tab.icon = cached(host)
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil, let image = await Favicons.square(data) else { return }
        remember(image, for: host)
        keep(image, for: host)
        arrived?(host, image)
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk.
    func fetch(for tab: Tab) {
        guard let url = tab.address, let host = url.host()?.lowercased(),
              url.scheme?.hasPrefix("http") == true
        else { return }

        let dark = Favicons.dark
        // Fresh and right for this look: nothing to do. In the dark, a fresh
        // light icon is not enough on its own — the site may offer a dark
        // one that has never been asked for — so the page is asked.
        if Favicons.fresh(Favicons.key(host, dark: dark)), let known = known(Favicons.key(host, dark: dark)) {
            if tab.address?.host()?.lowercased() == host { tab.icon = known }
            return
        }
        guard !busy.contains(host), !missing.contains(host) else { return }
        busy.insert(host)

        tab.web.evaluateJavaScript(Favicons.probe) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let offersDark = declared.contains { Favicons.media($0["media"]) == .dark }
                let wantDark = dark && offersDark
                let key = Favicons.key(host, dark: wantDark)
                // No dark variant here after all, and the ordinary one is
                // fresh: it is the one to wear.
                if !wantDark, Favicons.fresh(key), let known = self.known(key) {
                    if tab?.address?.host()?.lowercased() == host {
                        tab?.icon = known
                    }
                    self.busy.remove(host)
                    return
                }
                let candidates = Favicons.rank(declared, page: url, dark: wantDark)
                let shy = tab?.shy ?? false
                Task { await self.download(candidates, host: host, key: key, shy: shy) }
            }
        }
    }

    private enum Scheme { case any, light, dark }

    /// What a `media` attribute says about the scheme, if anything.
    private static func media(_ value: String?) -> Scheme {
        let text = (value ?? "").lowercased()
        if text.contains("prefers-color-scheme") {
            if text.contains("dark") { return .dark }
            if text.contains("light") { return .light }
        }
        return .any
    }

    private func download(_ candidates: [URL], host: String, key: String, shy: Bool) async {
        defer { busy.remove(host) }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            return config
        }())
        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.setValue(Web.userAgentName, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            guard let image = await Favicons.square(data) else { continue }
            remember(image, for: key)
            if !shy { keep(image, for: key) }
            arrived?(host, image)
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(host)
    }

    nonisolated private static let side = 64

    private static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary)
            return drawn(thumbnail(source) ?? NSImage(data: data))
        }.value
    }

    private static func square(from url: URL) -> NSImage? {
        let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary)
        return drawn(thumbnail(source) ?? NSImage(contentsOf: url))
    }

    nonisolated private static func thumbnail(_ source: CGImageSource?) -> NSImage? {
        guard let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Preserve vector/ICO fallbacks and aspect ratio in a display-independent bitmap.
    nonisolated private static func drawn(_ image: NSImage?) -> NSImage? {
        guard let image, image.isValid, image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let extent = CGFloat(side)
        rep.size = NSSize(width: extent, height: extent)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: extent, height: extent))
        let scale = min(extent / image.size.width, extent / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (extent-size.width)/2, y: (extent-size.height)/2,
                             width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    #if DEBUG
    func evictForProbe() { Self.cache.removeAllObjects() }
    #endif

    private func keep(_ image: NSImage, for key: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let file = Favicons.file(key)
        let dir = Self.folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
            Task { @MainActor [weak self] in self?.absent.remove(key) }
        }
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"],
                  let url = URL(string: href, relativeTo: page)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // An icon meant for the other scheme is the last resort; one
            // meant for this scheme comes first whatever its size.
            let scheme = media(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { score = 35 }
            if scheme != .any { score += 40 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let host = page.host(), let root = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            list.append(root)
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase()
        });
      }
      return out;
    })();
    """
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}
