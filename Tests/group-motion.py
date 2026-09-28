#!/usr/bin/env python3
"""A group folding and unfolding in the sidebar, filmed, headless.

Three tabs are put in a group, then the group is collapsed and expanded while
the column's corner is drawn every 25 ms. A change made in one frame draws
two different pictures (before and after); one that animates draws a run of
in-between ones. Prints PASS/FAIL and writes the frames and a JSON report.

    swift build && python3 Tests/group-motion.py
"""
import argparse, hashlib, json, plistlib, runpy, subprocess, threading, time, uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))
server = ThreadingHTTPServer(('127.0.0.1', 0), HELPERS['PageHandler'])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS['Run'](argparse.Namespace(binary=str(ROOT / '.build/debug/Search'), world='motion-' + uuid.uuid4().hex[:8]),
                     f'http://127.0.0.1:{server.server_port}')
run.prepare()
prefs_path = run.directory / 'prefs.plist'
prefs = plistlib.loads(prefs_path.read_bytes())
prefs.update({'sidebar': True, 'tabs.groups': True})
prefs_path.write_bytes(plistlib.dumps(prefs))
subprocess.run(['defaults', 'import', run.suite, str(prefs_path)], check=True, capture_output=True)
run.launch()
report = {'films': {}}
try:
    run.ask('resize', width=1100, height=760, steps=1)
    ids = [run.open(p) for p in ('/one', '/two', '/three')]
    run.ask('audit', step='group', ids=ids)
    time.sleep(1)
    for name in ('collapse', 'expand'):
        path = str(run.directory / name)
        frames = run.ask('film', path=path, frames=16, every=0.025, action='collapse')['frames']
        files = [f.get('file') for f in frames if f.get('file')]
        digests = [hashlib.sha1(Path(f).read_bytes()).hexdigest() for f in files]
        distinct = len(dict.fromkeys(digests))
        report['films'][name] = {'distinctFrames': distinct, 'times': [f['t'] for f in frames], 'files': files}
        run.check(distinct >= 4, f'{name}: {distinct} different frames, so it moves rather than cuts')
        time.sleep(1)
finally:
    run.stop()
    out = run.directory / 'group-motion.json'
    out.write_text(json.dumps(report, indent=2))
    print('ARTIFACT', out)
