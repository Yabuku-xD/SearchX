#!/usr/bin/env python3
"""A walk through Search the way a person uses it, one screenshot per step.

New tab (pixel-art picture, address field light), typing, a white page, the
column folded, brought out over the page and put away again, a second new
tab, Settings (Appearance, Tabs, Privacy), the picture's style switched and
switched back, a small window, and the light look. Each step is a composited
capture of the window as it is on screen; checks that can be read without
eyes (the picture is there, the address stayed, nothing crashed) are checked.
Run: swift build && python3 Tests/ux-tour.py [--picture path]
Writes .local-resolution/evidence/ux-<id>/ (PNGs and result.json).
"""
import argparse, json, plistlib, runpy, shutil, subprocess, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))

class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        light = self.path.startswith('/white')
        body = ('<!doctype html><meta charset=utf-8><title>%s page</title><body style="margin:0;font:18px system-ui;background:%s;color:%s">'
                '<h1 id="identity" style="padding:40px">%s</h1>%s</body>' % ('White' if light else 'Dark', '#fff' if light else '#111',
                '#111' if light else '#eee', self.path.split('?')[0],
                ''.join('<p style="padding:0 40px">Paragraph %d of ordinary reading text.</p>' % i for i in range(40)))).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / '.build/debug/Search'))
    parser.add_argument('--picture', default='/System/Library/Desktop Pictures/.thumbnails/Catalina Sunset.heic')
    args = parser.parse_args()
    args.world = 'ux-' + uuid.uuid4().hex[:8]
    server = ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = SUPPORT['Run'](args, 'http://127.0.0.1:%d' % server.server_port)
    out = ROOT / '.local-resolution/evidence' / args.world
    out.mkdir(parents=True)
    steps = []

    def front():
        # In front of whatever else is on screen: a covered window is one
        # WebKit stops drawing, and a picture of that is not what a person sees.
        subprocess.run(['osascript', '-e', 'tell application id "%s" to activate' % run.report.get('bundleID', '')],
                       capture_output=True)

    def shot(name, pause=0.8):
        front()
        time.sleep(pause)
        path = out / (name + '.png')
        try:
            run.ask('native', action='composited-shot', path=str(path))
            steps.append({'step': name, 'shot': str(path)})
        except Exception as error:
            steps.append({'step': name, 'error': str(error)})
        print('shot', name, flush=True)

    def press_label(label):
        rows = run.ask('native', action='nodes')['nodes']
        node = next((n for n in rows if n.get('label') == label and n.get('role') in ('AXButton', 'AXRadioButton')), None)
        if node is None:
            steps.append({'step': 'press ' + label, 'error': 'not found'})
            return False
        run.ask('native', action='press', index=node['index'])
        return True

    try:
        run.prepare()
        prefs_path = run.directory / 'prefs.plist'
        prefs = plistlib.loads(prefs_path.read_bytes())
        prefs.update({'wallpaper': True, 'wallpaper.style': 'pixel', 'chrome.fieldBeam': True})
        prefs_path.write_bytes(plistlib.dumps(prefs))
        subprocess.run(['defaults', 'import', run.suite, str(prefs_path)], check=True, capture_output=True)
        run.profile.mkdir(parents=True, exist_ok=True)
        subprocess.run(['sips', '-s', 'format', 'png', args.picture, '--out', str(run.profile / 'wallpaper.png')], check=True, capture_output=True)
        run.launch()
        run.ask('resize', width=1280, height=800, steps=1)
        run.ask('press', code=17, chars='t', mods=['cmd'])
        shot('01-new-tab-pixel', 2.0)
        for ch in 'exa':
            run.ask('press', code=0, chars=ch, mods=[])
        shot('02-typing')
        run.ask('press', code=53, chars='\x1b', mods=[])
        run.ask('ui', sidebar=True, hides=True)
        run.open('/white')
        shot('03-white-page', 1.5)
        run.ask('ui', folded=True)
        shot('04a-folded', 0.3); shot('04b-folded', 0.8)
        run.report['probeFolded'] = run.ask('probe').get('rows')
        run.ask('ui', peek=True)
        shot('05a-peek', 0.3); shot('05b-peek', 0.8)
        run.ask('ui', peek=False)
        shot('06a-peek-gone', 0.2); shot('06b-peek-gone', 0.6); shot('06c-peek-gone', 1.5)
        run.report['after'] = {'tabs': run.ask('tabs'), 'probe': run.ask('probe'),
                               'state': run.ask('native', action='window-state')}
        try:
            tab = next(t['id'] for t in run.ask('tabs')['tabs'] if t['active'])
            run.report['after']['js'] = run.js(tab, '({vis: document.visibilityState, path: location.pathname})')
        except Exception as error:
            run.report['after']['js'] = repr(error)
        shot('06d-peek-gone', 2.0)
        run.ask('press', code=17, chars='t', mods=['cmd'])
        shot('07-second-new-tab', 1.5)
        run.ask('ui', folded=False)
        run.ask('ui', settings=True)
        shot('08-settings', 1.2)
        for label in ('Appearance', 'Tabs', 'Privacy'):
            press_label(label)
            shot('09-settings-' + label.lower(), 1.0)
        press_label('Tabs')
        time.sleep(0.6)
        press_label('Photo')
        time.sleep(0.4)
        press_label('Pixel')
        time.sleep(0.4)
        press_label('Photo')
        time.sleep(0.4)
        press_label('Pixel')
        run.ask('ui', settings=False)
        shot('10-after-style-toggles', 2.0)
        for w, h in [(820, 560), (1500, 950), (640, 420), (1180, 780)]:
            run.ask('resize', width=w, height=h, steps=6)
            shot('11-resize-%dx%d-now' % (w, h), 0.1)
            shot('11-resize-%dx%d-later' % (w, h), 1.0)
        run.ask('resize', width=820, height=560, steps=6)
        shot('11a-small-window', 0.5)
        run.report['small'] = {'probe': {k: run.ask('probe').get(k) for k in ('activePageFrame', 'windows')}}
        shot('11b-small-window', 2.5)
        run.report['small']['later'] = run.ask('probe').get('activePageFrame')
        run.ask('resize', width=1280, height=800, steps=6)
        run.ask('ui', look='light')
        shot('12-light-new-tab', 1.5)
        run.open('/dark')
        run.ask('ui', folded=True)
        run.ask('ui', peek=True)
        shot('13-light-peek-over-dark', 1.2)
        time.sleep(1.5)
        run.ask('ui', peek=False)
        run.ask('ui', folded=False)
        run.report['tabs'] = run.ask('tabs')
        run.report['passed'] = True
    except Exception as error:
        run.report['passed'] = False
        run.report['error'] = repr(error)
    finally:
        run.report['steps'] = steps
        try:
            run.stop()
        finally:
            server.shutdown()
            (out / 'result.json').write_text(json.dumps(run.report, indent=2))
            print('ARTIFACT', out / 'result.json')

if __name__ == '__main__':
    main()
