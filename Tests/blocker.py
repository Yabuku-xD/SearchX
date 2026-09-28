#!/usr/bin/env python3
"""The blocker's own parts, end to end, headless (SEARCH_PARK): your filters
(procedural, network, $redirect, $csp, $removeparam, $header, $replace),
your rules (dynamic filtering, inline scripts), the log — and that none of
it acts on a sign-in, passkey or payment page.

  swift build && python3 Tests/blocker.py [binary]

Prints PASS/FAIL lines and writes the evidence to /tmp/searchx-blocker.json.
"""
import json, shutil, subprocess, sys, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler
ROOT = Path(__file__).resolve().parents[1]
src = (ROOT / 'Tests/smoothness.py').read_text()
g = {'__file__': str(ROOT / 'Tests/smoothness.py')}
exec(src[:src.index('PERF = ')], g)

PAGE = b"""<!doctype html><title>Blocker page</title><body>
<div class=shelf id=s1><span>Shorts</span></div><div class=shelf id=s2><span>Videos</span></div>
<div class=gone id=g1>remove me</div>
<div id=wrap><span class=inner>Ad</span></div>
<p class=styled id=st>styled</p>
<script>window.dataLayer=[{eventCallback:function(){window.callbackRan=true}}];</script>
<script src="/gtm.js" onload="window.gtmLoaded=true" onerror="window.gtmFailed=true"></script>
<script src="/blockme.js"></script>
<script src="/allowed.js"></script>
<script src="THIRD/3p.js"></script>
<script src="THIRD/3p-allowed.js"></script>
<img id=pic src="/pixel.gif">
<iframe id=hdr src="/hdr"></iframe>
<script>fetch('/data.json').then(r=>r.text()).then(t=>window.replaced=t)</script>
</body>"""

FILTERS = """! test filters
127.0.0.1##.shelf:has-text(Shorts)
127.0.0.1##.gone:remove()
127.0.0.1##.inner:has-text(Ad):upward(1)
127.0.0.1##.styled:style(color: rgb(255, 0, 0) !important)
127.0.0.1##.stress:has-text(Sponsored)
127.0.0.1##.stress-parent:has(.stress:has-text(Sponsored)):style(outline-width: 3px)
||127.0.0.1^*blockme.js
||127.0.0.1^*gtm.js$script,redirect=googletagmanager_gtm.js
||127.0.0.1^*/csp$csp=img-src 'none'
$removeparam=utm_campaign
||127.0.0.1^$removeparam=/^foo=/
||127.0.0.1^*/hdr$header=x-block:yes
||127.0.0.1^*/data.json$xhr,replace=/secret/public/
this is not a filter
"""
RULES = """127.0.0.1 localhost * block
localhost * inline-script block
"""
# The second run: a narrower allow wins over a broader block.
RULES_ALLOW = """* localhost * block
127.0.0.1 localhost * allow
"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        port = self.server.server_port
        headers = {'Content-Type': 'text/html', 'Cache-Control': 'no-store'}
        if path.endswith('.js'):
            name = path.rsplit('/', 1)[-1][:-3].replace('-', '_')
            body = ('window.loaded_%s=true;' % name).encode(); headers['Content-Type'] = 'text/javascript'
        elif path == '/data.json':
            body = b'secret'; headers['Content-Type'] = 'application/json'
        elif path == '/pixel.gif':
            body = bytes.fromhex('47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b')
            headers['Content-Type'] = 'image/gif'
        elif path == '/hdr':
            body = b'<!doctype html><body>header page'; headers['X-Block'] = 'yes'
        elif path == '/inline':
            body = b'<!doctype html><title>Inline</title><script>window.inlineRan=true</script><body>inline'
        else:
            body = PAGE.replace(b'THIRD', ('http://localhost:%d' % port).encode())
        self.send_response(200)
        for k, v in headers.items(): self.send_header(k, v)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
g['P'] = Handler

# Your filters and rules, in the profile before SearchX starts.
real = subprocess.run
wanted = {'rules': RULES}
def run(args, *a, **k):
    if args and args[0] == 'open':
        world = next(x.split('=', 1)[1] for x in args if x.startswith('SEARCH_PROBE='))
        folder = Path(g['BENCH']['folder'](world)) / 'filters'
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'mine.txt').write_text(FILTERS); (folder / 'rules.txt').write_text(wanted['rules'])
    return real(args, *a, **k)
g['subprocess'].run = run

results, evidence = [], {}
def check(name, ok, detail=None):
    results.append(ok); evidence[name] = {'ok': bool(ok), 'detail': detail}
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else '  ' + json.dumps(detail)[:300]), flush=True)

PROBE = """JSON.stringify({
  s1: getComputedStyle(document.getElementById('s1')).display, s2: getComputedStyle(document.getElementById('s2')).display,
  g1: !!document.getElementById('g1'), wrap: getComputedStyle(document.getElementById('wrap')).display,
  styled: getComputedStyle(document.getElementById('st')).color,
  blockme: !!window.loaded_blockme, allowed: !!window.loaded_allowed, gtm: !!window.loaded_gtm,
  gtmLoaded: !!window.gtmLoaded, gtmFailed: !!window.gtmFailed, callback: !!window.callbackRan,
  third: !!window.loaded_3p, thirdAllowed: !!window.loaded_3p_allowed,
  pic: document.getElementById('pic').naturalWidth, replaced: window.replaced || null,
  hdr: (function(){ try { return document.getElementById('hdr').contentDocument.body.innerText } catch (e) { return 'cross' } })(),
  search: location.search
})"""

binary = sys.argv[1] if len(sys.argv) > 1 else None
h = g['Headless'](binary, prefs={'sidebar': False})
origin = h.origin
try:
    time.sleep(3)
    def load(path):
        h.ask('bookmark', new=True, url=origin + path)
        tab = next(t['id'] for t in h.ask('tabs')['tabs'] if t['active'])
        time.sleep(3)
        return tab, json.loads(h.js(tab, PROBE))

    tab, p = load('/page?utm_campaign=spring&foo=1&keep=2')
    evidence['page'] = p
    check('procedural :has-text hides only the matching shelf', p['s1'] == 'none' and p['s2'] != 'none', p)
    check('procedural :remove() takes the element out', not p['g1'], p)
    check('procedural :upward(1) hides the parent', p['wrap'] == 'none', p)
    check('procedural :style() applies', p['styled'] == 'rgb(255, 0, 0)', p)
    h.js(tab, """(() => {
      window.filterFrames = []; let last = performance.now();
      const until = last + 3000;
      function frame(now) { filterFrames.push(now-last); last=now; if(now<until) requestAnimationFrame(frame); }
      requestAnimationFrame(frame);
      const root = document.createElement('section'); root.id='stress-root';
      root.innerHTML = Array.from({length:4000}, (_,i)=>'<article class="stress-parent"><span class="stress">Sponsored '+i+'</span></article>').join('');
      document.body.append(root); return true;
    })()""")
    deadline = time.monotonic() + 15
    stress = {}
    while time.monotonic() < deadline:
        stress = json.loads(h.js(tab, "JSON.stringify({hidden:document.querySelectorAll('.stress[searchx-veil]').length, frames:window.filterFrames})"))
        if stress['hidden'] == 4000: break
        time.sleep(.05)
    check('large procedural result completes without dropping matches', stress.get('hidden') == 4000, stress)
    evidence['procedural stress'] = stress
    h.js(tab, "document.querySelector('.stress').textContent='Keep this'; true")
    deadline = time.monotonic() + 10
    visible = False
    while time.monotonic() < deadline:
        visible = h.js(tab, "getComputedStyle(document.querySelector('.stress')).display !== 'none'")
        if visible: break
        time.sleep(.05)
    check('changed procedural match becomes visible again', visible)
    check('your network filter blocks, the rest loads', not p['blockme'] and p['allowed'], p)
    check('$redirect: stand-in runs, page sees a load', not p['gtm'] and p['gtmLoaded'] and not p['gtmFailed'] and p['callback'], p)
    check('$removeparam: named and /regex/ parameters taken off', p['search'] == '?keep=2', p)
    check('$header: frame refused for its header', p['hdr'] != 'header page', p)
    check('$replace: fetch answer rewritten', p['replaced'] == 'public', p)
    check('dynamic rule blocks a third party on the site', not p['third'] and not p['thirdAllowed'], p)
    entries = h.ask('eval', id=tab, log=True)['entries']
    evidence['log'] = entries
    check('the log names what your filters and rules blocked, and what was cleaned',
          any(e['kind'] == 'blocked' and 'blockme.js' in e['url'] and e['source'] == 'My filters' for e in entries)
          and any(e['kind'] == 'blocked' and 'localhost' in e['url'] and e['source'] == 'My rules' for e in entries)
          and any(e['kind'] == 'cleaned' for e in entries), entries)
    tab2, c = load('/csp')
    check('$csp: the page is given the policy (images refused)', c['pic'] == 0, c)
    h.ask('bookmark', new=True, url='http://localhost:%d/inline' % h.server.server_port)
    t3 = next(t['id'] for t in h.ask('tabs')['tabs'] if t['active']); time.sleep(3)
    inline = h.js(t3, "JSON.stringify({ran: !!window.inlineRan, title: document.title, href: location.href})")
    evidence['inline'] = inline
    check('inline-script rule stops a site\'s inline scripts', inline and json.loads(inline)['title'] == 'Inline' and not json.loads(inline)['ran'], inline)

    # Protected: the same filters on a checkout, a sign-in and a passkey page.
    for path in ['/checkout/cart?utm_campaign=x', '/login?utm_campaign=x', '/ax/claim/webauthn/nudge?utm_campaign=x']:
        _, q = load(path)
        evidence['protected ' + path] = q
        check('protected %s: nothing of yours acts' % path.split('?')[0],
              q['s1'] != 'none' and q['g1'] and q['styled'] != 'rgb(255, 0, 0)' and q['blockme'] and q['third']
              and 'utm_campaign' in q['search'] and q['replaced'] == 'secret' and q['hdr'] == 'header page', q)
finally:
    h.stop()
    shutil.rmtree(g['BENCH']['folder'](h.world), ignore_errors=True)

wanted['rules'] = RULES_ALLOW
h = g['Headless'](binary, prefs={'sidebar': False})
try:
    time.sleep(3)
    h.ask('bookmark', new=True, url=h.origin + '/page')
    tab = next(t['id'] for t in h.ask('tabs')['tabs'] if t['active']); time.sleep(3)
    p = json.loads(h.js(tab, PROBE))
    evidence['allow'] = p
    check('a narrower allow rule wins over a broader block', p['third'] and p['thirdAllowed'], p)
finally:
    h.stop()
    shutil.rmtree(g['BENCH']['folder'](h.world), ignore_errors=True)
Path('/tmp/searchx-blocker.json').write_text(json.dumps(evidence, indent=1))
print(f"{sum(results)}/{len(results)} passed · evidence /tmp/searchx-blocker.json")
sys.exit(0 if all(results) else 1)
