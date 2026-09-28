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
127.0.0.1##.feed-card:has-text(Sponsored)
127.0.0.1##.feed-card:has-text(Partner)
127.0.0.1##.tagged-card[data-kind="ad"]:watch-attr(data-kind):has-text(Tagged)
127.0.0.1##.plain-attribute[data-promoted="yes"]:has-text(Tagged)
127.0.0.1##.watch-class:watch-attr(class):has-text(ClassAd)
127.0.0.1##.feed-style:has-text(Styled):style(outline-width: 7px !important)
127.0.0.1###feed-context .context-card:has-text(Sponsored)
127.0.0.1###feed-siblings .gate + .sibling-card:has-text(Sponsored)
127.0.0.1##+js(remove-attr, data-tracking, .feed-helper, stay)
127.0.0.1##+js(remove-class, advert, .feed-helper, stay)
127.0.0.1##+js(set-attr, .feed-helper, data-clean, true)
127.0.0.1##+js(remove-attr, data-tracking, .helper-gate + .complex-helper, stay)
127.0.0.1##+js(href-sanitizer, .feed-link, [data-destination])
127.0.0.1##+js(remove-attr, data-cascade, .cascade-ready, stay)
127.0.0.1##+js(set-attr, .cascade-input, class, cascade-ready)
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
    def settled(name, expression):
        deadline = time.monotonic() + 10
        since = None
        while time.monotonic() < deadline:
            value = h.js(tab, expression)
            if value:
                if since is None: since = time.monotonic()
                if time.monotonic() - since >= .4: break
            else:
                since = None
            time.sleep(.05)
        check(name, bool(value) and since is not None and time.monotonic() - since >= .4, value)

    h.js(tab, """(() => {
      document.getElementById('stress-root').remove();
      const root = document.createElement('section'); root.id='feed-checks';
      root.innerHTML = '<article id="feed-ad" class="feed-card"><span>Sponsored Partner</span></article>'+
        '<article id="feed-organic" class="feed-card">Ordinary post</article>'+
        '<article id="feed-tag" class="tagged-card" data-kind="post">Tagged</article>'+
        '<article id="feed-unwatched" class="plain-attribute" data-promoted="no">Tagged</article>'+
        '<article id="feed-class" class="watch-class">ClassAd</article>'+
        '<article id="feed-style" class="feed-style" style="outline-width:0px">Styled</article>'+
        '<div id="feed-context"><article id="feed-context-card" class="context-card">Sponsored</article></div>'+
        '<div id="feed-siblings"><span class="gate"></span><article id="feed-sibling" class="sibling-card">Sponsored</article></div>'+
        '<article id="feed-helper" class="feed-helper advert" data-tracking="yes">Helper</article>'+
        '<div id="helper-context"><article id="complex-helper" class="complex-helper" data-tracking="yes">Complex</article></div>'+
        '<a id="feed-link" class="feed-link" href="https://invalid.example/" data-destination="https://example.com/first">Link</a>';
      document.body.append(root);
      window.hiddenFeed = id => getComputedStyle(document.getElementById(id)).display === 'none';
      return true;
    })()""")
    settled('new feed subtree filters ads without hiding ordinary posts',
            "hiddenFeed('feed-ad') && !hiddenFeed('feed-organic') && hiddenFeed('feed-class')")
    h.js(tab, "document.querySelector('#feed-ad span').firstChild.data='Sponsored'; true")
    settled('overlapping rules keep a post hidden while either still matches', "hiddenFeed('feed-ad')")
    h.js(tab, "document.querySelector('#feed-ad span').firstChild.data='Ordinary'; true")
    settled('recycled text node becomes visible when no rule matches', "!hiddenFeed('feed-ad')")
    h.js(tab, "document.querySelector('#feed-ad span').firstChild.data='Partner'; true")
    settled('recycled text node is hidden when it becomes an ad again', "hiddenFeed('feed-ad')")
    h.js(tab, "document.getElementById('feed-ad').removeAttribute('searchx-veil'); document.getElementById('feed-checks').append(document.createTextNode(' update')); true")
    settled('page cannot leave a matched post visible by removing its marker', "hiddenFeed('feed-ad')")
    h.js(tab, "document.getElementById('feed-unwatched').dataset.promoted='yes'; document.getElementById('feed-checks').append(document.createTextNode(' update')); true")
    settled('selector attributes remain current across unrelated mutations', "hiddenFeed('feed-unwatched')")
    h.js(tab, "document.getElementById('feed-tag').dataset.kind='ad'; true")
    settled('watched attribute can introduce a selector match', "hiddenFeed('feed-tag')")
    h.js(tab, "document.getElementById('feed-tag').dataset.kind='post'; document.getElementById('feed-class').className='ordinary'; true")
    settled('watched attribute and class changes remove obsolete matches', "!hiddenFeed('feed-tag') && !hiddenFeed('feed-class')")
    settled('procedural style applies to a new card', "getComputedStyle(document.getElementById('feed-style')).outlineWidth === '7px'")
    h.js(tab, "document.getElementById('feed-style').textContent='Ordinary'; true")
    settled('recycled card restores its original style', "getComputedStyle(document.getElementById('feed-style')).outlineWidth === '0px'")
    settled('context and sibling selectors initially match', "hiddenFeed('feed-context-card') && hiddenFeed('feed-sibling')")
    h.js(tab, "document.getElementById('feed-checks').append(document.getElementById('feed-context-card')); document.querySelector('#feed-siblings .gate').remove(); true")
    settled('broad selectors recheck moved nodes and changed siblings', "!hiddenFeed('feed-context-card') && !hiddenFeed('feed-sibling')")
    h.js(tab, "window.heldFeed=document.getElementById('feed-ad'); heldFeed.remove(); true")
    settled('detached matched node releases its hiding marker', "!heldFeed.hasAttribute('searchx-veil')")
    h.js(tab, "heldFeed.textContent='Ordinary'; document.getElementById('feed-checks').append(heldFeed); true")
    settled('detached row can return as ordinary content', "!hiddenFeed('feed-ad')")
    settled('persistent helpers clean a newly inserted card', "(() => { const e=document.getElementById('feed-helper'); return !e.hasAttribute('data-tracking') && !e.classList.contains('advert') && e.dataset.clean==='true'; })()")
    h.js(tab, "const helper=document.getElementById('feed-helper'); helper.dataset.tracking='again'; helper.classList.add('advert'); helper.dataset.clean='false'; helper.append(document.createTextNode(' update')); true")
    settled('persistent helpers reapply to an existing changed card', "(() => { const e=document.getElementById('feed-helper'); return !e.hasAttribute('data-tracking') && !e.classList.contains('advert') && e.dataset.clean==='true'; })()")
    h.js(tab, "helper.dataset.tracking='recycled'; helper.classList.add('advert'); helper.dataset.clean='false'; true")
    settled('persistent helpers notice attribute-only row recycling', "!helper.hasAttribute('data-tracking') && !helper.classList.contains('advert') && helper.dataset.clean==='true'")
    h.js(tab, "const gate=document.createElement('span'); gate.className='helper-gate'; document.getElementById('helper-context').prepend(gate); true")
    settled('persistent helper preserves sibling-dependent selector behavior', "!document.getElementById('complex-helper').hasAttribute('data-tracking')")
    settled('persistent link helper sanitizes inserted links', "document.getElementById('feed-link').href==='https://example.com/first'")
    h.js(tab, "document.getElementById('feed-link').dataset.destination='https://example.com/second'; document.getElementById('feed-link').textContent='Updated link'; true")
    settled('persistent link helper handles recycled links', "document.getElementById('feed-link').href==='https://example.com/second'")
    h.js(tab, "const cascade=document.createElement('article'); cascade.id='feed-cascade'; cascade.className='cascade-input'; cascade.dataset.cascade='pending'; document.getElementById('feed-checks').append(cascade); true")
    settled('persistent helper can introduce another helper selector', "document.getElementById('feed-cascade').className==='cascade-ready'")
    h.js(tab, "document.getElementById('feed-checks').append(document.createTextNode(' next page update')); true")
    settled('later page updates revisit candidates changed by another helper', "!document.getElementById('feed-cascade').hasAttribute('data-cascade')")
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
