import AppKit
import SwiftUI

// The colours a group or a container can wear: the Finder's tag colours,
// which macOS already draws for light and dark and for Increase Contrast,
// so they read the same here as on every file you have tagged. The colour is
// never the only way to tell one from another: the name is beside it.

enum Tint: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, grey

    var id: String { rawValue }

    var title: String { rawValue == "grey" ? "Grey" : rawValue.capitalized }

    var ns: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .grey: return .systemGray
        }
    }

    var color: Color { Color(nsColor: ns) }

    /// The next colour for the \`count\`th thing made, so side by side they
    /// differ without anyone choosing. Grey is left for choosing.
    static func next(after count: Int) -> Tint {
        let bright: [Tint] = [.blue, .orange, .green, .purple, .red, .yellow]
        return bright[count % bright.count]
    }
}

/// A tag's dot, as the Finder draws one beside a file's name.
struct TintDot: View {
    let tint: Tint
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(tint.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
