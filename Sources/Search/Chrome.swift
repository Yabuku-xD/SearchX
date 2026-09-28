import SwiftUI
import AppKit
import CoreImage

// Settings › Appearance: how tall the bars are, how see-through the chrome
// is and how blurred. The selection's colour is the new tab picture's
// (see Wallpaper.accent), grey without one.
//
// Chrome in its place beside the page — the column, the strip — shows what
// is behind the window, as a Mac sidebar does. Only chrome brought out over
// the page, the folded column or strip under the pointer, shows the page,
// blurred. Legibility is the material's job rather than each control's:
// the blurred page is tone-mapped into a band the chrome's text reads on
// (see BackgroundBlurView), so the controls stay as light as they are over
// the desktop, with no solid tile behind each one.

/// The ground under the tab you are on. Dark: a lighter, see-through lift
/// over the material, as a Mac sidebar's selection is, with the accent as a
/// soft wash inside and a hairline of it around; a darker solid chip read as
/// a hole in the column over a bright page. Light: a white card a little
/// above the material, with a soft shadow and the accent faint inside it.
/// Graphite is the same surface with no colour.
struct AccentGround: View {
    let tone: NSColor?
    var radius: CGFloat = 9
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        ZStack {
            shape.fill(dark ? Color.white.opacity(0.11) : Color(white: 0.995))
            if let tone {
                let tint = Color(nsColor: tone)
                // A little deeper at the foot: light falling from above.
                shape.fill(LinearGradient(
                    colors: [tint.opacity(dark ? 0.24 : 0.08), tint.opacity(dark ? 0.16 : 0.14)],
                    startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay(shape.strokeBorder(edge(dark), lineWidth: 0.5))
        // The top edge catching the light.
        .overlay(shape.inset(by: 0.5).strokeBorder(LinearGradient(
            colors: [.white.opacity(dark ? 0.10 : 0.8), .white.opacity(0)],
            startPoint: .top, endPoint: .center), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0 : 0.07), radius: 1.5, y: 1)
        .allowsHitTesting(false)
    }

    private func edge(_ dark: Bool) -> Color {
        guard let tone else { return dark ? .white.opacity(0.08) : .black.opacity(0.06) }
        return Color(nsColor: tone).opacity(dark ? 0.32 : 0.24)
    }
}

/// Perceptual colour for the accents (Björn Ottosson's OKLab, in its polar
/// form): changing lightness or chroma here changes only that, with no
/// drift in hue, so any page colour can be brought into one comfortable band.
enum OKLCH {
    /// A page colour as a tab tint: nil for a grey, otherwise the same hue
    /// at the lightness and strength the fixed accents have.
    static func tint(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let (l, a, b) = lab(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        let chroma = (a * a + b * b).squareRoot()
        guard chroma > 0.035 else { return nil }
        let hue = atan2(b, a)
        let lightness = min(0.70, max(0.56, l))
        let strength = min(0.15, max(0.09, chroma))
        let (r, g, bl) = srgb(lightness, strength * cos(hue), strength * sin(hue))
        return NSColor(srgbRed: r, green: g, blue: bl, alpha: 1)
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        let c = min(1, max(0, c))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let (r, g, b) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func srgb(_ L: Double, _ a: Double, _ b: Double) -> (CGFloat, CGFloat, CGFloat) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (CGFloat(gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
                CGFloat(gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
                CGFloat(gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)))
    }
}


/// The chrome's own ground, as see-through as Settings says: over the
/// desktop, frosted as a Mac sidebar is, when the chrome sits beside the
/// page; over the space's colour when it has one. Nothing where the chrome
/// out over the page brings its own (see ChromeBacking).
struct ChromeBackground: View {
    @ObservedObject var prefs: Preferences
    /// macOS Reduce Transparency, which wins over everything this sets.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeBacking) private var backing

    var body: some View {
        switch backing {
        case .provided:
            Color.clear.allowsHitTesting(false)
        case .desktop:
            ZStack {
                // The desktop is blurred by the window itself, as much as
                // Settings says (see WindowBlur): the same tint over the same
                // blur as the column brought out over the page. Only where
                // the Mac can't blur a window that way does the system's own
                // sidebar material stand in, at its own fixed strength.
                if !WindowBlur.available { Frost(material: .sidebar) }
                Palette.ground.opacity(1 - prefs.chromeTransparency)
            }
            .allowsHitTesting(false)
        case .own:
            Palette.ground.opacity(reduceTransparency ? 1 : 1 - prefs.chromeTransparency)
                .allowsHitTesting(false)
        }
    }
}

/// A see-through window blurring whatever is behind it — the desktop, beside
/// the page — by a radius of its own, as Ghostty and iTerm do for their blur
/// settings. The system's materials blur by a fixed amount; this is what lets
/// Blur strength soften the desktop behind the docked column exactly as it
/// softens the page under the column brought out over it. The call is
/// private to macOS, so it is looked up rather than linked: where it's
/// missing, `available` is false and the system material stands in.
@MainActor
enum WindowBlur {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32, Int32, Int32) -> Int32

    /// The first of `names` the process can see: SkyLight's name, then the
    /// older CoreGraphics one it still answers to.
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        let handle = dlopen(nil, RTLD_NOW)
        for name in names { if let found = dlsym(handle, name) { return found } }
        return nil
    }

    private static let connection: Connection? = symbol(["SLSMainConnectionID", "CGSMainConnectionID"])
        .map { unsafeBitCast($0, to: Connection.self) }
    private static let setter: Setter? = symbol(["SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius"])
        .map { unsafeBitCast($0, to: Setter.self) }

    static var available: Bool { connection != nil && setter != nil }

    /// What each window was last given, by window number (for the bench).
    private(set) static var applied: [Int: Int] = [:]

    /// Blurs what is behind `window` by `radius` points; 0 takes it away.
    /// False when the window has no number yet or the call isn't there.
    @discardableResult
    static func set(_ window: NSWindow, radius: Int) -> Bool {
        guard let connection, let setter, window.windowNumber > 0 else { return false }
        guard applied[window.windowNumber] != radius else { return true }
        guard setter(connection(), Int32(window.windowNumber), Int32(max(0, radius))) == 0 else { return false }
        applied[window.windowNumber] = radius
        return true
    }
}

/// What a piece of chrome is laid on: the window's own ground or colour,
/// the desktop behind a see-through window, or — out over the page — a
/// ground its container provides.
enum ChromeBacking {
    case own, desktop, provided
}

private struct ChromeBackingKey: EnvironmentKey {
    static let defaultValue = ChromeBacking.own
}

extension EnvironmentValues {
    var chromeBacking: ChromeBacking {
        get { self[ChromeBackingKey.self] }
        set { self[ChromeBackingKey.self] = newValue }
    }
}

/// The tint under the column or the strip while it is out over the page,
/// as see-through as Settings says; opaque with Reduce Transparency on. The
/// page under it is blurred by the stage, beside the page itself (see
/// PageOverlay), where a background filter can reach the page.
struct FloatingChromeGround: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Palette.ground.opacity(reduceTransparency ? 1 : 1 - prefs.chromeTransparency)
            .allowsHitTesting(false)
    }
}

/// Lives beside the WebKit view so its background filter contains the rendered
/// page rather than whatever the window behind it happens to be.
final class BackgroundBlurView: NSView {
    private var radius: Double = -1
    private var dark: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("page-chrome-backdrop")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRadius(_ value: Double) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard radius != value || self.dark != dark else { return }
        radius = value
        self.dark = dark
        guard value > 0 else { backgroundFilters = []; return }
        #if DEBUG
        NativeProbe.backdropBuilds += 1
        #endif
        // Keep the backdrop opaque after the Gaussian samples beyond the page
        // edges. CIColorMatrix operates on unpremultiplied colors, so restoring
        // alpha preserves those colors and leaves transparency to its own layer.
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: value]),
              let opaque = CIFilter(name: "CIColorMatrix"),
              let vivid = CIFilter(name: "CIColorControls"),
              let band = CIFilter(name: "CIToneCurve")
        else { backgroundFilters = []; return }
        opaque.setDefaults()
        opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        // Vibrancy: a blur alone greys a page out; a little more colour
        // keeps it reading as the page, as the system's materials do.
        vivid.setDefaults()
        vivid.setValue(1.5, forKey: kCIInputSaturationKey)
        // The band the chrome's text reads on, whatever the page is. Dark:
        // a white page comes down to a mid-dark grey while dark pages stay
        // as they are; light: the reverse. A curve rather than a flat tint,
        // so a page that already contrasts keeps its colour and depth.
        band.setDefaults()
        let points: [CGPoint] = dark
            ? [.init(x: 0, y: 0), .init(x: 0.25, y: 0.21), .init(x: 0.5, y: 0.29), .init(x: 0.75, y: 0.33), .init(x: 1, y: 0.35)]
            : [.init(x: 0, y: 0.66), .init(x: 0.25, y: 0.74), .init(x: 0.5, y: 0.82), .init(x: 0.75, y: 0.9), .init(x: 1, y: 0.97)]
        for (index, point) in points.enumerated() {
            band.setValue(CIVector(x: point.x, y: point.y), forKey: "inputPoint\(index)")
        }
        backgroundFilters = [blur, opaque, vivid, band]
    }

    /// The band follows the appearance: switched while the column is out,
    /// the filters are made again for the other one.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setRadius(radius)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
