#if DEBUG
import AppKit
import QuartzCore

/// Test runs only: main-thread callback timing, not compositor presentation.
@MainActor
final class Hitches: NSObject {
    static let shared = Hitches()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var expectedMs: Double = 0
    private var displayIntervals: [Double] = []
    private var started: CFTimeInterval = 0

    func start(on screen: NSScreen?) {
        link?.invalidate()
        gaps = []
        displayIntervals = []
        expectedMs = 0
        last = 0
        started = CACurrentMediaTime()
        guard let screen else { return }
        expectedMs = 1000 / Double(max(1, screen.maximumFramesPerSecond))
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { gaps.append((now - last) * 1000) }
        if link.duration > 0 { displayIntervals.append(link.duration * 1000) }
        last = now
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        // Never calibrate the budget to the observed callback median: a
        // consistently stalled main thread would then look perfectly smooth.
        let frame = expectedMs
        let display = displayIntervals.sorted()
        return [
            "ticks": gaps.count,
            "medianMs": pct(0.5),
            "targetMs": frame,
            "targetHz": frame > 0 ? 1000 / frame : 0,
            "targetSource": "screen maximum refresh rate",
            "callbackHz": gaps.isEmpty ? 0 : 1000 * Double(gaps.count) / gaps.reduce(0, +),
            "displayIntervalMs": display.isEmpty ? 0 : display[display.count / 2],
            "p99Ms": pct(0.99),
            "worstMs": sorted.last ?? 0,
            // Late callbacks relative to the nominal display period.
            "missed": frame > 0 ? gaps.filter { $0 > frame * 1.5 }.count : 0,
            "missedFrames": frame > 0 ? gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) } : 0,
            "seconds": CACurrentMediaTime() - started,
        ]
    }
}
#endif
