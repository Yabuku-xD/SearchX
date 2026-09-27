import AppKit
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()

    /// The picture as it is, or made into pixel art with a dark fall to the
    /// address field (see PixelArt). The copy kept is always the picture as
    /// chosen; the look is made from it each time.
    enum Style: String {
        case pixel, photo
    }

    @Published var enabled: Bool {
        didSet {
            settings.set(enabled, forKey: "wallpaper")
            if !enabled { image = nil; art = nil; loaded = false }
        }
    }
    @Published var fit: Bool {
        didSet {
            settings.set(fit, forKey: "wallpaper.fit")
            if fit != oldValue { Task { await makeArt() } }
        }
    }
    @Published var style: Style {
        didSet {
            guard style != oldValue else { return }
            settings.set(style.rawValue, forKey: "wallpaper.style")
            // Read again at the size the new look needs, now: nothing else
            // asks while a new tab is already showing, and it went blank.
            generation += 1
            loaded = false
            art = nil
            Task { await load() }
        }
    }
    @Published private(set) var image: CGImage?
    /// The picture's own colour, for the address field's light (see Beam):
    /// nil for a grey picture, and for none.
    @Published private(set) var tone: PixelArt.Tone?
    /// The picture as pixel art, one pixel a cell, made once for the largest
    /// screen (see PixelArt): shown at its own size, it never needs making
    /// again for a window's size.
    @Published private(set) var art: CGImage?
    @Published private(set) var hasImage: Bool
    @Published private(set) var busy = false

    private let file: URL
    private let settings: UserDefaults
    private var loaded = false
    /// Goes up whenever what should be showing changes (a style, a new
    /// picture, none): a read that finishes after that is somebody else's,
    /// and is dropped rather than put up — or, as it was, left holding the
    /// way so the read that was wanted never ran.
    private var generation = 0

    init(file: URL = Store.file("wallpaper.png"), settings: UserDefaults = Store.settings) {
        self.file = file
        self.settings = settings
        enabled = settings.bool(forKey: "wallpaper")
        fit = settings.bool(forKey: "wallpaper.fit")
        style = settings.string(forKey: "wallpaper.style").flatMap(Style.init) ?? .pixel
        hasImage = FileManager.default.fileExists(atPath: file.path)
        if !hasImage { enabled = false; settings.set(false, forKey: "wallpaper") }
        // The whole browser takes its colour from the picture (see accent),
        // so it is read at launch rather than when a new tab first shows it.
        if enabled { Task { await load() } }
        // A screen plugged in, or a new resolution: the art is made again for
        // the largest one, so the window never outgrows it.
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { _ in
            // Spelled out: as the closure's only expression, older compilers
            // could not tell which of Task's initialisers was meant.
            MainActor.assumeIsolated {
                _ = Task { @MainActor in await Wallpaper.shared.makeArt() }
            }
        }
    }

    private var screens: NSObjectProtocol?

    /// The colour the browser wears — the selected tab, the sliders — from
    /// the picture's strongest hue at a lightness a control reads well at;
    /// nil, so plain grey, with no picture or a colourless one.
    var accent: NSColor? {
        guard enabled, image != nil, let hue = tone?.hues.first else { return nil }
        let chroma = min(0.14, max(0.08, hue.chroma * 2))
        let (r, g, b) = OKLCH.srgb(0.64, chroma * cos(hue.angle), chroma * sin(hue.angle))
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var accentColor: Color { accent.map { Color(nsColor: $0) } ?? Palette.ink }

    /// The pixel art for the picture on show: the largest screen's size in
    /// cells, made off the main thread.
    func makeArt() async {
        guard style == .pixel, let image else { art = nil; return }
        let largest = NSScreen.screens.reduce(CGSize(width: 1512, height: 982)) {
            CGSize(width: max($0.width, $1.frame.width), height: max($0.height, $1.frame.height))
        }
        let columns = Int((largest.width / PixelArt.cell).rounded(.up)), rows = Int((largest.height / PixelArt.cell).rounded(.up))
        let fit = self.fit, ticket = generation
        let made = await Task.detached(priority: .userInitiated) {
            PixelArt.grid(image, columns: columns, rows: rows, fit: fit)
        }.value
        guard ticket == generation, self.image === image, self.fit == fit else { return }
        art = made
    }

    /// Pixel art needs no more of the picture than a cell per two points of
    /// the widest screen; kept that small, it costs a few megabytes rather
    /// than the twenty-six of the whole picture.
    private var sourceSize: Int { style == .pixel ? 1280 : 2560 }

    func load() async {
        guard enabled, hasImage, !loaded else { return }
        loaded = true
        let ticket = generation
        let file = file
        let size = sourceSize
        let result = await Task.detached(priority: .utility) {
            (try? Self.read(file, size: size)).map { ($0, PixelArt.tone(of: $0)) }
        }.value
        guard ticket == generation else { return }
        guard let result else { enabled = false; return }
        if enabled {
            image = result.0
            tone = result.1
            await makeArt()
        }
    }

    func use(_ source: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let ticket = generation
        let file = file
        let size = sourceSize
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let image = try Self.read(source, size: 2560)
                let data = NSMutableData()
                guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
                else { throw Failure.invalid }
                CGImageDestinationAddImage(output, image, nil)
                guard CGImageDestinationFinalize(output) else { throw Failure.invalid }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Commit only a decoded copy; a failed replacement leaves the old image intact.
                try (data as Data).write(to: file, options: .atomic)
                let shown = size < 2560 ? try Self.read(file, size: size) : image
                return (shown, PixelArt.tone(of: shown))
            }.value
            guard ticket == generation else { return }
            image = result.0
            tone = result.1
            await makeArt()
            hasImage = true
            loaded = true
            enabled = true
        } catch {
            enabled = false
        }
    }

    func remove() async {
        guard !busy else { return }
        busy = true
        generation += 1
        enabled = false
        defer { busy = false }
        let file = file
        do {
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }.value
            hasImage = false
            fit = false
            tone = nil
            art = nil
        } catch { return }
    }

    nonisolated private static func read(_ url: URL, size: Int) throws -> CGImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true else { throw Failure.invalid }
        guard let bytes = size.fileSize, bytes <= 50 * 1024 * 1024 else { throw Failure.invalid }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg, .png, .heic, .heif].contains(where: { $0.identifier == type }),
              CGImageSourceGetCount(source) == 1
        else { throw Failure.invalid }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 100_000_000
        else { throw Failure.invalid }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.invalid }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let image = context.makeImage() else { throw Failure.invalid }
        return image
    }

    private enum Failure: Error {
        case invalid
    }
}
