// The app's icon, drawn rather than exported: the mark is Drice's
// Subtract.svg, read from its own path data rather than loaded as an image,
// so it stays a crisp vector at every size instead of a raster scaled up.
// Each representation is drawn directly at its pixel size, avoiding a
// display-dependent lockFocus bitmap and a second raster resampling pass.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Drice's Subtract.svg (22 September 2026): a pill with an S cut out of it,
/// and SearchX's small-caps x beside the S, cut out the same way,
/// on its own 608 × 276 canvas. The same path is in Design.swift's
/// `Logomark` and in the website's mark — one shape, three places.
/// Fit the path's actual bounds so the artwork is centred within the plate.
let canvas = (width: 607.104, height: 275.321)
let markData = "M469.443 0C545.471 0.00013198 607.103 61.6325 607.104 137.66C607.104 213.688 545.471 275.321 469.443 275.321H137.66C61.6323 275.321 0 213.688 0 137.66C0.00016085 61.6325 61.6325 0.000140192 137.66 0H469.443ZM138.104 51.5977C127.234 51.5977 117.512 53.5115 108.938 57.3389C100.518 61.0132 93.8581 66.2188 88.959 72.9551C84.2132 79.5381 81.8398 87.3464 81.8398 96.3789C81.8399 105.258 83.6773 112.607 87.3516 118.425C91.0258 124.089 95.9251 128.682 102.049 132.203C108.173 135.571 114.833 138.327 122.028 140.471L151.652 149.197C158.389 151.188 163.9 154.249 168.187 158.383C172.473 162.516 174.617 168.028 174.617 174.917C174.617 182.572 171.402 188.849 164.972 193.748C158.695 198.494 150.122 200.867 139.252 200.867C132.21 200.867 125.702 199.413 119.731 196.504C113.914 193.442 109.091 189.308 105.264 184.103C101.436 178.744 99.2169 172.697 98.6045 165.961H97.6855L75.4102 171.013C76.3287 180.658 79.697 189.308 85.5146 196.963C91.3322 204.618 98.9103 210.665 108.249 215.104C117.741 219.544 128.076 221.765 139.252 221.765C151.193 221.765 161.68 219.774 170.713 215.794C179.746 211.813 186.711 206.225 191.61 199.029C196.662 191.834 199.188 183.414 199.188 173.769C199.188 164.124 197.352 156.239 193.678 150.115C190.003 143.838 185.104 138.863 178.98 135.188C172.857 131.514 166.044 128.605 158.542 126.462L128.229 117.735C121.799 115.898 116.516 113.219 112.383 109.698C108.402 106.177 106.412 101.354 106.412 95.2305C106.412 88.188 109.168 82.6758 114.68 78.6953C120.344 74.5619 128.152 72.4951 138.104 72.4951C147.901 72.4952 155.939 74.9448 162.216 79.8438C168.493 84.7428 172.397 91.1729 173.928 99.1338H174.847L196.663 93.8525C195.745 85.5853 192.605 78.3131 187.247 72.0361C181.889 65.6061 174.923 60.6306 166.35 57.1094C157.929 53.4351 148.514 51.5977 138.104 51.5977ZM220.000 101.800L247.000 101.800L272.000 140.761L297.000 101.800L324.000 101.800L285.500 161.800L324.000 221.800L297.000 221.800L272.000 182.839L247.000 221.800L220.000 221.800L258.500 161.800Z"

/// A tiny reader for the one path the mark is: absolute M, L, H, V, C, Z —
/// what Figma writes for a flattened shape, and nothing else.
func svgCommands(_ d: String) -> [(Character, [CGFloat])] {
    var out: [(Character, [CGFloat])] = []
    var current: Character?
    var numbers: [CGFloat] = []
    var token = ""
    func flushNumber() {
        if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
        token = ""
    }
    for ch in d {
        if "MLHVCZmlhvcz".contains(ch) {
            flushNumber()
            if let current { out.append((current, numbers)) }
            current = ch
            numbers = []
        } else if ch == " " || ch == "," {
            flushNumber()
        } else if ch == "-" && !token.isEmpty && !token.hasSuffix("e") {
            flushNumber()
            token = "-"
        } else {
            token.append(ch)
        }
    }
    flushNumber()
    if let current { out.append((current, numbers)) }
    return out
}

/// The mark, fitted to `mark`'s own width and centred in it. SVG's y grows
/// downward and AppKit's upward, so every y is flipped on the way in; the S is
/// a hole, so the path is filled even-odd.
func markPath(in mark: NSRect) -> NSBezierPath {
    let scale = mark.width / canvas.width
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: mark.origin.x + x * scale, y: mark.origin.y + (canvas.height - y) * scale)
    }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    var last = NSPoint.zero
    var start = NSPoint.zero
    for (c, n) in svgCommands(markData) {
        switch c {
        case "M": last = NSPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
        case "L": last = NSPoint(x: n[0], y: n[1]); path.line(to: pt(n[0], n[1]))
        case "H": last.x = n[0]; path.line(to: pt(last.x, last.y))
        case "V": last.y = n[0]; path.line(to: pt(last.x, last.y))
        case "C":
            var k = 0
            while k + 5 < n.count {
                path.curve(to: pt(n[k + 4], n[k + 5]), controlPoint1: pt(n[k], n[k + 1]), controlPoint2: pt(n[k + 2], n[k + 3]))
                last = NSPoint(x: n[k + 4], y: n[k + 5])
                k += 6
            }
        case "Z": path.close(); last = start
        default: break
        }
    }
    return path
}

/// Preserve the existing plate proportions, with its straight edges on pixels.
struct Layout {
    let pixels: Int
    private var s: CGFloat { CGFloat(pixels) / 1024.0 }

    var plate: NSRect {
        let inset = (100.0 * s).rounded()
        let width = CGFloat(pixels) - inset * 2
        return NSRect(x: inset, y: inset, width: width, height: width)
    }
    var corner: CGFloat { min(plate.width / 2, (plate.width * 0.2237).rounded()) }

    var mark: NSRect {
        let w = (plate.width * 0.754).rounded()
        let h = w * canvas.height / canvas.width
        return NSRect(x: plate.midX - w / 2, y: plate.midY - h / 2, width: w, height: h)
    }
}

enum IconError: Error { case bitmap(Int), encoding(URL) }

/// One bitmap at the size saved in the iconset, independent of screen scale.
func draw(_ pixels: Int) throws -> NSBitmapImageRep {
    let layout = Layout(pixels: pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { throw IconError.bitmap(pixels) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    // Keep the original soft shadow, while rasterising the plate only once.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * CGFloat(pixels) / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -10 * CGFloat(pixels) / 1024)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: layout.plate, xRadius: layout.corner, yRadius: layout.corner).fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark, near-black, on top of it.
    NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
    markPath(in: layout.mark).fill()

    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else { throw IconError.encoding(url) }
    try png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = try draw(pixels)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try write(rep, to: out.appendingPathComponent(name))
    }
}
print("drew: \(out.path)")

// The same icon as an Icon Composer document, when a second path is given.
// macOS 26 lets the Dock show icons Dark, Clear or Tinted, and it can only do
// that well with an icon that says what each style should be: from the flat
// image above it made a darkened plate with the black mark still on it, black
// on black. Here the plate and the mark are separate, so Dark turns them
// round — a white mark on the ink colour, the S and the x showing the plate
// through it — and Tinted gets a white mark whose brightness the system
// tints. The light look is left as it is: the same white, the same ink, the
// mark at the same share of the plate, no glass, gloss or shadow of its own.
// build.sh compiles it with actool; the images above stay the .icns.
if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    // An Icon Composer canvas is the plate, 1024 points across; the mark
    // takes the same share of it as Layout.mark does of the plate above.
    let width = 1024 * 0.754
    let height = width * canvas.height / canvas.width
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(canvas.width) \(canvas.height)">\
    <path fill-rule="evenodd" fill="#171717" d="\(markData)"/></svg>
    """
    try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

    let white = #"{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }"#
    let ink = #"{ "solid" : "srgb:0.09000,0.09000,0.09000,1.00000" }"#
    let json = """
    {
      "fill" : \(white),
      "fill-specializations" : [
        { "value" : \(white) },
        { "appearance" : "dark", "value" : \(ink) }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "name" : "mark",
              "image-name" : "mark.svg",
              "glass" : false,
              "fill-specializations" : [
                { "value" : \(ink) },
                { "appearance" : "dark", "value" : \(white) },
                { "appearance" : "tinted", "value" : \(white) }
              ]
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
