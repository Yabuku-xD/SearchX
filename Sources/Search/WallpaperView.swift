import SwiftUI
import UniformTypeIdentifiers

// A picture behind a new tab, if someone puts one there (Settings › Tabs).
//
// It stays anchored to the window while the column opens, folds or peeks out,
// because it is drawn here, beside the page, and not in the page. It never
// sits behind a real page — a site, or one of an extension’s, keeps its own.
struct WallpaperView: View {
    @ObservedObject var tab: Tab
    /// The image itself is the profile’s, like the bookmarks it is chosen
    /// from, so every window agrees on what is behind a blank tab.
    @ObservedObject private var wallpaper = Wallpaper.shared

    var body: some View {
        GeometryReader { area in
            if tab.isBlank, wallpaper.enabled, let image = wallpaper.image {
                if wallpaper.style == .pixel {
                    ZStack {
                        // At its own size, a cell to every two points, centred
                        // behind the window like a desktop picture: a window
                        // made smaller or larger shows less or more of it,
                        // and nothing is made again or scaled out of true.
                        if let art = wallpaper.art {
                            Image(decorative: art, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: CGFloat(art.width) * PixelArt.cell,
                                       height: CGFloat(art.height) * PixelArt.cell)
                        }
                        Scrim(height: area.size.height)
                    }
                    .frame(width: area.size.width, height: area.size.height)
                    .clipped()
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: wallpaper.fit ? .fit : .fill)
                        .frame(width: area.size.width, height: area.size.height)
                        .clipped()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Read when the switch goes on and when a blank tab arrives, and
        // nowhere else: the image keeps once it has been read.
        .task(id: tab.isBlank && wallpaper.enabled) {
            if tab.isBlank { await wallpaper.load() }
        }
    }
}

/// The ground under the tab you are on, in the new tab picture's colour
/// (Wallpaper.accent), grey without one.
struct SelectionGround: View {
    var radius: CGFloat = 9
    @ObservedObject private var wallpaper = Wallpaper.shared

    var body: some View {
        AccentGround(tone: wallpaper.accent, radius: radius)
    }
}

/// Dark over the picture, and darker toward the address field: the top of
/// the picture is seen, the field sits at the edge of the dark, and below it
/// is black — so the picture frames the field rather than competing with
/// what is typed into it. The field stands 30 points above the middle (see
/// Omnibox), and the fall is placed from it.
private struct Scrim: View {
    let height: CGFloat

    var body: some View {
        let field = height / 2 - 30 - 25
        let at = { (y: CGFloat) in Double(min(1, max(0, y / max(height, 1)))) }
        LinearGradient(stops: [
            .init(color: .black.opacity(0.28), location: 0),
            .init(color: .black.opacity(0.12), location: at(90)),
            .init(color: .black.opacity(0.22), location: at(field - 220)),
            .init(color: .black.opacity(0.62), location: at(field - 80)),
            .init(color: .black.opacity(0.9), location: at(field + 10)),
            .init(color: .black, location: at(field + 110)),
            .init(color: .black, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Settings › Tabs. A picture behind the address field on a new tab, how
/// big a copy Search keeps, and whether it fills the window or fits inside.
struct WallpaperSettings: View {
    @ObservedObject private var wallpaper = Wallpaper.shared
    @State private var choosing = false

    var body: some View {
        Card {
            Line("New tab image", "A picture behind the address field") {
                Switch(on: $wallpaper.enabled)
            }
            if wallpaper.enabled || wallpaper.hasImage {
                Rule()
                Line("Image", wallpaper.busy ? "Preparing image…" : "A copy is kept in SearchX") {
                    HStack(spacing: 6) {
                        Pill(wallpaper.hasImage ? "Change…" : "Choose…") { choose() }
                        if wallpaper.hasImage {
                            Pill("Remove") {
                                Task { await wallpaper.remove() }
                            }
                        }
                    }
                }
            }
            if wallpaper.enabled, wallpaper.hasImage {
                Rule()
                Line("Style", wallpaper.style == .pixel
                     ? "Pixel art in the picture’s own colors, darkening to the address field"
                     : "The picture as it is") {
                    Segmented(options: [(Wallpaper.Style.pixel, "Pixel"), (.photo, "Photo")], selection: $wallpaper.style)
                }
                Rule()
                Line("Layout", wallpaper.fit ? "Fit the picture to the window" : "Fill the window without stretching") {
                    Segmented(options: [(false, "Fill"), (true, "Fit")], selection: $wallpaper.fit)
                }
            }
        }
        .disabled(wallpaper.busy || choosing)
        // Turning it on with no picture asks for one straight away; saying
        // no to the panel turns it back off, rather than leaving it on over
        // nothing.
        .onChange(of: wallpaper.enabled) { _, on in
            if on, !wallpaper.hasImage { choose() }
        }
    }

    private func choose() {
        guard !choosing else { return }
        choosing = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use image"
        panel.begin { response in
            choosing = false
            guard response == .OK, let url = panel.url else {
                if !wallpaper.hasImage { wallpaper.enabled = false }
                return
            }
            Task { await wallpaper.use(url) }
        }
    }
}
