#!/usr/bin/env python3
"""Drag-pan a canvas page as fast as a hand can, and read what it cost.

Presses the left button on empty canvas (no link, image, button or video
under it), drags back and forth across most of the window six times a
second at 1000 events a second, and lets go, through the app's own event
queue (the DEBUG probe), so the run needs neither the pointer nor focus. The
page records every animation frame, every drag move it receives with the
button held, and where one of its cards sits on screen each frame, so a pan
that does not follow shows up as well as a slow one.

Run: swift build && python3 Tests/drag-pan.py [--url URL] [--seconds 8] [--binary PATH]
Artifact: .local-resolution/evidence/drag-pan-<world>/result.json
"""
import argparse, json, runpy, subprocess, threading, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = runpy.run_path(str(ROOT / 'Tests/chrome_support.py'))

LOGGER = r'''(() => {
  const out = window.__pan = {frames: [], moves: 0, dragMoves: 0, card: []};
  const card = [...document.querySelectorAll('a')].find(a => {
    const r = a.getBoundingClientRect(); return r.width > 40 && r.height > 40 && r.top > 0 && r.top < innerHeight;
  });
  out.hasCard = !!card;
  function loop(t) {
    out.frames.push(t);
    if (card) { const r = card.getBoundingClientRect(); out.card.push([t, r.x, r.y]); }
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
  addEventListener('pointermove', e => { out.moves++; if (e.buttons & 1) out.dragMoves++; }, {passive: true, capture: true});
  return true;
})()'''

EMPTY = r'''(() => {
  const busy = 'a, button, img, video, input, textarea, select, [role=button], [contenteditable]';
  for (let y = innerHeight * 0.3; y < innerHeight * 0.9; y += 12)
    for (let x = innerWidth * 0.2; x < innerWidth * 0.8; x += 12) {
      const e = document.elementFromPoint(x, y);
      if (e && !e.closest(busy)) return [x, y];
    }
  return null;
})()'''

READ = r'''(() => { const p = window.__pan; return {frames: p.frames, moves: p.moves, dragMoves: p.dragMoves,
  card: p.card, hasCard: p.hasCard}; })()'''


def cpu(pids):
    out = subprocess.run(['ps', '-o', 'pid=,%cpu=', '-p', ','.join(map(str, pids))], capture_output=True, text=True).stdout
    return {int(a): float(b) for a, b in (line.split() for line in out.strip().splitlines())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default='https://uselayouts.com/browse')
    ap.add_argument('--seconds', type=float, default=8)
    # As hard as a hand goes: nearly the whole window, six swings a second,
    # a 1000 Hz mouse.
    ap.add_argument('--rate', type=float, default=1000)
    ap.add_argument('--hz', type=float, default=6)
    ap.add_argument('--dx', type=float, default=520)
    ap.add_argument('--dy', type=float, default=330)
    ap.add_argument('--binary', default=str(ROOT / '.build/debug/Search'))
    ap.add_argument('--shield', default='on', choices=['on', 'off'])
    ap.add_argument('--stacks', action='store_true', help='sample both processes mid-drag (adds pauses)')
    ap.add_argument('--hz120', default='on', choices=['on', 'off'], help='Settings › Pages at 120 Hz')
    args = ap.parse_args()
    args.world = 'pan-' + uuid.uuid4().hex[:8]
    run = SUPPORT['Run'](args, 'http://127.0.0.1:1')
    artifact = ROOT / '.local-resolution/evidence' / ('drag-pan-' + args.world)
    artifact.mkdir(parents=True)
    report = {'url': args.url, 'rate': args.rate, 'hz': args.hz, 'dx': args.dx, 'dy': args.dy, 'seconds': args.seconds, 'binary': args.binary,
              'command': 'python3 Tests/drag-pan.py --url ' + args.url}
    try:
        run.prepare()
        subprocess.run(['defaults', 'write', run.suite, 'shield', '-bool', 'true' if args.shield == 'on' else 'false'], check=True)
        report['shield'] = args.shield
        subprocess.run(['defaults', 'write', run.suite, 'pages.120', '-bool', 'true' if args.hz120 == 'on' else 'false'], check=True)
        report['hz120'] = args.hz120
        run.launch()
        run.ask('native', action='performance', front=True, render=True)
        run.ask('resize', width=1280, height=860, steps=1)
        tab = run.ask('open', url=args.url)['id']
        # A tab the bench opens stays in the background until picked: hidden,
        # it gets no frames at all.
        run.ask('select', id=tab)
        end = time.monotonic() + 60
        while time.monotonic() < end and run.js(tab, 'document.readyState') != 'complete':
            time.sleep(.4)
        time.sleep(3)
        run.ask('native', action='performance', front=True)
        probe = run.ask('probe')
        host = next(r for r in probe['rows'] if r['key'])['host']
        wx, wy, ww, wh = next(w['frame'] for w in probe['windows'] if w['number'] == host)
        spot = run.js(tab, EMPTY)
        if not spot:
            raise RuntimeError('no empty canvas under the grid')
        # In front, and never treated as hidden, for the page being measured:
        # a page WebKit thinks is out of sight gets no frames at all.
        run.ask('native', action='performance', front=True, render=True)
        time.sleep(.5)
        run.js(tab, LOGGER)
        pids = [run.process.pid, *run.ask('native', action='performance').get('webPIDs', [])]
        samples = []
        stop = threading.Event()
        def sampler():
            while not stop.is_set():
                samples.append(cpu(pids))
                time.sleep(.5)
        thread = threading.Thread(target=sampler, daemon=True)
        thread.start()
        if args.stacks:
            def stacks():
                time.sleep(2)
                for pid in pids:
                    subprocess.Popen(['sample', str(pid), '3', '-file', str(artifact / ('stack-%d.txt' % pid))],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            threading.Thread(target=stacks, daemon=True).start()
        # Pressed on empty canvas; once held, a drag stays the page's
        # wherever the pointer goes.
        run.ask('native', action='drag', x=spot[0], y=spot[1], rate=args.rate, seconds=args.seconds,
                hz=args.hz, dx=args.dx, dy=args.dy)
        time.sleep(args.seconds + .6)
        drove = run.ask('native', action='drag-sent')
        report['after'] = run.js(tab, '({href: location.href, logger: !!window.__pan})')
        stop.set()
        thread.join()
        data = run.js(tab, READ)
        frames = data['frames']
        gaps = sorted(b - a for a, b in zip(frames, frames[1:]))
        card = data['card']
        moved = [abs(b[1] - a[1]) + abs(b[2] - a[2]) for a, b in zip(card, card[1:])]
        report.update(
            point=spot, posted=drove.get('sent'), moves=data['moves'], dragMoves=data['dragMoves'],
            frames=len(frames),
            fps=round(1000 * (len(frames) - 1) / (frames[-1] - frames[0]), 1) if len(frames) > 1 else 0,
            p50=gaps[len(gaps) // 2] if gaps else None, p95=gaps[int(len(gaps) * .95)] if gaps else None,
            p99=gaps[int(len(gaps) * .99)] if gaps else None, max=gaps[-1] if gaps else None,
            over12_5=round(100 * sum(g > 12.5 for g in gaps) / max(1, len(gaps)), 2),
            over25=round(100 * sum(g > 25 for g in gaps) / max(1, len(gaps)), 2),
            contentMovedFrames=sum(m > 0.5 for m in moved), cardTracked=data['hasCard'],
            longFrames=[[round(a - frames[0]), round(b - a, 1)] for a, b in zip(frames, frames[1:]) if b - a > 20],
            cpu=samples)
        run.report['passed'] = True
    finally:
        run.stop()
        (artifact / 'result.json').write_text(json.dumps(report, indent=2))
    keys = ['posted', 'fps', 'p50', 'p95', 'p99', 'max', 'over12_5', 'over25', 'contentMovedFrames']
    print(json.dumps({k: report.get(k) for k in keys}))
    print('Artifact:', artifact / 'result.json')


if __name__ == '__main__':
    main()
