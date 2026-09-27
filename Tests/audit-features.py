#!/usr/bin/env python3
"""The browser-audit features, end to end, in a disposable app and profile.

Split view of up to four (grid, stacked, side by side, a tab closed out of a
split of four, saved in the session), the peek's split button, whole-group
actions, Quick Commands on ⌘K, command chains, focus mode, saving power and
web panels — each driven through ./bench audit, which makes the same calls
the menus and buttons make. Screenshots and a JSON report are written to the
run's folder, printed at the end. Run after swift build:

    python3 Tests/audit-features.py
"""
import argparse
import glob
import json
import os
from pathlib import Path
import runpy
import subprocess
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / "Tests/chrome_support.py"))
server = ThreadingHTTPServer(("127.0.0.1", 0), HELPERS["PageHandler"])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS["Run"](argparse.Namespace(binary=str(ROOT / ".build/debug/Search"),
                                     world="audit-" + uuid.uuid4().hex[:8]),
                     f"http://127.0.0.1:{server.server_port}")
origin = run.origin


def audit(step, **fields):
    return run.ask("audit", step=step, **fields)


def wait(read, ok, message, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        last = read()
        if ok(last):
            return last
        time.sleep(0.2)
    raise AssertionError(f"{message}: {last}")


def shot(name):
    path = run.directory / (name + ".png")
    run.ask("native", action="composited-shot", path=str(path))
    wait(lambda: Path(str(path) + ".json").exists(), bool, "screenshot " + name, 10)
    run.report.setdefault("shots", []).append(str(path))


def sessions_now():
    out = []
    for path in glob.glob(str(run.profile / "session*.json")):
        try:
            out.append(json.loads(Path(path).read_text()))
        except (OSError, ValueError):
            pass
    return out


def by_url(state, path):
    return next(t["id"] for t in state["tabs"] if t["url"] == origin + path)


try:
    run.prepare()
    for key in ("tabs.split", "tabs.groups", "sidebar"):
        subprocess.run(["defaults", "write", run.suite, key, "-bool", "true"], check=True)
    run.launch()
    run.ask("resize", width=1400, height=900)
    ids = {name: run.open("/" + name) for name in ("a", "b", "c", "d", "e")}

    # Split view: two, then four, each layout, then a tab closed out of it.
    run.ask("select", id=ids["a"])
    run.ask("split", step="start", id=ids["b"])
    run.ask("split", step="finish", id=ids["a"])
    run.ask("split", step="add", id=ids["c"])
    state = run.ask("split", step="add", id=ids["d"])
    pair = state["pairs"][0]
    run.check(len(pair["members"]) == 4 and pair["layout"] == "grid", "four tabs in one split, laid out as a grid")
    run.check(len(audit("state")["visiblePair"]) == 4, "all four pages are on screen")
    time.sleep(1.5)
    shot("split-grid")
    run.check(audit("state")["pairs"][0]["layout"] == "grid", "grid kept")
    run.ask("split", step="layout", id=ids["a"], layout="rows")
    run.check(len(audit("state")["visiblePair"]) == 4, "stacked: four rows fit a 900 pt window")
    run.ask("split", step="layout", id=ids["a"], layout="columns")
    run.check(audit("state")["pairs"][0]["layout"] == "columns", "side by side")
    sessions = [json.loads(Path(p).read_text()) for p in glob.glob(str(run.profile / "session*.json"))]
    saved = [s for shape in sessions for w in shape.get("windows", [shape]) for s in (w.get("splits") or [])]
    run.check(any(len(s.get("extra") or []) == 2 for s in saved), "the session keeps the third and fourth pane")
    audit("close", id=ids["d"])
    after = audit("state")
    run.check(len(after["pairs"]) == 1 and len(after["pairs"][0]["members"]) == 3,
              "closing one of four leaves a split of three")
    run.ask("split", step="unsplit", id=ids["a"])
    run.check(audit("state")["pairs"] == [], "unsplit")

    # The peek's third button: the peeked page beside this one.
    run.ask("select", id=ids["e"])
    audit("peek", url=origin + "/peeked")
    wait(lambda: audit("state")["peek"], bool, "peek opens")
    time.sleep(1.2)
    shot("peek")
    state = audit("peekSplit")
    peeked = by_url(state, "/peeked")
    run.check(state["peek"] == "" and any(set(p["members"]) == {ids["e"], peeked} for p in state["pairs"]),
              "Open in split view puts the peeked page beside its tab")
    run.ask("split", step="unsplit", id=ids["e"])

    # A whole group at once.
    state = audit("group", ids=[ids["a"], ids["b"], ids["c"]])
    group = state["groups"][-1]["id"]
    state = audit("groupAct", group=group, act="tile")
    run.check(any(p["members"] == [ids["a"], ids["b"], ids["c"]] for p in state["pairs"]), "Show Group in Split View")
    run.ask("split", step="unsplit", id=ids["a"])
    state = audit("groupAct", group=group, act="bookmark")
    run.check(any(f["title"] == state["groups"][-1]["name"] and f["count"] == 3 for f in state["bookmarkFolders"]),
              "Bookmark Group makes a folder of its three pages")
    audit("close", id=ids["c"])
    run.ask("select", id=ids["e"])
    state = wait(lambda: audit("groupAct", group=group, act="sleep"),
                 lambda s: all(t["asleep"] for t in s["tabs"] if t["group"] == group), "Put Group to Sleep")
    run.check(True, "Put Group to Sleep lets every page in it go")
    state = audit("groupAct", group=group, act="pin")
    pinned = [t for t in state["tabs"] if t["id"] in (ids["a"], ids["b"])]
    run.check(all(t["pin"] for t in pinned) and all(g["id"] != group for g in state["groups"]),
              "Pin Group pins its pages and the empty group goes")

    # Quick Commands.
    state = audit("summon", text="split")
    first = state["offers"][0] if state["offers"] else {}
    run.check(first.get("kind") == "action" and first.get("key", "").startswith("Split"),
              f"⌘K 'split' leads with a command ({first.get('key')})")
    time.sleep(0.6)
    shot("quick-commands")
    state = audit("summon", text="shortcuts")
    run.check(any(o["key"] == "Shortcuts · Settings" for o in state["offers"]), "⌘K finds a Settings page")
    audit("summon", text="")
    typed = run.ask("field", text="spl", type=True)
    state = audit("state")
    run.check(typed["typed"] == "spl" and state["summoning"] and state["offers"][0]["kind"] == "action",
              f"typing letter by letter into ⌘K keeps every letter ({typed['typed']!r})")
    audit("dismiss")
    state = audit("summon", text="/c")
    run.check(any(o["kind"] == "bookmark" for o in state["offers"]), "⌘K finds a bookmark whose page is not open")
    state = audit("summon", text="focus mode")
    index = next(i for i, o in enumerate(state["offers"]) if o["key"] == "Focus Mode")
    run.check(state["offers"][index]["detail"] == "⇧⌘F", "a command shows the key it is on")
    state = audit("take", index=index)
    run.check(state["focusing"] == state["active"] and state["folded"], "running Focus Mode from ⌘K folds the sidebar")
    state = audit("focus")
    run.check(state["focusing"] == "" and not state["folded"], "leaving focus mode brings the sidebar back")

    # A command chain.
    before = len(audit("state")["tabs"])
    audit("chain", name="Read alone", steps=["file.newTab", "view.focus"], run=True)
    state = wait(lambda: audit("state"), lambda s: s["focusing"] != "", "chain runs both steps")
    run.check(len(state["tabs"]) == before + 1 and state["focusing"] == state["active"],
              "a chain of New Tab then Focus Mode opens a tab and focuses it")
    audit("focus")
    state = audit("summon", text="read alone")
    run.check(any(o["key"] == "Read alone" and o["kind"] == "action" for o in state["offers"]), "⌘K runs chains too")
    audit("dismiss")
    time.sleep(0.4)
    state = audit("state")
    run.check(state["offers"] == [] and "commands" not in json.dumps(state["placeholder"]),
              f"Escape on ⌘K over a new tab clears it back to an address field ({state['placeholder']}, summoning={state['summoning']}, offers={len(state['offers'])})")

    # Saving power.
    state = audit("power", mode="always")
    run.check(state["power"]["saving"] and state["power"]["sleepAfter"] == 300, "Save power: Always")
    state = audit("power", mode="never")
    run.check(not state["power"]["saving"] and state["power"]["sleepAfter"] > 300, "Save power: Never")
    state = audit("power", mode="withMac")
    run.check(state["power"]["saving"] == state["power"]["lowPowerMac"], "Save power follows macOS Low Power Mode")

    # A web panel: made on opening, mobile on asking, let go on closing.
    state = audit("panel", url=origin + "/panel-page", name="Chat")
    run.check(state["panel"].get("url") == origin + "/panel-page", "the site opens in the panel")
    wait(lambda: audit("state")["panel"], lambda p: p and not p["loading"], "panel page loads")
    time.sleep(1)
    shot("web-panel")
    state = audit("panelMobile", on=True)
    run.check("iPhone" in state["panel"]["agent"] and state["panelSites"][0]["mobile"], "mobile layout asks as a phone")
    state = audit("panelClose")
    run.check(state["panel"] == {} and len(state["panelSites"]) == 1, "closing lets the page go and keeps the site")
    state = audit("summon", text="chat")
    run.check(any(o["key"] == "Chat Panel" for o in state["offers"]), "⌘K opens kept panels")
    audit("dismiss")
    state = audit("panel", url=origin + "/panel-page")
    state = audit("panelTab")
    run.check(state["panel"] == {} and any(t["url"] == origin + "/panel-page" for t in state["tabs"]),
              "Open as Tab moves the panel's page into the row")
    # Group icons, saved groups and containers (Firefox, Brave).
    fresh = {name: run.open("/" + name) for name in ("g1", "g2", "k1", "k2")}
    state = audit("group", ids=[fresh["g1"], fresh["g2"]])
    group = state["groups"][-1]["id"]
    run.check(state["groups"][-1]["emoji"] == "", "a new group wears its first page's icon until one is chosen")
    state = audit("groupEmoji", group=group, emoji="🎧")
    run.check(state["groups"][-1]["emoji"] == "🎧", "a group's icon can be an emoji")
    wait(lambda: [g for shape in sessions_now() for w in shape.get("windows", [shape]) for g in (w.get("groups") or [])],
         lambda groups: any(g.get("emoji") == "🎧" for g in groups), "session keeps the icon")
    run.check(True, "the icon is kept in the session")
    before = len(audit("state")["tabs"])
    state = audit("saveGroup", group=group)
    run.check(len(state["tabs"]) == before - 2 and all(g["id"] != group for g in state["groups"])
              and state["savedGroups"][0]["pages"] == [origin + "/g1", origin + "/g2"] and state["savedGroups"][0]["emoji"] == "🎧",
              "Save and Close Group closes its tabs and keeps its pages, name and icon")
    state = audit("summon", text=state["savedGroups"][0]["name"])
    index = next(i for i, o in enumerate(state["offers"]) if o["kind"] == "action" and o["key"] == state["savedGroups"][0]["name"])
    state = audit("take", index=index)
    back = [t for t in state["tabs"] if t["url"] in (origin + "/g1", origin + "/g2")]
    run.check(len(back) == 2 and len({t["group"] for t in back}) == 1 and state["groups"][-1]["emoji"] == "🎧"
              and state["savedGroups"] == [], "⌘K opens a saved group again, as it was")

    audit("container", id=fresh["k1"], name="Work")
    state = wait(lambda: audit("state"), lambda s: next(t for t in s["tabs"] if t["id"] == fresh["k1"])["container"] == "Work",
                 "tab moves into Work")
    run.ask("select", id=fresh["k1"])
    run.page(fresh["k1"], "/k1")
    run.js(fresh["k1"], "document.cookie = 'who=work; path=/'; true")
    run.ask("select", id=fresh["k2"])
    plain = run.js(fresh["k2"], "document.cookie")
    work = run.js(fresh["k1"], "document.cookie")
    run.check("who=work" in work and "who=work" not in plain,
              f"a container keeps its cookies to itself (work: {work!r}, plain: {plain!r})")
    state = audit("openFrom", id=fresh["k1"], url=origin + "/k3")
    opened = [t for t in state["tabs"] if t["url"] == origin + "/k3"]
    run.check(opened and opened[0]["container"] == "Work", "a link opened from a container tab stays in the container")
    wait(lambda: [e for shape in sessions_now() for w in shape.get("windows", [shape]) for e in w.get("tabs", [])],
         lambda entries: any(e.get("container") for e in entries), "session keeps the container")
    run.check(True, "the session keeps each tab's container")
    time.sleep(0.8)
    shot("containers")
    state = audit("containerDelete", name="Work")
    run.check("Work" not in state["containers"] and all(t["container"] == "" for t in state["tabs"]),
              "deleting a container moves its tabs out of it")

    # The new Settings lines, opened from ⌘K as a person would.
    for page, name in (("shortcuts settings", "settings-chains"), ("general settings", "settings-power")):
        state = audit("summon", text=page)
        audit("take", index=next(i for i, o in enumerate(state["offers"]) if o["kind"] == "action"))
        time.sleep(1.0)
        shot(name)
        run.ask("ui", settings=False)
    audit("panelForget")
    audit("chainForget")
    run.report["ok"] = True
except BaseException as error:
    run.report.update(ok=False, error=str(error))
    raise
finally:
    run.stop()
    server.shutdown()
    server.server_close()
    report = run.directory / "audit-features.json"
    report.write_text(json.dumps(run.report, indent=2))
    print(f"Report: {report}", flush=True)
