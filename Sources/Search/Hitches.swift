#if DEBUG
import AppKit
import QuartzCore

/// Test runs only: how late the main thread answered each display tick.
@MainActor
final class Hitches: NSObject {
    static let shared = Hitches()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var busy: CFTimeInterval = 0
    private var started: CFTimeInterval = 0

    func start(on screen: NSScreen?) {
        link?.invalidate()
        gaps = []
        last = 0
        started = CACurrentMediaTime()
        guard let screen else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { gaps.append((now - last) * 1000) }
        last = now
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let frame = sorted.isEmpty ? 8.33 : sorted[sorted.count / 2]
        return [
            "ticks": gaps.count,
            "medianMs": frame,
            "p99Ms": pct(0.99),
            "worstMs": sorted.last ?? 0,
            // A tick more than half a frame late missed its frame.
            "missed": gaps.filter { $0 > frame * 1.5 }.count,
            "seconds": CACurrentMediaTime() - started,
        ]
    }
}
#endif
