#!/usr/bin/env python3
"""The pop-up checks with no lists at all, in the real app, on live sites.

Filter lists off (Settings › Privacy › Use filter lists), so only what the
click landed on decides (see Intent.swift). Each site is loaded, then clicked
the way a person would — a few places on the page, real events at real
points — and the tabs are counted: a new tab the click was not aimed at is a
pop-up that got through. Also the same with the blocker off entirely, as the
control that shows each site does open pop-ups.
Run: swift build && python3 Tests/popup-live.py [url ...]
"""
import argparse, json, plistlib, runpy, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
SITES = ['https://ww4.seeflix.to/heart-of-the-beast/',
         'https://animekhor.org/a-good-day-to-ascend-episode-13-subtitles-english-indonesian/']

def measure(urls, shield, lists):
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
        for url in urls:
            run.ask('bookmark', new=True, url=url)
            home = next(t['id'] for t in run.ask('tabs')['tabs'] if t['active'])
            time.sleep(10)
            before = {t['id'] for t in run.ask('tabs')['tabs']}
            frame = next(w['frame'] for w in run.ask('probe')['windows'] if w['visible'])
            # Screen points from the bottom left; the clicks below are from the window's top left.
            screen_y = lambda y: frame[1] + frame[3] - y
            opened, landed = [], []
            for x, y in [(640, 420), (300, 600), (900, 300), (640, 700), (500, 250), (1000, 600)]:
                subprocess.run(['osascript', '-e', 'tell application id "%s" to activate' % run.report['bundleID']], capture_output=True)
                run.ask('native', action='click', x=frame[0] + x, y=screen_y(y), mods=[])
                time.sleep(2.2)
                tabs = run.ask('tabs')['tabs']
                for t in tabs:
                    if t['id'] not in before:
                        opened.append(t['url']); before.add(t['id'])
                active = next((t for t in tabs if t['active']), None)
                if active and active['id'] == home:
                    landed.append(active['url'])
                elif active:
                    # Back to the page for the next click, as a person would close the ad.
                    run.ask('select', id=home)
            results[url] = {'newTabs': opened, 'homeAddresses': landed}
            for t in run.ask('tabs')['tabs']:
                if t['id'] != home and t['url'] not in ('',):
                    pass
    finally:
        run.stop()
    return results

parser = argparse.ArgumentParser()
parser.add_argument('urls', nargs='*', default=SITES)
urls = parser.parse_args().urls
report = {'behaviourOnly': measure(urls, True, False), 'blockerOff': measure(urls, False, False)}
out = ROOT / ('.local-resolution/evidence/popup-live-' + time.strftime('%Y%m%d-%H%M%S') + '.json')
out.write_text(json.dumps(report, indent=2))
for mode, sites in report.items():
    for url, r in sites.items():
        print(mode, url.split('/')[2], 'new tabs:', len(r['newTabs']), [u.split('/')[2] if '//' in u else u for u in r['newTabs']])
print('ARTIFACT', out)
