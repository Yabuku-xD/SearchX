#!/usr/bin/env python3
"""Real app flows. Each invocation owns its app process, profile and HTTP server."""
import argparse
import hashlib
import html
import json
import os
import plistlib
import runpy
import shutil
import signal
import subprocess
import threading
import time
import uuid
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
PAYLOAD = bytes(range(256)) * 8192


class OwnedLaunchedApp:
    """The unique test bundle's PID, confirmed by its own local probe."""
    def __init__(self, pid):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return 0

    def terminate(self):
        os.kill(self.pid, signal.SIGTERM)

    def wait(self, timeout):
        end = time.monotonic() + timeout
        while self.poll() is None and time.monotonic() < end:
            time.sleep(.1)
        if self.poll() is None:
            raise TimeoutError('owned hidden test app did not exit')
        return 0


class Fixture(BaseHTTPRequestHandler):
    # Every path asked for, in order: what the blocker let reach the server.
    seen = []
    suggestion_headers = []

    def do_POST(self):
        Fixture.seen.append(self.path)
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

    def do_GET(self):
        Fixture.seen.append(self.path)
        if self.path == '/wake.css':
            time.sleep(5 if Fixture.seen.count('/wake.css') > 1 else .05)
            body = b'body{background:#304050;color:white}'
            self.send_response(200)
            self.send_header('Content-Type', 'text/css')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/suggest?'):
            Fixture.suggestion_headers.append(dict(self.headers))
            query = parse_qs(urlsplit(self.path).query).get('q', [''])[0]
            if query.startswith('slow'):
                time.sleep(1.2)
            values = [query + ' first', query + ' second', query + ' first', '', 'https://example.org/']
            body = (b'{' if query == 'malformed' else b'x' * 100000 if query == 'oversized'
                    else json.dumps([query, values]).encode())
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', 'suggestion-test=secret; Path=/')
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path in ('/blocker', '/blocker-off'):
            body = (f'<!doctype html><meta charset="utf-8"><title>Fixture {self.path}</title>'
                    '<style>body{font:18px system-ui;padding:40px}a,button{display:block;margin:18px 0;font:inherit}</style>'
                    f'<h1 id="identity">{self.path}</h1>'
                    '<a id="tracked" href="/landed?id=5&utm_source=news&utm_medium=email&fbclid=abc&gclid=xyz">Tracked link</a>'
                    '<button id="popad" onclick="window.open(\'https://popads.net/serve\')">Pop-up network</button>'
                    '<button id="blankpop" onclick="var w=window.open(\'about:blank\');w.location=\'https://exoclick.com/ad\'">Blank pop-up</button>'
                    '<button id="okpop" onclick="window.open(\'/legit-window\')">Ordinary window</button>').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/wide-icon.png':
            def chunk(kind, data):
                return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
            pixels=b''.join(b'\x00'+bytes([210,70,25,255])*512 for _ in range(256))
            body=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',512,256,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
            self.send_response(200)
            self.send_header('Content-Type','image/png')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/download-'):
            name = self.path.strip('/') + '.bin'
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="' + name + '"')
            self.send_header('Content-Length', str(len(PAYLOAD)))
            self.end_headers()
            try:
                for offset in range(0, len(PAYLOAD), 65536):
                    self.wfile.write(PAYLOAD[offset:offset + 65536])
                    self.wfile.flush()
                    time.sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        path = html.escape(self.path)
        icon = '<link rel="icon" href="/wide-icon.png" sizes="512x256">' if self.path == '/favicon' else ''
        if self.path == '/wake': icon += '<link rel="stylesheet" href="/wake.css">'
        body = (f'<!doctype html><meta charset="utf-8"><title>Fixture {path}</title>'
                f'{icon}'
                '<style>body{padding:70px;font:18px system-ui}#capture{display:block;'
                'box-sizing:border-box;width:180px;height:90px;background:rgb(20,180,80);'
                'border:0;color:black}input{display:block;margin:30px 0}</style>'
                f'<h1 id="identity">{path}</h1>'
                '<a id="capture" href="/must-not-navigate">Capture this element</a>'
                '<input id="edit"><div contenteditable="true" id="rich">Editable</div>'
                '<a id="cancel-download" href="/download-cancel" download>Slow download</a> '
                '<a id="finish-download" href="/download-finish" download>Complete download</a>'
                '<script>window.sawExtensionStart=document.documentElement.hasAttribute("data-extension-start");window.__keys=[];document.addEventListener("keydown",e=>'
                'window.__keys.push({key:e.key,shift:e.shiftKey,meta:e.metaKey}));</script>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('flow', choices=['capture', 'downloads', 'pin-home', 'editor', 'core', 'spaces', 'extensions', 'offscreen', 'shield', 'blocker', 'blocker-off', 'restore-scripts', 'hidden-scripts', 'layout', 'selection', 'extension-shortcuts', 'find', 'applescript', 'split', 'startup', 'groups', 'bookmarks-dial', 'favicon', 'address-small', 'suggestions', 'forms-churn', 'wake', 'settings-scroll'])
    parser.add_argument('--binary', default=str(ROOT / '.build/debug/Search'))
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    newest_source = max(p.stat().st_mtime for p in (ROOT / 'Sources').rglob('*.swift'))
    if not binary.is_file() or binary.stat().st_mtime < newest_source:
        raise RuntimeError('Build the current source successfully before running app flows')
    args.world = 'res-' + args.flow[:5] + '-' + uuid.uuid4().hex[:8]
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = SUPPORT['Run'](args, f'http://127.0.0.1:{server.server_port}')
    artifact = ROOT / '.local-resolution/evidence' / args.world
    artifact.mkdir(parents=True)
    run.report.update(flow=args.flow, command=f'python3 Tests/local-resolution.py {args.flow}',
                      artifact=str(artifact))

    def wait(read, accept, message, timeout=20):
        end = time.monotonic() + timeout
        value = None
        while time.monotonic() < end:
            value = read()
            if accept(value):
                return value
            time.sleep(0.1)
        raise AssertionError(f'{message}: {value}')

    def menu(*path):
        wait(lambda: run.ask('native', action='menus')['items'],
             lambda rows: any(row['path'] == list(path) and row['enabled'] for row in rows),
             'menu did not become available: ' + ' / '.join(path))
        response = run.ask('native', action='menu', path=list(path))
        run.check(response.get('sent') is True, 'menu action sent: ' + ' / '.join(path))

    def nodes(name):
        value = run.ask('native', action='nodes')['nodes']
        (artifact / (name + '-nodes.json')).write_text(json.dumps(value, indent=2))
        return value

    def shot(name):
        run.ask('native', action='shot', path=str(artifact / (name + '.png')))

    def settings_category(label):
        # The toolbar also has an Extensions button. Scope this choice to
        # the Settings sidebar, whose categories align with General.
        def category():
            rows = nodes('settings-category')
            general = next((n for n in rows if n['role'] == 'AXButton' and n['label'] == 'General'), None)
            if general:
                return next((n for n in rows if n['role'] == 'AXButton' and n['label'] == label
                             and abs(n['frame'][0] - general['frame'][0]) < 1), None)
        node = wait(category, lambda n: n is not None, 'Settings category missing: ' + label)
        run.check(run.ask('native', action='press', index=node['index']).get('pressed'),
                  'Settings category responds: ' + label)

    def click_native(label, role=None, mods=None):
        previous = None
        since = time.monotonic()
        def ready():
            nonlocal previous, since
            rows = nodes('click')
            probe = run.ask('probe')
            owner = next(r for r in probe['rows'] if r['key'])
            frame = next(w['frame'] for w in probe['windows'] if w['number'] == owner['host'])
            item = next((n for n in rows if label in (n['label'], n['value'], n['title'])
                         and (role is None or n['role'] == role)
                         and frame[0] <= n['frame'][0] < frame[0] + frame[2]
                         and n['frame'][2] > 0), None)
            position = item['frame'] if item else None
            if position != previous:
                previous, since = position, time.monotonic()
            return item if time.monotonic() - since >= .2 else None
        item = wait(ready, lambda n: n is not None, 'native control missing: ' + label)
        x, y, w, h = item['frame']
        run.ask('native', action='click', x=x+w/2, y=y+h/2, mods=mods or [])

    try:
        run.prepare()
        if args.flow == 'applescript':
            resource = run.app / 'Contents/Resources'
            resource.mkdir(exist_ok=True)
            shutil.copy2(ROOT / 'Search.sdef', resource / 'Search.sdef')
            info_path = run.app / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            info.update(NSAppleScriptEnabled=True, OSAScriptingDefinition='Search.sdef')
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(run.app)], check=True, capture_output=True)
        (run.profile / 'session.json').write_text(json.dumps({'tabs': [], 'active': 0}))
        downloads = run.profile / 'Downloads'
        downloads.mkdir(exist_ok=True)
        prefs_path = run.directory / 'prefs.plist'
        prefs = plistlib.loads(prefs_path.read_bytes())
        prefs.update({'downloads': str(downloads), 'downloads.ask': False,
                      'pins.returnHome': True})
        if args.flow == 'suggestions':
            os.environ['SEARCH_SUGGESTIONS_URL'] = run.origin + '/suggest'
            prefs['search.keywords'] = json.dumps([{'id':str(uuid.uuid4()),'keyword':'fixture',
                                                    'template':run.origin+'/results?q=%s'}]).encode()
        if args.flow == 'groups':
            prefs['tabs.groups'] = True
        if args.flow == 'blocker-off':
            # The control: the same page and clicks with the blocker off,
            # so every blocker check below is shown able to fail.
            prefs['shield'] = False
        if args.flow == 'bookmarks-dial':
            prefs.update({'bookmarks.sidebar': True, 'dial.button': True, 'toolbar.downloads': True})
            (run.profile / 'bookmarks.json').write_text(json.dumps([
                {'id': str(uuid.uuid4()), 'title': 'Reading', 'children': [
                    {'id': str(uuid.uuid4()), 'title': 'Reference', 'children': [
                        {'id': str(uuid.uuid4()), 'title': 'Book fixture', 'url': run.origin + '/book-page'}]}]}]))
        prefs_path.write_bytes(plistlib.dumps(prefs))
        subprocess.run(['defaults', 'import', run.suite, str(prefs_path)], check=True, capture_output=True)
        run.launch()
        if args.flow == 'address-small':
            for i in range(8):
                run.open('/offer-' + str(i))
            run.ask('ui', sidebar=True)
            run.ask('resize', width=640, height=420, steps=1)
            run.ask('native', action='performance', front=True)
            run.ask('press', code=40, chars='k', mods=['cmd'])
            fields = wait(lambda: nodes('summon'),
                          lambda ns: any(n['role']=='AXTextField' and n['value']=='Fixture /offer-6' for n in ns),
                          'tab search did not offer the recent tab')
            # Prove keyboard routing through selection and Return, rather
            # than the containing field's accessibility focus metadata.
            field = next(n for n in fields if n['role']=='AXTextField')['frame']
            frame = next(n for n in fields if n['role']=='AXWindow')['frame']
            run.check(frame[0] <= field[0] and field[0]+field[2] <= frame[0]+frame[2],
                      'address field fits inside the small window')
            for _ in range(5):
                run.ask('press', code=125, chars='\uf701', mods=[])
            target = 'Fixture /offer-1'
            def visible_last():
                rows = nodes('last-suggestion')
                if not any(n['role']=='AXTextField' and n['value']==target for n in rows):
                    return None
                viewport = next((n['frame'] for n in rows if n['role']=='AXScrollArea'
                                 and n['frame'][0] <= field[0] < n['frame'][0]+n['frame'][2]), frame)
                return next((n for n in rows if n['role']=='AXStaticText' and n['value']==target
                             and n['frame'][0] >= field[0] and n['frame'][1] >= viewport[1]
                             and n['frame'][1]+n['frame'][3] <= viewport[1]+viewport[3]), None)
            wait(visible_last, lambda n: n is not None, 'keyboard-selected suggestion stayed below the window')
            run.check(True, 'keyboard navigation scrolls the last suggestion into view')
            shot('address-small-selected')
            run.ask('press', code=36, chars='\r', mods=[])
            wait(lambda: run.ask('tabs')['tabs'],
                 lambda ts: any(t['active'] and t['url']==run.origin+'/offer-1' for t in ts),
                 'Return did not activate the selected tab')
            selected = run.ask('tabs')
            (artifact / 'selected-tabs.json').write_text(json.dumps(selected, indent=2))
            run.check(len(selected['tabs'])==8, 'selecting a suggestion preserves every open tab')
        elif args.flow == 'favicon':
            run.check(not run.ask('native',action='favicon',cached=True,host='127.0.0.1')['available'],
                      'new host initially has no cached icon')
        if args.flow == 'startup':
            state = run.ask('native', action='startup')
            (artifact / 'launch-pool.json').write_text(json.dumps(state, indent=2))
            run.check(not state['created'] or state['windowVisible'], 'blank launch defers the process pool until a window is visible')
        tab = run.open('/' + args.flow)
        (artifact / 'menus.json').write_text(json.dumps(run.ask('native', action='menus'), indent=2))
        if args.flow == 'startup':
            state = run.ask('native', action='startup')
            run.check(state['created'] and state['windowVisible'], 'first navigation creates its pool after the window is visible')
            (artifact / 'navigation-pool.json').write_text(json.dumps(state, indent=2))
        elif args.flow == 'favicon':
            icon=wait(lambda:run.ask('native',action='favicon',path=str(artifact/'loaded-icon.png')),
                      lambda value:value.get('available'),'website favicon did not arrive')
            run.check(icon['pixels']==[64,64], 'network favicon is decoded to64physicalpixels')
            top,center,bottom=icon['verticalAlpha']
            run.check(top<.01 and center>.99 and bottom<.01,'wide source keeps its aspect ratio and transparent padding')
            wait(lambda:(run.profile/'icons/127.0.0.1.png').exists(),bool,'favicon was not persisted')
            run.ask('native',action='favicon',host='127.0.0.1',cached=True,evict=True)
            restored=wait(lambda:run.ask('native',action='favicon',host='127.0.0.1',cached=True,
                                        path=str(artifact/'reloaded-icon.png')),
                          lambda value:value.get('available'),'disk icon did not arrive after eviction')
            run.check(restored.get('available') and restored['pixels']==[64,64],
                      'a host first marked absent reloads from disk after cache eviction')
            run.check(restored['verticalAlpha']==icon['verticalAlpha'],'disk reload preserves the normalized artwork')
            (artifact/'favicon.json').write_text(json.dumps({'loaded':icon,'reloaded':restored},indent=2))
            shot('favicon-tab')
        elif args.flow == 'offscreen':
            result = subprocess.run(['python3', 'Tests/offscreen.py', '--world', args.world],
                                    cwd=ROOT, text=True, capture_output=True, timeout=240)
            (artifact / 'offscreen.log').write_text(result.stdout + '\n' + result.stderr)
            run.check(result.returncode == 0, 'real offscreen document lifecycle suite passes')
        elif args.flow == 'shield':
            run.ask('go', id=tab, url='https://en.as.com/')
            status = wait(lambda: run.js(tab, "({ready:document.readyState, slots:[...document.querySelectorAll('div.ad[data-adtype][data-slot]')].map(e=>({slot:e.dataset.slot,display:getComputedStyle(e).display})), articles:[...document.querySelectorAll('article')].filter(e=>e.getBoundingClientRect().height>0).length})"),
                          lambda v: v and v.get('ready') == 'complete' and v.get('slots'),
                          'AS page did not expose ad slots', timeout=40)
            (artifact / 'as-slots.json').write_text(json.dumps(status, indent=2))
            run.check(all(row['display'] == 'none' for row in status['slots']
                          if row['slot'] == '/7811748/as_mob/google/en'),
                      'verified AS ad wrappers are hidden')
            run.check(status['articles'] > 0, 'AS editorial content remains visible')
            shot('as-page')
        elif args.flow in ('blocker', 'blocker-off'):
            blocking = args.flow == 'blocker'
            def tabs():
                return run.ask('tabs')['tabs']
            def back_home():
                run.ask('go', id=tab, url=run.origin + '/blocker')
                wait(lambda: run.js(tab, 'location.pathname'), lambda p: p == '/blocker', 'fixture did not reload')
            # The blocker is compiled before the first page asks for it.
            wait(lambda: run.js(tab, 'document.readyState'), lambda s: s == 'complete', 'fixture did not load')
            before = len(tabs())

            run.ask('tap', id=tab, selector='#tracked')
            landed = wait(lambda: run.js(tab, 'location.pathname + location.search'),
                          lambda v: v and v.startswith('/landed'), 'tracked link did not navigate')
            run.check((landed == '/landed?id=5') == blocking, 'click-tracking parameters come off the address only when blocking: ' + str(landed))
            asked = [p for p in Fixture.seen if p.startswith('/landed')]
            run.check(bool(asked) and all('utm_' not in p and 'clid' not in p for p in asked) == blocking,
                      'the server sees the tracking parameters only when not blocking: ' + str(asked))


            back_home()
            run.ask('tap', id=tab, selector='#popad')
            time.sleep(1.5)
            run.check((len(tabs()) == before) == blocking, 'a window onto a pop-up network opens only when not blocking')
            if not blocking:
                (artifact / 'popup-tabs.json').write_text(json.dumps(tabs(), indent=2))
                before = len(tabs())
                run.ask('select', id=tab)
                time.sleep(.3)

            run.ask('tap', id=tab, selector='#blankpop')
            # Blocking: it opens, heads for the network, is refused and closes.
            # Without the blocker it stays open on its way there.
            seen_open = False
            end = time.monotonic() + (10 if blocking else 3)
            while time.monotonic() < end:
                current = tabs()
                seen_open = seen_open or len(current) > before
                if blocking and seen_open and len(current) == before:
                    break
                time.sleep(.005)
            (artifact / 'blank-popup-tabs.json').write_text(json.dumps(tabs(), indent=2))
            if blocking:
                run.check(seen_open and len(tabs()) == before, 'blank pop-up sent to an ad network opens, then closes')
                run.check(any(t['active'] and t['id'] == tab for t in tabs()),
                          'the page that opened the pop-up is back on screen')
                run.check(run.js(tab, 'location.pathname') == '/blocker', 'the opener page is left where it was')
                run.ask('tap', id=tab, selector='#okpop')
                opened = wait(tabs, lambda ts: len(ts) == before + 1, 'an ordinary window.open was blocked')
                run.check(any(t['url'] == run.origin + '/legit-window' for t in opened),
                          'an ordinary pop-up still opens')
            else:
                run.check(len(tabs()) > before, 'without the blocker the blank pop-up stays open')
            (artifact / 'requests.json').write_text(json.dumps(Fixture.seen, indent=2))
        elif args.flow == 'extensions':
            fixture = artifact / 'extension'
            shutil.copytree(ROOT / 'Tests/sidepanel/fixture', fixture)
            manifest = json.loads((fixture / 'manifest.json').read_text())
            manifest['host_permissions'] = ['http://127.0.0.1/*']
            (fixture / 'manifest.json').write_text(json.dumps(manifest))
            run.ask('ext-folder', path=str(fixture), yes=True)
            item = wait(lambda: run.ask('extensions')['extensions'],
                        lambda rows: any(r['name'] == 'Side panel fixture' and r['loaded'] for r in rows),
                        'side panel extension did not load', timeout=30)
            ext = next(r['id'] for r in item if r['name'] == 'Side panel fixture')
            def press_panel():
                run.ask('ext-press', id=ext)
                return run.ask('probe').get('panel')
            wait(press_panel, lambda p: isinstance(p, dict) and p.get('id') == ext,
                 'extension panel did not open')
            def panel_js(js):
                return run.ask('ext-panel', id=ext, js=js).get('value')
            wait(lambda: panel_js("document.getElementById('h')?.textContent"),
                 lambda v: v == 'Fixture panel', 'panel HTML did not render')
            def api(js):
                panel_js("window.__result=null; Promise.resolve(" + js +
                         ").then(value=>window.__result={value},e=>window.__result={error:String(e)});undefined")
                result = wait(lambda: panel_js('window.__result'), lambda v: v is not None,
                              'extension API did not settle')
                run.check('error' not in result, 'extension API succeeded: ' + js)
                return result.get('value')
            tabs = api('chrome.tabs.query({active:true})')
            run.check(any(t.get('url') == run.origin + '/extensions' for t in tabs),
                      'panel sees its real active web page')
            echo = api("chrome.runtime.sendMessage('panel-events')")
            run.check(any(str(e).startswith('opened:') for e in echo), 'worker receives panel open event')
            panel_window = api('chrome.windows.getCurrent()')['id']
            menu('File', 'New Window')
            second = run.open('/extension-second')
            run.ask('ext-press', id=ext)
            wait(lambda: run.ask('probe').get('panel'), lambda p: isinstance(p, dict),
                 'panel did not open in second window')
            wait(lambda: panel_js("document.getElementById('h')?.textContent"),
                 lambda v: v == 'Fixture panel', 'second panel did not render')
            tabs = api('chrome.tabs.query({})')
            (artifact / 'extension-tabs.json').write_text(json.dumps(tabs, indent=2))
            first = next(t for t in tabs if t.get('url') == run.origin + '/extensions')
            second_info = next(t for t in tabs if t.get('url') == run.origin + '/extension-second')
            run.check(first['windowId'] != second_info['windowId'], 'extension tabs retain distinct window IDs')
            created = api('chrome.tabs.create(' + json.dumps({'windowId': first['windowId'],
                          'url': run.origin + '/extension-target', 'active': False}) + ')')
            rows = run.ask('probe')['rows']
            first_owner = next(r for r in rows if any(t['id'] == tab for t in r['entries']))
            run.check(any(t['url'] == run.origin + '/extension-target' for t in first_owner['entries']),
                      'tabs.create honors the requested background window')
            target = next(i for i, row in enumerate(rows) if row['key'])
            run.ask('move-tab', id=tab, window=target)
            moved = api('chrome.tabs.get(' + str(first['id']) + ')')
            run.check(moved['windowId'] == second_info['windowId'], 'moving a tab preserves its extension tab ID')
            shot('extension-panel')
        elif args.flow == 'extension-shortcuts':
            fixture = artifact / 'extension'
            shutil.copytree(ROOT / 'Tests/sidepanel/fixture', fixture)
            manifest = json.loads((fixture / 'manifest.json').read_text())
            manifest['commands'] = {'mark-page': {'description': 'Mark fixture page', 'suggested_key': {'mac': 'Command+Shift+Y'}}}
            manifest['permissions'].append('storage')
            (fixture / 'manifest.json').write_text(json.dumps(manifest))
            with (fixture / 'worker.js').open('a') as f:
                f.write("\nchrome.commands.onCommand.addListener(name=>chrome.storage.local.get('hits').then(v=>chrome.storage.local.set({hits:(v.hits||0)+1})));\n")
            run.ask('ext-folder', path=str(fixture), yes=True)
            rows = wait(lambda: run.ask('extensions')['extensions'],
                        lambda rs: any(r['name']=='Side panel fixture' and r['loaded'] for r in rs),
                        'command fixture did not load')
            ext = next(r['id'] for r in rows if r['name']=='Side panel fixture')
            run.ask('ui', settings=True)
            settings_category('Extensions')
            controls = wait(lambda: nodes('commands'),
                            lambda ns: any(n['label']=='Shortcut for Mark fixture page' for n in ns),
                            'Extension command shortcut editor is missing')
            run.ask('native', action='press', label='Shortcut for Mark fixture page')
            run.ask('press', chars='t', code=17, mods=['cmd'])
            wait(lambda: nodes('conflict'), lambda ns: any('Used by New Tab' in str(n) for n in ns),
                 'browser shortcut conflict was not shown')
            run.ask('press', chars='u', code=32, mods=['cmd', 'opt'])
            wait(lambda: nodes('rebound'), lambda ns: any('⌥⌘U' in str(n) for n in ns),
                 'replacement shortcut was not saved')
            run.ask('ui', settings=False)
            run.ask('ext-press', id=ext)
            wait(lambda: run.ask('ext-panel', id=ext, js="document.getElementById('h')?.textContent").get('value'),
                 lambda v: v=='Fixture panel', 'panel did not render')
            def api(expr):
                run.ask('ext-panel', id=ext, js="window.__commandResult=null; Promise.resolve("+expr+").then(value=>window.__commandResult={value},e=>window.__commandResult={error:String(e)});undefined")
                r=wait(lambda: run.ask('ext-panel',id=ext,js='window.__commandResult').get('value'), lambda v:v is not None,'command API did not settle')
                if 'error' in r: raise AssertionError(r)
                return r.get('value')
            commands = api('chrome.commands.getAll()')
            run.check(any(c['name']=='mark-page' and 'U' in c['shortcut'].upper() for c in commands), 'extension reads its edited shortcut')
            run.ask('press', chars='u', code=32, mods=['cmd', 'opt'])
            wait(lambda: api("chrome.storage.local.get('hits')"), lambda v:v.get('hits')==1, 'new shortcut did not invoke worker')
            run.check(True, 'edited extension shortcut invokes its service worker')
            run.ask('native', action='save')
            run.stop()
            run.launch()
            run.ask('ui', settings=True)
            settings_category('Extensions')
            wait(lambda: nodes('persisted'), lambda ns:any('⌥⌘U' in str(n) for n in ns), 'extension shortcut did not persist')
            run.check(True, 'extension shortcut survives relaunch')
            run.ask('native', action='press', label='Clear shortcut for Mark fixture page')
            wait(lambda: nodes('cleared'), lambda ns:any(n['label']=='Shortcut for Mark fixture page' and n['value']=='None' for n in ns),
                 'clear did not remove the command shortcut')
            run.check(True, 'clear removes the extension command shortcut')
            run.ask('native', action='press', label='Reset shortcut for Mark fixture page')
            wait(lambda: nodes('reset'), lambda ns:any('⇧⌘Y' in str(n) for n in ns), 'manifest shortcut did not restore')
            run.check(True, 'clear and reset restore the manifest default')
        elif args.flow in ['restore-scripts', 'hidden-scripts']:
            fixture = artifact / 'extension'
            fixture.mkdir()
            (fixture / 'manifest.json').write_text(json.dumps({
                'manifest_version': 3, 'name': 'Restore script fixture', 'version': '1.0',
                'content_scripts': [{'matches': ['http://127.0.0.1/*'], 'js': ['content.js'],
                                     'run_at': 'document_start'}]}))
            (fixture / 'content.js').write_text("document.documentElement.setAttribute('data-extension-start','yes');")
            run.ask('ext-folder', path=str(fixture), yes=True)
            wait(lambda: run.ask('extensions')['extensions'],
                 lambda rows: any(r['name'] == 'Restore script fixture' and r['loaded'] for r in rows),
                 'content script extension did not load')
            run.ask('go', id=tab, url=run.origin + '/scripted')
            run.page(tab, '/scripted')
            run.check(run.js(tab, 'window.sawExtensionStart') is True,
                      'new navigation receives the extension at document_start')
            run.ask('native', action='save')
            run.stop()
            if args.flow == 'hidden-scripts':
                subprocess.run(['open', '-j', '-n', '--env', 'SEARCH_PROBE=' + args.world,
                                '--stdout', str(run.directory / 'app.log'),
                                '--stderr', str(run.directory / 'app.log'), str(run.app)], check=True)
                def process():
                    try:
                        return run.ask('native', action='process')
                    except (RuntimeError, OSError, ValueError, SystemExit):
                        return None
                proc = wait(process, lambda v: v is not None, 'hidden test app did not launch', timeout=30)
                run.check(proc['bundleID'] == run.report['bundleID'] and
                          Path(proc['executable']).resolve() == (run.app / 'Contents/MacOS/Search').resolve(),
                          'hidden launch belongs to the unique test app')
                run.process = OwnedLaunchedApp(proc['pid'])
                run.report['hiddenPID'] = proc['pid']
                run.check(proc['hidden'], 'open -j launches the restored app hidden')
                (artifact / 'hidden-process.json').write_text(json.dumps(proc, indent=2))
            else:
                run.launch()
            tab = run.restored('/scripted')
            run.ask('select', id=tab)
            run.page(tab, '/scripted')
            run.check(run.js(tab, 'window.sawExtensionStart') is True,
                      'restored navigation receives the extension at document_start')
        elif args.flow == 'layout':
            run.ask('ui', sidebar=True, side='right')
            run.ask('ui', folded=True, peek=True)
            tab_nodes = wait(lambda: nodes('right-peek'),
                             lambda rows: any('Fixture /layout' in (n['label'], n['value']) for n in rows),
                             'tab title did not appear in sidebar')
            probe = run.ask('probe')
            row = next(r for r in probe['rows'] if r['key'])
            frame = next(w['frame'] for w in probe['windows'] if w['number'] == row['host'])
            title = next(n for n in tab_nodes if 'Fixture /layout' in (n['label'], n['value']))
            shot('right-peek')
            run.check(title['frame'][0] >= frame[0] + frame[2] - probe['sideWidth'],
                      'folded right sidebar reveals at the right edge')
            run.ask('ui', side='left', folded=True, peek=False)
            run.ask('native', action='fullscreen')
            state = wait(lambda: run.ask('native', action='window-state'),
                         lambda v: v['fullscreen'], 'window did not enter fullscreen')
            run.ask('ui', peek=True)
            run.ask('ui', peek=False)
            state = wait(lambda: run.ask('native', action='window-state'),
                         lambda v: all(not b['hidden'] and b['x'] == 0 and b['y'] == 0 for b in v['buttons']),
                         'folding sidebar hides or translates fullscreen window controls')
            run.check(True, 'fullscreen window controls remain under AppKit control')
            run.ask('native', action='fullscreen')
        elif args.flow == 'selection':
            second = run.open('/selection-two')
            third = run.open('/selection-three')
            run.ask('ui', sidebar=True)
            def click_title(title, mods):
                frame = next(w['frame'] for w in run.ask('probe')['windows'] if w['visible'] and w['title'].startswith('Fixture'))
                def ready(ns):
                    return any(title in (n['label'], n['value']) and n['role'] == 'AXStaticText'
                               and frame[0] <= n['frame'][0] < frame[0]+frame[2] for n in ns)
                rows = wait(lambda: nodes('selection'),
                            ready,
                            'tab title missing: ' + title)
                item = next(n for n in rows if title in (n['label'], n['value']) and n['role'] == 'AXStaticText')
                x,y,w,h = item['frame']
                run.ask('native', action='click', x=x+w/2, y=y+h/2, mods=mods)
            def selected():
                return next(r['selected'] for r in run.ask('probe')['rows'] if r['key'])
            run.ask('select', id=tab)
            click_title('Fixture /selection-two', ['cmd'])
            wait(selected, lambda ids: tab in ids and second in ids,
                 'Command-click did not extend selection from active tab')
            menu('Tabs', 'Copy URLs of Selected Tabs')
            copied = subprocess.check_output(['pbpaste'], text=True).splitlines()
            run.check(copied == [run.origin+'/selection', run.origin+'/selection-two'],
                      'copy selected URLs preserves tab order')
            menu('Tabs', 'Unload Other Tabs')
            wait(lambda: run.ask('tabs')['tabs'],
                 lambda ts: next(t for t in ts if t['id']==third).get('asleep') is True,
                 'unselected background tab did not unload')
            remaining = run.ask('tabs')['tabs']
            run.check(all(not t['asleep'] for t in remaining if t['id'] in [tab, second]),
                      'bulk unload keeps the active and selected pages')
            run.ask('select', id=tab)
            click_title('Fixture /selection-three', ['shift'])
            wait(selected, lambda ids: set(ids) == {tab, second, third},
                 'Shift-click did not select the complete range')
            run.check(True, 'Shift-click selects a contiguous range from the active tab')
            run.ask('select', id=tab)
            menu('Tabs', 'Pin Tab')
            click_title('Fixture /selection-two', ['cmd'])
            wait(selected, lambda ids: set(ids) == {tab, second},
                 'active pin did not anchor the selection')
            click_native('1', 'AXStaticText', ['cmd'])  # 127.0.0.1 fixture's pin monogram
            wait(selected, lambda ids: set(ids) == {second},
                 'single Command-click on the active pin did not remove it from selection')
            run.check(True, 'active pin responds to one modified click without entering rename')
        elif args.flow == 'bookmarks-dial':
            run.ask('ui', sidebar=True)
            click_native('Reading', 'AXStaticText')
            click_native('Reference', 'AXStaticText')
            click_native('Book fixture', 'AXStaticText')
            current = next(t['id'] for t in run.ask('tabs')['tabs'] if t['active'])
            run.page(current, '/book-page')
            run.check(True, 'sidebar bookmark folders expand and their page opens')
            menu('Bookmarks', 'Add This Page to Speed Dial')
            dial = run.profile / 'SpeedDial/sites.json'
            wait(lambda: json.loads(dial.read_text()) if dial.exists() else [], lambda rows:len(rows)==1,
                 'native Add to Speed Dial did not save the site')
            run.ask('native', action='press', label='Speed Dial')
            wait(lambda: nodes('dial'), lambda ns:any(n['role']=='AXButton' and 'Book fixture' in (n['label'], n['title']) for n in ns),
                 'Speed Dial tile did not render')
            shot('bookmarks-dial')
            run.ask('native', action='press', label='Book fixture')
            current = next(t['id'] for t in run.ask('tabs')['tabs'] if t['active'])
            run.page(current, '/book-page')
            run.check(True, 'Speed Dial tile opens its saved page')
            run.ask('native', action='press', label='Downloads')
            wait(lambda: run.ask('probe')['downloads'], bool, 'sidebar Downloads button did not open the panel')
            run.ask('ui', downloads=False, sidebar=False)
            run.ask('native', action='press', label='Downloads')
            wait(lambda: run.ask('probe')['downloads'], bool, 'top Downloads button did not open the panel')
            run.check(True, 'Downloads buttons open the panel in both layouts')
            run.ask('ui', downloads=False)
            run.ask('native', action='save')
            run.stop()
            run.launch()
            run.ask('native', action='press', label='Speed Dial')
            wait(lambda: nodes('dial-restored'), lambda ns:any(n['role']=='AXButton' and 'Book fixture' in (n['label'], n['title']) for n in ns),
                 'saved Speed Dial tile missing after restart')
            run.check(True, 'Speed Dial site and nested bookmark survive restart')
        elif args.flow == 'groups':
            second = run.open('/group-second')
            third = run.open('/group-third')
            run.ask('ui', sidebar=True)
            run.ask('select', id=tab)
            menu('Tabs', 'Move to Group', 'New Group')
            click_native('Group name', 'AXTextField')
            run.ask('press', chars='a', code=0, mods=['cmd'])
            subprocess.run(['pbcopy'], input='Research', text=True, check=True)
            run.ask('press', chars='v', code=9, mods=['cmd'])
            run.ask('press', chars='\r', code=36)
            def group():
                rows = run.ask('probe')['rows']
                return next((g for r in rows if r['key'] for g in r['groups'] if g['name'] == 'Research'), None)
            wait(group, lambda g: g is not None, 'native group rename did not save')
            run.check(True, 'native menu creates a group and the heading renames it')
            run.ask('select', id=second)
            menu('Tabs', 'Move to Group', 'Research')
            run.ask('select', id=third)
            click_native('Research', 'AXStaticText')
            wait(group, lambda g: g['collapsed'], 'group heading did not collapse')
            def visible_titles():
                return [n['value'] for n in nodes('group-layout') if n['role'] == 'AXStaticText']
            titles = wait(visible_titles,
                          lambda ts: 'Fixture /groups' not in ts and 'Fixture /group-second' not in ts,
                          'collapsed group still shows background members')
            run.check('Fixture /group-third' in titles, 'collapse keeps ungrouped tabs visible')
            run.ask('select', id=tab)
            wait(group, lambda g: not g['collapsed'], 'selecting a grouped tab did not reveal its group')
            run.check(True, 'selecting a hidden member expands its group')
            click_native('Research', 'AXStaticText')
            wait(group, lambda g: g['collapsed'], 'active group did not collapse')
            wait(visible_titles, lambda ts: 'Fixture /groups' in ts and 'Fixture /group-second' not in ts,
                 'collapsed group does not keep its active member visible')
            run.check(True, 'collapsed group keeps its active tab visible')
            shot('sidebar-group')
            run.ask('ui', sidebar=False)
            wait(visible_titles, lambda ts: 'Research' in ts and 'Fixture /groups' in ts,
                 'group heading or active member missing in top tabs')
            shot('top-group')
            run.ask('native', action='save')
            run.stop()
            run.launch()
            wait(group, lambda g: g is not None and g['collapsed'], 'group metadata lost on restart')
            saved = json.loads((run.profile / 'session.json').read_text())
            row = next(w for w in saved['windows'] if any(g['name'] == 'Research' for g in w.get('groups', [])))
            gid = next(g['id'] for g in row['groups'] if g['name'] == 'Research')
            run.check({t['url'] for t in row['tabs'] if t.get('groupID') == gid} ==
                      {run.origin + '/groups', run.origin + '/group-second'},
                      'group membership and collapsed state survive restart')
            click_native('Research', 'AXStaticText')
            run.ask('ui', split=True)
            menu('Tabs', 'Split Tab')
            click_native('Fixture /group-second', 'AXStaticText')
            wait(lambda: run.ask('split'), lambda s:s['visible'], 'native Split Tab selection did not show both pages')
            run.check(True, 'native menu and second-tab click open split view')
            shot('native-split')
            menu('Tabs', 'Unsplit')
            wait(lambda: run.ask('split'), lambda s:not s['pairs'], 'native Unsplit did not release the pair')
            run.check(True, 'native Unsplit removes the pair')
        elif args.flow == 'settings-scroll':
            run.ask('ui', settings=True)
            settings_category('Tabs')
            before = run.ask('native', action='scroll-areas')['areas']
            scroll = max(before, key=lambda area:area['documentHeight']-area['height'])
            run.ask('native', action='scroll-areas', index=scroll['index'], lines=-3)
            def scrolled():
                return next(area for area in run.ask('native', action='scroll-areas')['areas'] if area['index']==scroll['index'])
            after = wait(scrolled,lambda area:area['y']>scroll['y']+60,'Settings wheel still barely moves a row')
            run.check(after['y'] < after['documentHeight']-after['height'], 'wheel scroll moves within the Settings page')
            run.ask('native',action='scroll-areas',index=scroll['index'],lines=3)
            wait(scrolled,lambda area:abs(area['y']-scroll['y'])<1,'reverse wheel did not return to the original position')
            run.check(True,'Settings wheel moves both ways without overshooting the top')
            (artifact/'settings-scroll.json').write_text(json.dumps({'before':before,'after':after},indent=2))
        elif args.flow == 'wake':
            other = run.open('/wake-other')
            run.ask('sleep',id=tab)
            run.check(next(t for t in run.ask('tabs')['tabs'] if t['id']==tab)['asleep'],'page releases its live view before wake')
            run.ask('native',action='navigation',reset=True)
            run.ask('select',id=tab)
            time.sleep(4.3)
            waiting = run.ask('native',action='navigation')
            target = next(t for t in waiting['tabs'] if t['id'].lower().startswith(tab.lower()))
            run.check(target['unpainted'] and target['cover'],'slow first paint keeps its saved picture beyond the old timer')
            run.page(tab,'/wake')
            after=wait(lambda:run.ask('native',action='navigation'),lambda s:s['retainedPictures']==0,
                       'finished wake kept decoded screenshot artwork')
            target=next(t for t in after['tabs'] if t['id'].lower().startswith(tab.lower()))
            run.check(not target['cover'] and not target['unpainted'] and target['alpha']==1,'woken page is opaque and no longer covered')
            events=[e for e in after['events'] if e['tab'].lower().startswith(tab.lower())]
            paint=next(e['time'] for e in events if e['event']=='firstFrame')
            uncover=next(e['time'] for e in events if e['event']=='uncover')
            run.check(uncover>=paint,'picture leaves only after the page paints')
            run.check(after['retainedPictures']==0,'finished fade releases the saved picture')
            (artifact/'wake.json').write_text(json.dumps({'waiting':waiting,'after':after},indent=2))
        elif args.flow == 'forms-churn':
            run.ask('native', action='performance', render=True)
            def forms(script):
                return run.ask('eval', id=tab, world='search', js=script).get('value')
            # Instrument only SearchX's isolated script world. Page code and
            # its own query costs are not attributed to the browser.
            forms("""(() => {
                window.formScans=[];
                const original=Document.prototype.querySelectorAll;
                Document.prototype.querySelectorAll=function(selector) {
                    const start=performance.now(), result=original.call(this,selector);
                    if(selector==='input[type="password"]') formScans.push(performance.now()-start);
                    return result;
                }; return true;
            })()""")
            run.js(tab,"""(() => {
                const deck=document.createElement('div');deck.id='cards';
                const fragment=document.createDocumentFragment();
                for(let i=0;i<8000;i++){const card=document.createElement('div');card.textContent='Card '+i;fragment.append(card)}
                deck.append(fragment);document.body.append(deck);window.churnCount=0;
                window.churn=setInterval(()=>{deck.firstChild.textContent='Frame '+(++churnCount)},16);
                return true;
            })()""")
            time.sleep(4)
            run.js(tab,'clearInterval(churn);true')
            measurements={'mutations':run.js(tab,'churnCount'),'passwordScansMs':forms('formScans')}
            (artifact/'form-scans.json').write_text(json.dumps(measurements,indent=2))
            run.js(tab,"""document.body.insertAdjacentHTML('beforeend',
                '<form id="signin"><input id="user" type="email"><input id="pass" type="password"></form>');
                window.changed=[];document.querySelector('#signin').addEventListener('input',e=>changed.push(e.target.id));true""")
            wait(lambda:forms('__officeForms.hasPassword()'),bool,'dynamic login not detected')
            run.check(forms('__officeForms.fill("test@example.com","local-test-only")'),'autofill finds a late login form')
            run.check(run.js(tab,'changed.includes("user") && changed.includes("pass")'),'autofill dispatches input events to the site')
            run.js(tab,"document.querySelector('#pass').type='text';true")
            run.check(not forms('__officeForms.hasPassword()'),'show-password changes are respected')
            run.js(tab,"document.querySelector('#pass').type='password';true")
            run.check(forms('__officeForms.hasPassword()'),'password input is recognized when its type returns')
            run.js(tab,"document.querySelector('#signin').remove();true")
            run.check(not forms('__officeForms.hasPassword()'),'removed forms release their fields')
            run.js(tab,"document.body.insertAdjacentHTML('beforeend','<input type=" + '"password" id="replacement" style="display:none">' + "');true")
            run.check(not forms('__officeForms.hasPassword()'),'hidden password does not offer autofill')
            run.js(tab,"document.querySelector('#replacement').style.display='block';true")
            run.check(forms('__officeForms.fill("","new-local-test")'),'a revealed replacement password field can be filled')
            run.check(run.js(tab,"document.querySelector('#replacement').value")=="new-local-test",'autofill reaches the current page field')
        elif args.flow == 'suggestions':
            def field():
                return run.ask('native', action='field')
            def queries():
                return [parse_qs(urlsplit(path).query).get('q', [''])[0]
                        for path in Fixture.seen if path.startswith('/suggest?')]
            run.ask('field', text='how many')
            suggestions = wait(field, lambda s: any(o['key']=='how many first' for o in s['offers']),
                               'provider suggestions never arrived', timeout=4)
            run.check(suggestions['typed']=='how many' and suggestions['completed']=='how many',
                      'suggestions do not replace typed words')
            keys = [o['key'] for o in suggestions['offers']]
            run.check(len(keys)==len(set(keys)) and '' not in keys, 'empty and duplicate suggestions are discarded')
            run.ask('field', text='slow old')
            wait(queries, lambda q:'slow old' in q, 'delayed request never started')
            run.ask('press', code=125, chars='\uf701', mods=[])
            chosen = field()['completed']
            wait(field, lambda s:any(o['key']=='slow old first' for o in s['offers']), 'delayed result missing')
            run.check(field()['completed']==chosen, 'arriving results preserve the selected row')
            run.ask('field', text='slow stale')
            wait(queries, lambda q:'slow stale' in q, 'stale request never started')
            run.ask('field', text='fresh query')
            wait(field, lambda s:any(o['key']=='fresh query first' for o in s['offers']), 'new query missing')
            time.sleep(1.3)
            run.check(all(not o['key'].startswith('slow stale') for o in field()['offers']), 'late response cannot overwrite a newer query')
            for query in ['https://example.com/account?token=secret', 'name@example.com', 'file:///tmp/private', 'localhost:8080/token', 'fixture local query']:
                before = len(queries())
                run.ask('field', text=query); time.sleep(.3)
                run.check(len(queries())==before, 'address stays local: ' + query)
            for query in ['malformed', 'oversized']:
                run.ask('field', text=query)
                wait(queries, lambda q:query in q, 'invalid-response request missing')
                time.sleep(.3)
                run.check(field()['completed']==query and len(field()['offers'])==1, 'bad suggestion response leaves search usable: ' + query)
            run.ask('field', text='🦊 travel')
            wait(field, lambda s:any(o['key']=='🦊 travel first' for o in s['offers']), 'Unicode completion missing')
            for _ in range(2): run.ask('press', code=125, chars='\uf701', mods=[])
            run.ask('press', code=51, chars='\x7f', mods=[])
            run.check(field()['typed']=='🦊 travel', 'deleting a Unicode completion preserves the typed prefix')
            run.ask('field', text='choose query')
            wait(field, lambda s:any(o['key']=='choose query second' for o in s['offers']), 'keyboard results missing')
            for _ in range(3): run.ask('press', code=125, chars='\uf701', mods=[])
            run.check(field()['completed']=='choose query second', 'arrow keys choose a completion')
            shot('suggestions-selected')
            run.ask('press', code=36, chars='\r', mods=[])
            wait(lambda: run.ask('tabs')['tabs'], lambda ts:any(t['active'] and 'q=choose%20query%20second' in t['url'] for t in ts),
                 'Return did not search for selected completion')
            run.check(not any('Cookie' in headers for headers in Fixture.suggestion_headers), 'suggestion requests do not reuse provider cookies')
            run.ask('ui', engine='bing')
            run.ask('field', text='bing query')
            wait(field, lambda s:any(o['key']=='bing query first' for o in s['offers']), 'selected engine did not suggest')
            run.check(any('engine=bing' in path for path in Fixture.seen), 'suggestions use the selected search engine')
            run.ask('field', text='slow opted out')
            wait(queries, lambda q:'slow opted out' in q, 'opt-out request never started')
            run.ask('ui', suggestions=False)
            time.sleep(1.3)
            run.check(not any(o['key']=='slow opted out first' for o in field()['offers']), 'turning suggestions off discards an in-flight reply')
            before = len(queries())
            run.ask('field', text='disabled query'); time.sleep(.4)
            run.check(len(queries())==before, 'typing with suggestions disabled stays local')
            run.ask('ui', suggestions=True)
            wait(field, lambda s:any(o['key']=='disabled query first' for o in s['offers']), 'live opt-in did not refresh suggestions')
            menu('File', 'New Private Window')
            before = len(queries())
            run.ask('field', text='private query'); time.sleep(.4)
            run.check(len(queries())==before, 'private-window typing never reaches the suggestion service')
            (artifact/'suggestions.json').write_text(json.dumps({'field':field(),'requests':Fixture.seen,
                                                               'headers':Fixture.suggestion_headers},indent=2))
        elif args.flow == 'core':
            run.js(tab, "document.cookie='marker=normal; Path=/; Max-Age=3600'; window.retainedState='still here'")
            first_window = run.ask('probe')['keyModel']
            menu('File', 'New Window')
            second = run.open('/second')
            rows = run.ask('probe')['rows']
            target = next(i for i, row in enumerate(rows) if row['key'])
            run.check(rows[target]['id'] != first_window, 'New Window creates an independent window')
            run.check(run.ask('move-tab', id=tab, window=target)['moved'], 'tab transfers to another window')
            run.check(run.js(tab, 'window.retainedState') == 'still here', 'tab transfer preserves live page state')
            run.ask('detach-tab', id=tab)
            rows = run.ask('probe')['rows']
            owners = [row for row in rows if any(t['id'] == tab for t in row['entries'])]
            run.check(len(owners) == 1 and len(rows) == 2, 'detach keeps one owner and two distinct windows')
            run.check(run.js(tab, 'window.retainedState') == 'still here', 'detach preserves live page state')
            menu('File', 'New Private Window')
            private = run.open('/private')
            run.check('marker=' not in run.js(private, 'document.cookie'), 'private window starts without normal cookies')
            run.js(private, "document.cookie='marker=private; Path=/; Max-Age=3600'")
            run.ask('select', id=tab)
            run.check('marker=normal' in run.js(tab, 'document.cookie'), 'private cookie does not replace normal cookie')
            rows = run.ask('probe')['rows']
            private_index = next(i for i, row in enumerate(rows) if row['private'])
            run.ask('close-window', window=private_index)
            menu('File', 'New Private Window')
            fresh = run.open('/private-fresh')
            run.check('marker=' not in run.js(fresh, 'document.cookie'), 'closed private window drops its cookies')
            run.ask('native', action='save')
            saved = json.loads((run.profile / 'session.json').read_text())
            urls = [t['url'] for row in saved['windows'] for t in row['tabs']]
            run.check(run.origin + '/core' in urls and run.origin + '/second' in urls,
                      'both normal windows are saved')
            run.check(all('/private' not in url for url in urls), 'private addresses are excluded from session')
            expected_windows = {row['id'] for row in saved['windows']}
            run.stop()
            run.launch()
            rows = run.ask('probe')['rows']
            run.check({r['id'] for r in rows} == expected_windows and not any(r['private'] for r in rows),
                      'restart restores normal window identities and excludes private windows')
            for path in ['/core', '/second']:
                restored = next(t['id'] for row in rows for t in row['entries'] if t['url'] == run.origin + path)
                run.ask('select', id=restored)
                run.page(restored, path)
            run.check('marker=normal' in run.js(restored, 'document.cookie'), 'normal cookies survive app restart')
            for _ in list(rows):
                run.ask('close-window', window=0)
            run.check(not run.ask('probe')['rows'], 'closing all windows removes every model')
            menu('File', 'New Window')
            run.open('/reopened')
            run.check(len(run.ask('probe')['rows']) == 1, 'New Window works after the last window closes')
        elif args.flow == 'spaces':
            run.ask('ui', spaces=True)
            first = tab
            first_window = run.ask('probe')['keyModel']
            first_space = next(r['space'] for r in run.ask('probe')['rows'] if r['key'])
            menu('File', 'New Window')
            run.ask('space', action='new', name='Second')
            second = run.open('/second-space')
            rows = run.ask('probe')['rows']
            expected = {r['id']: r['space'] for r in rows}
            run.check(len(rows) == 2 and len(set(expected.values())) == 2,
                      'two windows are on different Spaces before restart')
            run.ask('native', action='save')
            run.stop()
            run.launch()
            rows = run.ask('probe')['rows']
            run.check({r['id']: r['space'] for r in rows} == expected,
                      'restart restores each window to its own Space')
            for path in ['/spaces', '/second-space']:
                restored = next(t['id'] for row in rows for t in row['entries'] if t['url'] == run.origin + path)
                run.ask('select', id=restored)
                run.page(restored, path)
        elif args.flow == 'capture':
            subprocess.run(['pbcopy'], input='', text=True, check=True)
            menu('View', 'Capture Element', 'Copy Image…')
            run.ask('tap', id=tab, selector='#capture')
            image = wait(lambda: SUPPORT['BENCH']['ask'](run.socket_path, {
                'do': 'native', 'action': 'clipboard-image', 'path': str(artifact / 'element.png')}),
                lambda v: 'error' not in v, 'element capture did not reach clipboard')
            run.check(image['width'] == 180 and image['height'] == 90,
                      'clipboard image matches selected element dimensions')
            run.check(run.js(tab, 'location.pathname') == '/capture', 'capture consumes link navigation')
            run.ask('tap', id=tab, selector='#capture')
            run.page(tab, '/must-not-navigate')
            run.check(True, 'picker disarms after a capture; next click navigates')
        elif args.flow == 'downloads':
            run.ask('tap', id=tab, selector='#cancel-download')
            active = wait(lambda: run.ask('probe')['downloadsInProgress'],
                          lambda v: len(v) == 1 and v[0]['completed'] > 0,
                          'download did not report progress')
            run.report['downloadProgress'] = active
            fetching = run.ask('probe')['fetching']
            run.check(fetching['showing'] and not fetching['done'],
                      'the Downloads button comes while a file downloads')
            run.ask('ui', downloads=True)
            wait(lambda: nodes('download-progress'),
                 lambda ns: any('Cancel' in (n['label'], n['title']) for n in ns),
                 'download cancel control missing')
            shot('download-progress')
            run.check(run.ask('native', action='press', label='Cancel')['pressed'],
                      'cancel button responds')
            wait(lambda: run.ask('probe')['downloadsInProgress'], lambda v: not v,
                 'cancelled download stayed active')
            wait(lambda: run.ask('probe')['fetching'], lambda f: not f['showing'],
                 'a cancelled download took its button away')
            run.check(not (run.profile / 'downloads.json').exists() or
                      not json.loads((run.profile / 'downloads.json').read_text()),
                      'cancelled download is absent from completed history')
            run.ask('ui', downloads=False)
            destination = downloads / 'download-finish.bin'
            # The Finder's view of the file: a subscriber started before the
            # download sees its progress published, rising, then taken off.
            watcher = subprocess.Popen(['swift', str(ROOT / 'Tests/progress-watch.swift'), str(destination), '40'],
                                       stdout=subprocess.PIPE, text=True)
            time.sleep(8)  # the interpreter compiles the watcher first
            run.ask('tap', id=tab, selector='#finish-download')
            wait(lambda: destination.stat().st_size if destination.exists() else 0,
                 lambda n: n == len(PAYLOAD), 'finished download has wrong byte count')
            wait(lambda: run.ask('probe')['downloadsInProgress'], lambda v: not v,
                 'finished download stayed active')
            run.check(hashlib.sha256(destination.read_bytes()).digest() == hashlib.sha256(PAYLOAD).digest(),
                      'completed download bytes match fixture')
            (artifact / 'download-finish.bin').write_bytes(destination.read_bytes())
            history = wait(lambda: json.loads((run.profile / 'downloads.json').read_text())
                           if (run.profile / 'downloads.json').exists() else [],
                           lambda v: len(v) == 1, 'completed history missing')
            run.check(history[0]['path'] == str(destination), 'completed download is listed once')
            finished = run.ask('probe')
            finder = json.loads(watcher.communicate(timeout=60)[0].strip().splitlines()[-1])
            run.report['finderProgress'] = finder
            run.check(finder['seen'] > 1 and finder['last'] > finder['first'] and finder['unpublished'],
                      f'the file publishes its progress for the Finder and the Dock, then takes it off: {finder}')
            run.check(finished['fetching']['done'] and finished['fetching']['showing'],
                      'the Downloads button says the file is in')
            run.check(finished['announcedFile'] == str(destination),
                      'the Saved line can show the file in the Finder')
            wait(lambda: run.ask('probe')['fetching'], lambda f: not f['showing'],
                 'the Downloads button goes a moment after the last file', )
        elif args.flow == 'pin-home':
            menu('Tabs', 'Pin Tab')
            run.ask('go', id=tab, url=run.origin + '/pin-nested')
            run.page(tab, '/pin-nested')
            menu('File', 'Close Tab')
            run.ask('select', id=tab)
            run.page(tab, '/pin-home')
            run.check(True, 'putting down a pin restores its pinned address when enabled')
        elif args.flow == 'applescript':
            second = run.open('/script-second')
            run.ask('select', id=tab)
            def osa(body):
                script = 'tell application "' + str(run.app) + '"\n' + body + '\nend tell'
                r = subprocess.run(['osascript','-e',script],text=True,capture_output=True,timeout=120)
                (artifact/'script.applescript').write_text(script)
                (artifact/'osascript.log').write_text(r.stdout+r.stderr)
                if r.returncode: raise AssertionError(r.stderr)
                return r.stdout.strip()
            run.check(osa('get URL of current tab of window 1') == run.origin+'/applescript',
                      'AppleScript reads the active tab URL')
            run.check(osa('set selectedTab to current tab of window 1\nget URL of selectedTab') == run.origin+'/applescript',
                      'AppleScript object references keep the selected tab identity')
            run.ask('select', id=second)
            run.check(osa('set selectedTab to current tab of window 1\nget URL of selectedTab') == run.origin+'/script-second',
                      'AppleScript references the last tab without an index error')
            menu('File', 'New Private Window')
            run.open('/script-private')
            run.check(osa('count tabs of window 1') == '0', 'AppleScript excludes private tab metadata')
        elif args.flow == 'split':
            second = run.open('/split-second')
            run.ask('ui', split=True)
            run.ask('split', step='start', id=tab)
            run.ask('split', step='finish', id=second)
            run.ask('split', step='fraction', fraction=0.4)
            state = wait(lambda: run.ask('split'), lambda v:v['visible'] and len(v['pairs'])==1,
                         'split did not show both tabs')
            run.check(run.js(tab,'innerWidth') > 0 and run.js(second,'innerWidth') > 0,
                      'both split pages have a live viewport')
            run.js(tab, "window.splitRetained='left'")
            run.ask('ui', split=False)
            run.check(len(run.ask('split')['pairs']) == 1 and not run.ask('split')['visible'],
                      'disabling splits preserves the pair')
            run.ask('ui', split=True)
            run.check(run.js(tab,'window.splitRetained')=='left', 're-enabling split preserves live page state')
            run.ask('native', action='save')
            run.stop()
            run.launch()
            first=run.restored('/split')
            run.ask('select', id=first)
            state = wait(lambda: run.ask('split'), lambda v:v['visible'], 'split was not restored')
            run.check(abs(state['pairs'][0]['fraction']-0.4)<0.01, 'split divider position survives restart')
            run.ask('split', step='unsplit', id=first)
            run.check(not run.ask('split')['pairs'], 'unsplit restores independent tabs')
        elif args.flow == 'find':
            menu('Edit', 'Find on Page…')
            wait(lambda: nodes('find'), lambda ns: any(n['role']=='AXTextField' and n['focused'] for n in ns),
                 'Find input did not receive focus')
            run.ask('press', chars='f', code=3, mods=[])
            wait(lambda: nodes('find-typed'), lambda ns: any(n['role']=='AXTextField' and n['value']=='f' for n in ns),
                 'typing after Find did not enter the search field')
            run.check(True, 'Find immediately accepts typing in its input')
        elif args.flow == 'editor':
            run.ask('tap', id=tab, selector='#edit')
            subprocess.run(['pbcopy'], input='plain clipboard text', text=True, check=True)
            run.ask('keyeq', chars='v', code=9, mods=['shift'])
            value = wait(lambda: run.js(tab, "document.querySelector('#edit').value"),
                         lambda v: v == 'plain clipboard text', 'plain-text paste was intercepted')
            run.check(value == 'plain clipboard text', 'Command-Shift-V pastes into page input')
            run.check(run.js(tab, 'location.pathname') == '/editor', 'paste leaves page address intact')
            run.ask('keyeq', chars='\uf702', code=123, mods=['shift'])
            selection = run.js(tab, "({start:document.querySelector('#edit').selectionStart,end:document.querySelector('#edit').selectionEnd})")
            run.check(selection['end'] > selection['start'], 'Command-Shift-Left extends text selection')
        shot('final')
        run.report['passed'] = True
    except BaseException as error:
        run.report['passed'] = False
        run.report['error'] = str(error)
        try:
            nodes('failure')
            shot('failure')
        except Exception:
            pass
        raise
    finally:
        try:
            run.report['finalProbe'] = SUPPORT['BENCH']['ask'](run.socket_path, {'do': 'probe'}) if run.process and run.process.poll() is None else None
        except BaseException as error:
            run.report['finalProbeError'] = str(error)
        finally:
            run.stop()
        server.shutdown()
        (artifact / 'result.json').write_text(json.dumps(run.report, indent=2))
        print('ARTIFACT ' + str(artifact / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
