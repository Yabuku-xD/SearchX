import Foundation

// What uBO's syntax asks of a page that WebKit's blocker can't do, done by
// SearchX's own scripts — added to a page only when a rule for its site asks,
// and never to a sign-in, passkey or payment page (see Protected, and
// Shield.work):
//
//   • procedural cosmetic filters (:has-text, :upward, :xpath, :remove, …),
//     in SearchX's own world, where the page can't see or undo them;
//   • $csp, as a policy the document is given before its own head;
//   • $redirect: a blocked script's small stand-in, run where it failed,
//     so the page carries on as though it had loaded;
//   • $replace, on a page's fetch and XMLHttpRequest answers.
//
// Written for SearchX from uBO's documentation of each
// (github.com/gorhill/uBlock/wiki/Procedural-cosmetic-filters,
// …/Static-filter-syntax, …/Resources-Library), not copied from its code.

enum PageFilters {
    /// What one document gets, worked out before it loads.
    struct Work: Equatable {
        var procedural: [String] = []
        var csp: [String] = []
        var redirect: [[String: String]] = []
        var replace: [[String: String]] = []
        /// The page may have the stand-ins every site shares (not a protected
        /// page, blocker on).
        var shared = false
        var isEmpty: Bool { procedural.isEmpty && csp.isEmpty && redirect.isEmpty && replace.isEmpty }
    }

    /// The procedural filters for a document at \`host\`: those for it,
    /// every domain above it and their "site.*", less those turned off there.
    static func procedural(for host: String, in extras: FilterCompiler.Extras) -> [String] {
        guard !extras.procedural.isEmpty else { return [] }
        let names = siteNames(host)
        var off = Set<String>()
        for name in names { off.formUnion(extras.proceduralOff[name] ?? []) }
        var seen = Set<String>(), out: [String] = []
        for name in names {
            for selector in extras.procedural[name] ?? [] where !off.contains(selector) && seen.insert(selector).inserted {
                out.append(selector)
            }
        }
        return out
    }

    /// "a.b.example.co.uk": itself, each domain above it, and their "name.*".
    static func siteNames(_ host: String) -> [String] {
        var names: [String] = []
        var labels = host.lowercased().split(separator: ".").map(String.init)
        // "localhost", a machine's own name: itself and nothing above it.
        if labels.count == 1 { return labels }
        while labels.count >= 2 {
            names.append(labels.joined(separator: "."))
            names.append(labels.dropLast().joined(separator: ".") + ".*")
            if labels.count >= 3 { names.append(labels.dropLast(2).joined(separator: ".") + ".*") }
            labels.removeFirst()
        }
        return names
    }

    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Each document picks its own host's part of the map; a frame with no
    /// address of its own is its parent's.
    private static let pick = "var h = location.hostname; if (!h) { try { h = window.parent.location.hostname; } catch (e) {} }"
        + " var mine = Object.prototype.hasOwnProperty.call(map, h) ? map[h] : null; if (!mine) return;"

    // MARK: - procedural

    static func proceduralSource(byHost map: [String: [String]]) -> String? {
        let map = map.filter { !$0.value.isEmpty }
        guard !map.isEmpty else { return nil }
        return "(function (map) {" + pick + proceduralRuntime + "})(" + json(map) + ");"
    }

    private static let proceduralRuntime = #"""
    if (window.__searchxProcedural) return;
    Object.defineProperty(window, '__searchxProcedural', { value: true });
    var OPS = { 'has-text': 1, 'contains': 1, 'upward': 1, 'nth-ancestor': 1, 'xpath': 1, 'matches-css': 1,
      'matches-css-before': 1, 'matches-css-after': 1, 'matches-attr': 1, 'matches-path': 1, 'min-text-length': 1,
      'has': 1, 'if': 1, 'not': 1, 'if-not': 1, 'remove': 1, 'style': 1, 'remove-attr': 1, 'remove-class': 1,
      'watch-attr': 1, 'matches-media': 1, 'others': 1, 'matches-prop': 1, 'shadow': 1, '-abp-has': 1, '-abp-contains': 1 };
    var NESTED = { 'has': 1, 'if': 1, 'not': 1, 'if-not': 1, '-abp-has': 1 };
    var ACTIONS = { 'remove': 1, 'style': 1, 'remove-attr': 1, 'remove-class': 1 };
    function procedural(text) { for (var k in OPS) { if (!NESTED[k] && text.indexOf(':' + k + '(') !== -1) return true; } return false; }
    // Plain CSS and operators, in order: [{css}] and [{op, arg}].
    function tokens(s) {
      var out = [], plain = '', i = 0;
      while (i < s.length) {
        var c = s[i];
        if (c === '[') { var e = s.indexOf(']', i); if (e < 0) return null; plain += s.slice(i, e + 1); i = e + 1; continue; }
        if (c === ':') {
          var m = /^:([-a-z]+)\(/.exec(s.slice(i));
          if (m && OPS[m[1]]) {
            var start = i + m[0].length, depth = 1, j = start, q = null;
            for (; j < s.length; j++) {
              var d = s[j];
              if (q) { if (d === '\\') { j++; continue; } if (d === q) q = null; continue; }
              if (d === '"' || d === "'") { q = d; continue; }
              if (d === '(') depth++; else if (d === ')') { depth--; if (!depth) break; }
            }
            if (depth) return null;
            var arg = s.slice(start, j);
            if (NESTED[m[1]] && !procedural(arg)) { plain += s.slice(i, j + 1); i = j + 1; continue; }
            if (plain.trim()) out.push({ css: plain });
            plain = '';
            out.push({ op: m[1], arg: arg });
            i = j + 1;
            continue;
          }
        }
        plain += c; i++;
      }
      if (plain.trim()) out.push({ css: plain });
      return out;
    }
    function needle(arg) {
      var m = /^\/(.+)\/([imsu]*)$/.exec(arg.trim());
      if (m) { try { var re = new RegExp(m[1], m[2]); return function (t) { return re.test(t); }; } catch (e) { return null; } }
      var text = arg.replace(/^(["'])(.*)\1$/, '$2');
      return function (t) { return t.indexOf(text) !== -1; };
    }
    function compile(selector) {
      var list = tokens(selector);
      if (!list || !list.length) return null;
      var steps = [], action = { type: 'hide' };
      for (var i = 0; i < list.length; i++) {
        var t = list[i];
        if (t.css !== undefined) { steps.push({ css: t.css }); continue; }
        if (ACTIONS[t.op]) { if (i !== list.length - 1) return null; action = { type: t.op, arg: t.arg }; continue; }
        if (t.op === 'others' || t.op === 'matches-prop' || t.op === 'shadow') return null;
        var step = { op: t.op, arg: t.arg };
        if (t.op === 'has-text' || t.op === 'contains' || t.op === '-abp-contains' || t.op === 'matches-path') { step.test = needle(t.arg); if (!step.test) return null; }
        if (t.op === 'matches-css' || t.op === 'matches-css-before' || t.op === 'matches-css-after') {
          var at = t.arg.indexOf(':'); if (at < 0) return null;
          step.prop = t.arg.slice(0, at).trim(); step.test = needle(t.arg.slice(at + 1).trim()); if (!step.test) return null;
          step.pseudo = t.op === 'matches-css-before' ? '::before' : (t.op === 'matches-css-after' ? '::after' : null);
        }
        if (t.op === 'matches-attr') {
          var eq = t.arg.indexOf('=');
          var name = eq < 0 ? t.arg : t.arg.slice(0, eq), value = eq < 0 ? null : t.arg.slice(eq + 1);
          step.name = needle(name.replace(/^"|"$/g, '')); step.value = value === null ? null : needle(value.replace(/^"|"$/g, ''));
          if (!step.name) return null;
        }
        if (NESTED[t.op]) { step.sub = compile(/^\s*[>+~]/.test(t.arg) ? t.arg : t.arg); if (!step.sub) return null; step.relative = /^\s*[>+~]/.test(t.arg); }
        steps.push(step);
      }
      // Only an element's own selector and text/attributes can be invalidated
      // locally. Relationships, style, XPath and nested selectors keep a sweep.
      var css = steps.length && steps[0].css !== undefined ? steps[0].css.trim() : '';
      var local = css && /^(?:[a-zA-Z][\w-]*|\*)?(?:[.#][\w-]+|\[[\w-]+(?:[~|^$*]?=(?:"[^"\\]*"|'[^'\\]*'|[\w-]+))?(?:\s+[iIsS])?\])*$/.test(css)
        && steps.slice(1).every(function (s) { return /^(has-text|contains|-abp-contains|min-text-length|matches-attr|watch-attr)$/.test(s.op || ''); });
      return { steps: steps, action: action, local: local ? css : null,
        watch: list.filter(function (t) { return t.op === 'watch-attr'; }).map(function (t) { return t.arg; }) };
    }
    function unique(list) { var out = [], seen = new Set(); list.forEach(function (n) { if (n && !seen.has(n)) { seen.add(n); out.push(n); } }); return out; }
    function* run(task, from, seeds) {
      var nodes = seeds || null;
      for (var i = seeds ? 1 : 0; i < task.steps.length; i++) {
        var s = task.steps[i];
        if (s.css !== undefined) {
          var css = s.css;
          if (nodes === null) {
            var base = from || document;
            try { nodes = Array.from(from ? base.querySelectorAll(/^\s*[>+~]/.test(css) ? ':scope ' + css : css) : base.querySelectorAll(css)); } catch (e) { return []; }
          } else if (/^\s*[>+~\s]/.test(css)) {
            var next = [];
            for (var n of nodes) { try { next.push.apply(next, n.querySelectorAll(':scope ' + css.trim())); } catch (e) {} yield; }
            // A sibling combinator reaches outside the node.
            if (/^\s*[+~]/.test(css)) {
              next = [];
              for (var n of nodes) { var p = n.parentElement; if (!p) continue; try { for (var m of p.querySelectorAll(':scope > ' + css.trim().replace(/^[+~]\s*/, ''))) { if (css.trim()[0] === '+' ? n.nextElementSibling === m : (n.compareDocumentPosition(m) & 4)) next.push(m); yield; } } catch (e) {} yield; }
            }
            nodes = unique(next);
          } else {
            var matched = [];
            for (var n of nodes) { try { if (n.matches(css)) matched.push(n); } catch (e) {} yield; }
            nodes = matched;
          }
          yield;
          continue;
        }
        if (nodes === null) nodes = from ? Array.from(from.querySelectorAll('*')) : Array.from(document.querySelectorAll('body *'));
        var next = [];
        for (var n of nodes) {
        switch (s.op) {
          case 'has-text': case 'contains': case '-abp-contains':
            if (s.test(n.textContent || '')) next.push(n); break;
          case 'min-text-length':
            var min = parseInt(s.arg, 10) || 0; if ((n.textContent || '').length >= min) next.push(n); break;
          case 'upward': case 'nth-ancestor':
            var count = /^\d+$/.test(s.arg.trim()) ? parseInt(s.arg, 10) : 0;
            if (count) { var a = n; for (var k = 0; k < count && a; k++) a = a.parentElement; if (a) next.push(a); }
            else { try { var a = n.parentElement && n.parentElement.closest(s.arg); if (a) next.push(a); } catch (e) {} }
            break;
          case 'xpath':
              try { var r = document.evaluate(s.arg, n, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                for (var k = 0; k < r.snapshotLength; k++) { var x = r.snapshotItem(k); if (x && x.nodeType === 1) next.push(x); yield; } } catch (e) {}
            break;
          case 'matches-css': case 'matches-css-before': case 'matches-css-after':
            try { if (s.test(String(getComputedStyle(n, s.pseudo).getPropertyValue(s.prop)))) next.push(n); } catch (e) {} break;
          case 'matches-attr':
            if (Array.from(n.attributes).some(function (a) { return s.name(a.name) && (s.value === null || s.value(a.value)); })) next.push(n); break;
          case 'matches-path':
            if (s.test(location.pathname + location.search)) next.push(n); break;
          case 'matches-media':
            try { if (matchMedia(s.arg).matches) next.push(n); } catch (e) {} break;
          case 'has': case 'if': case '-abp-has':
            if ((yield* run(s.sub, n)).length > 0) next.push(n); break;
          case 'not': case 'if-not':
            if ((yield* run(s.sub, n)).length === 0) next.push(n); break;
          case 'watch-attr': next.push(n); break;
        }
        yield;
        }
        nodes = unique(next);
        if (!nodes.length) return [];
      }
      return nodes || [];
    }
    var tasks = [];
    mine.forEach(function (selector) { var t = compile(selector); if (t) tasks.push(t); });
    if (!tasks.length) return;
    var mark = 'searchx-veil';
    var sheet = document.createElement('style');
    sheet.textContent = '[' + mark + ']{display:none!important}';
    tasks.forEach(function (t, i) {
      if (t.action.type === 'style') {
        var rule = t.action.arg;
        if (/url\(|\/\*|\\|\/\//.test(rule)) { t.action = { type: 'none' }; return; }
        sheet.textContent += '[searchx-style-' + i + ']{' + rule + '}';
      }
    });
    function attach() { var root = document.head || document.documentElement; if (root && !sheet.isConnected) root.appendChild(sheet); }
    var shown = tasks.map(function () { return new Set(); }), hides = new WeakMap(), ownAttributes = new WeakMap();
    var marked = '[' + mark + ']' + tasks.map(function (t, i) { return t.action.type === 'style' ? ',[searchx-style-' + i + ']' : ''; }).join('');
    function connected(n) { return n.isConnected && n.ownerDocument === document; }
    function marker(n, attr, value) {
      if (n.getAttribute(attr) === value) return;
      var tracked = connected(n);
      if (value === null) n.removeAttribute(attr); else n.setAttribute(attr, value);
      if (tracked) {
        var counts = ownAttributes.get(n);
        if (!counts) { counts = new Map(); ownAttributes.set(n, counts); }
        counts.set(attr, (counts.get(attr) || 0) + 1);
      }
    }
    function release(i, n, unhide) {
      if (!shown[i].delete(n)) return;
      if (tasks[i].action.type === 'hide') {
        var count = (hides.get(n) || 1) - 1;
        if (count) hides.set(n, count); else { hides.delete(n); unhide.add(n); }
      } else marker(n, 'searchx-style-' + i, null);
    }
    function* candidates(t, i, batch) {
      var found = new Set(), visited = new Set();
      function consider(n) {
        if (!n || n.nodeType !== 1 || !connected(n)) return;
        try { if (shown[i].has(n) || n.matches(t.local)) found.add(n); } catch (e) {}
      }
      // A detached subtree can be edited before our queued work runs, then
      // returned with different selectors and none of its old markers.
      if (batch.removed) for (var n of shown[i]) { found.add(n); yield; }
      for (var changed of batch.changed) {
        for (var n = changed.nodeType === 1 ? changed : changed.parentElement; n && !visited.has(n); n = n.parentElement) {
          visited.add(n); consider(n); yield;
        }
      }
      for (var root of batch.added) {
        if (root.nodeType !== 1 || !connected(root)) continue;
        var covered = false;
        for (var p = root.parentElement; p; p = p.parentElement) { if (batch.added.has(p)) { covered = true; break; } }
        if (covered) continue;
        consider(root);
        // Include an old match whose class changed while its subtree moved.
        try { for (var n of root.querySelectorAll(t.local + ',' + marked)) { consider(n); yield; } } catch (e) {}
        yield;
      }
      return found;
    }
    function* sweep(batch, full) {
      attach();
      var unhide = new Set();
      if (batch.removed) for (var i = 0; i < tasks.length; i++) {
        for (var n of shown[i]) { if (!connected(n)) release(i, n, unhide); yield; }
      }
      for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i], affected = null, seeds = undefined;
        if (!full && !t.local && !batch.broad) continue;
        if (!full && t.local) {
          affected = yield* candidates(t, i, batch); seeds = [];
          for (var n of affected) { try { if (connected(n) && n.matches(t.local)) seeds.push(n); } catch (e) {} yield; }
        }
        var now = new Set(yield* run(t, null, seeds));
        var type = t.action.type;
        if (type === 'hide' || type === 'style') {
          var attr = type === 'hide' ? mark : 'searchx-style-' + i;
          for (var n of affected || shown[i]) { if (!now.has(n)) release(i, n, unhide); yield; }
          for (var n of now) {
            if (connected(n)) {
              if (!shown[i].has(n)) { shown[i].add(n); if (type === 'hide') hides.set(n, (hides.get(n) || 0) + 1); }
              if (!n.hasAttribute(attr)) marker(n, attr, '');
            }
            yield;
          }
        } else if (type === 'remove') {
          for (var n of now) { n.remove(); yield; }
        } else if (type === 'remove-attr' || type === 'remove-class') {
          var test = needle(t.action.arg.replace(/^"|"$/g, ''));
          for (var n of now) {
            if (type === 'remove-attr') Array.from(n.attributes).forEach(function (a) {
              if (test(a.name)) { if (markers.has(a.name)) marker(n, a.name, null); else n.removeAttribute(a.name); }
            });
            else Array.from(n.classList).forEach(function (c) { if (test(c)) n.classList.remove(c); });
            yield;
          }
        }
      }
      // A different rule may still hide the same recycled post.
      for (var n of unhide) { if (!hides.has(n)) marker(n, mark, null); yield; }
    }
    function changes() { return { added: new Set(), changed: new Set(), removed: false, broad: false }; }
    var pending = changes(), initial = true;
    // Keep the existing 4 ms cooperative budget. One DOM operation can still
    // exceed it; all rules resume, including those that need the whole page.
    var queued = false, last = 0, work = null, dirty = false;
    function chunk() {
      queued = false;
      if (!work) { dirty = false; last = Date.now(); work = sweep(pending, initial); pending = changes(); initial = false; }
      var deadline = performance.now() + 4, step;
      do { step = work.next(); } while (!step.done && performance.now() < deadline);
      if (!step.done) { queued = true; requestAnimationFrame(chunk); return; }
      work = null;
      if (dirty) soon();
    }
    function soon() {
      dirty = true;
      if (queued) return;
      queued = true;
      var wait = Math.max(0, 120 - (Date.now() - last));
      setTimeout(function () { requestAnimationFrame(chunk); }, wait);
    }
    var watched = [];
    tasks.forEach(function (t) { t.watch.forEach(function (w) { w.split(',').forEach(function (a) { if (a.trim()) watched.push(a.trim()); }); }); });
    var markers = new Set([mark]), attributes = new Set(watched), anyAttribute = false;
    tasks.forEach(function (t, i) {
      if (t.action.type === 'style') markers.add('searchx-style-' + i);
      if (!t.local) return;
      attributes.add('class'); attributes.add('id');
      for (var match of t.local.matchAll(/\[([\w-]+)/g)) { attributes.add(match[1]); attributes.add(match[1].toLowerCase()); }
      if (t.steps.some(function (s) { return s.op === 'matches-attr'; })) anyAttribute = true;
    });
    markers.forEach(function (name) { attributes.add(name); });
    function start() {
      var options = { subtree: true, childList: true, characterData: true, attributes: true };
      if (!anyAttribute) options.attributeFilter = Array.from(attributes);
      new MutationObserver(function (records) {
        var changed = false;
        for (var r of records) {
          if (r.type === 'attributes') {
            var counts = ownAttributes.get(r.target), count = counts && counts.get(r.attributeName);
            if (count) {
              if (count === 1) counts.delete(r.attributeName); else counts.set(r.attributeName, count - 1);
              if (!counts.size) ownAttributes.delete(r.target);
              continue;
            }
            if (watched.indexOf(r.attributeName) !== -1 || markers.has(r.attributeName)) pending.broad = true;
          } else pending.broad = true;
          changed = true;
          pending.changed.add(r.target);
          if (r.type === 'childList') {
            for (var n of r.addedNodes) pending.added.add(n);
            for (var n of r.removedNodes) if (n.nodeType === 1) pending.removed = true;
          }
        }
        if (changed) soon();
      }).observe(document.documentElement, options);
      soon();
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
    """#

    // MARK: - $csp

    /// The policies, given to the document before its own head arrives.
    static func cspSource(_ policies: [String]) -> String? {
        guard !policies.isEmpty else { return nil }
        return "(function (policies) { try { var head = document.head;"
            + " if (!head) { head = document.createElement('head'); document.documentElement.prepend(head); }"
            + " policies.forEach(function (p) { var m = document.createElement('meta'); m.httpEquiv = 'Content-Security-Policy';"
            + " m.content = p; head.appendChild(m); }); } catch (e) {} })(" + json(policies) + ");"
    }

    // MARK: - $redirect

    /// \`shared\`: the rules for every site, under "*" once rather than
    /// under each host.
    static func redirectSource(byHost map: [String: [[String: String]]], shared: [[String: String]]) -> String? {
        var map = map.filter { !$0.value.isEmpty }
        if !shared.isEmpty { map["*"] = shared }
        guard !map.isEmpty else { return nil }
        let wanted = Set(map.values.flatMap { $0.map { $0["value"] ?? "" } })
        let stubs = Stubs.all.filter { wanted.contains($0.key) }
        guard !stubs.isEmpty else { return nil }
        let pickBoth = "var h = location.hostname; if (!h) { try { h = window.parent.location.hostname; } catch (e) {} }"
            + " var own = Object.prototype.hasOwnProperty.call(map, h) ? map[h] : [];"
            + " var mine = own.concat(map['*'] || []); if (!mine.length) return;"
        return "(function (map, stubs) {" + pickBoth + redirectRuntime + "})(" + json(map) + ", " + json(stubs) + ");"
    }

    private static let redirectRuntime = #"""
    var rules = [], off = [];
    mine.forEach(function (r) {
      // Made into a regular expression only when a script fails.
      (r.exception ? off : rules).push({ pattern: r.pattern, value: r.value });
    });
    rules = rules.filter(function (r) { return stubs[r.value]; });
    if (!rules.length) return;
    function hits(r, url) {
      if (!r.pattern) return true;
      if (r.re === undefined) { try { r.re = new RegExp(r.pattern, 'i'); } catch (e) { r.re = null; } }
      return !!r.re && r.re.test(url);
    }
    addEventListener('error', function (event) {
      var el = event.target;
      if (!el || el.tagName !== 'SCRIPT' || !el.src) return;
      var url = el.src;
      for (var i = 0; i < rules.length; i++) {
        var r = rules[i];
        if (!hits(r, url)) continue;
        if (off.some(function (o) { return hits(o, url) && (!o.value || o.value === r.value); })) return;
        var s = document.createElement('script');
        s.textContent = stubs[r.value];
        (document.head || document.documentElement).appendChild(s);
        s.remove();
        // As though it had loaded: its own onload runs, its onerror doesn't.
        event.stopImmediatePropagation();
        el.dispatchEvent(new Event('load'));
        return;
      }
    }, true);
    """#

    /// Stand-ins for scripts the lists block, each doing just enough that a
    /// page waiting on it carries on. Written for SearchX.
    enum Stubs {
        static let all: [String: String] = [
            "noop.js": "(function(){})();",
            "noopjs": "(function(){})();",
            "googletagmanager_gtm.js": #"""
            (function(){var none=function(){};window.ga=window.ga||none;var layer=window.dataLayer;
            function answer(item){if(item&&typeof item.eventCallback==='function'){var cb=item.eventCallback;item.eventCallback=none;setTimeout(cb,1);}}
            if(layer&&typeof layer==='object'){if(layer.hide&&typeof layer.hide.end==='function'){layer.hide.end();layer.hide.end=none;}
            if(Array.isArray(layer)){layer.forEach(answer);var push=layer.push;layer.push=function(){for(var i=0;i<arguments.length;i++)answer(arguments[i]);return push.apply(layer,arguments);};}}})();
            """#,
            "google-analytics_analytics.js": #"""
            (function(){var none=function(){};function tracker(){return{get:none,set:none,send:none};}
            function ga(){var args=Array.prototype.slice.call(arguments),last=args[args.length-1],done=null;
            if(last&&typeof last==='object'&&typeof last.hitCallback==='function')done=last.hitCallback;
            else if(typeof last==='function')done=function(){last(tracker());};
            if(done){try{done();}catch(e){}}}
            ga.create=tracker;ga.getByName=tracker;ga.getAll=function(){return[tracker()];};ga.remove=none;ga.loaded=true;
            var name=window.GoogleAnalyticsObject||'ga',queue=window[name];window[name]=ga;
            if(queue&&Array.isArray(queue.q)){queue.q.splice(0).forEach(function(a){ga.apply(null,a);});}})();
            """#,
            "google-analytics_ga.js": #"""
            (function(){var none=function(){};var t=new Proxy({},{get:function(){return none;}});
            window._gat={_getTracker:function(){return t;},_createTracker:function(){return t;},_getTrackerByName:function(){return t;},_anonymizeIp:none};
            window._gaq={push:function(){for(var i=0;i<arguments.length;i++){var a=arguments[i];if(typeof a==='function'){try{a();}catch(e){}}
            else if(Array.isArray(a)&&a[0]==='_set'&&a[1]==='hitCallback'&&typeof a[2]==='function'){try{a[2]();}catch(e){}}}}};})();
            """#,
            "googlesyndication_adsbygoogle.js": "(function(){var q=window.adsbygoogle;window.adsbygoogle={loaded:true,push:function(){}};})();",
            "doubleclick_instream_ad_status.js": "window.google_ad_status=1;",
            "scorecardresearch_beacon.js": "window.COMSCORE={purge:function(){},beacon:function(){}};",
            "amazon_apstag.js": "window.apstag={init:function(){},setDisplayBids:function(){},targetingKeys:function(){return[];},fetchBids:function(c,cb){if(typeof cb==='function')setTimeout(function(){cb([]);},1);}};",
            "ampproject_v0.js": "(function(){})();",
            "fuckadblock.js-3.2.0": #"""
            (function(){function Checker(){}Checker.prototype={onDetected:function(){return this;},onNotDetected:function(f){if(typeof f==='function')setTimeout(f,1);return this;},
            on:function(d,f){if(!d)this.onNotDetected(f);return this;},check:function(){return true;},emitEvent:function(){return this;},clearEvent:function(){},setOption:function(){return this;}};
            window.FuckAdBlock=window.BlockAdBlock=window.SniffAdBlock=Checker;window.fuckAdBlock=window.blockAdBlock=window.sniffAdBlock=new Checker();})();
            """#,
        ]
    }

    // MARK: - $replace

    /// In the page's world, on the sites with rules only: fetch and XHR
    /// answers from matching addresses, rewritten. "/regex/replacement/flags".
    static func replaceSource(byHost map: [String: [[String: String]]]) -> String? {
        let map = map.filter { !$0.value.isEmpty }
        guard !map.isEmpty else { return nil }
        return "(function (map) {" + pick + replaceRuntime + "})(" + json(map) + ");"
    }

    private static let replaceRuntime = #"""
    var rules = [];
    mine.forEach(function (r) {
      if (r.exception) return;
      var m = /^\/((?:\\\/|[^\/])+)\/((?:\\\/|[^\/])*)\/([gimsu]*)$/.exec(r.value);
      if (!m) return;
      try { rules.push({ at: r.pattern ? new RegExp(r.pattern, 'i') : null, find: new RegExp(m[1], m[3]), to: m[2].replace(/\\\//g, '/') }); } catch (e) {}
    });
    if (!rules.length) return;
    function rewrite(url, text) {
      var out = text;
      rules.forEach(function (r) { if (!r.at || r.at.test(url)) out = out.replace(r.find, r.to); });
      return out;
    }
    function wanted(url) { return rules.some(function (r) { return !r.at || r.at.test(url); }); }
    var realFetch = window.fetch;
    if (typeof realFetch === 'function') {
      window.fetch = new Proxy(realFetch, { apply: function (target, self, args) {
        var p = Reflect.apply(target, self, args);
        var url = '';
        try { url = new URL(args[0] instanceof Request ? args[0].url : String(args[0]), location.href).href; } catch (e) {}
        if (!wanted(url)) return p;
        return p.then(function (response) {
          return response.clone().text().then(function (text) {
            var out = rewrite(url, text);
            if (out === text) return response;
            var made = new Response(out, { status: response.status, statusText: response.statusText, headers: response.headers });
            try { Object.defineProperty(made, 'url', { value: response.url }); } catch (e) {}
            return made;
          }, function () { return response; });
        });
      } });
    }
    var X = XMLHttpRequest.prototype, open = X.open;
    X.open = new Proxy(open, { apply: function (target, self, args) { try { self.__searchxURL = new URL(String(args[1]), location.href).href; } catch (e) {} return Reflect.apply(target, self, args); } });
    ['responseText', 'response'].forEach(function (name) {
      var d = Object.getOwnPropertyDescriptor(X, name);
      if (!d || !d.get) return;
      Object.defineProperty(X, name, { configurable: true, enumerable: d.enumerable, get: function () {
        var value = d.get.call(this);
        if (this.readyState !== 4 || typeof value !== 'string' || !this.__searchxURL || !wanted(this.__searchxURL)) return value;
        return rewrite(this.__searchxURL, value);
      } });
    });
    """#
}
