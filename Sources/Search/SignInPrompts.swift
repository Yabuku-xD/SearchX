import Foundation

// Sign-in prompts drawn by an identity provider inside the page — Google's
// "Sign in with Google" card, One Tap, its account chooser — come in a frame
// of the provider's own, with a light line round the card that shows as a
// hard edge over any page and against the browser's own look. That line is
// taken off here, and nothing else: the card keeps its size, colours, corners
// and buttons, and any soft shadow that lifts it off the page.
//
// Found by shape, not by name: the provider's class names are generated and
// change from release to release. The card is whatever in the frame is nearly
// as wide as the frame and has a line round it — a border, an outline, or,
// as Google draws it, a shadow with no blur and a one-point spread; buttons
// and fields are narrower and are left alone. The card is marked, and a rule
// of our own for the mark does the rest: the provider rewrites the card's
// inline style as it lays it out, and would put the line straight back.

enum SignInPrompts {
    static let script = #"""
    (() => {
      const here = location.hostname, path = location.pathname;
      if (!(here === 'accounts.google.com' && path.startsWith('/gsi/'))) return;
      const mark = 'data-searchx-plain';
      const rule = document.createElement('style');
      rule.textContent = '[' + mark + '] { border-color: transparent !important; outline: none !important;'
        + ' box-shadow: var(--searchx-shadow, none) !important; }';
      (document.head || document.documentElement).appendChild(rule);
      const edged = (cs) => ['Top', 'Right', 'Bottom', 'Left'].some(side =>
        parseFloat(cs['border' + side + 'Width']) > 0 && cs['border' + side + 'Style'] !== 'none');
      // A shadow's layers, split on the commas between them and not those
      // inside a colour; a ring is one with no offset and no blur.
      const layers = (shadow) => shadow === 'none' ? [] : shadow.split(/,(?![^(]*\))/).map(s => s.trim());
      const ring = (layer) => /(^|\s)0px 0px 0px [\d.]+px/.test(layer) && !/inset/.test(layer);
      const sweep = () => {
        if (!rule.isConnected) (document.head || document.documentElement).appendChild(rule);
        const width = innerWidth;
        for (const el of document.querySelectorAll('body *')) {
          if (el.hasAttribute(mark)) continue;
          const box = el.getBoundingClientRect();
          if (box.width < width * 0.85 || box.height < 48) continue;
          const cs = getComputedStyle(el);
          const shadows = layers(cs.boxShadow);
          if (!edged(cs) && cs.outlineStyle === 'none' && !shadows.some(ring)) continue;
          const kept = shadows.filter(layer => !ring(layer));
          el.setAttribute(mark, '');
          if (kept.length) el.style.setProperty('--searchx-shadow', kept.join(', '));
        }
      };
      let queued = false;
      const soon = () => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; sweep(); });
      };
      new MutationObserver(soon).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
      addEventListener('DOMContentLoaded', soon);
      addEventListener('load', soon);
      addEventListener('resize', soon);
    })();
    """#
}
