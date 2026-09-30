#!/usr/bin/env python3
"""Upstream 1.0.4 pieces ported into SearchX, end to end, in a disposable app.

Several windows with pins shared between them, ⇧⌘T bringing back a closed
window, Move to Window, a background tab's alert() held until it is on screen,
the movable window, Prevent cross-site tracking and Videos wait for a click,
the per-site sound switch, and extensions refused javascript:/file: addresses.
Driven through ./bench audit step=port104, which makes the same calls the
menus make. Writes a JSON report and prints its path. Run after swift build:

    python3 Tests/port-104.py
"""
import argparse
import json
import runpy
import threading
import time
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / "Tests/chrome_support.py"))
parser = argparse.ArgumentParser()
parser.add_argument("--binary", default=str(ROOT / ".build/debug/Search"))
parser.add_argument("--output", type=Path)
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", 0), HELPERS["PageHandler"])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS["Run"](argparse.Namespace(binary=args.binary, world="p104-" + uuid.uuid4().hex[:8]),
                     f"http://127.0.0.1:{server.server_port}")
origin = run.origin


def p(act="state", **fields):
    return run.ask("audit", step="port104", act=act, **fields)


def until(check, what, seconds=10):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = p()
        if check(last):
            return last
        time.sleep(0.2)
    raise AssertionError(f"{what}: {json.dumps(last)[:600]}")


def pins(state, window):
    return [t for t in state["windows"][window]["tabs"] if t["pin"]]


try:
    run.prepare()
    run.launch()

    # --- windows and the pins they share -----------------------------------
    s = p("open", window=0, url=origin + "/pinned-a")
    a = s["id"]
    p("pin", window=0, id=a)
    s = p("write")
    run.check(len(pins(s, 0)) >= 1, "a pinned tab in the first window")
    first_pins = len(pins(s, 0))
    run.check(len(s["pins"]) == first_pins, "pins.json records the space's pins")

    s = p("newWindow")
    run.check(len(s["windows"]) == 2, "⌘N opens a second window")
    run.check(len(pins(s, 1)) == first_pins, "the new window has the same pins")
    run.check([t["pinID"] for t in pins(s, 0)] == [t["pinID"] for t in pins(s, 1)],
              "each pin has the same id in both windows")
    run.check(pins(s, 0)[0]["id"] != pins(s, 1)[0]["id"], "each window keeps its own tab for a pin")

    s = p("open", window=1, url=origin + "/pinned-b")
    b = s["id"]
    p("pin", window=1, id=b)
    s = p("write")
    run.check(len(pins(s, 0)) == first_pins + 1, "a pin made in the second window reaches the first")
    run.check(any(t["home"].endswith("/pinned-b") for t in pins(s, 0)), "the first window's copy goes home to its page")

    p("unpin", window=1, id=b)
    s = p("write")
    run.check(len(pins(s, 0)) == first_pins and len(pins(s, 1)) == first_pins,
              "unpinned in one window, gone from the other")

    # --- Move to Window ------------------------------------------------------
    s = p("open", window=0, url=origin + "/travels")
    moving = s["id"]
    s = p("moveToWindow", window=0, to=1, id=moving)
    run.check(any(t["id"] == moving for t in s["windows"][1]["tabs"])
              and not any(t["id"] == moving for t in s["windows"][0]["tabs"]),
              "Move to Window takes the tab to the other window, as it is")

    # --- ⇧⌘T brings a closed window back -------------------------------------
    before = len(s["windows"])
    s = p("closeWindow", window=1)
    run.check(len(s["windows"]) == before - 1 and s["closedWindows"] == 1, "a window closed while another stays is kept")
    s = p("reopen", window=0)
    run.check(len(s["windows"]) == before, "⇧⌘T brings the closed window back")
    run.check(any(t["url"].endswith("/travels") for t in s["windows"][-1]["tabs"]), "with its tabs")
    run.check(len(pins(s, len(s["windows"]) - 1)) == first_pins, "and the shared pins, once each")

    # --- the window can be moved and tiled between presses ------------------
    run.check(all(w["movable"] for w in s["windows"]), "every window is movable between presses (Move & Resize, tiling)")

    # --- a background tab's alert waits until the tab is in front ------------
    front = p("open", window=0, url=origin + "/front")["id"]
    behind = p("open", window=0, url=origin + "/behind", front=False)["id"]
    run.page(behind, "/behind")
    p("select", window=0, id=front)
    run.js(behind, "setTimeout(() => { window.answered = confirm('from behind'); }, 50); 1")
    s = until(lambda s: any(behind in h for h in s["held"]), "the background tab's confirm() is held")
    run.check(True, "confirm() from a tab not on screen is held, not shown over the one in front")
    p("select", window=0, id=behind)
    s = until(lambda s: not any(behind in h for h in s["held"]), "the held confirm() is asked once its tab is in front")
    run.check(True, "going to the tab asks the held question")

    # --- switches -------------------------------------------------------------
    s = p("state")
    run.check(s["tracking"] is True, "Prevent cross-site tracking is on by default")
    s = p("prefs", tracking=False)
    run.check(s["tracking"] is False, "Prevent cross-site tracking can be turned off")
    p("prefs", tracking=True)
    before = p("state")["clickFor"]
    run.check("video" not in before, "by default, video may start by itself")
    s = p("prefs", waits=True)
    run.check(s["waits"] and set(s["clickFor"]) == {"audio", "video"},
              "Videos wait for a click: new pages need a click for video as well as sound")
    p("prefs", waits=False)
    run.check(p("state")["clickFor"] == before, "turned off, back to what it was")

    # --- pins fill their rows evenly (column layout, Automatic) -------------
    def pin_frames():
        # The pinned cells as the accessibility tree has them, in screen space.
        nodes = run.ask("native", action="nodes")["nodes"]
        return [n["frame"] for n in nodes if n["label"].startswith("Pinned: ")]

    def settled_frames(count, seconds=8):
        # Cells come and go, and move, with a short animation: read once there
        # are `count` of them and two reads in a row agree.
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            frames = [[round(v) for v in f] for f in pin_frames()]
            if len(frames) == count and frames == last:
                return frames
            last = frames
            time.sleep(0.3)
        return last or []

    def rows_of(frames):
        # Cells grouped by row, top to bottom: each row's count. Accessibility
        # frames are in screen space, where y grows upward.
        tops = sorted({round(f[1]) for f in frames}, reverse=True)
        return [sum(1 for f in frames if round(f[1]) == top) for top in tops]

    p("prefs", sidebar=True, sideWidth=260.0, pinColumns=0, pinRows=False)
    for window in range(len(p()["windows"]) - 1, 0, -1):
        p("closeWindow", window=window)
    have = len(pins(p("write"), 0))
    made = []
    for i in range(have, 7):
        made.append(p("open", window=0, url=f"{origin}/pin-{i}")["id"])
        p("pin", window=0, id=made[-1])
    p("write")
    layout = rows_of(settled_frames(7))
    run.check(layout == [4, 3], f"seven pins are four and three: {layout}")
    frames = settled_frames(7)
    top = max(f[1] for f in frames)
    first = [f[2] for f in frames if abs(f[1] - top) < 1]
    second = [f[2] for f in frames if abs(f[1] - top) >= 1]
    run.check(max(first) - min(first) < 1.5 and max(second) - min(second) < 1.5
              and min(second) - max(first) > 10,
              f"each row shares the column's width between its own pins: {first} / {second}")
    p("unpin", window=0, id=made[-1])
    p("unpin", window=0, id=made[-2])
    s = p("write")
    run.check(len(pins(s, 0)) == 5, f"two unpinned leave five: {[t['url'] for t in pins(s, 0)]}")
    five = settled_frames(5)
    run.report["fivePins"] = {"frames": five, "labels": [n["label"] for n in run.ask("native", action="nodes")["nodes"] if n["label"].startswith("Pinned: ")]}
    layout = rows_of(five)
    run.check(layout == [3, 2], f"five pins are three and two: {layout}")
    # The live pin against the resting ones, measured from the drawn window:
    # the mean brightness inside each cell, light appearance.
    live = next((t for t in p()["windows"][0]["tabs"] if t["pin"]), None)
    p("select", window=0, id=live["id"])
    time.sleep(0.6)
    shot = run.directory / "pins.png"
    run.ask("native", action="shot", path=str(shot))
    run.report["pinShot"] = str(shot)
    run.report["pinFrames"] = settled_frames(5)
    run.report["windowFrame"] = p()["windows"][0]["frame"]
    run.report["livePinIndex"] = [t["id"] for t in pins(p(), 0)].index(live["id"])
    p("prefs", pinColumns=2)
    time.sleep(0.5)
    layout = rows_of(settled_frames(5))
    run.check(layout == [2, 2, 1], f"a column count set in Settings still wins: {layout}")
    p("prefs", pinColumns=0)

    # --- extensions may not send tabs to javascript: or file: ------------------
    try:
        run.check(p("mayOpen", url="javascript:alert(1)")["allowed"] is False, "extensions can't open javascript: addresses")
        run.check(p("mayOpen", url="file:///etc/hosts")["allowed"] is False, "extensions can't open file: addresses")
        run.check(p("mayOpen", url="https://example.com/")["allowed"] is True, "extensions can open https addresses")
    except RuntimeError as error:
        run.check("15.4" in str(error), "extension checks skipped below macOS 15.4")

    # --- What's new, once, after an update ------------------------------------
    # A fresh profile has been welcomed (prefs "welcomed"), so relaunching as
    # a version with a card is an update to it.
    import os
    run.stop()
    os.environ["SEARCH_WHATSNEW"] = "1.1.9"
    try:
        run.launch()
        s = p("state")
        run.check(s["news"] is True and s["newsSeen"] == "1.1.9", "after an update, the card says what's new, once")
        time.sleep(0.8)
        texts = [n["label"] or n["title"] or n["value"] for n in run.ask("native", action="nodes")["nodes"]]
        run.check(any("New in SearchX 1.1.9" in x for x in texts) and any("Videos wait for a click" in x for x in texts),
                  "the card shows this version's switches")
        run.ask("native", action="shot", path=str(run.directory / "whats-new.png"))
        s = p("escape")
        run.check(s["news"] is False, "Escape puts the card away")
        run.stop()
        run.launch()
        run.check(p("state")["news"] is False, "closed, it doesn't come back for that version")
    finally:
        os.environ.pop("SEARCH_WHATSNEW", None)

    run.report["ok"] = True
finally:
    run.stop()
    out = args.output or (run.directory / "port-104.json")
    out.write_text(json.dumps(run.report, indent=2))
    print("report:", out)
