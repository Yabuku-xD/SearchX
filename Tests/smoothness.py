#!/usr/bin/env python3
"""Smoothness, measured without a window on anyone's screen.

A disposable SearchX (own profile, own preferences) opens in the background
with its window see-through, ignoring the pointer and off every screen
(SEARCH_PARK), its pages told they are seen. Five workloads, six seconds
each: an animated page, a scrolling page, the folded sidebar sliding out and
back, switching between tabs, and another tab loading. For each: the page's
own frame intervals, and how late SearchX's main thread answered each
display tick (NativeProbe "hitches") — every tick it misses is a frame the
page and the chrome waited on.

Needs the probes, which only a DEBUG build has. For numbers that mean
something, build optimised with them:
  swift build -c release -Xswiftc -DDEBUG --build-path .build-probe
  python3 Tests/smoothness.py .build-probe/release/Search
Prints one JSON line.
"""
import json, os, plistlib, runpy, shutil, socket, statistics, subprocess, sys, threading, time, uuid
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
ROOT = Path(__file__).resolve().parents[1]
BENCH = runpy.run_path(str(ROOT / 'bench'))
PAGES = {}
class P(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split('?')[0], b'<!doctype html><title>x</title><p>x')
        self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
class Headless:
    def __init__(self, app=None, prefs=None, session=None):
        app = Path(app or ROOT/'.build/debug/Search')
        if app.is_file():
            import tempfile
            bundle = Path(tempfile.mkdtemp(prefix='hl-'))/'SearchX Headless.app'
            (bundle/'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(app, bundle/'Contents/MacOS/Search')
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.shyamalankannan.searchx.headless.'+uuid.uuid4().hex,
                'CFBundleExecutable':'Search','CFBundleName':'SearchX Headless','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
            subprocess.run(['codesign','--force','--deep','--sign','-',str(bundle)],check=True,capture_output=True)
            app = bundle
        self.app = Path(app); self.world = 'hl-' + uuid.uuid4().hex[:6]
        self.suite = 'com.shyamalankannan.searchx.test.' + self.world
        self.profile = Path(BENCH['folder'](self.world)); self.sock = str(self.profile / 'bench.sock')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), P); threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.origin = f'http://127.0.0.1:{self.server.server_port}'
        base = {'bench': True, 'welcomed': True, 'update.install': False}
        base.update(prefs or {})
        p = Path('/tmp')/(self.world+'.plist'); p.write_bytes(plistlib.dumps(base)); subprocess.run(['defaults','import',self.suite,str(p)],check=True); p.unlink()
        self.profile.mkdir(parents=True)
        wid = str(uuid.uuid4()).upper()
        # `session`: (tabs, groups) to start with, restored asleep as after a
        # relaunch — each tab {'url', 'title', 'pin'?, 'groupID'?}.
        tabs, groups = session or ([], [])
        tabs = [{**t, 'url': t['url'].replace('{origin}', self.origin)} for t in tabs]
        (self.profile/'session.json').write_text(json.dumps({'layout':[{'id':wid,'space':'00000000-0000-0000-0000-000000000001'}],
            'windows':[{'id':wid,'active':0,'tabs':tabs,'groups':groups,'frameBox':{'x':0,'y':0,'width':1300,'height':860}}]}))
        subprocess.run(['open','-g','-n','-a',str(self.app),'--env','SEARCH_PROBE='+self.world,'--env','SEARCH_PARK=1'],check=True)
        end = time.time()+30
        while time.time() < end:
            try: self.ask('tabs'); break
            except BaseException: time.sleep(0.2)
        self.pid = int(subprocess.run(['pgrep','-n','-f',str(self.app/'Contents/MacOS')],capture_output=True,text=True).stdout.strip())
    def ask(self, verb, **k):
        r = BENCH['ask'](self.sock, {'do': verb, **k})
        if isinstance(r, dict) and 'error' in r: raise RuntimeError(f"{verb}: {r['error']}")
        return r
    def open(self, path):
        self.ask('bookmark', new=True, url=self.origin + path)
        return next(t['id'] for t in self.ask('tabs')['tabs'] if t['active'])
    def js(self, tab, s): return self.ask('eval', id=tab, js=s).get('value')
    def render(self):
        return self.ask('native', action='performance', render=True)
    def stop(self):
        try: os.kill(self.pid, 15)
        except Exception: pass
        for _ in range(100):
            try: os.kill(self.pid, 0); time.sleep(.1)
            except ProcessLookupError: break
        self.server.shutdown()
        shutil.rmtree(self.profile, ignore_errors=True)
        if 'SearchX Headless' in str(self.app): subprocess.run(['trash',str(self.app.parent)])
        subprocess.run(['defaults','delete',self.suite],capture_output=True)
        pl = Path.home()/'Library/Preferences'/(self.suite+'.plist')
        if pl.exists(): subprocess.run(['trash',str(pl)])

PERF = runpy.run_path(str(ROOT/'Tests/performance.py'), run_name='lib')
FR = b'<script>window.frames_=[];let l=0;(function f(t){if(l)window.frames_.push(t-l);l=t;requestAnimationFrame(f)})(0)</script>'
PAGES['/lab'] = PERF['HTML'].encode() + FR
long = ''.join(f'<p style="font:16px system-ui;margin:0;padding:10px 40px">Paragraph {i} '+('lorem ipsum dolor sit amet '*12)+'</p>' for i in range(900))
PAGES['/long'] = (f'<!doctype html><title>long</title><body style="margin:0">{long}</body>').encode() + FR + b'<script>let d=1;(function s(){scrollBy(0,18*d);if(scrollY+innerHeight>=document.body.scrollHeight-5)d=-1;if(scrollY<=0)d=1;requestAnimationFrame(s)})()</script>'
for i in range(6):
    PAGES[f'/p{i}'] = (f'<!doctype html><title>p{i}</title><body style="margin:0;font:15px system-ui">' + ''.join(f'<div style="padding:8px 30px;border-bottom:1px solid #ddd">Row {j} of page {i} '+'x '*40+'</div>' for j in range(400)) + '</body>').encode()
def stats(fr):
    if not fr: return {}
    return {'n': len(fr), 'med': round(statistics.median(fr),1), 'late': sum(1 for x in fr if x > 12.5), 'bad': sum(1 for x in fr if x > 25), 'worst': round(max(fr),1)}
def measure(h, tab, seconds, during=None):
    h.js(tab, 'window.frames_=[];true')
    h.ask('native', action='hitches', start=True)
    end = time.time() + seconds
    while time.time() < end:
        if during: during()
        else: time.sleep(0.1)
    main = h.ask('native', action='hitches')
    fr = json.loads(h.js(tab, 'JSON.stringify(window.frames_)') or '[]')
    return {'page': stats(fr), 'main': {k: (round(v,1) if isinstance(v,float) else v) for k,v in main.items() if k != 'seconds'}}
prefs = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
h = Headless(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != '-' else None, prefs={'sidebar': True, 'sidebar.hides': True, **prefs})
out = {}
try:
    lab = h.open('/lab'); h.render(); time.sleep(2)
    out['animated'] = measure(h, lab, 6)
    lng = h.open('/long'); h.render(); time.sleep(1.5)
    out['scrolling'] = measure(h, lng, 6)
    h.ask('select', id=lab); h.render(); time.sleep(1)
    state = {'out': False, 't': 0}
    def flip():
        state['out'] = not state['out']
        h.ask('ui', slide=state['out'])
        time.sleep(0.45)
    out['sidebar'] = measure(h, lab, 6, flip)
    tabs = [h.open(f'/p{i}') for i in range(6)]
    h.ask('select', id=lab); h.render()
    idx = {'i': 0}
    def switch():
        idx['i'] += 1; h.ask('select', id=tabs[idx['i'] % len(tabs)]); time.sleep(0.3)
    out['switching'] = {'main': measure(h, lab, 6, switch)['main']}
    h.ask('select', id=lab); h.render(); time.sleep(1)
    def load():
        h.ask('go', id=tabs[0], url=h.origin + f'/p{int(time.time()*10)%6}?' + str(time.time())); time.sleep(0.5)
    out['loading'] = measure(h, lab, 6, load)
finally:
    h.stop()
print(json.dumps(out))

