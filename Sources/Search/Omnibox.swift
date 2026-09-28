import SwiftUI
import AppKit

/// One field for addresses and searches, with local history immediately
/// below it and optional provider completions arriving afterward.
struct Omnibox: View {
    @ObservedObject var window: WindowModel
    /// What typing changes: the text, the list, the grey ending, the row
    /// walked to (see FieldSignal).
    @ObservedObject private var typing: FieldSignal
    /// Raised over a page by ⌘L, rather than standing on an empty tab.
    let over: Bool

    init(window: WindowModel, over: Bool) {
        self.window = window
        self.over = over
        _typing = ObservedObject(wrappedValue: window.field)
    }

    /// The field's own height — the 22 of text and 14 of air above and below it
    /// that `field` lays out — so the list can sit below it without being
    /// stacked with it.
    private static let fieldHeight: CGFloat = 22 + 14 * 2
    private static let suggestionHeight: CGFloat = 34

    @State private var shake: CGFloat = 0
    @State private var refused = false

    var body: some View {
        GeometryReader { room in
            ZStack {
                if over {
                    // The page is still there, just out of the way.
                    Rectangle()
                        .fill(Palette.ground.opacity(0.74))
                        .ignoresSafeArea()
                        .onTapGesture { window.dismiss() }
                        .transition(.opacity)
                }

                field
                    .frame(width: min(Metrics.fieldWidth, max(0, room.size.width - 32)))
                    // The list hangs below the field rather than stacking with it,
                    // so a list that grows never lifts the field out from under
                    // what is being typed.
                    .overlay(alignment: .top) {
                        // Present or gone, not always-on-and-hidden: the list keeps
                        // the appear and disappear it had, and the overlay is what
                        // keeps that from moving the field.
                        if !window.offers.isEmpty {
                            list(maxHeight: max(0, room.size.height / 2 - 19))
                                .offset(y: Self.fieldHeight + 8)
                        }
                    }
                    // Lifted a little above centre: dead centre reads as low,
                    // because the strip at the top isn't part of what the eye is
                    // measuring.
                    .padding(.bottom, 60)
                    // The list's arrival and its leaving are animated from here,
                    // briefly: nothing that changes the suggestions does it inside
                    // an animation of its own. Its rows follow what was typed or
                    // pasted at once — sliding into place on a spring between
                    // keystrokes, they trailed behind the field.
                    .animation(Motion.quick, value: window.offers.isEmpty)
                    .animation(Motion.settle, value: refused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var field: some View {
        AddressField(window: window, field: window.field, summoning: window.summoning)
            .frame(height: 22)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    // A slow, almost invisible breath under the field. It is
                    // the only thing on an empty tab, and a thing that never
                    // moves at all reads as a picture of an app rather than
                    // an app.
                    Breath()

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.ground)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        refused ? Color.red.opacity(0.35) : Palette.hairline,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            // On an empty tab, a light travelling the field's edge in the
            // accent's colours (see Beam.swift).
            .overlay {
                if !over { FieldBeam(prefs: window.profile.prefs) }
            }
            .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
            .modifier(Shake(travel: shake))
            .onChange(of: window.refusals) { _, _ in
                shake = 0
                refused = true
                withAnimation(Motion.easeOut(0.5)) { shake = 1 }
            }
            .onChange(of: window.typed) { _, _ in
                withAnimation(Motion.quick) { refused = false }
            }
    }

    /// What it thinks you mean. Places you have been come with their titles;
    /// the handful of well-known addresses it starts life knowing come without
    /// the weight of one.
    ///
    /// It lives below the field, in an overlay, so arriving or leaving never
    /// moves the field — and the transition that carried it in and out before
    /// is kept, only anchored to its own top edge.
    private func list(maxHeight: CGFloat) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(window.offers.enumerated()), id: \.element.id) { index, offer in
                        Row(offer: offer, picked: window.picked == index)
                            .contentShape(Rectangle())
                            .onTapGesture { window.take(offer) }
                            .id(index)
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(maxHeight, CGFloat(window.offers.count) * Self.suggestionHeight + 12))
            .onChange(of: window.picked) { _, index in
                if let index { scroller.scrollTo(index) }
            }
        }
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 20, y: 6)
        // Opened hundreds of times a day, so it arrives at once, as a menu
        // does; only its going is eased, and less than an arrival would be.
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
    }

    private struct Row: View {
        let offer: Suggestion
        /// Where the arrow keys have walked to. The pointer gets its own,
        /// quieter mark, and changes nothing but the look of the row.
        let picked: Bool

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                switch offer.kind {
                case .search:
                    // The site's own icon when it's already known - a search
                    // typed for a site you've been to before doesn't need to
                    // say so with a magnifying glass. Nothing is fetched for
                    // one that isn't; the glass is what a row wears until then.
                    CachedIcon(host: offer.url.host()?.lowercased() ?? "") { icon in
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                case .open:
                    // Already open: naming it takes you back to it rather than
                    // opening a second copy.
                    Circle()
                        .fill(Palette.ink.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .padding(.horizontal, 2)
                case .command:
                    Image(systemName: "command")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                case .bookmark:
                    Image(systemName: "bookmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 14)
                case .action(let action):
                    Image(systemName: Symbols.current(action.symbol))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 14)
                default:
                    EmptyView()
                }
                Text(offer.key)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                if case .action = offer.kind {
                    // The key it is on, or where it lives, at the far end
                    // where a menu puts a key.
                    Spacer(minLength: 8)
                    Text(offer.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                } else {
                    if !offer.title.isEmpty {
                        Text(offer.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Omnibox.suggestionHeight)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.wash)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            // A list walked many times a day answers the pointer at once.
            .onHover { hovering = $0 }
        }
    }
}

/// The breath under the field: a soft shape of ink, blurred, moved by Core
/// Animation. Animated by SwiftUI, it was drawn again on the main thread
/// every frame for as long as an empty tab was showing — 18% of a core with
/// the window doing nothing (24 Sep 2026). As a layer's shadow, breathed by
/// Core Animation, it is played in the render server and costs the app
/// nothing; and it is a layer, not a second SwiftUI view to build before
/// the first frame.
private struct Breath: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = Power.shared
    /// As dark as the shape it replaces, 5% ink blurred by 26: a shadow of
    /// the same radius comes out at 0.7 of the darkness at equal strength,
    /// measured on pictures of both (24 Sep 2026), so 7%.
    static let strength: Swift.Float = 0.07

    func makeNSView(context: Context) -> NSView { Lung() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Lung)?.setMotion(!reduceMotion && !power.saving)
    }

    private final class Lung: NSView {
        private let glow = CALayer()
        private var breathed: CGSize = .zero
        private var animates = true

        func setMotion(_ enabled: Bool) {
            guard animates != enabled else { return }
            animates = enabled
            breathe()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            breathe()
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glow.shadowOpacity = Breath.strength
            glow.shadowOffset = .zero
            glow.shadowRadius = 26
            layer?.addSublayer(glow)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The ink is the look's: light on a dark window, dark on a light one.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance { glow.shadowColor = Palette.NS.ink.cgColor }
        }

        override func layout() {
            super.layout()
            guard bounds.size != breathed, bounds.width > 0 else { return }
            breathed = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.bounds = bounds
            glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
            glow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 26, cornerHeight: 26, transform: nil)
            effectiveAppearance.performAsCurrentDrawingAppearance { glow.shadowColor = Palette.NS.ink.cgColor }
            CATransaction.commit()
            breathe()
        }

        private func breathe() {
            guard animates, window != nil, !bounds.isEmpty else {
                glow.removeAnimation(forKey: "breath")
                return
            }
            guard glow.animation(forKey: "breath") == nil else { return }
            // From 0.97 to 1.03, from 0.65 to full, 2.6 s each way, for as
            // long as the field is there.
            let size = CABasicAnimation(keyPath: "transform.scale")
            size.fromValue = 0.97
            size.toValue = 1.03
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.65
            fade.toValue = 1.0
            let both = CAAnimationGroup()
            both.animations = [size, fade]
            both.duration = 2.6
            both.autoreverses = true
            both.repeatCount = .infinity
            both.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(both, forKey: "breath")
        }
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    @ObservedObject var window: WindowModel
    /// What typing changes, so text put in from elsewhere (⌘K, a pick from
    /// the list) reaches the field.
    @ObservedObject var field: FieldSignal
    /// ⌘K or not, handed in so a change to it is a change SwiftUI sees
    /// here, and the placeholder follows it at once.
    var summoning = false

    func makeCoordinator() -> Coordinator { Coordinator(window: window) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        // An address, not a sign-in: told nothing, AppKit takes a focused
        // field for one that might want a password or a one-time code, and
        // starts Safari's AutoFill helper (20 MB) for it on every launch.
        field.contentType = .URL
        field.isAutomaticTextCompletionEnabled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15.5)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        field.placeholderAttributedString = Self.placeholder(summoning: false)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.window = window
        // ⌘K finds tabs and runs commands (see QuickCommands); the field says so.
        if coordinator.summoning != summoning {
            coordinator.summoning = summoning
            let placeholder = Self.placeholder(summoning: summoning)
            field.placeholderAttributedString = placeholder
            // While the field is being typed into, its editor draws the
            // placeholder from a copy of its own, taken when editing began.
            if let editor = field.currentEditor() as? NSTextView,
               editor.responds(to: NSSelectorFromString("setPlaceholderAttributedString:")) {
                editor.setValue(placeholder, forKey: "placeholderAttributedString")
                editor.needsDisplay = true
            }
        }

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = window.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: window.typed.utf16.count, in: field)
        }

        if coordinator.answered != window.focusRequest {
            let request = window.focusRequest
            field.pendingFocus = { [weak field, weak coordinator] in
                guard let field, let coordinator, coordinator.window.fieldShowing,
                      coordinator.window.focusRequest == request,
                      let host = field.window, host.makeFirstResponder(field),
                      let editor = field.currentEditor() as? NSTextView else { return }
                coordinator.answered = request
                field.pendingFocus = nil
                // The system paints selected text as a block of accent colour,
                // which over this pale field is the loudest thing in the
                // window. A tenth of the ink says "selected" quietly enough.
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                    .foregroundColor: Palette.NS.ink,
                ]
                editor.selectAll(nil)
            }
            DispatchQueue.main.async { field.pendingFocus?() }
        }
    }

    final class Field: NSTextField {
        var pendingFocus: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // SwiftUI may update the field before attaching it. Keep the
            // request until AppKit can actually create its field editor.
            DispatchQueue.main.async { [weak self] in self?.pendingFocus?() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var window: WindowModel
        var answered = -1
        /// Which placeholder the field is showing (see placeholder(summoning:)).
        var summoning = false
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(window: WindowModel) {
            self.window = window
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            window.typed = text
            guard !deleting, let ending = window.ending else {
                if deleting { window.stopCompleting() }
                deleting = false
                synced = window.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.utf16.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // NSTextView ranges use UTF-16 offsets, including emoji and
            // combining characters in typed searches and completions.
            let length = field.stringValue.utf16.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                window.submit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                window.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                window.walk(-1)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}

extension AddressField {
    /// What the empty field says: an address, or on ⌘K everything it finds.
    static func placeholder(summoning: Bool) -> NSAttributedString {
        NSAttributedString(
            string: (summoning ? "Search tabs, bookmarks and commands" : "Search or enter a web address").saidNow,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )
    }
}
