import AppKit
import QuartzCore

// A mouse wheel's steps, played as a glide instead of a jump.
//
// Whether an event needs this is read from the event itself, never from which
// app or device sent it: a wheel step (not continuous) is eased here, and a
// continuous event — a trackpad, a Magic Mouse, or a mouse tool such as
// LinearMouse, Mos or SteerMouse set to smooth or pixel scrolling — has been
// shaped already and goes to the page untouched, so nothing is smoothed twice.
// How far a step goes is the event's own delta, so a tool's distance,
// acceleration and direction settings still apply exactly as set.
//
// Chrome's way: each step starts a curve toward where the steps so far add up
// to, 200 ms long, beginning at the speed the page already has and ending at
// rest. A single step eases in and out; on a quick spin the next step always
// arrives before the curve has finished, so the page never slows between
// notches and a spin is one steady glide. What it replaced slowed almost to a
// stop before each next notch and surged again — ten surges a second on a
// quick spin, which read as a page drawn at 15 Hz on a 120 Hz screen. A
// spring was tried next and couldn't be both quick and unbroken; WebKit's own
// scroll animator eases nothing from a wheel.
//
// It reaches the page as continuous pixel events with no gesture phase:
// WebKit scrolls them by the pixel under the pointer, as a wheel's steps
// would, without the rubber band or the swipe between pages that belong to a
// trackpad gesture. A step the other way turns it round at once. Every frame
// is placed by the clock, so a frame the main thread missed is caught up on
// the curve rather than with the rest of a step.
@MainActor
final class WheelGlide {
    /// WebKit's distance for one line of a wheel step (Scrollbar::pixelsPerLineStep),
    /// so a glide ends where the step would have jumped to.
    static let line: CGFloat = 40
    /// How long each step's curve runs: Chrome's for a wheel step.
    nonisolated static let duration: CFTimeInterval = 0.2

    /// One axis's curve: from where it was, at the speed it had, to where the
    /// steps add up to, arriving at rest.
    private struct Curve {
        var from: Double = 0
        var to: Double = 0
        var speed: Double = 0
        var began: CFTimeInterval = 0

        func at(_ now: CFTimeInterval) -> (position: Double, speed: Double, done: Bool) {
            let d = WheelGlide.duration
            let u = min(1, max(0, (now - began) / d))
            if u >= 1 { return (to, 0, true) }
            // Cubic Hermite: position from→to, speed `speed`→0.
            let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u, h01 = -2 * u * u * u + 3 * u * u
            let position = h00 * from + h10 * d * speed + h01 * to
            let d00 = 6 * u * u - 6 * u, d10 = 3 * u * u - 4 * u + 1, d01 = -6 * u * u + 6 * u
            let velocity = (d00 * from + d10 * d * speed + d01 * to) / d
            return (position, velocity, false)
        }

        mutating func retarget(by step: Double, at now: CFTimeInterval) {
            let here = at(now)
            // The other way: from here, standing still, at once.
            let turning = step * (to - here.position) < 0 || step * here.speed < 0
            from = here.position
            speed = turning ? 0 : here.speed
            to = (turning ? here.position : to) + step
            began = now
        }
    }

    private weak var view: NSView?
    private let deliver: (NSEvent) -> Void
    private var x = Curve(), y = Curve()
    /// How far the page has been sent, in whole points, on each axis.
    private var sent = CGVector.zero
    private var aim = CGPoint.zero
    private var flags: CGEventFlags = []
    private var link: CADisplayLink?

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
        let now = CACurrentMediaTime()
        if step.dx != 0 { x.retarget(by: Double(step.dx), at: now) }
        if step.dy != 0 { y.retarget(by: Double(step.dy), at: now) }
        aim = cg.location
        flags = cg.flags
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        return true
    }

    /// Lets go of the page: nothing more is sent to it.
    func stop() {
        link?.invalidate()
        link = nil
        x = Curve()
        y = Curve()
        sent = .zero
    }

    @objc private func frame(_ link: CADisplayLink) {
        // Where this frame will be seen, not when the tick arrived.
        let now = link.targetTimestamp
        let across = x.at(now), down = y.at(now)
        // Whole points, rounded from where the curve is rather than a frame's
        // share of it, so rounding never builds up into a stall or a jump.
        let reached = CGVector(dx: CGFloat(across.position.rounded()), dy: CGFloat(down.position.rounded()))
        let move = CGVector(dx: reached.dx - sent.dx, dy: reached.dy - sent.dy)
        if move.dx != 0 || move.dy != 0 {
            send(move)
            sent = reached
        }
        if across.done, down.done { stop() }
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
