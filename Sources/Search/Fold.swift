import SwiftUI

// The column of tabs, folded away with ⌘S.
//
// The column is two hundred and some points the page never gets back, even
// while all you do is read. Folded, the page takes the whole window. The tabs
// are one push against the left edge away: the column slides out over the
// page, the same column with the same rows, and goes again once the pointer
// leaves it. A short grace before it goes, so a hand that overshoots on the
// way back in doesn't lose it.
//
// The traffic lights go with it. They live in the column's corner, and left
// alone over a page they sit on top of whatever the page put in its own
// corner — a logo, a menu button. They come back with the column when it
// slides out, which is also where the window is dragged from.
//
// Folding lasts the session. A browser opening with no tabs anywhere on
// screen, for a reason set days ago, reads as a broken one.
//
// Unless that is the reason: Settings can keep the column folded for good,
// Arc's way, and then the fold is where it rests, at launch and after every
// change of layout. ⌘S still brings it out to stay, and puts it away again.
// Folded like that, the edge is met far more often by a hand on its way
// somewhere else — the Dock, the window beside — than by one reaching for
// the tabs, so the column waits for the pointer to settle there a moment
// before it comes. Folded by hand with ⌘S, it comes at once, as it always did.
//
// The edge isn't only where the pointer stops. A hand flung at it, with the
// window away from the screen's own edge, sails past it off the window, and
// was never seen at the edge at all. Past the edge counts as the edge, if
// the pointer got there from the window: not a hand coming in from the left.
// And while the column is out, a pointer just past the edge is still on it.
//
// While a tab's address is being typed into its row, the column stays out:
// the pointer drifting off it is no reason to take the field away.
//
// The strip across the top folds the same way: up out of the window, the
// page taking the full height, and back down over the page when the pointer
// rests against the top edge. There the edge is crossed on every trip to the
// menu bar just above, so the strip always waits for the pointer to settle.

// The column’s own spring, which Settings sets its length of (see
// Motion.fold). On the profile, for the things that fold the layout for
// the whole window; on a window, for what one window does on its own.
extension Browser {
    var foldMotion: Animation? { Motion.fold(prefs.sideSpeed) }
}

/// The shade chrome out over the page casts past its edge: a short fall to
/// nothing, so the edge reads as depth rather than a drawn line. A gradient
/// rather than a shadow, which would be blurred again on every frame of the
/// slide.
private struct FoldShade: View {
    let edge: Edge
    private static let reach: CGFloat = 18

    var body: some View {
        let from: UnitPoint, to: UnitPoint, offset: CGSize
        switch edge {
        case .trailing: (from, to, offset) = (.leading, .trailing, CGSize(width: Self.reach, height: 0))
        case .leading: (from, to, offset) = (.trailing, .leading, CGSize(width: -Self.reach, height: 0))
        case .bottom: (from, to, offset) = (.top, .bottom, CGSize(width: 0, height: Self.reach))
        case .top: (from, to, offset) = (.bottom, .top, CGSize(width: 0, height: -Self.reach))
        }
        let horizontal = edge == .leading || edge == .trailing
        return LinearGradient(
            stops: [.init(color: .black.opacity(0.10), location: 0),
                    .init(color: .black.opacity(0.03), location: 0.45),
                    .init(color: .clear, location: 1)],
            startPoint: from, endPoint: to
        )
        .frame(width: horizontal ? Self.reach : nil, height: horizontal ? nil : Self.reach)
        .offset(offset)
        .allowsHitTesting(false)
    }
}

/// Over the window while the column or the strip is folded: the column or
/// the strip itself while it is out, brought out by the pointer at the
/// window's left edge, or its top edge.
struct Fold: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var prefs: Preferences

    /// The column going back in, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?
    /// The column coming out, once the pointer has settled on the edge.
    @State private var arriving: DispatchWorkItem?
    /// The pointer is over the column.
    @State private var inside = false
    @State private var pointer = Pointer()
    @State private var fullscreen = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var onRight: Bool { prefs.sidebar && prefs.sidePosition == .right }
    private var sideEdge: Edge { onRight ? .trailing : .leading }

    /// How near the edge the pointer has to be to start the column coming.
    private static let edge: CGFloat = 16
    /// How far it may drift from the edge while the column is on its way.
    /// A hand resting against the edge wanders; at a single threshold the
    /// opening delay was cancelled by a few points' drift, and the edge felt
    /// like it had to be hit exactly. Two thresholds, as the Dock's reveal
    /// has: a narrow one to begin, a wider one to keep going.
    private static let hold: CGFloat = 40
    /// How far past the window's left edge the pointer still counts as on it.
    private static let overshoot: CGFloat = 48
    /// The grace before the column goes back in.
    private static let grace: TimeInterval = 0.3
    /// The band along the top that is the title bar over the page.
    private static let top: CGFloat = 8
    /// How long the pointer rests on the edge before a column folded for
    /// good comes out. Long enough to cross the edge, short enough not to be
    /// waited for.
    private static let dwell: TimeInterval = 0.15
    /// How far past the edge the folded column or row waits: its own
    /// ground reaches 40 points beyond it, and its shade a little more.
    private static let parked: CGFloat = 64

    var body: some View {
        ZStack(alignment: onRight ? .topTrailing : .topLeading) {
            // In the column's mode the page reaches the window's top edge —
            // beside the column, and everywhere once it is folded away — and
            // there was nowhere there to drag the window from, or to
            // double-click to fill the screen: only the column's own corner,
            // gone when folded. A band too thin to be in a page's way stands
            // in for the title bar along the whole top; the column lies over
            // it with its own.
            if prefs.sidebar, window.active?.immersed != true {
                DragStrip()
                    .frame(height: Fold.top)
                    .frame(maxWidth: .infinity)
            }
            if folding, !prefs.sidebar {
                // The row has no ground of its own: in the window it lies on
                // the window's. Out over the page it brings that ground along,
                // as the column does, or the page showed through between the
                // tabs, and the shadow fell from every title and icon rather
                // than from the row's edge.
                //
                // Kept, folded or not, just above the window's top edge (see
                // the column below for why).
                TabBar(window: window)
                    .background(FloatingChromeGround(prefs: prefs))
                    .background(alignment: .bottom) { FoldShade(edge: .bottom) }
                    .environment(\.chromeBacking, .provided)
                    .offset(y: window.peeking ? 0 : -(prefs.topBarHeight + Fold.parked))
                    .allowsHitTesting(window.peeking)
                    .accessibilityHidden(!window.peeking)
            }
            ZStack(alignment: onRight ? .trailing : .leading) {
                Color.clear.frame(width: 0)
                if folding, prefs.sidebar {
                    // The spring carries the column a few points past the
                    // window edge before it settles. Beside the page the
                    // window fills that; out over the page it showed the
                    // page, so the column brings its ground along — the page
                    // under it, blurred, when the chrome is see-through. Its
                    // edge is a soft fall of shade, no line.
                    SideBar(window: window, prefs: prefs, floating: true)
                        .background(FloatingChromeGround(prefs: prefs).padding(onRight ? .trailing : .leading, -40))
                        .background(alignment: onRight ? .leading : .trailing) {
                            FoldShade(edge: onRight ? .leading : .trailing)
                        }
                        .environment(\.chromeBacking, .provided)
                        // Kept, folded or not, just past the window's edge,
                        // and slid out and back on the column's spring. Made
                        // afresh each time it came out, every row, heading
                        // and pin was built and measured again in the frame
                        // the slide began: 25–33 ms on the main thread, the
                        // page's frames with it. Now only its place changes.
                        .offset(x: window.peeking ? 0 : (onRight ? 1 : -1) * (prefs.sideWidth + Fold.parked))
                        .allowsHitTesting(window.peeking)
                        .accessibilityHidden(!window.peeking)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .topTrailing : .topLeading)
        .ignoresSafeArea()
        .onAppear {
            hideLights()
            watch()
        }
        .onDisappear { pointer.stop() }
        // A column folded for good is folded before there is a window to
        // hide the lights of; they go once there is one.
        .background(WindowSetup { window in
            fullscreen = window.styleMask.contains(.fullScreen)
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff && !fullscreen
            pointer.window = window
            watch()
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let host = note.object as? NSWindow, host === pointer.window else { return }
            fullscreen = true
            hideLights()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let host = note.object as? NSWindow, host === pointer.window else { return }
            fullscreen = false
            hideLights()
        }
        .onChange(of: folding) { _, _ in watch() }
        // Back to the strip and then to the column again: the column comes
        // back as it rests — whole, not folded from a time nobody remembers,
        // unless Settings says it rests folded.
        .onChange(of: prefs.sidebar) { _, _ in
            window.folded = prefs.sidebar && prefs.sideHides
            window.peeking = false
        }
        .onChange(of: prefs.sideHides) { _, hides in
            guard prefs.sidebar else { return }
            window.peeking = false
            withAnimation(window.profile.foldMotion) { window.folded = hides }
        }
        // The address typed into a row is done with, and the pointer went
        // elsewhere while it was: the column goes the way it would have.
        .onChange(of: window.editingTab) { _, editing in
            if editing == nil, !inside, window.peeking { peek(false) }
        }
        .onChange(of: window.choosingIconFor) { _, choosing in
            if choosing == nil, !inside, window.peeking { peek(false) }
        }
    }

    /// Folded, and not taken over by a page filling the screen.
    private var folding: Bool {
        window.folded && window.active?.immersed != true
    }

    private var lightsOff: Bool {
        window.folded && !window.peeking
    }

    /// The pointer is watched only while there is something folded for it
    /// to bring out; the rest of the time no move of it costs anything.
    private func watch() {
        if folding {
            pointer.start { follow() }
        } else {
            pointer.stop()
        }
    }

    /// Opens or closes the column from the pointer's actual position, on
    /// every move. Hover events weren't enough: a view that appears under a
    /// still pointer never gets "entered", so it never gets "exited" either,
    /// and after a few quick opens and closes the column stayed open, or the
    /// edge stopped opening it.
    private func follow() {
        guard folding, let host = pointer.window, host.isVisible else { return pass() }
        let screen = NSEvent.mouseLocation
        let point = host.convertPoint(fromScreen: screen)
        let size = host.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        // Distance from the left edge for the column, from the top for the strip.
        let distance = prefs.sidebar ? (onRight ? size.width - point.x : point.x) : size.height - point.y
        // Just past the left edge, beside the window rather than above or
        // below it.
        let beside = prefs.sidebar && distance < 0 && distance > -Fold.overshoot
            && point.y >= 0 && point.y < size.height
        // There, and come off the window to get there.
        let overshot = beside && pointer.crossing
        pointer.crossing = inWindow || overshot
        if window.peeking {
            pass()
            // Only this window counts, not another app's window over it. One
            // of this app's own windows, such as a popover opened from the
            // column, counts as the column.
            let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            let onWindow = top == host.windowNumber
            let onOwnPanel = !onWindow && NSApp.windows.contains { $0.windowNumber == top }
            let reach = prefs.sidebar ? prefs.sideWidth : prefs.topBarHeight
            let over = onOwnPanel || beside || (onWindow && inWindow && distance < reach)
            if over != inside { inside = over }
            peek(over)
        } else if inWindow, distance < (arriving == nil ? Fold.edge : Fold.hold) {
            // Which window is under the pointer is asked only here, at the
            // edge: another app's window over it doesn't bring the column out.
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == host.windowNumber
            else { return pass() }
            if arriving == nil { arrive() }
        } else if overshot {
            // Off the window, so whatever is under the pointer now isn't it.
            if arriving == nil { arrive() }
        } else {
            pass()
        }
    }

    /// The pointer on the edge: out at once, or after the dwell when the
    /// column is folded for good, and always for the strip, whose edge is
    /// the way to the menu bar.
    private func arrive() {
        // Focus mode keeps the column away (see Focus.swift).
        guard window.focusing == nil else { return pass() }
        guard !prefs.sidebar || prefs.sideHides else { return peek(true) }
        pass()
        let coming = DispatchWorkItem {
            arriving = nil
            peek(true)
        }
        arriving = coming
        let delay = prefs.sidebar ? prefs.sideDelay : Fold.dwell
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: coming)
    }

    /// The pointer crossed the edge without stopping.
    private func pass() {
        guard let arriving else { return }
        arriving.cancel()
        self.arriving = nil
    }

    /// Out at once; in only once the pointer has stayed away for the grace,
    /// counted from when it left rather than from its latest move.
    private func peek(_ out: Bool) {
        if out {
            if let leaving {
                leaving.cancel()
                self.leaving = nil
            }
            guard !window.peeking else { return }
            window.peek(true)
        } else {
            guard leaving == nil else { return }
            let going = DispatchWorkItem {
                leaving = nil
                guard window.editingTab == nil, window.editingGroupID == nil, window.choosingIconFor == nil,
                      window.editingSidebarBookmarkID == nil else { return }
                window.peek(false)
            }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Fold.grace, execute: going)
        }
    }

    /// The title bar's own view holds the three buttons, so hiding it hides
    /// them, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = titlebar else { return }
        // AppKit moves this view into its fullscreen title bar. Folding must
        // not leave that shared view hidden or running our slide animation.
        if fullscreen || pointer.window?.styleMask.contains(.fullScreen) == true {
            bar.layer?.setValue(nil, forKey: "searchFoldTicket")
            bar.layer?.removeAnimation(forKey: "fold")
            bar.isHidden = false
            return
        }
        if prefs.sidebar {
            Fold.slide(bar, off: lightsOff, by: onRight ? -prefs.sideWidth : prefs.sideWidth, response: prefs.sideSpeed)
        } else {
            Fold.slide(bar, off: lightsOff, by: prefs.topBarHeight, up: true, response: prefs.sideSpeed)
        }
    }

    var titlebar: NSView? {
        window.profile.host(of: window)?.standardWindowButton(.closeButton)?.superview
    }

    /// The lights ride with the column, as everything else in its corner
    /// does. Shown or hidden at once, they stood in their place while the
    /// column was still sliding in under them, and vanished before it had
    /// gone. So they come in from the left edge and go back off it, on the
    /// column's own spring (Motion.fold, in Core Animation's terms) — from
    /// wherever they are, when the pointer turns back halfway. `up`: off the
    /// top edge with the strip rather than off the left edge with the column.
    /// `response`: the spring's, from Settings › Tabs; zero is no slide.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, up: Bool = false, response: Double) {
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        let ticket = UUID().uuidString
        layer.setValue(ticket, forKey: "searchFoldTicket")
        // Up is +y in a superview that isn't flipped, -y in one that is.
        let path = up ? "transform.translation.y" : "transform.translation.x"
        let gone: CGFloat = up ? ((bar.superview?.isFlipped ?? false) ? -width : width) : -width
        let other = up ? "transform.translation.x" : "transform.translation.y"
        let moving = layer.animation(forKey: "fold") != nil
        // A slide still running on the other axis — the layout was switched
        // halfway — is simply let go.
        if moving, (layer.animation(forKey: "fold") as? CABasicAnimation)?.keyPath == other {
            layer.removeAnimation(forKey: "fold")
        }
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to, let spring = Motion.foldSpring(path, response: response) else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard layer.value(forKey: "searchFoldTicket") as? String == ticket else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}

/// The pointer's moves, wherever it goes, while something is folded: over
/// this app's windows, and over everything else while another app is in
/// front, since the edge is still the edge with Search behind.
@MainActor
private final class Pointer {
    weak var window: NSWindow?
    /// The pointer is over the window, or just went off its left edge from
    /// it and hasn't gone further.
    var crossing = false
    private var local: Any?
    private var global: Any?
    /// The window's own say on mouse-moved events, given back when the
    /// watch ends.
    private var accepted = false

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard local == nil, let window else { return }
        // The pointer's moves reach the monitor wherever it is over the
        // window, not only over what tracks it — for as long as the watch
        // lasts, and no longer.
        accepted = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { moved() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { moved() }
        }
    }

    func stop() {
        guard local != nil || global != nil else { return }
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        window?.acceptsMouseMovedEvents = accepted
    }
}
