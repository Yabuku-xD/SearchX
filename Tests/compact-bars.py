#!/usr/bin/env python3
"""Verify compact chrome via native settings and real WebKit in an isolated app.

Run `swift build && python3 tests/compact-bars.py`.
"""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
SUITE = runpy.run_path(str(ROOT / "tests/chrome_support.py"))


def main():
    args = argparse.Namespace(binary=str(ROOT / ".build/debug/Search"),
                              world="bars-" + uuid.uuid4().hex[:8])
    server = ThreadingHTTPServer(("127.0.0.1", 0), SUITE["PageHandler"])
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = SUITE["Run"](args, f"http://127.0.0.1:{server.server_port}")

    def control(label, role=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            nodes = run.ask("native", action="nodes")["nodes"]
            matches = [n for n in nodes if label in (n["label"], n["title"])
                       and (n["role"] == role if role else n["role"] != "AXStaticText")]
            if matches:
                return matches[0]
            time.sleep(0.1)
        (run.directory / "missing-control.json").write_text(json.dumps(nodes, indent=2))
        raise AssertionError(f"native control missing: {label}")

    def press(label):
        control(label)
        run.check(run.ask("native", action="press", label=label)["pressed"],
                  f"native control responds: {label}")
        time.sleep(0.5)

    def settings():
        run.ask("ui", settings=True)
        time.sleep(0.4)
        press("Appearance")
        control("Bar height", "AXSlider")

    def slider(label, value):
        node = control(label, "AXSlider")
        for _ in range(25):
            current = float(node["value"])
            if abs(current - value) < 0.001:
                run.check(True, f"{label} updates to {value}")
                return
            action = "increment" if current < value else "decrement"
            result = run.ask("native", action=action, index=node["index"])
            assert result["requested"], result
            time.sleep(0.1)
            node = next(n for n in run.ask("native", action="nodes")["nodes"]
                        if n["role"] == "AXSlider" and label in (n["label"], n["title"]))
        raise AssertionError(f"{label} did not reach {value}: {node}")

    def close_settings():
        run.ask("ui", settings=False)
        time.sleep(0.5)

    def shot(name):
        time.sleep(0.4)
        run.ask("native", action="shot", path=str(run.directory / (name + ".png")))
        if "captureError" in run.report:
            return
        path = run.directory / (name + "-composited.png")
        run.ask("native", action="composited-shot", path=str(path))
        status = Path(str(path) + ".json")
        deadline = time.monotonic() + 10
        while not status.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        result = json.loads(status.read_text()) if status.exists() else {"error": "capture timed out"}
        if "error" in result:
            run.report["captureError"] = result["error"]


    def toggle():
        settings()
        slider("Bar height", 52 if float(control("Bar height", "AXSlider")["value"]) == 30 else 30)
        close_settings()

    def lights(y):
        deadline = time.monotonic() + 5
        while True:
            positions = run.ask("probe")["lights"]
            if len(positions) == 3 and all(p[1] == y for p in positions):
                break
            if time.monotonic() >= deadline:
                (run.directory / "lights-failure.json").write_text(json.dumps(run.ask("probe"), indent=2))
                break
            time.sleep(0.1)
        run.check(len(positions) == 3 and all(p[1] == y for p in positions),
                  f"traffic lights are centered at {y} points")
        run.check(all(16 <= b[0] - a[0] <= 32 for a, b in zip(positions, positions[1:])),
                  "traffic light spacing stays intact")

    def viewport(tab):
        return run.js(tab, "innerHeight")

    def frosted(hit):
        # NSVisualEffectView.BlendingMode.behindWindow is 0; Material.sidebar is 7.
        return [e for e in hit["effects"] if e["mode"] == 0 and e["material"] == 7 and not e["hidden"]]

    def peek_backdrop(radius):
        run.ask("ui", folded=True, peek=True)
        time.sleep(0.8)
        hit = run.ask("native", action="hit-test", x=700, y=300)
        (run.directory / f"revealed-{radius}.json").write_text(json.dumps(hit, indent=2))
        run.check(hit["hit"] == "PageView", "the page beside a revealed column still takes clicks")
        backdrops = hit["backdrops"]
        run.check(len(backdrops) == 1 and backdrops[0]["alpha"] == 1
                  and {"name": "CIGaussianBlur", "radius": radius} in backdrops[0]["filters"],
                  f"revealed column blurs the page under it at radius {radius}")
        run.check(not frosted(hit), "revealed column over the page drops the desktop material")
        return hit

    try:
        run.prepare()
        run.launch()
        subprocess.run(["open", str(run.app)], check=True)
        time.sleep(0.5)
        run.ask("resize", width=1180, height=780)
        tab = run.open("/compact-bars")
        lights(26)
        normal = viewport(tab)
        run.js(tab, "window.compactState = 'preserved'")
        toggle()
        lights(15)
        run.check(viewport(tab) == normal + 22, "compact strip gives the page 22 more points")
        run.check(run.js(tab, "window.compactState") == "preserved", "toggle preserves the loaded page")
        for sidebar in (False, True):
            for look in ("light", "dark"):
                run.ask("ui", sidebar=sidebar, look=look)
                run.ask("resize", width=780, height=680)
                time.sleep(0.5)
                lights(15)
                run.ask("native", action="shot", path=str(run.directory / f"compact-{sidebar}-{look}.png"))
        run.ask("ui", sidebar=False, look="light")
        run.ask("resize", width=1180, height=780)
        run.organize("save")
        time.sleep(0.5)
        run.stop()
        run.launch()
        subprocess.run(["open", str(run.app)], check=True)
        time.sleep(0.5)
        run.ask("resize", width=1180, height=780)
        tab = run.restored("/compact-bars")
        run.page(tab, "/compact-bars")
        lights(15)
        run.check(viewport(tab) == normal + 22, "compact layout survives restart")
        run.ask("ui", settings=True)
        time.sleep(0.5)
        run.ask("native", action="shot", path=str(run.directory / "compact-settings.png"))
        toggle()
        lights(26)
        run.check(viewport(tab) == normal, "turning compact off restores the original height")
        # Change the actual controls, then measure the live WebKit viewport.
        settings()
        slider("Bar height", 30)
        slider("Transparency", 0.8)
        slider("Blur strength", 0)
        shot("appearance-controls")
        close_settings()
        run.check(viewport(tab) == 750, "transparent strip keeps its band; the page starts under it")
        run.js(tab, "document.body.style.background = 'repeating-linear-gradient(90deg, #ee4433 0 24px, #2255cc 24px 48px)'; document.body.style.minHeight = '2000px'; window.chromeClicks = 0; document.addEventListener('click', () => window.chromeClicks++)")
        shot("strip-clear")
        settings()
        slider("Blur strength", 1)
        close_settings()
        shot("strip-blurred")
        for sidebar in (False, True):
            run.ask("ui", sidebar=sidebar)
            time.sleep(0.5)
            expected = {"width": 948, "height": 780} if sidebar else {"width": 1180, "height": 750}
            run.check(run.js(tab, "({width: innerWidth, height: innerHeight})") == expected,
                      f"docked see-through chrome keeps its room beside the page: sidebar={sidebar}")
            hit = run.ask("native", action="hit-test", x=700, y=300)
            run.check(hit["hit"] == "PageView", "uncovered webpage is the native click target")
            run.ask("tap", id=tab, selector="#identity")
            time.sleep(0.3)
            run.check(run.js(tab, "window.chromeClicks") > 0, "webpage handles trusted pointer events")
            hit = run.ask("native", action="hit-test", x=220 if sidebar else 700, y=15)
            run.check(hit["hit"] != "PageView", "chrome intercepts clicks over the page")
            run.check(not hit["backdrops"], "docked chrome does not blur the page")
            run.check(len(frosted(hit)) == 1, "docked chrome shows the desktop through a sidebar material")
            run.js(tab, "scrollTo(0, 200)")
            for look in ("light", "dark"):
                run.ask("ui", look=look)
                time.sleep(0.3)
                shot(f"glass-{sidebar}-{look}")
            peek_backdrop(30)
            for look in ("light", "dark"):
                run.ask("ui", look=look, peek=True)
                time.sleep(0.3)
                shot(f"revealed-{sidebar}-{look}")
            run.ask("ui", folded=False, peek=False)
            time.sleep(0.6)
            run.check(not run.ask("native", action="hit-test", x=700, y=300)["backdrops"],
                      "the blur goes with the column")
            lights(15)
        settings()
        slider("Blur strength", 0.5)
        slider("Bar height", 42)
        close_settings()
        lights(21)
        peek_backdrop(15)
        run.ask("ui", folded=False, peek=False)
        time.sleep(0.6)
        run.organize("save")
        time.sleep(0.5)
        run.stop()
        run.launch()
        subprocess.run(["open", str(run.app)], check=True)
        time.sleep(0.5)
        run.ask("resize", width=1180, height=780)
        tab = run.restored("/compact-bars")
        run.page(tab, "/compact-bars")
        run.check(run.js(tab, "innerWidth") == 948, "sidebar keeps its room after restart")
        run.check(len(frosted(run.ask("native", action="hit-test", x=700, y=300))) == 1,
                  "sidebar transparency survives restart")
        settings()
        run.check(float(control("Bar height", "AXSlider")["value"]) == 42, "custom bar height persists")
        run.check(abs(float(control("Transparency", "AXSlider")["value"]) - 0.8) < 0.001, "transparency value persists")
        run.check(abs(float(control("Blur strength", "AXSlider")["value"]) - 0.5) < 0.001, "blur strength persists")
        slider("Transparency", 0)
        close_settings()
        run.check(run.js(tab, "innerWidth") == 1180 - 232, "opaque sidebar keeps reserved page space")
        run.check(not frosted(run.ask("native", action="hit-test", x=700, y=300)),
                  "opaque sidebar drops the desktop material")
        run.report["ok"] = True
    except BaseException as error:
        run.report.update(ok=False, error=str(error))
        raise
    finally:
        run.stop()
        server.shutdown()
        server.server_close()
        report = run.directory / "compact-bars.json"
        report.write_text(json.dumps(run.report, indent=2))
        print(f"Report: {report}", flush=True)


if __name__ == "__main__":
    main()
