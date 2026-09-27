import CoreGraphics
import Foundation

// Any picture as pixel art: a grid of cells, each the picture's own colour
// there, shaded by ordered (Bayer) dithering — the dotted look of a screen
// from the late eighties, rather than a blurred photograph. The colours are
// the picture's: each channel is dithered between the two nearest of a few
// levels, so a patch of dots averages to the colour it came from.
//
// Made once per picture, at the size of the largest screen, and shown at its
// own size behind the window like a desktop picture: resizing the window
// shows more or less of it and never makes it again, so no size can leave a
// stale copy on screen or change what colour anything is.

enum PixelArt {
    /// Points per cell. Two reads as pixel art at arm's length and still
    /// keeps a face a face; on a Retina screen it is a whole four pixels,
    /// so every dot is the same size.
    static let cell: CGFloat = 2
    /// Levels per channel between which the cells are dithered.
    private static let levels = 5.0

    /// Bayer's 8×8 threshold matrix: the thresholds spread so that every
    /// level between two tones is a regular pattern of dots.
    private static let bayer: [UInt8] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// The picture as `columns` × `rows` cells, one pixel each: to be shown
    /// `cell` points to the pixel with no smoothing. `fit` keeps all of the
    /// picture, in its own proportions, inside that grid; otherwise it fills
    /// the grid and the edges are cropped.
    static func grid(_ source: CGImage, columns: Int, rows: Int, fit: Bool) -> CGImage? {
        guard columns > 0, rows > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ratio = fit
            ? min(CGFloat(columns) / CGFloat(source.width), CGFloat(rows) / CGFloat(source.height))
            : max(CGFloat(columns) / CGFloat(source.width), CGFloat(rows) / CGFloat(source.height))
        let width = fit ? max(1, Int(CGFloat(source.width) * ratio)) : columns
        let height = fit ? max(1, Int(CGFloat(source.height) * ratio)) : rows
        var cells = [UInt8](repeating: 0, count: width * height * 4)
        guard let small = CGContext(data: &cells, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawn down to the grid, each cell is the average of its pixels.
        small.interpolationQuality = .high
        let drawn = CGSize(width: CGFloat(source.width) * ratio, height: CGFloat(source.height) * ratio)
        small.draw(source, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
        let steps = levels - 1
        for y in 0..<height {
            for x in 0..<width {
                let threshold = (Double(bayer[(y % 8) * 8 + x % 8]) + 0.5) / 64
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    let tone = Double(cells[index + channel]) / 255 * steps
                    let base = floor(tone)
                    let level = min(steps, base + (tone - base > threshold ? 1 : 0))
                    cells[index + channel] = UInt8((level / steps * 255).rounded())
                }
                cells[index + 3] = 255
            }
        }
        return small.makeImage()
    }

    // MARK: - the picture's colour

    /// A picture's own colours: its strongest hues, most first, with how
    /// colourful each is where the picture has it.
    struct Tone: Equatable {
        struct Hue: Equatable {
            var angle: Double
            var chroma: Double
        }
        var hues: [Hue]
        /// How much of the picture has any colour at all.
        var coverage: Double
        var isGrey: Bool { hues.isEmpty || coverage < 0.02 || hues[0].chroma < 0.012 }
    }

    /// The tone of a picture as a window shows it — filled, so cropped to a
    /// window's shape — from a small copy: the address field's light and the
    /// selected tab take their colour from it (see Wallpaper.accent).
    static func tone(of image: CGImage) -> Tone? {
        let columns = 80, rows = 50
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        let fill = max(CGFloat(columns) / CGFloat(image.width), CGFloat(rows) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
        context.draw(image, in: CGRect(x: (CGFloat(columns) - drawn.width) / 2, y: (CGFloat(rows) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        let tone = measure(pixels, count: columns * rows)
        return tone.isGrey ? nil : tone
    }

    /// Hues in 36 bins, counted by how colourful and how lit each pixel is,
    /// each bin with its neighbours so a hue on a bin's edge is not split.
    /// An average of every hue would be one the picture never had — orange
    /// sky and blue sea came out olive — so the strongest few are kept apart.
    private static func measure(_ pixels: [UInt8], count total: Int) -> Tone {
        var vote = [Double](repeating: 0, count: 36)
        var sumA = [Double](repeating: 0, count: 36), sumB = [Double](repeating: 0, count: 36)
        var chromaSum = [Double](repeating: 0, count: 36), members = [Double](repeating: 0, count: 36)
        var coloured = 0.0
        for index in 0..<total {
            let r = Double(pixels[index * 4]) / 255, g = Double(pixels[index * 4 + 1]) / 255, b = Double(pixels[index * 4 + 2]) / 255
            let (l, a, bb) = OKLCH.lab(r, g, b)
            let chroma = (a * a + bb * bb).squareRoot()
            guard chroma > 0.02 else { continue }
            coloured += 1
            let bin = Int(((atan2(bb, a) + .pi) / (2 * .pi) * 36).rounded(.down)) % 36
            let weight = chroma * (0.3 + l)
            vote[bin] += weight; sumA[bin] += a * weight; sumB[bin] += bb * weight
            chromaSum[bin] += chroma; members[bin] += 1
        }
        var taken = Set<Int>()
        var hues: [Tone.Hue] = []
        let first = vote.max() ?? 0
        for _ in 0..<3 {
            var best = -1, bestVote = 0.0
            for bin in 0..<36 where !taken.contains(bin) {
                let near = [(bin + 35) % 36, bin, (bin + 1) % 36].filter { !taken.contains($0) }
                let v = near.map { vote[$0] }.reduce(0, +)
                if v > bestVote { bestVote = v; best = bin }
            }
            // A hue with next to none of the picture is not its colour.
            guard best >= 0, bestVote > first * 0.25 else { break }
            let near = [(best + 35) % 36, best, (best + 1) % 36].filter { !taken.contains($0) }
            near.forEach { taken.insert($0) }
            let count = near.map { members[$0] }.reduce(0, +)
            hues.append(Tone.Hue(angle: atan2(near.map { sumB[$0] }.reduce(0, +), near.map { sumA[$0] }.reduce(0, +)),
                                 chroma: near.map { chromaSum[$0] }.reduce(0, +) / max(count, 1)))
        }
        return Tone(hues: hues, coverage: coloured / Double(max(total, 1)))
    }
}
