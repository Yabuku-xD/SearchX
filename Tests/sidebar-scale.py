#!/usr/bin/env python3
"""Does SearchX slow down as its sidebar grows? The same workloads with a
small sidebar and with a big one — 150 tabs, 10 groups, 12 pins, restored
asleep as after a relaunch — each measured as SearchX's main thread against
the display (NativeProbe "hitches"), headless like Tests/smoothness.py.

Needs the probes; for numbers that mean something, an optimised build:
  swift build -c release -Xswiftc -DDEBUG --build-path .build-probe
  python3 Tests/sidebar-scale.py .build-probe/release/Search
Prints one JSON line per sidebar size.
"""
import json, statistics, sys, time, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
src = (ROOT / 'Tests/smoothness.py').read_text()
env = {'__file__': str(ROOT / 'Tests/smoothness.py')}
exec(src[:src.index('PERF = ')], env)
Headless, PAGES = env['Headless'], env['PAGES']
for i in range(6):
    PAGES[f'/live{i}'] = (f'<!doctype html><title>Live page {i}</title><body style="margin:0;font:15px system-ui">'
                         + ''.join(f'<p style="padding:6px 30px">Row {j} of page {i}</p>' for j in range(300)) + '</body>').encode()

def session(big):
    if not big:
        return ([], [])
    groups = [{'id': str(uuid.uuid4()).upper(), 'name': f'Group {g + 1}', 'collapsed': False} for g in range(10)]
    tabs = [{'url': '{origin}/pin%d' % i, 'title': f'Pinned {i}', 'pin': chr(65 + i)} for i in range(12)]
    for g, group in enumerate(groups):
        tabs += [{'url': '{origin}/g%d-%d' % (g, i), 'title': f'Group {g + 1} tab {i}', 'groupID': group['id']} for i in range(10)]
    tabs += [{'url': '{origin}/loose%d' % i, 'title': f'Loose tab {i}'} for i in range(38)]
    return (tabs, groups)

def hitches(h, seconds, during):
    h.ask('native', action='hitches', start=True)
    end = time.time() + seconds
    while time.time() < end:
        during()
    out = h.ask('native', action='hitches')
    return {'missed': out['missed'], 'worstMs': round(out['worstMs'], 1), 'p99Ms': round(out['p99Ms'], 1)}

def row_at(h, title):
    """Where a row of the column sits, in window points from the top left —
    found through its accessibility frame (screen points, from the bottom)."""
    nodes = h.ask('native', action='nodes')['nodes']
    window = nodes[0]['frame']
    x, y, w, height = next(n['frame'] for n in nodes if n['role'] == 'AXStaticText' and n['value'] == title)
    return x - window[0] + w / 2, window[1] + window[3] - (y + height / 2)

def measure(binary, big):
    h = Headless(binary, prefs={'sidebar': True, 'sidebar.hides': False, 'tabs.groups': True}, session=session(big))
    out = {'tabs': len(h.ask('tabs')['tabs'])}
    try:
        live = [h.open(f'/live{i}') for i in range(6)]
        h.render(); time.sleep(1.5)
        out['sidebarTabs'] = len(h.ask('tabs')['tabs'])
        turn = {'i': 0}
        def switch():
            turn['i'] += 1; h.ask('select', id=live[turn['i'] % len(live)]); time.sleep(0.3)
        out['switching'] = hitches(h, 6, switch)
        # Typing, a character at a time, each timed until the app rests.
        typed = h.ask('field', text='wikipedia org news', type=True)
        rest = [ms[1] for ms in typed.get('ms', [])]
        out['typing'] = {'medianMs': round(statistics.median(rest), 1), 'worstMs': round(max(rest), 1)} if rest else typed
        h.ask('audit', step='dismiss'); time.sleep(0.5)
        def resize():
            h.ask('resize', width=1000, height=700, steps=40); h.ask('resize', width=1300, height=860, steps=40)
        out['resizing'] = hitches(h, 4, resize)
        def drag():
            # A row carried two rows and a bit down and back, so the order ends as it began.
            h.ask('native', action='mouse', x=x, y=y, dx=0, dy=70, steps=40); time.sleep(0.8)
            h.ask('native', action='mouse', x=x, y=y + 70, dx=0, dy=-70, steps=40); time.sleep(0.8)
        x, y = row_at(h, 'Live page 1')
        # The row really is carried: the order changes on the way down and
        # is the same again on the way back — else the numbers are for nothing.
        ids = lambda: [t['id'] for t in h.ask('tabs')['tabs']]
        order = ids()
        h.ask('native', action='mouse', x=x, y=y, dx=0, dy=70, steps=40); time.sleep(0.8)
        moved = ids() != order
        h.ask('native', action='mouse', x=x, y=y + 70, dx=0, dy=-70, steps=40); time.sleep(0.8)
        took = moved and ids() == order
        out['dragging'] = hitches(h, 4, drag)
        out['dragging']['tookHold'] = took
        h.ask('ui', folded=True); time.sleep(0.8)
        state = {'out': False}
        def slide():
            state['out'] = not state['out']; h.ask('ui', slide=state['out']); time.sleep(0.45)
        out['sliding'] = hitches(h, 6, slide)
    finally:
        h.stop()
    return out

binary = sys.argv[1] if len(sys.argv) > 1 else None
for big in (False, True):
    print(json.dumps({'big' if big else 'small': measure(binary, big)}), flush=True)
