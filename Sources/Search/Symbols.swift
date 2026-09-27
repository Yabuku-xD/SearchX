import Foundation

// The Mac's own newer names for a few of the symbols this app draws, used
// where the Mac has them. Chosen as the app draws, never stored: a space's
// icon is kept in spaces.json under the name every macOS knows, so a profile
// opened on an older Mac still draws it.
//
// Each newer name was checked against the system's own record of when each
// symbol arrived (CoreGlyphs.bundle, name_availability.plist): 2026 is
// macOS 27, 2024 macOS 15.
enum Symbols {
    /// macOS 27: the app window drawn as the new interface window, and the
    /// Speed Dial as the new grid of apps.
    private static let macOS27 = [
        "macwindow": "interface.window",
        "square.grid.2x2": "app.grid.2x2",
    ]

    /// macOS 15 renamed these; the old spellings live on only as aliases.
    private static let macOS15 = [
        "doc": "document",
        "doc.badge.ellipsis": "document.badge.ellipsis",
        "mic": "microphone",
    ]

    /// Already the name on every macOS this app runs on.
    private static let everywhere = [
        "terminal": "apple.terminal",
    ]

    static func current(_ name: String) -> String {
        if #available(macOS 27, *), let newer = macOS27[name] { return newer }
        if #available(macOS 15, *), let newer = macOS15[name] { return newer }
        return everywhere[name] ?? name
    }
}
