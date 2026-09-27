import Foundation
import Combine

// Saving power, Orion's Low Power Mode: the same browser, asked to spend
// less. Nothing is turned off that you would miss in the moment — the page
// in front still scrolls and plays as it did — only what runs on its own:
//
// - pages draw at 60 frames a second instead of 120 (see FrameRate),
// - tabs in the background sleep after five minutes, not thirty (see Sleep),
// - a new page waits for a click before it plays anything,
// - the light round the new tab's field and its glow stand still.
//
// By default it follows the Mac: on while macOS Low Power Mode is on
// (System Settings › Battery), off again with it.

@MainActor
final class Power: ObservableObject {
    static let shared = Power()

    enum Mode: String, CaseIterable, Identifiable {
        case withMac, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .withMac: return "With Low Power Mode"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            Store.settings.set(mode.rawValue, forKey: "power.save")
            update()
        }
    }
    /// Whether the browser is saving power right now.
    @Published private(set) var saving = false

    /// How long a background tab may wait before it sleeps while saving.
    static let sleepAfter: TimeInterval = 5 * 60

    /// `saving`, for a page's configuration, which is made off the main
    /// actor's books. Written only here, on the main thread; a page made in
    /// the moment it changes simply follows the new value at its next wake.
    nonisolated(unsafe) private(set) static var savingNow = false

    private var watcher: NSObjectProtocol?

    private init() {
        mode = Store.settings.string(forKey: "power.save").flatMap(Mode.init) ?? .withMac
        watcher = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Power.shared.update() }
        }
        update()
    }

    /// ⌘K and the menu: saving on for good, or back to following the Mac.
    func toggle() {
        mode = saving ? (mode == .always ? .withMac : .never) : .always
    }

    private func update() {
        let now: Bool
        switch mode {
        case .always: now = true
        case .never: now = false
        case .withMac: now = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        guard now != saving else { return }
        saving = now
        Power.savingNow = now
        FrameRate.saving = now
    }
}
