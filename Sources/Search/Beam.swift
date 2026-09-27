import SwiftUI
import AppKit
import QuartzCore

// The light travelling round the address field on an empty tab, in native
// Core Animation: no web view, no script, no package. The look matches the
// "border beam" effect of the React library of that name, measured from its
// published source, rebuilt here layer by layer:
//
//   • a 1-point ring of soft coloured blobs placed round the edge, seen
//     where a long light is, with a bright highlight at its front;
//   • a faint wash of the same colours inside the edge, with a soft inner
//     light, where the same light is, fading out 28 points in;
//   • a bloom: the highlight again, wide and soft;
//   • white, or the picture's own strongest colours round the edge.
//
// The web version turns a gradient round the element's centre. On a field
// eleven times wider than tall that raced round the ends and crawled along
// the long sides, stretching as it went. Here each light is a trail of soft
// dots running the field's outline at one speed, a lap every 4.2 s: the
// outline is closed, so a lap ends where the next begins, and every light
// keeps its place from the wall clock, so leaving the tab and coming back,
// or resizing, never restarts it. The render server moves the dots; nothing
// is drawn again while it runs. With Reduce Motion it holds still.
//
// The strengths (stroke, inner, bloom), brightness 1.3, saturation 1.2 dark
// and 1.5 light, and the blobs' places and sizes are the library's.

/// What the light is made of: white, or the colour of the picture behind
/// the field (see Wallpaper.tone) — never the chrome's accent.
enum BeamPalette: Equatable {
    case white
    case tone(PixelArt.Tone)

    struct Blob {
        let color: NSColor
        /// Centre, as a fraction of the field from its top left.
        let x: CGFloat, y: CGFloat
        /// Horizontal and vertical radius, in points.
        let rx: CGFloat, ry: CGFloat
    }

    /// Where the library places its nine blobs round the edge, and how big.
    private static let places: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.33, -0.074, 70, 40),
        (0.12, -0.05, 60, 35),
        (0.021, 0.683, 40, 70),
        (0.021, 0.683, 20, 35),
        (0.744, 1, 180, 32),
        (0.55, 1, 85, 26),
        (0.939, 0, 74, 32),
        (1, 0.271, 26, 42),
        (1, 0.271, 52, 48),
    ]
    /// White's blobs, a little uneven so the edge still has some depth.
    private static let greys: [CGFloat] = [250, 210, 230, 200, 240, 220, 255, 215, 235]
    var blobs: [Blob] {
        Self.places.enumerated().map { index, place in
            let color: NSColor
            switch self {
            case .white:
                let v = Self.greys[index] / 255
                color = NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
            case .tone(let tone):
                // The picture's own hues in turn round the edge, each at the
                // lightness a light needs to read at all.
                let own = tone.hues[index % tone.hues.count]
                let hue = own.angle
                // Dark pictures are muted; the light is lit. Their hue, at
                // the strength a light of that colour needs to read at all.
                let chroma = min(0.18, max(0.1, own.chroma * 2))
                let (r, g, b) = OKLCH.srgb(0.7, chroma * cos(hue), chroma * sin(hue))
                color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            return Blob(color: color, x: place.0, y: place.1, rx: place.2, ry: place.3)
        }
    }
}

struct Beam: NSViewRepresentable {
    let palette: BeamPalette
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Still while saving power (see Power).
    @ObservedObject private var power = Power.shared

    func makeNSView(context: Context) -> BeamView { BeamView() }

    func updateNSView(_ view: BeamView, context: Context) {
        view.configure(palette: palette, dark: scheme == .dark, radius: radius, moving: !reduceMotion && !power.saving)
    }
}

final class BeamView: NSView {
    private struct Look: Equatable {
        var palette: BeamPalette
        var dark: Bool
        var radius: CGFloat
        var moving: Bool
        var size: CGSize
    }

    private var look: Look?
    private var wanted: (palette: BeamPalette, dark: Bool, radius: CGFloat, moving: Bool) = (.white, true, 14, true)
    /// Shown once already: made again for a new size or colour, it carries
    /// on rather than fading in a second time.
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(palette: BeamPalette, dark: Bool, radius: CGFloat, moving: Bool) {
        wanted = (palette, dark, radius, moving)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Back on screen after a tab or two elsewhere: the lights are where
        // the clock says they are, so nothing restarts and nothing fades in.
        if window != nil { rebuild() }
    }

    // MARK: - the numbers

    private struct Strength {
        let stroke: Swift.Float, inner: Swift.Float, bloom: Swift.Float
        let innerShadow: NSColor
        let saturation: CGFloat
    }

    private static func strength(dark: Bool) -> Strength {
        dark
            ? Strength(stroke: 0.26, inner: 0.42, bloom: 0.24, innerShadow: NSColor(white: 1, alpha: 0.27), saturation: 1.2)
            : Strength(stroke: 0.12, inner: 0.26, bloom: 0.34, innerShadow: NSColor(white: 0, alpha: 0.14), saturation: 1.5)
    }

    /// One lap of the field. Constant, whatever the field's width, so the
    /// light's place on the clock never jumps when the window is resized.
    private static let lap: CFTimeInterval = 4.2
    private static let brightness: CGFloat = 1.3

    private func rebuild() {
        guard let root = layer, bounds.width > 0, bounds.height > 0, window != nil else { return }
        let now = Look(palette: wanted.palette, dark: wanted.dark, radius: wanted.radius, moving: wanted.moving, size: bounds.size)
        guard now != look else { return }
        look = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.cornerRadius = now.radius
        root.cornerCurve = .continuous
        let strength = Self.strength(dark: now.dark)
        let track = Self.track(bounds.insetBy(dx: 0.5, dy: 0.5), radius: max(0, now.radius - 0.5))
        let perimeter = Self.length(of: bounds, radius: now.radius)

        // Colour: the ring and the wash inside.
        let colour = CALayer()
        colour.frame = bounds
        root.addSublayer(colour)
        colour.addSublayer(stroke(now, strength, track, perimeter))
        colour.addSublayer(inner(now, strength, track, perimeter))
        // The bloom: the highlight again, wide and soft, over everything.
        let bloom = comet(track, perimeter, length: 0.16, radius: 9, spacing: 3,
                          color: now.dark ? .white : .black, strength: 0.85, moving: now.moving)
        bloom.opacity = strength.bloom
        root.addSublayer(bloom)
        CATransaction.commit()

        if !shown, now.moving {
            shown = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.6
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.add(fade, forKey: "arrive")
        }
    }

    // MARK: - travelling light

    /// The field's outline, clockwise from the middle of the top edge: the
    /// track every light runs on, closed, so a lap ends where it began.
    private static func track(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.midX, y: rect.maxY), radius: r)
        path.closeSubpath()
        return path
    }

    private static func length(of rect: CGRect, radius: CGFloat) -> CGFloat {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return 2 * (rect.width + rect.height) - 8 * r + 2 * .pi * r
    }

    /// The start of a lap long ago, on the wall clock: every light, each dot
    /// of every trail, and every rebuild agree on where the lap is, and no
    /// dot is ever waiting to start.
    private static func clock(_ layer: CALayer, period: CFTimeInterval) -> CFTimeInterval {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        return now - now.truncatingRemainder(dividingBy: period) - 50 * period
    }

    /// A soft round dot, white, to be tinted: the grain every light is made of.
    private static let dot: CGImage? = {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let colors = stops.map { NSColor(white: 1, alpha: exp(-4.5 * $0 * $0)).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops.map { CGFloat($0) }) else { return nil }
        let centre = CGPoint(x: side / 2, y: side / 2)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: CGFloat(side) / 2, options: [])
        return context.makeImage()
    }()

    /// A light running the track: a trail of soft dots, a short fade up at
    /// its head and a long fade out behind, one lap per `lap`. The dots are
    /// copies of one by a replicator, each a little behind the last, so the
    /// render server moves them and nothing is drawn again. `length` is a
    /// share of the lap; `strength` how opaque the brightest part is.
    private func comet(_ track: CGPath, _ perimeter: CGFloat, length: CGFloat, radius: CGFloat, spacing: CGFloat,
                       color: NSColor, strength: CGFloat, moving: Bool) -> CALayer {
        let holder = CALayer()
        holder.frame = bounds
        let span = length * perimeter
        let count = max(2, Int((span / spacing).rounded()))
        let step = Self.lap * Double(spacing / perimeter)
        // How many dots overlap at a point, so the whole reaches `strength`.
        let overlap = max(1, 2 * radius / spacing * 0.6)
        let each = 1 - pow(1 - min(strength, 0.999), 1 / overlap)
        let head = max(1, count / 7)
        let parts: [(count: Int, delay: Int, from: CGFloat, to: CGFloat)] = [
            (head, 0, 0, each),
            (count - head, head, each, 0),
        ]
        for part in parts where part.count > 0 {
            let copies = CAReplicatorLayer()
            copies.frame = bounds
            copies.instanceCount = part.count
            copies.instanceDelay = step
            copies.instanceColor = color.withAlphaComponent(part.from).cgColor
            copies.instanceAlphaOffset = Swift.Float((part.to - part.from) / CGFloat(max(1, part.count - 1)))
            let sprite = CALayer()
            sprite.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            sprite.contents = Self.dot
            sprite.position = track.currentPoint
            copies.addSublayer(sprite)
            if moving {
                let run = CAKeyframeAnimation(keyPath: "position")
                run.path = track
                run.calculationMode = .paced
                run.duration = Self.lap
                run.repeatCount = .infinity
                // The head of the light leads by `delay` dots.
                run.beginTime = Self.clock(sprite, period: Self.lap) + Double(part.delay) * step
                sprite.add(run, forKey: "run")
            }
            holder.addSublayer(copies)
        }
        return holder
    }

    // MARK: - the parts

    /// The blobs, each a radial gradient from its colour to nothing, at the
    /// package's place and size; brightened and saturated as its filter does.
    private func blobs(_ look: Look, alpha: CGFloat, scale: CGFloat, saturation: CGFloat) -> CALayer {
        let holder = CALayer()
        holder.frame = bounds
        for blob in look.palette.blobs {
            let rx = blob.rx * scale, ry = blob.ry * scale
            let spot = CAGradientLayer()
            spot.type = .radial
            // Top-left fractions, into a layer whose origin is bottom left.
            spot.frame = CGRect(x: blob.x * bounds.width - rx, y: (1 - blob.y) * bounds.height - ry, width: rx * 2, height: ry * 2)
            spot.startPoint = CGPoint(x: 0.5, y: 0.5)
            spot.endPoint = CGPoint(x: 1, y: 1)
            // White on a light field would be nothing: there it is a soft grey.
            let base = look.palette == .white && !look.dark ? blob.color.blended(withFraction: 0.62, of: .black) ?? blob.color : blob.color
            let lit = Self.lift(base, brightness: look.palette == .white && !look.dark ? 1 : Self.brightness,
                                saturation: saturation).withAlphaComponent(alpha)
            spot.colors = [lit.cgColor, lit.withAlphaComponent(0).cgColor]
            holder.addSublayer(spot)
        }
        return holder
    }

    /// CSS brightness() and saturate(), applied to one colour.
    private static func lift(_ color: NSColor, brightness: CGFloat, saturation: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = luma + (r - luma) * saturation; g = luma + (g - luma) * saturation; b = luma + (b - luma) * saturation
        return NSColor(srgbRed: min(1, max(0, r * brightness)), green: min(1, max(0, g * brightness)),
                       blue: min(1, max(0, b * brightness)), alpha: 1)
    }

    /// The 1-point ring the stroke is drawn in.
    private func ring(_ look: Look, width: CGFloat = 1) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = bounds
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: bounds, cornerWidth: look.radius, cornerHeight: look.radius, transform: nil))
        let r = max(0, look.radius - width)
        path.addPath(CGPath(roundedRect: bounds.insetBy(dx: width, dy: width), cornerWidth: r, cornerHeight: r, transform: nil))
        shape.path = path
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.white.cgColor
        return shape
    }

    /// The coloured ring: the blobs, seen where the long light is, and the
    /// highlight running at its front.
    private func stroke(_ look: Look, _ strength: Strength, _ track: CGPath, _ perimeter: CGFloat) -> CALayer {
        let inRing = CALayer()
        inRing.frame = bounds
        inRing.mask = ring(look)
        inRing.opacity = strength.stroke
        let seen = CALayer()
        seen.frame = bounds
        seen.mask = comet(track, perimeter, length: 0.6, radius: 7, spacing: 3, color: .white, strength: 1, moving: look.moving)
        seen.addSublayer(blobs(look, alpha: 1, scale: 1, saturation: strength.saturation))
        inRing.addSublayer(seen)
        inRing.addSublayer(comet(track, perimeter, length: 0.2, radius: 3, spacing: 1.5,
                                 color: look.dark ? .white : .black, strength: 0.75, moving: look.moving))
        return inRing
    }

    /// The faint wash inside the edge, where the long light is, fading out
    /// 28 points in, with a soft light cast in from the edge.
    private func inner(_ look: Look, _ strength: Strength, _ track: CGPath, _ perimeter: CGFloat) -> CALayer {
        let edges = CALayer()
        edges.frame = bounds
        for vertical in [true, false] {
            let fade = CAGradientLayer()
            fade.frame = bounds
            let extent = vertical ? bounds.height : bounds.width
            let reach = NSNumber(value: Double(min(0.5, 28 / max(extent, 1))))
            let far = NSNumber(value: 1 - reach.doubleValue)
            fade.colors = [NSColor.white, .clear, .clear, .white].map(\.cgColor)
            fade.locations = [0, reach, far, 1]
            fade.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            fade.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
            edges.addSublayer(fade)
        }
        let near = CALayer()
        near.frame = bounds
        near.mask = edges
        near.opacity = strength.inner
        let seen = CALayer()
        seen.frame = bounds
        seen.mask = comet(track, perimeter, length: 0.6, radius: 30, spacing: 6, color: .white, strength: 1, moving: look.moving)
        let white = look.palette == .white
        seen.addSublayer(blobs(look, alpha: white ? 0.225 : 0.45, scale: 0.9, saturation: strength.saturation))
        // box-shadow: inset 0 0 9px 1px — a shadow cast inward by the
        // outside of the field.
        let glow = CAShapeLayer()
        glow.frame = bounds
        let around = CGMutablePath()
        around.addRect(bounds.insetBy(dx: -40, dy: -40))
        around.addPath(CGPath(roundedRect: bounds.insetBy(dx: -1, dy: -1), cornerWidth: look.radius + 1,
                              cornerHeight: look.radius + 1, transform: nil))
        glow.path = around
        glow.fillRule = .evenOdd
        glow.fillColor = strength.innerShadow.withAlphaComponent(1).cgColor
        glow.shadowColor = strength.innerShadow.withAlphaComponent(1).cgColor
        glow.shadowOpacity = Swift.Float(strength.innerShadow.alphaComponent)
        glow.shadowRadius = 4.5
        glow.shadowOffset = .zero
        let clip = CAShapeLayer()
        clip.frame = bounds
        clip.path = CGPath(roundedRect: bounds, cornerWidth: look.radius, cornerHeight: look.radius, transform: nil)
        glow.mask = clip
        seen.addSublayer(glow)
        near.addSublayer(seen)
        return near
    }
}

/// The beam on the address field, as Settings › Appearance has it: white,
/// or in the colour of the picture behind the field when there is one.
struct FieldBeam: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var wallpaper = Wallpaper.shared

    private var palette: BeamPalette {
        guard wallpaper.enabled, wallpaper.image != nil, let tone = wallpaper.tone else { return .white }
        return .tone(tone)
    }

    var body: some View {
        if prefs.fieldBeam {
            Beam(palette: palette, radius: 14)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
