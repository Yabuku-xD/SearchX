import Foundation

// uBO's scriptlets: small patches a filter list asks for on a site, run in
// the page's own world before its scripts, for what a network rule cannot
// reach — a pop-up opened from a script, an anti-adblock check, a timer that
// brings the overlay back. Written for Search from uBO's documented
// behaviour (github.com/gorhill/uBlock/wiki/Resources-Library), not copied
// from its code. A scriptlet this does not know is skipped; trusted-* ones,
// which uBO runs only from its own trusted lists, are not run at all.
//
// Only a site whose lists ask for one gets any: the rest of the web sees
// nothing of this.

enum Scriptlets {
    /// The page-world source for a page and its frames: each document runs
    /// the calls for its own host. A frame with no address of its own
    /// (about:blank, written by a script) is its parent's. Nil when no host
    /// on the page has any.
    static func source(byHost map: [String: [[String]]]) -> String? {
        let map = map.filter { !$0.value.isEmpty }
        guard !map.isEmpty, let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(function (map) { var h = location.hostname;"
            + " if (!h) { try { h = window.parent.location.hostname; } catch (e) {} }"
            + " var calls = Object.prototype.hasOwnProperty.call(map, h) ? map[h] : null; if (!calls) return;\n"
            + runtime + "(calls); })(" + json + ");"
    }

    /// The calls for a page at this host, from a compiled table: the host and
    /// every domain above it, their "site.*" entities, the generic ones, less
    /// what an exception turned off there. `top` is the page a frame is
    /// on, for the lists' "site>>" (the site and every frame on its pages).
    static func calls(for host: String, top: String? = nil, in table: FilterCompiler.ScriptletTable) -> [[String]] {
        let host = host.lowercased()
        var names = Scriptlets.names(host)
        if let top = top?.lowercased() { names += Scriptlets.names(top).map { $0 + ">>" } }
        var off = Set<String>()
        for name in names { off.formUnion(table.off[name] ?? []) }
        if off.contains("") { return [] }
        var seen = Set<Int>()
        var picked: [Int] = []
        for name in names { for index in table.byHost[name] ?? [] where seen.insert(index).inserted { picked.append(index) } }
        for index in table.generic where seen.insert(index).inserted {
            let excluded = table.except[index] ?? []
            if excluded.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { continue }
            picked.append(index)
        }
        return picked.map { table.calls[$0] }.filter { !off.contains($0.joined(separator: ",")) }
    }

    /// The host, every domain above it, and their "site.*" entities.
    private static func names(_ host: String) -> [String] {
        var names: [String] = []
        var labels = host.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            names.append(labels.joined(separator: "."))
            // "site.co.uk" and "site.com" are both "site.*".
            names.append(labels.dropLast().joined(separator: ".") + ".*")
            if labels.count >= 3 { names.append(labels.dropLast(2).joined(separator: ".") + ".*") }
            labels.removeFirst()
        }
        return names
    }

    static let runtime = #"""
(function (calls) {
  'use strict';
  if (window.__searchScriptlets) return;
  Object.defineProperty(window, '__searchScriptlets', { value: true });
  var W = window, D = document;
  var fnToString = Function.prototype.toString;
  var hasOwn = Object.prototype.hasOwnProperty;

  // A needle as uBO writes it: "text", "/regex/flags", "!" for the opposite.
  function needle(raw) {
    raw = raw == null ? '' : String(raw);
    var not = false;
    if (raw.charAt(0) === '!') { not = true; raw = raw.slice(1); }
    var test;
    var m = /^\/(.+)\/([gimsu]*)$/.exec(raw);
    if (m) { try { var re = new RegExp(m[1], m[2]); test = function (s) { return re.test(s); }; } catch (e) { test = function () { return false; }; } }
    else if (raw === '' || raw === '*') { test = function () { return true; }; }
    else { test = function (s) { return String(s).indexOf(raw) !== -1; }; }
    return { any: raw === '' || raw === '*', test: function (s) { var r = test(String(s)); return not ? !r : r; } };
  }
  function text(fn) { try { return typeof fn === 'function' ? fnToString.call(fn) : String(fn); } catch (e) { return ''; } }
  function value(raw) {
    switch (raw) {
      case 'undefined': return undefined;
      case 'null': return null;
      case 'true': return true;
      case 'false': return false;
      case 'noopFunc': return function () {};
      case 'trueFunc': return function () { return true; };
      case 'falseFunc': return function () { return false; };
      case 'throwFunc': return function () { throw new Error(); };
      case 'emptyArr': case '[]': return [];
      case 'emptyObj': case '{}': return {};
      case "''": case 'emptyStr': case '': return '';
      case 'noopCallbackFunc': return function () { return function () {}; };
      case 'noopPromiseResolve': return function () { return Promise.resolve(); };
      case 'noopPromiseReject': return function () { return Promise.reject(); };
      case 'yes': return 'yes';
      case 'no': return 'no';
      case '-1': return -1;
    }
    if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
    return undefined;
  }
  function magic() { return String.fromCharCode(Date.now() % 26 + 97) + Math.floor(Math.random() * 982451653 + 982451653).toString(36); }

  // Defines a trap on a dotted chain, waiting for the pieces that do not
  // exist yet: "a.b.c" set once "a" and "a.b" appear.
  function chain(path, handler) {
    var parts = path.split('.');
    function at(owner, i) {
      var prop = parts[i];
      if (i === parts.length - 1) { handler(owner, prop); return; }
      var current = owner[prop];
      if (current instanceof Object || (typeof current === 'object' && current !== null)) { at(current, i + 1); return; }
      var descriptor = Object.getOwnPropertyDescriptor(owner, prop);
      if (descriptor && descriptor.configurable === false) return;
      var stored = current;
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () { return stored; },
          set: function (v) { stored = v; if (v instanceof Object) at(v, i + 1); }
        });
      } catch (e) {}
    }
    at(W, 0);
  }

  var runners = {
    'set-constant': function (path, raw) {
      if (!path) return;
      var v = value(raw);
      if (v === undefined && raw !== 'undefined') return;
      chain(path, function (owner, prop) {
        var descriptor = Object.getOwnPropertyDescriptor(owner, prop);
        if (descriptor && descriptor.configurable === false) return;
        try {
          Object.defineProperty(owner, prop, { configurable: false, get: function () { return v; }, set: function () {} });
        } catch (e) {}
      });
    },
    'abort-on-property-read': function (path) {
      if (!path) return;
      var tag = magic();
      chain(path, function (owner, prop) {
        try { Object.defineProperty(owner, prop, { configurable: false, get: function () { throw new ReferenceError(tag); }, set: function () {} }); } catch (e) {}
      });
      guardErrors(tag);
    },
    'abort-on-property-write': function (path) {
      if (!path) return;
      var tag = magic();
      chain(path, function (owner, prop) {
        try { Object.defineProperty(owner, prop, { configurable: false, get: function () { return undefined; }, set: function () { throw new ReferenceError(tag); } }); } catch (e) {}
      });
      guardErrors(tag);
    },
    'abort-current-script': function (path, search) {
      if (!path) return;
      var tag = magic(), match = needle(search);
      chain(path, function (owner, prop) {
        var descriptor = Object.getOwnPropertyDescriptor(owner, prop) || {};
        var stored = descriptor.get ? undefined : owner[prop];
        function check() {
          var s = D.currentScript;
          if (!(s instanceof HTMLScriptElement)) return;
          var body = s.src ? s.src : s.textContent;
          if (match.any || match.test(body)) throw new ReferenceError(tag);
        }
        try {
          Object.defineProperty(owner, prop, {
            configurable: true,
            get: function () { check(); return descriptor.get ? descriptor.get.call(this) : stored; },
            set: function (v) { check(); if (descriptor.set) descriptor.set.call(this, v); else stored = v; }
          });
        } catch (e) {}
      });
      guardErrors(tag);
    },
    'abort-on-stack-trace': function (path, search) {
      if (!path || !search) return;
      var tag = magic(), match = needle(search);
      chain(path, function (owner, prop) {
        var stored = owner[prop];
        function check() { if (match.test(new Error().stack || '')) throw new ReferenceError(tag); }
        try {
          Object.defineProperty(owner, prop, { configurable: true,
            get: function () { check(); return stored; }, set: function (v) { check(); stored = v; } });
        } catch (e) {}
      });
      guardErrors(tag);
    },
    'no-window-open-if': function (search, delay, decoy) {
      var match = needle(search);
      var original = W.open;
      W.open = new Proxy(original, {
        apply: function (target, self, args) {
          var url = String(args[0] || '');
          if (!match.test(url)) return Reflect.apply(target, self, args);
          if (delay === undefined || delay === '') return null;
          // A stand-in window, so a page that checks for one carries on.
          var frame = D.createElement(decoy === 'obj' ? 'object' : 'iframe');
          frame.style.cssText = 'display:none!important';
          (D.body || D.documentElement).appendChild(frame);
          setTimeout(function () { frame.remove(); }, (parseInt(delay, 10) || 1) * 1000);
          return frame.contentWindow || { closed: false, close: function () {}, focus: function () {}, location: {} };
        }
      });
    },
    'no-setTimeout-if': function (search, delay) { timer('setTimeout', search, delay); },
    'no-setInterval-if': function (search, delay) { timer('setInterval', search, delay); },
    'adjust-setTimeout': function (search, delay, factor) { adjust('setTimeout', search, delay, factor, 1000); },
    'adjust-setInterval': function (search, delay, factor) { adjust('setInterval', search, delay, factor, 1000); },
    'prevent-addEventListener': function (type, search) {
      var types = needle(type), match = needle(search);
      var original = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = new Proxy(original, {
        apply: function (target, self, args) {
          if (types.test(args[0]) && match.test(text(args[1]))) return;
          return Reflect.apply(target, self, args);
        }
      });
    },
    'no-fetch-if': function (props) {
      if (!props) return;
      var wanted = conditions(props);
      var original = W.fetch;
      if (!original) return;
      W.fetch = new Proxy(original, {
        apply: function (target, self, args) {
          var details = request(args[0], args[1]);
          if (!matches(wanted, details)) return Reflect.apply(target, self, args);
          return Promise.resolve(new Response('', { status: 200, statusText: 'OK' }));
        }
      });
    },
    'no-xhr-if': function (props) {
      if (!props) return;
      var wanted = conditions(props);
      var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__searchBlocked = matches(wanted, { url: String(url), method: String(method) });
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        if (!this.__searchBlocked) return send.apply(this, arguments);
        var xhr = this;
        Object.defineProperties(xhr, {
          readyState: { value: 4, configurable: true }, status: { value: 200, configurable: true },
          responseText: { value: '', configurable: true }, response: { value: '', configurable: true }
        });
        setTimeout(function () {
          xhr.dispatchEvent(new Event('readystatechange'));
          xhr.dispatchEvent(new Event('load'));
          xhr.dispatchEvent(new Event('loadend'));
        }, 1);
      };
    },
    'noeval-if': function (search) {
      var match = needle(search);
      var original = W.eval;
      W.eval = new Proxy(original, { apply: function (target, self, args) {
        if (match.test(args[0])) return undefined;
        return Reflect.apply(target, self, args);
      } });
    },
    'noeval': function () { runners['noeval-if'](''); },
    'json-prune': function (prune, needed) {
      if (!prune) return;
      var paths = prune.split(/ +/), required = needed ? needed.split(/ +/) : [];
      function clean(object) {
        if (!(object instanceof Object)) return object;
        if (required.length && !required.every(function (p) { return has(object, p); })) return object;
        paths.forEach(function (p) { remove(object, p.split('.')); });
        return object;
      }
      var parse = JSON.parse;
      JSON.parse = new Proxy(parse, { apply: function (target, self, args) { return clean(Reflect.apply(target, self, args)); } });
      var json = Response.prototype.json;
      Response.prototype.json = new Proxy(json, { apply: function (target, self, args) {
        return Reflect.apply(target, self, args).then(clean);
      } });
    },
    'remove-node-text': function (nodeName, search) { nodeText(nodeName, search, null); },
    'replace-node-text': function (nodeName, pattern, replacement) { nodeText(nodeName, pattern, replacement || ''); },
    'remove-attr': function (attrs, selector, behavior) { attributes(attrs, selector, behavior, function (el, name) { writeAttribute(el, name, null); }); },
    'remove-class': function (classes, selector, behavior) {
      if (!classes) return;
      var names = classes.split(/\s*\|\s*/);
      var target = selector || names.map(function (c) { return '.' + CSS.escape(c); }).join(',');
      settle(behavior, target, function (el) {
        names.forEach(function (c) {
          if (!el.classList.contains(c)) return;
          var tracked = connected(el); el.classList.remove(c);
          if (tracked) ownAttribute(el, 'class');
        });
      }, ['class']);
    },
    'set-attr': function (selector, attr, raw) {
      if (!selector || !attr) return;
      settle('stay', selector, function (el) { writeAttribute(el, attr, raw || ''); }, [attr]);
    },
    'set-local-storage-item': function (key, raw) { storage(W.localStorage, key, raw); },
    'set-session-storage-item': function (key, raw) { storage(W.sessionStorage, key, raw); },
    'set-cookie': function (name, raw, path) {
      if (!name) return;
      var v = { 'true': 'true', 'false': 'false', 'yes': 'yes', 'no': 'no', 'ok': 'ok', 'accept': 'accept', 'reject': 'reject',
                'allow': 'allow', 'deny': 'deny', 'on': 'on', 'off': 'off', '0': '0', '1': '1', '': '' }[raw];
      if (v === undefined && !/^\d+$/.test(raw)) return;
      if (v === undefined) v = raw;
      D.cookie = encodeURIComponent(name) + '=' + encodeURIComponent(v) + '; path=' + (path === 'none' ? location.pathname : '/');
    },
    'remove-cookie': function (search) {
      var match = needle(search);
      function sweep() {
        D.cookie.split(';').forEach(function (pair) {
          var name = pair.split('=')[0].trim();
          if (!name || !match.test(name)) return;
          var expired = name + '=; Max-Age=-1000; path=/';
          D.cookie = expired;
          D.cookie = expired + '; domain=' + location.hostname;
          D.cookie = expired + '; domain=.' + location.hostname.split('.').slice(-2).join('.');
        });
      }
      sweep();
      W.addEventListener('beforeunload', sweep);
    },
    'nowebrtc': function () {
      var stub = function () { return { close: function () {}, createDataChannel: function () {}, createOffer: function () { return Promise.resolve(); }, setRemoteDescription: function () { return Promise.resolve(); } }; };
      ['RTCPeerConnection', 'webkitRTCPeerConnection'].forEach(function (name) { if (W[name]) W[name] = stub; });
    },
    'window.name-defuser': function () { if (W === W.top) W.name = ''; },
    'disable-newtab-links': function () {
      D.addEventListener('click', function (e) {
        var a = e.target && e.target.closest && e.target.closest('a[target="_blank"]');
        if (a) { e.preventDefault(); location.href = a.href; }
      }, true);
    },
    'close-window': function (search) { if (needle(search).test(location.pathname + location.search)) W.close(); },
    'prevent-refresh': function () {
      settle('stay', 'meta[http-equiv="refresh" i]', function (m) { m.remove(); });
    },
    'href-sanitizer': function (selector, source) {
      if (!selector) return;
      settle('stay', selector, function (a) {
          var next = null;
          if (!source || source === 'text') next = (a.textContent || '').trim();
          else if (source.charAt(0) === '?') { try { next = new URL(a.href).searchParams.get(source.slice(1)); } catch (e) {} }
          else if (source.charAt(0) === '[') next = a.getAttribute(source.slice(1, -1));
          if (next && /^https?:\/\//.test(next)) writeAttribute(a, 'href', next);
      }, ['href'].concat(source && source.charAt(0) === '[' ? [source.slice(1, -1)] : []));
    }
  };
  // uBO's short names.
  var aliases = {
    'set': 'set-constant', 'aopr': 'abort-on-property-read', 'aopw': 'abort-on-property-write',
    'acs': 'abort-current-script', 'acis': 'abort-current-script', 'abort-current-inline-script': 'abort-current-script',
    'aost': 'abort-on-stack-trace', 'nowoif': 'no-window-open-if', 'prevent-window-open': 'no-window-open-if',
    'window.open-defuser': 'no-window-open-if', 'nostif': 'no-setTimeout-if', 'prevent-setTimeout': 'no-setTimeout-if',
    'setTimeout-defuser': 'no-setTimeout-if', 'nosiif': 'no-setInterval-if', 'prevent-setInterval': 'no-setInterval-if',
    'setInterval-defuser': 'no-setInterval-if', 'nano-stb': 'adjust-setTimeout', 'nano-setTimeout-booster': 'adjust-setTimeout',
    'nano-sib': 'adjust-setInterval', 'nano-setInterval-booster': 'adjust-setInterval', 'aeld': 'prevent-addEventListener',
    'addEventListener-defuser': 'prevent-addEventListener', 'prevent-fetch': 'no-fetch-if', 'prevent-xhr': 'no-xhr-if',
    'prevent-eval-if': 'noeval-if', 'rmnt': 'remove-node-text', 'rpnt': 'replace-node-text', 'ra': 'remove-attr',
    'rc': 'remove-class', 'cookie-remover': 'remove-cookie', 'refresh-defuser': 'prevent-refresh'
  };

  // Errors this raised on purpose stay out of the page's own error handlers.
  var tags = [];
  function guardErrors(tag) {
    if (tags.push(tag) > 1) return;
    W.addEventListener('error', function (e) {
      if (typeof e.message === 'string' && tags.some(function (t) { return e.message.indexOf(t) !== -1; })) {
        e.preventDefault(); e.stopImmediatePropagation();
      }
    }, true);
  }
  function timer(name, search, delay) {
    var match = needle(search);
    var wantDelay = delay !== undefined && delay !== '' ? parseInt(String(delay).replace('!', ''), 10) : null;
    var notDelay = String(delay || '').charAt(0) === '!';
    var original = W[name];
    W[name] = new Proxy(original, { apply: function (target, self, args) {
      var body = text(args[0]);
      var delayHit = wantDelay === null || ((Number(args[1]) || 0) === wantDelay) !== notDelay;
      if (match.test(body) && delayHit) return 0;
      return Reflect.apply(target, self, args);
    } });
  }
  function adjust(name, search, delay, factor, fallback) {
    var match = needle(search);
    var wantDelay = delay === '*' || delay === undefined || delay === '' ? null : parseInt(delay, 10) || fallback;
    var scale = parseFloat(factor);
    if (!(scale > 0 && scale < 50)) scale = 0.05;
    var original = W[name];
    W[name] = new Proxy(original, { apply: function (target, self, args) {
      if (match.test(text(args[0])) && (wantDelay === null || Number(args[1]) === wantDelay)) args[1] = Math.max(0, (Number(args[1]) || 0) * scale);
      return Reflect.apply(target, self, args);
    } });
  }
  function conditions(props) {
    var out = {};
    props.split(/\s+/).forEach(function (pair) {
      if (!pair) return;
      var i = pair.indexOf(':');
      if (i === -1) out.url = needle(pair);
      else out[pair.slice(0, i)] = needle(pair.slice(i + 1));
    });
    return out;
  }
  function request(input, init) {
    var out = { url: '', method: 'GET' };
    try {
      if (input instanceof Request) { out.url = input.url; out.method = input.method; }
      else out.url = String(input);
      if (init && init.method) out.method = String(init.method);
    } catch (e) {}
    return out;
  }
  function matches(wanted, details) {
    for (var k in wanted) {
      if (!hasOwn.call(wanted, k)) continue;
      if (!wanted[k].test(details[k] === undefined ? '' : details[k])) return false;
    }
    return true;
  }
  function has(object, path) {
    var o = object, parts = path.split('.');
    for (var i = 0; i < parts.length; i++) { if (!(o instanceof Object) || !(parts[i] in o)) return false; o = o[parts[i]]; }
    return true;
  }
  function remove(object, parts) {
    if (!(object instanceof Object)) return;
    var head = parts[0];
    if (parts.length === 1) {
      if (head === '*') Object.keys(object).forEach(function (k) { delete object[k]; });
      else delete object[head];
      return;
    }
    if (head === '*' || head === '[]') { Object.keys(object).forEach(function (k) { remove(object[k], parts.slice(1)); }); return; }
    remove(object[head], parts.slice(1));
  }
  var persistentJobs = [], persistentObserver = null, attributeNames = new Set();
  var ownAttributes = new WeakMap(), pendingDOM = domChanges(), persistentWork = null, persistentQueued = false;
  function connected(n) { return n.isConnected && n.ownerDocument === D; }
  function domChanges() { return { added: new Set(), changed: new Set(), broad: false, external: false }; }
  function ownAttribute(el, name) {
    if (el.namespaceURI === 'http://www.w3.org/1999/xhtml') name = name.toLowerCase();
    if (!persistentObserver || !attributeNames.has(name)) return;
    var counts = ownAttributes.get(el);
    if (!counts) { counts = new Map(); ownAttributes.set(el, counts); }
    counts.set(name, (counts.get(name) || 0) + 1);
  }
  function writeAttribute(el, name, value) {
    if (el.getAttribute(name) === value) return;
    var tracked = connected(el);
    if (value === null) el.removeAttribute(name); else el.setAttribute(name, value);
    if (tracked) ownAttribute(el, name);
  }
  function localSelector(selector) {
    return selector && /^(?:[a-zA-Z][\w-]*|\*)?(?:[.#][\w-]+|\[[\w-]+(?:[~|^$*]?=(?:"[^"\\]*"|'[^'\\]*'|[\w-]+))?(?:\s+[iIsS])?\])*$/.test(selector);
  }
  function* jobNodes(job, batch) {
    if (!batch || !job.local) {
      if (!batch || batch.broad) {
        try { for (var n of D.querySelectorAll(job.selector)) { yield n; } } catch (e) {}
      }
      return;
    }
    var seen = new Set();
    for (var changed of batch.changed) {
      for (var n = changed.nodeType === 1 ? changed : changed.parentElement; n && !seen.has(n); n = n.parentElement) {
        seen.add(n);
        if (connected(n)) { try { if (n.matches(job.selector)) yield n; } catch (e) {} }
        yield null;
      }
    }
    for (var root of batch.added) {
      if (root.nodeType !== 1 || !connected(root)) continue;
      var covered = false;
      for (var p = root.parentElement; p; p = p.parentElement) { if (batch.added.has(p)) { covered = true; break; } }
      if (covered) continue;
      try {
        if (!seen.has(root) && root.matches(job.selector)) { seen.add(root); yield root; }
        for (var n of root.querySelectorAll(job.selector)) { if (!seen.has(n)) { seen.add(n); yield n; } }
      } catch (e) {}
    }
  }
  function* persistentSweep(batch) {
    for (var job of persistentJobs) {
      for (var n of jobNodes(job, batch)) {
        if (n && connected(n)) { try { job.apply(n); } catch (e) {} }
        yield;
      }
      yield;
    }
  }
  function persistentChunk() {
    persistentQueued = false;
    if (!persistentWork) { persistentWork = persistentSweep(pendingDOM); pendingDOM = domChanges(); }
    // Match the procedural worker's cooperative slice while keeping the
    // existing debounce for persistent scriptlets.
    var deadline = performance.now() + 4, step;
    do { step = persistentWork.next(); } while (!step.done && performance.now() < deadline);
    if (!step.done) { persistentQueued = true; requestAnimationFrame(persistentChunk); return; }
    persistentWork = null;
    if (pendingDOM.external) queuePersistent();
  }
  function queuePersistent() {
    if (persistentQueued) return;
    persistentQueued = true;
    setTimeout(function () { requestAnimationFrame(persistentChunk); }, 100);
  }
  function observePersistent() {
    if (!persistentObserver) persistentObserver = new MutationObserver(function (records) {
      for (var r of records) {
        if (r.type === 'attributes') {
          // Consume only as many records as our own writes produced. If a
          // page rewrites the same attribute, a record remains to recheck it.
          var counts = ownAttributes.get(r.target), count = counts && counts.get(r.attributeName);
          if (count) {
            if (count === 1) counts.delete(r.attributeName); else counts.set(r.attributeName, count - 1);
            if (!counts.size) ownAttributes.delete(r.target);
            // Revisit this candidate on the next page update: this helper
            // may have made it match an earlier helper. Do not self-schedule.
            pendingDOM.changed.add(r.target);
            continue;
          }
        } else pendingDOM.broad = true;
        pendingDOM.external = true;
        pendingDOM.changed.add(r.target);
        if (r.type === 'childList') for (var n of r.addedNodes) pendingDOM.added.add(n);
      }
      if (pendingDOM.external) queuePersistent();
    });
    var options = { childList: true, subtree: true, characterData: true };
    if (attributeNames.size) { options.attributes = true; options.attributeFilter = Array.from(attributeNames); }
    persistentObserver.observe(D, options);
  }
  function settle(behavior, selector, apply, inputs) {
    selector = selector.trim();
    var job = { selector: selector, apply: apply, local: localSelector(selector) };
    if (behavior === 'stay') {
      persistentJobs.push(job);
      if (job.local) {
        attributeNames.add('class'); attributeNames.add('id');
        for (var match of selector.matchAll(/\[([\w-]+)/g)) { attributeNames.add(match[1]); attributeNames.add(match[1].toLowerCase()); }
        (inputs || []).forEach(function (name) { attributeNames.add(name); attributeNames.add(name.toLowerCase()); });
      }
      observePersistent();
    }
    function go() { for (var n of jobNodes(job, null)) { try { apply(n); } catch (e) {} } }
    if (D.readyState === 'loading') D.addEventListener('DOMContentLoaded', go, { once: true }); else go();
    if (behavior === 'stay' || /complete/.test(behavior || '')) W.addEventListener('load', go, { once: true });
  }
  function attributes(attrs, selector, behavior, act) {
    if (!attrs) return;
    var names = attrs.split(/\s*\|\s*/);
    var target = selector || names.map(function (n) { return '[' + CSS.escape(n) + ']'; }).join(',');
    settle(behavior || 'stay', target, function (el) { names.forEach(function (n) { act(el, n); }); }, names);
  }
  function nodeText(nodeName, pattern, replacement) {
    if (!nodeName || !pattern) return;
    var names = needle(nodeName.toUpperCase()), match = needle(pattern);
    var re = null, m = /^\/(.+)\/([gimsu]*)$/.exec(pattern);
    if (replacement !== null) { try { re = m ? new RegExp(m[1], m[2]) : new RegExp(pattern.replace(/[.*+?^$\{\}()|[\]\\]/g, '\\$&'), 'g'); } catch (e) { return; } }
    function visit(node) {
      var parent = node.nodeType === 3 ? node.parentNode : node;
      if (!parent || !names.test(parent.nodeName)) return;
      var content = node.textContent || '';
      if (!match.test(content)) return;
      if (replacement === null) { if (node.nodeType === 3) node.textContent = ''; else node.remove(); }
      else node.textContent = content.replace(re, replacement);
    }
    new MutationObserver(function (records) {
      records.forEach(function (r) { r.addedNodes.forEach(visit); });
    }).observe(D, { childList: true, subtree: true });
  }
  function storage(store, key, raw) {
    if (!store || !key) return;
    var allowed = { 'undefined': undefined, 'false': 'false', 'true': 'true', 'null': 'null', "''": '', 'emptyArr': '[]',
                    'emptyObj': '{}', 'yes': 'yes', 'no': 'no', 'on': 'on', 'off': 'off', '': '' };
    try {
      if (raw === '$remove$') { store.removeItem(key); return; }
      var v = hasOwn.call(allowed, raw) ? allowed[raw] : (/^\d+$/.test(raw) ? raw : null);
      if (v === null || v === undefined) return;
      store.setItem(key, v);
    } catch (e) {}
  }

  for (var i = 0; i < calls.length; i++) {
    var call = calls[i], name = call[0];
    if (hasOwn.call(aliases, name)) name = aliases[name];
    if (!name || !hasOwn.call(runners, name)) continue;
    try { runners[name].apply(null, call.slice(1)); } catch (e) {}
  }
})
"""#
}
