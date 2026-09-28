import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for half an hour gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// When macOS says memory is short, the half hour shrinks: to five minutes on
// a warning, to nothing when it is critical.

extension Browser {
    /// How long a tab has to go without being looked at. Half an hour, or
    /// `sleep.after` in seconds — for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        let usual = set > 0 ? set : 30 * 60
        // Saving power, a tab left alone is let go of sooner (see Power).
        return Power.shared.saving ? min(usual, Power.sleepAfter) : usual
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.sleepIdle(within: event.contains(.critical) ? 0 : 5 * 60)
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.sleepAfter
        let now = Date()
        // Every window's row, and the rows of the other spaces too: parked
        // is not the same as used.
        let idle = allTabs
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab, manually: Bool = false) -> String? {
        if tab.owner?.activeID == tab.id || tab.owner?.visiblePair?.contains(tab.id) == true { return "on screen" }
        if tab.pin != nil && !manually && !prefs.pinsSleep { return "pinned" }
        if tab.bench && !(manually && Store.testing) { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        if Passkeys.shared.isPresenting { return "using a passkey" }
        if LittleWindow.holding(tab) != nil { return "in a separate window" }
        if LittleWindow.all.contains(where: { $0.tab.opener == tab.id }) { return "has an open popup" }
        // A sign-in window hands its answer back to the page that opened it.
        if tab.owner?.active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, manually: Bool = false, done: ((String) -> Void)? = nil) {
        sleepQueue.enqueue(tab, manually: manually, done: done)
    }
}

/// One snapshot pipeline at a time, including JPEG encoding. Memory pressure
/// must not start a full-size surface allocation for every resting page at once.
@MainActor
final class SleepQueue {
    @MainActor private final class Job {
        weak var tab: Tab?
        weak var page: WKWebView?
        let touched: Date
        var manually: Bool
        var completions: [(String) -> Void] = []
        init(_ tab: Tab, manually: Bool) {
            self.tab = tab
            page = tab.built
            touched = tab.touched
            self.manually = manually
        }
    }
    private weak var browser: Browser?
    private var pending: [Job] = []
    private var running: Job?

    init(browser: Browser) { self.browser = browser }

    func enqueue(_ tab: Tab, manually: Bool, done: ((String) -> Void)?) {
        guard let browser else { done?("browser closed"); return }
        if let reason = browser.awake(because: tab, manually: manually) { done?(reason); return }
        if let job = (running?.tab === tab ? running : nil) ?? pending.first(where: { $0.tab === tab }) {
            job.manually = job.manually || manually
            if let done { job.completions.append(done) }
            return
        }
        let job = Job(tab, manually: manually)
        if let done { job.completions.append(done) }
        pending.append(job)
        advance()
    }

    private func reason(_ job: Job) -> String? {
        guard let browser, let tab = job.tab,
              browser.allTabs.contains(where: { $0 === tab }) else { return "tab closed" }
        guard tab.built === job.page, job.page != nil, tab.touched == job.touched else { return "used again" }
        return browser.awake(because: tab, manually: job.manually)
    }

    private func advance() {
        guard running == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        running = job
        if let reason = reason(job) { finish(job, reason); return }
        job.tab?.unsaved { [weak self] typed in
            guard let self else { return }
            if typed { self.finish(job, "holding something typed"); return }
            if let reason = self.reason(job) { self.finish(job, reason); return }
            job.tab?.snapshot { [weak self] picture in
                guard let self else { return }
                if let reason = self.reason(job) { self.finish(job, reason); return }
                job.tab?.sleep(picture: picture)
                self.finish(job, "asleep")
            }
        }
    }

    private func finish(_ job: Job, _ result: String) {
        guard running === job else { return }
        running = nil
        job.completions.forEach { $0(result) }
        // Let input and selection changes run before starting the next page.
        DispatchQueue.main.async { [weak self] in self?.advance() }
    }
}
