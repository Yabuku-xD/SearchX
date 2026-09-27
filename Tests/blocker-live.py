#!/usr/bin/env python3
"""Live ad-heavy pages with the blocker on and off, in isolated test worlds.

Counts what each page fetched (Resource Timing), how many bytes crossed the
network, and how many requests went to hosts on the blocker's lists.
Run: swift build && python3 Tests/blocker-live.py
"""
import argparse, json, re, runpy, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
PAGES = ['https://www.theverge.com/', 'https://www.cnn.com/', 'https://www.dailymail.co.uk/home/index.html']
source = (ROOT / 'Sources/Search/ShieldRules.swift').read_text()
def listed(name):
    block = re.search(r'static let ' + name + r' = \[(.*?)\]', source, re.S).group(1)
    return set(re.findall(r'"([^"]+)"', block))
DOMAINS = listed('ads') | listed('trackers') | listed('popups')

def on_list(host):
    parts = host.split('.')
    return any('.'.join(parts[i:]) in DOMAINS for i in range(len(parts)))

READ = """(() => {
  const entries = performance.getEntriesByType('resource');
  const hosts = entries.map(e => { try { return new URL(e.name).host } catch { return '' } });
  return {requests: entries.length, bytes: entries.reduce((a, e) => a + (e.transferSize || 0), 0),
          hosts, ready: document.readyState};
})()"""

def measure(shield):
    args = argparse.Namespace(binary=str(ROOT / '.build/debug/Search'), world='live-' + uuid.uuid4().hex[:8])
    run = SUPPORT['Run'](args, 'http://127.0.0.1:9')
    run.prepare()
    subprocess.run(['defaults', 'write', run.suite, 'shield', '-bool', 'true' if shield else 'false'], check=True)
    run.launch()
    results = {}
    try:
        for url in PAGES:
            tab = run.ask('open', url=url)['id']
            end = time.monotonic() + 45
            value = None
            while time.monotonic() < end:
                value = run.js(tab, READ)
                if value and value['ready'] == 'complete':
                    break
                time.sleep(.5)
            time.sleep(8)  # the ads a page loads after its own load event
            value = run.js(tab, READ)
            results[url] = {'requests': value['requests'], 'bytes': value['bytes'],
                            'listedRequests': sum(1 for h in value['hosts'] if on_list(h)),
                            'listedHosts': sorted({h for h in value['hosts'] if on_list(h)})}
            run.ask('close', id=tab)
    finally:
        run.stop()
    return results

report = {'pages': PAGES, 'on': measure(True), 'off': measure(False)}
out = ROOT / ('.local-resolution/evidence/blocker-live-' + time.strftime('%Y%m%d-%H%M%S') + '.json')
out.write_text(json.dumps(report, indent=2))
for url in PAGES:
    on, off = report['on'][url], report['off'][url]
    print(f"{url}: requests {off['requests']} -> {on['requests']}, bytes {off['bytes']} -> {on['bytes']}, listed {off['listedRequests']} -> {on['listedRequests']}")
print('Report:', out)
