import AppKit
import WebKit

// Screenshot one element of a page (#308), the way the element-hiding picker
// works (see Curtain.swift): pick from the menu, hover to highlight, click,
// and the picture of that element goes wherever you put it. Nothing is
// written on its own — an NSSavePanel, or the clipboard.
//
// What this file believes: nothing the page says about its own elements. No
// CSS selector is read from it or written back into it; what is used is where
// the pointer landed and what box that thing has, read at the click.
//
// The picker runs in Search's own content world, so the page cannot read its
// state or call its functions. The document itself is shared, so a page can
// rearrange it between the click and the snapshot below; that is why the box
// is read on the click and clamped to what the view is showing, and why a
// page that moves something after the click can still mis-crop.

enum ElementCapture {
    /// Where a capture goes once the person has it. Tab.captureDestination
    /// carries the choice; a pick arriving with none waiting is refused.
    enum Destination {
        case clipboard
        case file
    }

    /// The highlight that follows the pointer, and the element under it.
    /// Asleep until asked for, as the picker in Curtain.swift is.
    static let picker = """
(function () {
  if (window.__officeShot) return window.__officeShot;
  var frame = null, live = false;

  function chrome() {
    if (frame) return frame;
    frame = document.createElement('div');
    frame.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;' +
      'border:2px solid rgba(23,23,23,.92);background:rgba(23,23,23,.06);' +
      'border-radius:4px;display:none';
    document.documentElement.appendChild(frame);
    return frame;
  }

  function box(el) { return el.getBoundingClientRect(); }

  function show(el) {
    var b = chrome(), r = box(el);
    b.style.display = 'block';
    b.style.left = r.left + 'px';
    b.style.top = r.top + 'px';
    b.style.width = r.width + 'px';
    b.style.height = r.height + 'px';
  }

  function hide() { if (frame) frame.style.display = 'none'; }

  /// What the pointer is on. An element with no box of its own — a collapsed
  /// node, an empty span — is passed over for the nearest thing above it with
  /// one, because there is no picture of something with no area.
  function under(x, y) {
    var el = document.elementFromPoint(x, y);
    while (el && el !== document.documentElement) {
      var r = box(el);
      if (r.width > 0 && r.height > 0) return el;
      el = el.parentElement;
    }
    return null;
  }

  var self = {
    on: function () {
      if (live) return true;
      live = true;
      // Capture, as the hiding picker does: the page's own handlers run
      // afterwards, and only for events left to them.
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', take, true);
      document.addEventListener('keydown', key, true);
      return true;
    },
    off: function () {
      live = false;
      document.removeEventListener('mousemove', move, true);
      document.removeEventListener('click', take, true);
      document.removeEventListener('keydown', key, true);
      hide();
      return true;
    }
  };

  function move(e) {
    if (!live) return;
    var el = under(e.clientX, e.clientY);
    if (!el) { hide(); return; }
    show(el);
  }

  /// Where the pointer landed, read here rather than carried over from the
  /// last mousemove: a click without a first move still gets the element
  /// under the pointer.
  function take(e) {
    if (!live) return;
    var el = under(e.clientX, e.clientY);
    if (!el) return;
    var r = box(el);
    // A link would otherwise navigate the tab away, and the element with it,
    // between the click and the snapshot.
    e.preventDefault();
    e.stopImmediatePropagation();
    var relay = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.officeShot;
    if (relay) relay.postMessage({ left: r.left, top: r.top, width: r.width, height: r.height });
    self.off();
  }

  function key(e) {
    if (!live) return;
    if (e.key === 'Escape' || e.keyCode === 27) {
      e.preventDefault();
      e.stopImmediatePropagation();
      var relay = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.officeShot;
      if (relay) relay.postMessage({ cancelled: true });
      self.off();
    }
  }

  window.__officeShot = self;
  return self;
})()
"""

    /// The box, as the picker posted it. Nil when it is not one: finite,
    /// and with area on both sides.
    ///
    /// A negative left or top is a normal partly-scrolled element and is left
    /// alone; whether any of it is on screen is the snapshot's business, not
    /// the picker's. Only a box with no area is refused here.
    static func rect(from body: [String: Any]) -> CGRect? {
        guard let left = body["left"] as? Double, let top = body["top"] as? Double,
              let width = body["width"] as? Double, let height = body["height"] as? Double,
              left.isFinite, top.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0
        else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    /// The box, in this web view's pixels, clamped to what the view is
    /// showing. The picker deals in CSS pixels of the layout viewport; a
    /// snapshot rect is in the view's own coordinates at the page's zoom. An
    /// element scrolled partly out of view keeps the part that is on screen.
    static func snapshotRect(_ rect: CGRect, in web: WKWebView) -> CGRect? {
        let zoom = web.pageZoom
        guard zoom.isFinite, zoom > 0 else { return nil }
        let wanted = CGRect(
            x: rect.origin.x * zoom, y: rect.origin.y * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        )
        let shown = wanted.intersection(web.bounds)
        guard !shown.isNull, !shown.isEmpty else { return nil }
        return shown
    }

    /// The picture of one element, or nothing when it could not be had. Only
    /// this web view's own snapshot is used, and only the box asked for.
    @MainActor
    static func capture(_ rect: CGRect, in web: WKWebView) async -> NSImage? {
        guard let wanted = snapshotRect(rect, in: web) else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = wanted
        guard let shot = try? await web.takeSnapshot(configuration: configuration) else { return nil }
        return shot
    }
}

/// Carries the picked box back from the page. Only Search's own script can
/// post here, and only the page's main frame is heard: an element inside an
/// iframe has no box of its own in this frame's viewport, so it is refused
/// rather than captured at the wrong offset.
final class ShotRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeShot"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let tab, message.frameInfo.isMainFrame else { return }
            guard let body = message.body as? [String: Any] else { return }
            if body["cancelled"] as? Bool == true {
                // Disarm before saying so. The window has cleared
                // captureDestination by now, so a pick arriving twice — a
                // double-click — is refused below rather than starting a
                // capture for a choice nobody made.
                ElementPicker.stop(in: tab)
                tab.captureCancelled?(tab)
                return
            }
            // No destination waiting is not one to act on: the window has put
            // the picker away already, or never asked for one.
            guard tab.captureDestination != nil else { return }
            guard let rect = ElementCapture.rect(from: body) else {
                tab.captureFailed?(tab, "Nothing there to capture")
                return
            }
            tab.capturePicked?(tab, rect)
        }
    }
}

/// The picker, as the window drives it.
@MainActor
enum ElementPicker {
    /// Arm it. The page's own clicks are taken from it while it is armed, so
    /// a link cannot navigate the tab out from under a capture.
    static func start(in tab: Tab) {
        // The picker is the body of the expression, not a name resolved
        // later: evaluateInSearch hands its string to evaluateJavaScript as
        // it stands, so a top-level return would be a syntax error and an
        // escaped interpolation would reach the page as literal text.
        //
        // The error is not swallowed. A page that has gone away, or one whose
        // world has been cleared, produces an error here and nothing further:
        // the window is told, and that is what clears captureDestination, so a
        // picker armed in a page nobody is looking at cannot leave one waiting
        // for a click that will never come.
        tab.web.evaluateJavaScript(
            "(window.__officeShot || (\(ElementCapture.picker))) && window.__officeShot.on()",
            in: nil, in: Web.world
        ) { [weak tab] result in
            MainActor.assumeIsolated {
                guard case .failure = result, let tab else { return }
                tab.captureDestination = nil
                tab.captureFailed?(tab, "Couldn't start picking on this page")
            }
        }
    }

    /// Disarm it, wherever it got to. Never wakes a sleeping tab: it only
    /// touches a page that is already built.
    static func stop(in tab: Tab) {
        guard let web = tab.built else { return }
        web.evaluateJavaScript(
            "window.__officeShot && window.__officeShot.on ? window.__officeShot.off() : true",
            in: nil, in: Web.world
        ) { _ in }
    }
}
