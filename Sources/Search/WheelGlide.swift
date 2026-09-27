import AppKit
import QuartzCore

// A mouse wheel's steps, played as a short glide instead of a jump.
//
// Whether an event needs this is read from the event itself, never from which
// app or device sent it: a wheel step (not continuous) is eased here, and a
// continuous event — a trackpad, a Magic Mouse, or a mouse tool such as
// LinearMouse, Mos or SteerMouse set to smooth or pixel scrolling — has been
// shaped already and goes to the page untouched, so nothing is smoothed twice.
// How far a step goes is the event's own delta, so a tool's distance,
// acceleration and direction settings still apply exactly as set.
//
// The glide reaches the page as continuous pixel events with no gesture
// phase: WebKit scrolls them by the pixel under the pointer, as a wheel's
// steps would, without the rubber band or the swipe between pages that
// belong to a trackpad gesture. Steps that arrive during a glide add to
// where it is going, so a fast spin speeds up instead of stuttering; a step
// the other way turns it round at once.
@MainActor
final class WheelGlide {
    /// WebKit's distance for one line of a wheel step (Scrollbar::pixelsPerLineStep),
    /// so a glide ends where the step would have jumped to.
    static let line: CGFloat = 40
    /// How quickly the rest of the way is covered: about 95% of it in three
    /// of these, 150 ms, near Safari's own wheel animation.
    static let pace: CFTimeInterval = 0.05
    /// The slowest a glide moves, in points a second, so its last few points
    /// arrive together instead of one at a time over a tenth of a second.
    static let floor: CGFloat = 600

    private weak var view: NSView?
    private let deliver: (NSEvent) -> Void
    private var remaining = CGVector.zero
    /// What rounding to whole points has held back, carried to the next frame.
    private var carry = CGVector.zero
    private var aim = CGPoint.zero
    private var flags: CGEventFlags = []
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    init(view: NSView, deliver: @escaping (NSEvent) -> Void) {
        self.view = view
        self.deliver = deliver
    }

    /// Takes a wheel step to glide, or returns false for the page to have
    /// the event as it is.
    func take(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
              event.phase.isEmpty, event.momentumPhase.isEmpty,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              UserDefaults.standard.bool(forKey: "NSScrollAnimationEnabled"),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let cg = event.cgEvent, let view
        else { return false }
        let step = CGVector(dx: event.scrollingDeltaX * Self.line, dy: event.scrollingDeltaY * Self.line)
        guard step.dx != 0 || step.dy != 0 else { return true }
        // A turn the other way starts from here rather than finishing the old way first.
        if step.dx * remaining.dx < 0 { remaining.dx = 0; carry.dx = 0 }
        if step.dy * remaining.dy < 0 { remaining.dy = 0; carry.dy = 0 }
        remaining.dx += step.dx
        remaining.dy += step.dy
        aim = cg.location
        flags = cg.flags
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            last = CACurrentMediaTime()
        }
        return true
    }

    /// Lets go of the page: nothing more is sent to it.
    func stop() {
        link?.invalidate()
        link = nil
        remaining = .zero
        carry = .zero
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = min(0.05, max(0.001, now - last))
        last = now
        let share = CGFloat(1 - exp(-elapsed / Self.pace))
        let least = Self.floor * CGFloat(elapsed)
        func part(_ left: CGFloat) -> CGFloat {
            let eased = max(abs(left * share), least)
            // The last half point is sent whole, so the glide ends where it meant to.
            return abs(left) - eased < 0.5 ? left : eased * (left < 0 ? -1 : 1)
        }
        let move = CGVector(dx: part(remaining.dx), dy: part(remaining.dy))
        remaining.dx -= move.dx
        remaining.dy -= move.dy
        let wanted = CGVector(dx: move.dx + carry.dx, dy: move.dy + carry.dy)
        let sent = CGVector(dx: wanted.dx.rounded(), dy: wanted.dy.rounded())
        carry = CGVector(dx: wanted.dx - sent.dx, dy: wanted.dy - sent.dy)
        if sent.dx != 0 || sent.dy != 0 { send(sent) }
        if remaining.dx == 0, remaining.dy == 0 { stop() }
    }

    private func send(_ delta: CGVector) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(delta.dy), wheel2: Int32(delta.dx), wheel3: 0)
        else { return }
        cg.location = aim
        cg.flags = flags
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta.dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(delta.dx))
        if let event = NSEvent(cgEvent: cg) { deliver(event) }
    }
}
