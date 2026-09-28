#!/usr/bin/env python3
"""Pop-ups, redirects and ads on live sites, in the real app, headless.

Three setups per site: the full blocker (lists on), the blocker with its
lists off (only what a click landed on decides, see Intent.swift), and no
blocker at all as the control. Each page is loaded, clicked at six points
the way a person would, and checked: new tabs the click wasn't aimed at,
the page itself sent to another site, clicks that never reached the page,
requests to hosts on the lists, visible ad frames, and a screenshot.
Run: swift build && python3 Tests/popup-live.py [url ...]
"""
import argparse, json, plistlib, re, runpy, subprocess, time, uuid
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
SITES = ['https://ww4.seeflix.to/home/',
         'https://ww4.seeflix.to/heart-of-the-beast/',
         'https://animekhor.org/',
         'https://animekhor.org/a-good-day-to-ascend-episode-13-subtitles-english-indonesian/']
POINTS = [(640, 420), (300, 600), (900, 300), (640, 700), (500, 250), (1000, 600)]
EVIDENCE = ROOT / '.local-resolution/evidence'

source = (ROOT / 'Sources/Search/ShieldRules.swift').read_text()
def listed(name):
    block = re.search(r'static let ' + name + r' = \[(.*?)\]', source, re.S)
    return set(re.findall(r'"([^"]+)"', block.group(1))) if block else set()
DOMAINS = listed('ads') | listed('trackers') | listed('popups')
def on_list(host):
    parts = host.split('.')
    return any('.'.join(parts[i:]) in DOMAINS for i in range(len(parts)))
def site(url):
    host = urlsplit(url).hostname or ''
    return '.'.join(host.split('.')[-2:])

# Counts clicks that reach the page, and what it shows that looks like an ad:
# visible frames from another site and full-window overlays on top.
WATCH = "window.__clicks = window.__clicks || 0; if (!window.__watching) { window.__watching = true; addEventListener('mousedown', () => window.__clicks++, true); } true"
READ = """(() => {
  const entries = performance.getEntriesByType('resource');
  const own = location.hostname.split('.').slice(-2).join('.');
  const frames = [...document.querySelectorAll('iframe')].filter(f => {
    const r = f.getBoundingClientRect(); const s = getComputedStyle(f);
    let h = ''; try { h = new URL(f.src, location.href).hostname } catch {}
    return r.width > 30 && r.height > 30 && s.visibility != 'hidden' && s.display != 'none' && h && !h.endsWith(own);
  }).map(f => { try { return new URL(f.src, location.href).hostname } catch { return '' } });
  const overlays = [...document.querySelectorAll('body *')].filter(e => {
    const s = getComputedStyle(e); if (s.position != 'fixed' && s.position != 'absolute') return false;
    const r = e.getBoundingClientRect(); return r.width >= innerWidth * .8 && r.height >= innerHeight * .8 && (+s.zIndex || 0) > 1000;
  }).length;
  return {requests: entries.length, hosts: entries.map(e => { try { return new URL(e.name).hostname } catch { return '' } }),
          frames, overlays, clicks: window.__clicks || 0, ready: document.readyState, url: location.href};
})()"""

# The page sits below the window's top bar; its height tells how far.
TARGET = """(() => { const e = document.elementFromPoint(%d, %d - (820 - innerHeight)); if (!e) return 'nothing';
  const a = e.closest('a'); if (e.tagName == 'IFRAME') { try { return 'frame ' + new URL(e.src).hostname } catch { return 'frame' } }
  return a ? 'link ' + a.href.slice(0, 80) : e.tagName.toLowerCase() + (e.className && typeof e.className == 'string' ? '.' + e.className.split(' ')[0] : ''); })()"""

def settle(run, tab, seconds=45):
    end, value = time.monotonic() + seconds, None
    while time.monotonic() < end:
        try:
            value = run.js(tab, READ)
            if value and value['ready'] == 'complete':
                break
        except RuntimeError:
            pass
        time.sleep(.5)
    return value

def measure(urls, mode, stamp):
    shield, lists = {'full': (True, True), 'listsOff': (True, False), 'off': (False, False)}[mode]
    args = argparse.Namespace(binary=str(ROOT / '.build/debug/Search'), world='pop-' + uuid.uuid4().hex[:8])
    run = SUPPORT['Run'](args, 'http://127.0.0.1:9')
    run.prepare()
    prefs_path = run.directory / 'prefs.plist'
    prefs = plistlib.loads(prefs_path.read_bytes())
    prefs.update({'shield': shield, 'shield.lists': lists})
    prefs_path.write_bytes(plistlib.dumps(prefs))
    subprocess.run(['defaults', 'import', run.suite, str(prefs_path)], check=True, capture_output=True)
    run.launch()
    results = {}
    try:
        run.ask('resize', width=1280, height=820, steps=1)
        if lists:
            time.sleep(20)  # the lists compile in the background on a fresh profile
        for url in urls:
            home = run.ask('open', url=url)['id']
            run.ask('select', id=home)  # opened behind; the clicks land on the tab on screen
            settle(run, home); time.sleep(8)
            loaded = run.js(home, READ)
            shot = EVIDENCE / f'popup-{stamp}-{mode}-{site(url)}-{len(results)}.png'
            run.ask('native', action='shot', path=str(shot))
            before = {t['id'] for t in run.ask('tabs')['tabs']}
            opened, sent, reached, targets = [], [], 0, []
            for x, y in POINTS:
                try: run.js(home, WATCH)
                except RuntimeError: pass
                clicks = (run.js(home, READ) or {}).get('clicks', 0)
                # What the press lands on: a link or an ad is a click aimed somewhere.
                try:
                    targets.append(run.js(home, TARGET % (x, y)))
                except RuntimeError:
                    targets.append(None)
                # Sent through the window, as WebKit reads a page's presses (NativeProbe "mouse").
                run.ask('native', action='mouse', x=x, y=y, steps=1)
                time.sleep(2.5)
                tabs = run.ask('tabs')['tabs']
                for t in tabs:
                    if t['id'] not in before:
                        opened.append(t['url']); before.add(t['id'])
                for little in run.ask('little', what='list').get('littles', []):
                    opened.append('window:' + little)
                    run.ask('little', what='close')
                now = next((t for t in run.ask('tabs')['tabs'] if t['id'] == home), None)
                after = (run.js(home, READ) or {}) if now else {}
                if after.get('clicks', 0) > clicks: reached += 1
                address = now['url'] if now else ''
                if address and site(address) != site(url):
                    sent.append(address)
                if address != url:
                    # Back to the page for the next click, as a person would.
                    run.ask('select', id=home)
                    run.js(home, 'location.href = %s' % json.dumps(url))
                    settle(run, home); time.sleep(3)
                else:
                    run.ask('select', id=home)
            log = run.ask('eval', id=home, log=True).get('entries', [])
            results[url] = {'targets': targets, 'newTabs': opened, 'sentAway': sent, 'clicksReached': reached, 'clicks': len(POINTS),
                            'requests': loaded['requests'],
                            'listedHosts': sorted({h for h in loaded['hosts'] if on_list(h)}),
                            'listedRequests': sum(1 for h in loaded['hosts'] if on_list(h)),
                            'adFrames': loaded['frames'], 'overlays': loaded['overlays'],
                            'blockerLog': len(log), 'screenshot': str(shot)}
            try: run.ask('close', id=home)
            except RuntimeError: pass
    finally:
        run.stop()
    return results

parser = argparse.ArgumentParser()
parser.add_argument('urls', nargs='*', default=SITES)
urls = parser.parse_args().urls
stamp = time.strftime('%Y%m%d-%H%M%S')
EVIDENCE.mkdir(parents=True, exist_ok=True)
report = {mode: measure(urls, mode, stamp) for mode in ('full', 'listsOff', 'off')}
out = EVIDENCE / f'popup-live-{stamp}.json'
out.write_text(json.dumps(report, indent=2))
for mode, sites in report.items():
    for url, r in sites.items():
        print(f"{mode:8} {url[8:60]:52} tabs {len(r['newTabs'])} away {len(r['sentAway'])} reached {r['clicksReached']}/{r['clicks']} "
              f"req {r['requests']} listed {r['listedRequests']} adFrames {len(r['adFrames'])} overlays {r['overlays']} log {r['blockerLog']}")
print('ARTIFACT', out)
