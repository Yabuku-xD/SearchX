import Foundation
import WebKit

// The blocker's other half, which knows no names. Lists say which servers
// serve ads; sites that live on pop-ups move to new names every few days, and
// a list is always one step behind them. What does not change is how the
// pop-up is got past a browser that only opens windows for a click: the
// click is taken. An invisible layer over the page, a listener on the whole
// document, a link whose click also opens somewhere else, a frame that sends
// the whole tab away, a page that swaps itself for an ad behind the window it
// just opened. Each of those is a click asked to do something it was not
// aimed at, and that is what is judged here.
//
// Search's own world watches every trusted press, in every frame, before the
// page's scripts can see it, and says what it landed on: a link and where it
// goes, a control (a button, a field, anything with a role that acts), plain
// content, or an overlay — a layer covering much of the view with nothing to
// see in it. The windows and navigations that follow are then held to it:
//
//   • a window opens to the site of what was clicked: a link's own site, or,
//     from a control, anywhere (a sign-in with Google opens Google);
//   • one window per click; the second is the pop-under;
//   • plain content or an overlay opens nothing on another site, and an
//     overlay sends the tab nowhere on another site either;
//   • a frame from another site does not send the whole tab away unless a
//     link or control in it was pressed (Chrome's framebusting rule);
//   • a page that has just opened a window does not then go to another site
//     by itself (Chrome's tab-under rule);
//   • a blank window opened from plain content or an overlay closes when it
//     goes to a site other than the opener's.
//
// Same site means the same registrable domain (Public Suffix List), so a
// site's own subdomains, CDNs under its name and its own pop-ups are free.
// Everything is off on a site the blocker is paused on.

enum Intent {
    static let name = "searchIntent"

    /// What a press landed on, as the page's world cannot fake it: only
    /// trusted events are counted, and they are seen first, in Search's world.
    struct Press {
        enum Kind: String { case link, control, plain, overlay }
        var kind: Kind
        var href: URL?
        /// The frame's own host, where the press was.
        var host: String
        var main: Bool
        var at: TimeInterval
        /// Windows this press has opened.
        var opened = 0
    }

    enum Verdict: Equatable {
        case allow
        /// Allowed, but watched: a blank window from content that shows no
        /// wish to open one.
        case watch
        case block(String)
    }

    /// How long a press answers for what follows. WebKit's own window for a
    /// press is about a second; the judgment matches it.
    static let reach: TimeInterval = 1.0
    /// How long after opening a window a page's own trip elsewhere is a
    /// tab-under.
    static let tabUnder: TimeInterval = 3.0

    /// example.com for www.example.com and cdn.example.com.
    nonisolated static func site(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        return Registrable.domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    nonisolated static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let a = site(a), let b = site(b) else { return false }
        return a == b
    }

    /// A page asking for a new window.
    static func window(to url: URL?, page: String?, press: Press?, now: TimeInterval) -> Verdict {
        guard let press, now - press.at < reach else { return .allow }
        if press.opened >= 1 { return .block("a second window from one click") }
        let host = url?.host()?.lowercased()
        guard let host, !host.isEmpty, ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else {
            // about:blank, filled in by script: only its first trip says
            // where it goes.
            return press.kind == .plain || press.kind == .overlay ? .watch : .allow
        }
        if sameSite(host, press.host) || sameSite(host, page) { return .allow }
        switch press.kind {
        case .control: return .allow
        case .link:
            if let href = press.href?.host(), sameSite(href, host) { return .allow }
            return .block("a link that opened somewhere else")
        case .plain: return .block("a click on the page that opened another site")
        case .overlay: return .block("an invisible layer over the page")
        }
    }

    /// The tab itself going somewhere: `from` is the page it is on.
    static func navigation(to url: URL, from page: String?, frame: String?, mainFrame: Bool, link: Bool,
                           press: Press?, openedAt: TimeInterval?, now: TimeInterval) -> Verdict {
        guard let host = url.host()?.lowercased(), let page, !sameSite(host, page) else { return .allow }
        let fresh = press.map { now - $0.at < reach } ?? false
        // A frame sending the whole tab away.
        if !mainFrame, !sameSite(frame, page) {
            let meant = fresh && (press?.kind == .link || press?.kind == .control) && sameSite(press?.host, frame)
            if !link && !meant { return .block("a frame that tried to take over the tab") }
        }
        // Behind a window it just opened, by itself.
        if let openedAt, now - openedAt < tabUnder, !link {
            return .block("the page swapping itself for another site behind a pop-up")
        }
        // An invisible layer's click.
        if fresh, press?.kind == .overlay { return .block("an invisible layer over the page") }
        return .allow
    }

    /// Search's world, every frame, before anything of the page's.
    static let script = #"""
    (function () {
      if (window.__searchIntent) return;
      Object.defineProperty(window, '__searchIntent', { value: true });
      var post = function (m) { try { window.webkit.messageHandlers.searchIntent.postMessage(m); } catch (e) {} };
      var CONTROL = 'button,input,select,textarea,label,summary,details,[contenteditable=""],[contenteditable="true"],' +
        '[role=button],[role=link],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=tab],' +
        '[role=option],[role=checkbox],[role=radio],[role=switch],[role=slider],[role=combobox],[role=textbox]';
      function hrefOf(a) {
        var h = a.href;
        if (h && typeof h === 'object') { try { h = h.baseVal ? new URL(h.baseVal, a.baseURI).href : ''; } catch (e) { h = ''; } }
        return h || '';
      }
      // Covers much of the view and shows nothing: no text, no picture, no
      // colour of its own, or next to no opacity.
      function hollow(el) {
        var w = innerWidth || 1, h = innerHeight || 1;
        for (var i = 0, node = el; node && node.nodeType === 1 && i < 4; i++, node = node.parentElement) {
          var r = node.getBoundingClientRect();
          var share = Math.max(0, Math.min(r.right, w) - Math.max(r.left, 0)) * Math.max(0, Math.min(r.bottom, h) - Math.max(r.top, 0)) / (w * h);
          var cs = getComputedStyle(node);
          if (share >= 0.3 && parseFloat(cs.opacity) < 0.1) return true;
          // A card's own stretched link covers the card; an ad's layer
          // covers the view.
          if (share < 0.6) continue;
          var tag = node.tagName;
          if (/^(IMG|VIDEO|CANVAS|SVG|PICTURE|IFRAME|OBJECT|EMBED)$/.test(tag)) return false;
          var colour = cs.backgroundColor.split(' ').join('');
          var clear = cs.backgroundImage === 'none' && (colour === 'transparent' || colour.slice(-3) === ',0)');
          var empty = !(node.textContent || '').trim() && !node.querySelector('img,video,canvas,svg,picture');
          var lifted = cs.position === 'fixed' || cs.position === 'absolute';
          if (clear && empty && lifted) return true;
          return false;
        }
        return false;
      }
      function tell(target) {
        var el = target && target.nodeType === 1 ? target : (target && target.parentElement);
        if (!el) return;
        var kind = 'plain', href = '';
        var a = el.closest ? el.closest('a[href],area[href]') : null;
        if (a) { kind = 'link'; href = hrefOf(a); }
        else if (el.closest && el.closest(CONTROL)) kind = 'control';
        if (hollow(el)) kind = 'overlay';
        post({ kind: kind, href: href, host: location.hostname, main: window === window.top });
      }
      addEventListener('pointerdown', function (e) {
        if (!e.isTrusted) return;
        var path = e.composedPath ? e.composedPath() : [];
        tell(path.length ? path[0] : e.target);
      }, true);
      addEventListener('keydown', function (e) {
        if (!e.isTrusted || (e.key !== 'Enter' && e.key !== ' ')) return;
        tell(document.activeElement);
      }, true);
    })();
    """#
}
