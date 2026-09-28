#!/usr/bin/env python3
"""Mouse wheel steps glide; continuous scrolling passes through untouched.

A step of whole lines (a plain wheel, or LinearMouse's By Lines) must reach
the page as a glide over several frames that ends exactly where WebKit's own
step would (40 points a line). A continuous event (a trackpad, or a mouse
tool that already smooths) must land at once, unchanged, so nothing is
smoothed twice. Run after swift build: python3 Tests/wheel-glide.py
The JSON report path is printed at the end.
"""
import argparse
import json
from pathlib import Path
import runpy
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / "Tests/chrome_support.py"))
parser = argparse.ArgumentParser()
parser.add_argument("--binary", default=str(ROOT / ".build/debug/Search"))
parser.add_argument("--output", type=Path)
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", 0), HELPERS["PageHandler"])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS["Run"](argparse.Namespace(binary=args.binary,
                                     world="wheel-" + uuid.uuid4().hex[:8]),
                     f"http://127.0.0.1:{server.server_port}")

RECORD = """(function () {
  window.scrollTo(0, 5000);
  const out = window.trace = [];
  const t0 = performance.now();
  function frame(now) {
    out.push([Math.round(now - t0), window.scrollY]);
    if (now - t0 < 900) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  return true;
})()"""


def trace(tab, **wheel):
    run.js(tab, RECORD)
    time.sleep(0.1)
    run.ask("wheel", **wheel)
    time.sleep(1.0)
    samples = run.js(tab, "window.trace")
    run.check(len(samples) >= 10, "wheel recording receives foreground animation callbacks")
    start = samples[0][1]
    moved = [(t, y - start) for t, y in samples]
    changes = [t for (t, y), (_, before) in zip(moved[1:], moved) if y != before]
    return {"samples": moved, "distance": moved[-1][1],
            "frames": len(changes), "span": (changes[-1] - changes[0]) if changes else 0}


try:
    run.prepare()
    run.launch()
    tab = run.open("/wheel-glide")
    run.js(tab, "document.body.style.minHeight = '20000px'; true")
    run.ask("resize", width=1100, height=760)
    run.ask("native", action="performance", render=True)
    deadline = time.monotonic() + 3
    while run.js(tab, "document.hidden") and time.monotonic() < deadline:
        time.sleep(.1)
    run.check(not run.js(tab, "document.hidden"), "measured wheel page is visible to WebKit")

    flat = trace(tab, pixels=-120)
    run.report["continuous"] = flat
    run.check(flat["distance"] == 120 and flat["frames"] <= 2,
              f"continuous 120 pt lands at once, untouched ({flat['distance']} pt over {flat['frames']} frames)")

    step = trace(tab, lines=-3)
    run.report["lineStep"] = step
    run.check(step["distance"] == 120,
              f"a 3-line step goes WebKit's own 120 pt ({step['distance']} pt)")
    run.check(step["frames"] >= 6 and 60 <= step["span"] <= 400,
              f"it glides over {step['frames']} frames in {step['span']} ms")

    spin = trace(tab, lines=-1, count=10, ms=20)
    run.report["spin"] = spin
    ys = [y for _, y in spin["samples"]]
    run.check(spin["distance"] == 400 and all(b >= a for a, b in zip(ys, ys[1:])),
              f"ten quick steps add up to 400 pt without stepping back ({spin['distance']} pt)")

    run.js(tab, RECORD)
    time.sleep(0.1)
    run.ask("wheel", lines=-3)
    time.sleep(0.05)
    run.ask("wheel", lines=3)
    time.sleep(1.0)
    samples = run.js(tab, "window.trace")
    ys = [y - samples[0][1] for _, y in samples]
    run.report["reverse"] = ys
    run.check(max(ys) > 0 and ys[-1] < max(ys) - 60,
              f"a step the other way turns the glide round (peak {max(ys)} pt, end {ys[-1]} pt)")

    # Player settings menus often handle wheel events themselves. Their default
    # action must remain cancellable even after coarse input is interpolated.
    run.js(tab, """(() => {
      window.scrollTo(0, 2000);
      const menu = document.createElement('div'); menu.id = 'player-menu';
      menu.style.cssText = 'position:fixed;left:25%;top:25%;width:50%;height:50%;overflow:auto;background:#222';
      menu.innerHTML = '<div style="height:3000px">Player settings</div>';
      document.body.append(menu);
      window.wheelEvents = [];
      menu.addEventListener('wheel', e => {
        window.wheelEvents.push({dy:e.deltaY, cancelable:e.cancelable, prevented:e.defaultPrevented});
        if (window.scriptedMenu) {
          e.preventDefault(); e.stopPropagation(); menu.scrollTop += e.deltaY;
        }
      }, {passive:false});
      return true;
    })()""")
    for scripted in (False, True):
        for wheel in ({"lines": -3}, {"pixels": -120}):
            run.js(tab, f"window.scriptedMenu = {str(scripted).lower()}; document.querySelector('#player-menu').scrollTop = 500; window.scrollTo(0,2000); window.wheelEvents = []; true")
            time.sleep(0.15)
            before = run.js(tab, "({inner:document.querySelector('#player-menu').scrollTop, outer:window.scrollY})")
            run.ask("wheel", **wheel)
            time.sleep(0.65)
            after = run.js(tab, "({inner:document.querySelector('#player-menu').scrollTop, outer:window.scrollY, events:window.wheelEvents})")
            case = {"scripted": scripted, "input": wheel, "before": before, "after": after}
            run.report.setdefault("nested", []).append(case)
            run.check(after["inner"] > before["inner"] and after["outer"] == before["outer"],
                      f"{'scripted' if scripted else 'native'} menu consumes {wheel} without moving page")
            if scripted:
                run.js(tab, "document.querySelector('#player-menu').scrollTop = 3000; true")
                run.ask("wheel", **wheel)
                time.sleep(0.65)
                edge = run.js(tab, "window.scrollY")
                run.check(edge == before["outer"], "cancelled menu input stays inside at its boundary")
    run.report["ok"] = True
except BaseException as error:
    run.report.update(ok=False, error=str(error))
    raise
finally:
    run.stop()
    server.shutdown()
    server.server_close()
    report = args.output or run.directory / "wheel-glide.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(run.report, indent=2))
    print(f"Report: {report}", flush=True)
