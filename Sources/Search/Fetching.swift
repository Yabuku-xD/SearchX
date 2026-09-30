import AppKit
import SwiftUI
import WebKit

// Downloads, seen while they happen.
//
// A file on its way was a word at the bottom of the window and then nothing
// until ⇧⌘J. Now the Downloads button comes by itself while something is
// downloading, and for a moment after, filling as the files come; with
// Settings › Show the Downloads button on it stays all the time. The file
// itself shows its progress in the Finder and on the Dock's Downloads stack,
// as Safari's do, the stack bouncing once it is there. Nothing is watched or
// published while nothing is downloading.

@MainActor
final class Fetches: ObservableObject {
    /// A download running, or one just done.
    @Published private(set) var showing = false
    /// How far the running ones are, together; nil while none says its size.
    @Published private(set) var fraction: Double?
    /// Everything finished, and the button says so for a moment.
    @Published private(set) var done = false

    /// How long the button stays once the last download is in.
    static let linger: TimeInterval = 5

    private final class Running {
        let download: WKDownload
        var watch: NSKeyValueObservation?
        /// The progress the Finder and the Dock read, on the file itself.
        var shown: Progress?
        init(_ download: WKDownload) { self.download = download }
    }

    private var running: [ObjectIdentifier: Running] = [:]
    private var leaving: DispatchWorkItem?

    /// A download has begun: the button comes, and follows it.
    func start(_ download: WKDownload) {
        guard running[ObjectIdentifier(download)] == nil else { return }
        let item = Running(download)
        running[ObjectIdentifier(download)] = item
        leaving?.cancel()
        leaving = nil
        done = false
        showing = true
        // Many times a second as the bytes come; the ring only moves a whole
        // percent at a time.
        item.watch = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.measure() }
        }
        measure()
    }

    /// Where the file is going, known: its progress is put on it, for the
    /// Finder's bar under the file and the Dock's Downloads stack.
    func going(_ download: WKDownload, to file: URL) {
        guard let item = running[ObjectIdentifier(download)] else { return }
        let shown = Progress(totalUnitCount: max(1, download.progress.totalUnitCount))
        shown.kind = .file
        shown.fileOperationKind = .downloading
        shown.fileURL = file
        shown.isCancellable = true
        // Cancelled from the Finder: the download stops. WebKit takes the
        // half-written file away itself.
        shown.cancellationHandler = { [weak download] in
            DispatchQueue.main.async { download?.cancel { _ in } }
        }
        shown.completedUnitCount = download.progress.completedUnitCount
        shown.publish()
        item.shown = shown
    }

    /// Arrived. The Dock's Downloads stack is told, as Safari tells it, and
    /// bounces. A private tab's file is not announced to anyone.
    func finish(_ download: WKDownload, file: URL?, quietly: Bool = false) {
        end(download)
        if let file, !quietly {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: file.path
            )
        }
        settle(succeeded: true)
    }

    /// Failed or cancelled: its progress comes off the file at once.
    func fail(_ download: WKDownload) {
        end(download)
        settle(succeeded: false)
    }

    private func end(_ download: WKDownload) {
        guard let item = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.watch?.invalidate()
        item.shown?.unpublish()
    }

    /// The last one in: the button says so, then goes. One that failed with
    /// nothing else running takes it away at once.
    private func settle(succeeded: Bool) {
        guard running.isEmpty else { return measure() }
        guard succeeded else {
            showing = false
            done = false
            fraction = nil
            return
        }
        fraction = 1
        done = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, running.isEmpty else { return }
            showing = false
            done = false
            fraction = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Fetches.linger, execute: work)
    }

    /// The running downloads, together, in whole percents; each file's own
    /// progress brought up to date on the way.
    private func measure() {
        var total: Int64 = 0
        var completed: Int64 = 0
        var sized = true
        for item in running.values {
            let progress = item.download.progress
            if progress.totalUnitCount > 0 {
                total += progress.totalUnitCount
                completed += progress.completedUnitCount
            } else {
                sized = false
            }
            if let shown = item.shown {
                if progress.totalUnitCount > 0, shown.totalUnitCount != progress.totalUnitCount {
                    shown.totalUnitCount = progress.totalUnitCount
                }
                shown.completedUnitCount = progress.completedUnitCount
            }
        }
        guard !running.isEmpty else { return }
        let now: Double? = sized && total > 0 ? (Double(completed) / Double(total) * 100).rounded() / 100 : nil
        if now != fraction { fraction = now }
    }
}

/// The Downloads button beside the other doors: there while files come and
/// a moment after, or all the time with Settings › Show the Downloads button.
/// It fills while files come, and shows an arrow a moment once they are in.
/// A click opens Downloads.
struct FetchDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var fetches: Fetches
    /// Settings › Show the Downloads button.
    let always: Bool

    @State private var hovering = false

    var body: some View {
        if fetches.showing {
            Button { browser.hoarding = true } label: {
                ZStack {
                    if fetches.done {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.ink.opacity(0.75))
                            .transition(.opacity)
                    } else if let fraction = fetches.fraction {
                        Circle()
                            .stroke(Palette.muted.opacity(0.3), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.2), value: fraction)
                    } else {
                        // No size given: turning, on Core Animation's time.
                        Ring(size: 12)
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(browser.shortcuts.tip("Downloads", "history.downloads"))
            .accessibilityLabel("Downloads")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .animation(Motion.quick, value: fetches.done)
            .animation(Motion.quick, value: hovering)
        } else if always {
            Door(icon: "arrow.down.circle", help: browser.shortcuts.tip("Downloads", "history.downloads")) { browser.hoarding = true }
                .accessibilityLabel("Downloads")
        }
    }
}
