#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Browser test of the Agent loop page (Container-Root/agent/loop-view.py and loop-view/): how a loop's outcome reads,
whether a refresh keeps the keyboard focus, whether each caption tells the truth about refreshing, what a phone shows
first, whether the header lines up with the page on the harness stylesheet, and what the two actions (Run next
fire, Pause loop) show.

Runs on the host, offline: the fixtures under tests/ux/fixtures/loop/ are written out as loop directories with times
relative to now, the real renderer (a copy, run with --once against an empty tmux socket directory, so it finds no tmux
server and probes no service, and with its Loop Deck probe pointed at a closed port or a check's stub) writes data.json
and the page, and a local server on 127.0.0.1 hands them to headless
Chromium. Every check runs once against the shipped files and once against a copy with the property removed - the
control - which must fail it.

Needs python3 with Playwright and its Chromium (pip install playwright; python3 -m playwright install chromium).
Usage: python3 tests/ux/test_loop_view.py        exit 0 when every check and every control behave
       SHOTS_DIR=<dir> keeps a screenshot of what the main checks saw
"""
import functools
import re
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENT = os.path.join(REPO, "Container-Root", "agent")
FIXTURES = os.path.join(REPO, "tests", "ux", "fixtures", "loop")
# the harness stylesheet, served at /__harness/harness.css as the home proxy serves it on every host - when the checkout
# has one (HARNESS_CSS names another); without it that path answers 404, as on a proxy that has no such route, and the
# two header checks fail: what they measure is the sheet's header on the measure the page declares (--hs-max)
HARNESS_CSS = os.environ.get("HARNESS_CSS") or os.path.join(REPO, "Container-Root", "agent", "ui", "harness.css")
TMP = tempfile.mkdtemp(prefix="loop-view-ux-")
# the autonomy loop's per-loop address (/loop/<loop-id>/): the site serves the page under it too
LOOP_PREFIX = "/loop/autonomy-loop"
HOLDERS = []

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sys.exit("test_loop_view: needs Playwright (pip install playwright; python3 -m playwright install chromium)")


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def variant(name, mutations=()):
    """A copy of the renderer and its page files, with (file, old, new) replacements applied - each must match once."""
    d = os.path.join(TMP, "variant-" + name)
    shutil.copytree(os.path.join(AGENT, "loop-view"), os.path.join(d, "loop-view"))
    shutil.copy(os.path.join(AGENT, "loop-view.py"), d)
    for f, old, new in mutations:
        p = os.path.join(d, f)
        s = open(p).read()
        assert s.count(old) == 1, "%s: the control's anchor is not in %s exactly once: %r" % (name, f, old[:70])
        open(p, "w").write(s.replace(old, new))
    return d


def loop_case(case, tag):
    """The fixture `case` written out as a loop directory (times relative to now); a lock holder named loop.sh stands
    in for a running loop. Returns the directory of the case."""
    spec = json.load(open(os.path.join(FIXTURES, case + ".json")))
    root = os.path.join(TMP, "case-%s-%s" % (case, tag))
    loop, goals = os.path.join(root, "loop"), os.path.join(root, "goals", "GOALS.md")
    for d in ("loop/fires", "goals", "work", "tmux", "claude"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    os.chmod(os.path.join(root, "tmux"), 0o700)
    now = int(time.time())
    names = {"goals": goals, "work": os.path.join(root, "work"), "loop": loop}
    with open(os.path.join(loop, "loop.log"), "w") as f:
        for dt, line in spec["log"]:
            f.write("%s %s\n" % (iso(now + dt), line.format(**names)))
    dt, line = spec["state"]
    open(os.path.join(loop, "loop.state"), "w").write("%s pid=2147480000 utc=%s\n" % (line, iso(now + dt)))
    if spec["stop_flag"]:
        open(os.path.join(loop, "STOP"), "w").write("all goals done\n")
    if spec["goals"] is not None:
        open(goals, "w").write(spec["goals"])
    for n, text in spec["fires"].items():
        open(os.path.join(loop, "fires", "fire-%s.out" % n), "w").write(text)
    if spec["running"]:
        HOLDERS.append(subprocess.Popen(["bash", "-c", 'exec 9> "$1"; flock 9; exec -a loop.sh sleep 600', "_",
                                         os.path.join(loop, "loop.lock")]))
        time.sleep(0.5)
    return root


def free_port():
    """A loopback port nothing listens on (bound, read, released)."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class ProbeStub:
    """A home listener for the renderer's Loop Deck probe: GET /__probe/loop-deck answers 204, as the home proxy does
    while the Deck it serves answers."""

    def __init__(self):
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                self.send_response(204 if self.path == "/__probe/loop-deck" else 404)
                self.end_headers()

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def render(var, root, extra=None):
    """One render of the case at `root` by the renderer of variant `var`, with `extra` in its environment (its Loop
    Deck probe goes to a closed port unless `extra` says otherwise); returns (ui dir, data)."""
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    env.update(AUTONOMY_LOOP_DIR=os.path.join(root, "loop"), AUTONOMY_LOOP_GOALS=os.path.join(root, "goals", "GOALS.md"),
               AUTONOMY_LOOP_WORKDIR=os.path.join(root, "work"), UI_DIR=os.path.join(root, "ui-" + os.path.basename(var)),
               TMUX_TMPDIR=os.path.join(root, "tmux"), CLAUDE_CONFIG_DIR=os.path.join(root, "claude"), HOME=root,
               UI_PORT_HOME=str(free_port()))
    env.pop("LOOP_DECK_URL", None)
    env.update(extra or {})
    r = subprocess.run([sys.executable, os.path.join(var, "loop-view.py"), "--once"], env=env, capture_output=True,
                       text=True, timeout=120)
    assert r.returncode == 0, "the renderer failed: %s" % (r.stderr or r.stdout)[-400:]
    ui = os.path.join(env["UI_DIR"], "loop")
    return ui, json.load(open(os.path.join(ui, "data.json")))


class Site:
    """The rendered page on 127.0.0.1: the transcripts from the case's fires/, a count of data.json reads; `fail` makes
    data.json answer 503, `alt` replaces its body. A POST is recorded in `posts` (path and headers) and answered from
    `answers` (path -> (code, answer)), the way the renderer answers an action."""

    def __init__(self, ui, root):
        self.ui, self.fires, self.reads, self.fail, self.alt = ui, os.path.join(root, "loop", "fires"), 0, False, None
        self.css_reads = 0
        self.posts, self.answers = [], {}
        self.data_paths = []
        self.status = {}  # slug -> the status JSON its /loop/<slug>/data.json answers (the other loops' page)
        site = self

        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                raw = self.path.split("?", 1)[0]
                if raw.startswith(LOOP_PREFIX + "/"):
                    self.path = self.path[len(LOOP_PREFIX):]
                other = re.match(r"^/loop/([a-z0-9-]+)(/.*)$", raw)
                if other and other.group(1) in site.status:
                    rest = other.group(2)
                    if rest == "/data.json":
                        body = json.dumps(site.status[other.group(1)]).encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        return self.wfile.write(body)
                    self.path = "/status.html" if rest in ("/", "/index.html") else rest
                path = self.path.split("?", 1)[0]
                if path == "/data.json":
                    site.reads += 1
                    site.data_paths.append(raw)
                    if site.fail:
                        return self.send_error(503)
                    if site.alt is not None:
                        body = site.alt.encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        return self.wfile.write(body)
                if path == "/__harness/harness.css":
                    if not os.path.isfile(HARNESS_CSS):
                        return self.send_error(404)
                    site.css_reads += 1
                    body = open(HARNESS_CSS, "rb").read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/css")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    return self.wfile.write(body)
                if path.startswith("/transcripts/fire-"):
                    p = os.path.join(site.fires, os.path.basename(path))
                    if not os.path.isfile(p):
                        return self.send_error(404)
                    body = open(p, "rb").read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    return self.wfile.write(body)
                return super().do_GET()

            def do_POST(self):
                path = self.path.split("?", 1)[0]
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    self.rfile.read(min(n, 4096))
                site.posts.append({"path": path, "X-Loop-Control": self.headers.get("X-Loop-Control"),
                                   "Origin": self.headers.get("Origin"), "Sec-Fetch-Site": self.headers.get("Sec-Fetch-Site")})
                code, answer = site.answers.get(path, (405, {"result": "refused", "message": "not an action"}))
                body = json.dumps(answer).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=ui))
        self.base = "http://127.0.0.1:%d/" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def open_page(browser, url, phone=False):
    ctx = browser.new_context(**({"viewport": {"width": 390, "height": 844}, "is_mobile": True, "has_touch": True,
                                  "device_scale_factor": 2} if phone else {"viewport": {"width": 1920, "height": 1080}}))
    pg = ctx.new_page()
    pg.errors = []
    pg.on("pageerror", lambda e: pg.errors.append(str(e)))
    pg.goto(url)
    return ctx, pg


def shot(pg, var, name):
    """With SHOTS_DIR set, a screenshot of the page as the check saw it (the shipped files only)."""
    d = os.environ.get("SHOTS_DIR")
    if d and os.path.basename(var) == "variant-shipped":
        os.makedirs(d, exist_ok=True)
        pg.screenshot(path=os.path.join(d, name + ".png"), full_page=True)


def pills(pg, sel):
    sel = ", ".join(part.strip() + " .pill" for part in sel.split(","))
    return pg.eval_on_selector_all(sel, "els => els.map(e => e.textContent.trim())")


def staged(var, case, tag, edit=None, env=None):
    root = loop_case(case, tag + "-" + os.path.basename(var))
    ui, data = render(var, root, env)
    if edit:
        data = edit(data)
        open(os.path.join(ui, "data.json"), "w").write(json.dumps(data))
    return root, ui, data


def overview(browser, var, case, tag, phone=False, edit=None):
    root, ui, data = staged(var, case, tag, edit)
    site = Site(ui, root)
    ctx, pg = open_page(browser, site.base + "index.html", phone)
    pg.wait_for_function("() => document.querySelectorAll('#stats li').length > 0", timeout=20000)
    return site, ctx, pg, data


# ---------------------------------------------------------------- the checks: each returns (ok, what it saw)
def c06_complete(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c06")
    shot(pg, var, "complete-1920x1080")
    seen = {"data": d["hub"]["health"], "headline": pills(pg, "#headline"), "health": pills(pg, "#stats li:first-child"),
            "tree": pills(pg, "ul.tree .node.loop"), "red": pg.eval_on_selector_all("#attention li.red", "e => e.length")}
    ctx.close(); site.close()
    ok = (seen["data"] == "COMPLETE" and seen["headline"][:1] == ["COMPLETE"] and seen["health"] == ["COMPLETE"]
          and "COMPLETE" in seen["tree"] and "RED" not in seen["tree"] + seen["headline"] and seen["red"] == 0)
    return ok, seen


def c06f_failed(b, var):
    site, ctx, pg, d = overview(b, var, "failed-last", "c06f")
    shot(pg, var, "failed-last-1920x1080")
    att = pg.eval_on_selector_all("#attention li.red", "els => els.map(e => e.textContent)")
    seen = {"data": d["hub"]["health"], "headline": pills(pg, "#headline"), "attention": att,
            "row": pg.text_content("#fire-table tbody tr:first-child td:nth-child(4) .pill")}
    ctx.close(); site.close()
    ok = (seen["data"] == "RED" and seen["headline"][:1] == ["RED"] and any("fire 2 failed" in a for a in att)
          and seen["row"] == "failed (rc 1)")
    return ok, seen


def c03_words(b, var):
    out = {}
    for case in ("complete", "live-fire"):
        site, ctx, pg, d = overview(b, var, case, "c03")
        out[case] = pills(pg, "#headline, #stats, #diag, #tree, #fire-table")
        ctx.close(); site.close()
    empty = [c for c, ws in out.items() if not ws or any(not w for w in ws)]
    return not empty, {"pills": {c: len(w) for c, w in out.items()}, "cases with a pill and no word": empty}


def c10_focus(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c10")
    pg.wait_for_selector("#cmds button")
    key = pg.evaluate("() => { const b = document.querySelector('#cmds button'); b.focus(); window.__btn = b; return b.dataset.key; }")
    pg.wait_for_timeout(6500)
    same = pg.evaluate("() => document.activeElement === window.__btn")
    d2 = dict(d, commands=[{"label": "A command the next render added", "cmd": "true"}] + d["commands"])
    site.alt = json.dumps(d2)
    pg.wait_for_timeout(6500)
    after = pg.evaluate("() => [document.activeElement.tagName, document.activeElement.dataset.key || null,"
                        " document.querySelectorAll('#cmds li').length]")
    ctx.close(); site.close()
    ok = same and after[0] == "BUTTON" and after[1] == key and after[2] == len(d2["commands"])
    return ok, {"focused": key, "same node after a refresh": same, "after the commands changed": after}


def c11_overview_polls(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c11o")
    pg.wait_for_timeout(1000)
    r0, cap = site.reads, pg.text_content("#freshness")
    pg.wait_for_timeout(11000)
    r1 = site.reads
    ctx.close(); site.close()
    claims = "refreshes every 5 s" in cap
    return claims and r1 - r0 >= 2, {"caption": cap, "data reads in 11 s": r1 - r0}


def fire_page(b, var, case, n, tag):
    root, ui, d = staged(var, case, tag)
    site = Site(ui, root)
    ctx, pg = open_page(b, site.base + "fire.html?n=%d" % n)
    pg.wait_for_function("() => /snapshot|live|cannot/.test(document.getElementById('freshness').textContent)", timeout=20000)
    pg.wait_for_timeout(11000)
    shot(pg, var, "fire-%d-%s-1920x1080" % (n, case))
    seen = {"caption": pg.text_content("#freshness"), "data reads in 11 s": site.reads,
            "transcript": (pg.text_content("#transcript") or "")[:60]}
    ctx.close(); site.close()
    return seen


def c11_snapshot(b, var):
    s = fire_page(b, var, "complete", 1, "c11s")
    claims = "refreshes" in s["caption"]
    ok = "snapshot" in s["caption"] and "read at" in s["caption"] and (not claims or s["data reads in 11 s"] >= 2) \
        and s["transcript"].startswith("The only goal is done")
    return ok, s


def c11_live(b, var):
    s = fire_page(b, var, "live-fire", 2, "c11l")
    return "refreshes every 5 s until it ends" in s["caption"] and s["data reads in 11 s"] >= 3, s


def boxes(pg, sels):
    return pg.evaluate("sels => sels.map(s => { const e = document.querySelector(s); if (!e) return null;"
                       " const r = e.getBoundingClientRect(); return [Math.round(r.top), Math.round(r.bottom)]; })", sels)


def c05p_first_screen(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c05p", phone=True)
    shot(pg, var, "complete-390x844")
    head, last, interval = boxes(pg, ["#headline", "#stats li:nth-child(2)", "#diag li:nth-child(3)"])
    ctx.close(); site.close()
    ok = head and last and interval and 0 <= head[0] and head[1] <= 844 and last[1] <= 844 and head[0] < interval[0] \
        and last[0] < interval[0]
    return bool(ok), {"headline": head, "last fire": last, "interval": interval, "screen": 844}


def c05p_goals_condensed(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c05g", phone=True)
    seen = pg.evaluate("() => { const done = [...document.querySelectorAll('#goals li')].filter(li => /Inventory/.test(li.textContent));"
                       " const sum = document.querySelector('#goals details > summary');"
                       " return [done.length, done.filter(li => !(li.closest('details') && !li.closest('details').open)).length, sum ? sum.textContent : null]; }")
    ctx.close(); site.close()
    return seen[0] == 1 and seen[1] == 0 and seen[2] == "1 done", {"done goal lines": seen[0], "not folded": seen[1], "summary": seen[2]}


def old(d):
    return dict(d, generated_epoch=d["generated_epoch"] - 3600, generated_at=iso(d["generated_epoch"] - 3600))


def c_stale(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "stale", edit=old)
    cap, cls = pg.text_content("#freshness"), pg.get_attribute("#freshness", "class")
    ctx.close(); site.close()
    return cap.startswith("stale: this data is 60 min old") and "bad" in cls, {"caption": cap, "class": cls}


def c_failed_fetch(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "fail")
    site.fail = True
    pg.wait_for_timeout(6500)
    seen = {"caption": pg.text_content("#freshness"), "tiles kept": pg.eval_on_selector_all("#stats li", "e => e.length"),
            "headline kept": pg.text_content("#headline")[:40]}
    ctx.close(); site.close()
    ok = "cannot read the loop state" in seen["caption"] and "HTTP 503" in seen["caption"] and \
        "showing what was read" in seen["caption"] and seen["tiles kept"] == 3 and "COMPLETE" in seen["headline kept"]
    return ok, seen


def c_no_fires(b, var):
    site, ctx, pg, d = overview(b, var, "no-fires", "nofire")
    seen = {"rows": pg.eval_on_selector_all("#fire-table tbody tr", "els => els.map(e => e.textContent.slice(0, 40))"),
            "headline": pg.text_content("#headline"), "state": d["hub"]["state"]}
    ctx.close(); site.close()
    ok = seen["state"] == "running" and len(seen["rows"]) == 1 and seen["rows"][0].startswith("No fire yet") and \
        "Idle" in seen["headline"] and "No fire has ended yet" in seen["headline"]
    return ok, seen


def c_live_overview(b, var):
    site, ctx, pg, d = overview(b, var, "live-fire", "live")
    shot(pg, var, "live-fire-1920x1080")
    seen = {"headline": pg.text_content("#headline"), "first row": pg.get_attribute("#fire-table tbody tr:first-child", "class"),
            "live": d["hub"]["live_fire"]}
    ctx.close(); site.close()
    return seen["live"] == 2 and seen["headline"].startswith("working Fire 2 is running") and seen["first row"] == "live", seen


def edges(pg):
    """The left edges of the header's text and of the nav's first link, in CSS px."""
    return pg.evaluate("() => [document.querySelector('header h1'), document.querySelector('nav a')]"
                       ".map(e => Math.round(e.getBoundingClientRect().left))")


def c_header_aligned(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "align")
    shot(pg, var, "header-1920x1080")
    head, nav = edges(pg)
    served = site.css_reads
    ctx.close(); site.close()
    return served > 0 and abs(head - nav) <= 2, {"header text left": head, "nav left": nav, "stylesheet reads": served}


def c_header_gutter_phone(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "gutter", phone=True)
    head, nav = edges(pg)
    served = site.css_reads
    ctx.close(); site.close()
    return served > 0 and abs(head - 16) <= 2, {"header text left": head, "nav left": nav, "stylesheet reads": served}


# the answers the renderer reads back when the scripts report success but the loop is not where the action asked: a lock
# no loop process holds (loop-start.sh says "already running" and exits 0) and a STOP that is a directory (loop-stop.sh's
# touch succeeds on it, and loop.sh tests for a file)
PLANTED = {
    "/control/run": (200, {"action": "run", "result": "failed", "rc": 0, "script": "/agent/loop-start.sh",
                           "message": "the loop did not start: its lock is held by pid 4242 (sleep 120), which is not a loop",
                           "output": "Autonomy loop already running (pid 4100); nothing to do.",
                           "after": {"state": "stale", "phase": None, "pid": 4100, "stop_flag": False, "stop_kind": "absent"}}),
    "/control/pause": (200, {"action": "pause", "result": "failed", "rc": 0, "script": "/agent/loop-stop.sh",
                             "message": "the STOP flag is not set: /wd/loop/STOP is directory",
                             "output": "Stop flag created: /wd/loop/STOP",
                             "after": {"state": "stale", "phase": None, "pid": 4100, "stop_flag": False, "stop_kind": "directory"}}),
}


def press(pg, button, label):
    """Click an action and wait for its answer (a pill under the action's own name); returns the answer as shown."""
    pg.click(button)
    pg.wait_for_function("label => { const r = document.getElementById('act-result');"
                         " return r.querySelector('.pill') && r.textContent.indexOf(label + ': ') >= 0; }", arg=label, timeout=20000)
    pg.wait_for_function("() => !document.getElementById('act-run').disabled", timeout=20000)
    return {"pill": pg.text_content("#act-result .pill"), "text": pg.text_content("#act-result")}


def actions(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c38")
    site.answers = dict(PLANTED)
    pg.wait_for_selector("#act-run", state="visible", timeout=20000)
    run = press(pg, "#act-run", "Run next fire")
    pause = press(pg, "#act-pause", "Pause loop")
    shot(pg, var, "actions-answered-1920x1080")
    origin = site.base.rstrip("/")
    ctx.close(); site.close()
    return run, pause, site.posts, origin, d


def c38_read_back(b, var):
    run, pause, posts, origin, d = actions(b, var)
    ok = (run["pill"] == "failed" and "its lock is held by pid 4242" in run["text"]
          and "Read back: the loop is stale, pid 4100; the STOP flag is not set." in run["text"]
          and pause["pill"] == "failed" and "/wd/loop/STOP is directory" in pause["text"]
          and "Read back: the loop is stale, pid 4100; the STOP flag is not set." in pause["text"])
    return ok, {"Run next fire": run, "Pause loop": pause}


def c38_requests(b, var):
    run, pause, posts, origin, d = actions(b, var)
    want = [{"path": "/control/run", "X-Loop-Control": "1", "Origin": origin, "Sec-Fetch-Site": "same-origin"},
            {"path": "/control/pause", "X-Loop-Control": "1", "Origin": origin, "Sec-Fetch-Site": "same-origin"}]
    return d["control"]["enabled"] is True and posts == want, {"requests": posts}


def controls_off(d):
    return dict(d, control=dict(d["control"], enabled=False))


def c38_off(b, var):
    site, ctx, pg, d = overview(b, var, "complete", "c38off", edit=controls_off)
    seen = {"buttons shown": pg.is_visible("#act-run") or pg.is_visible("#act-pause"),
            "off note": pg.is_visible("#control-off") and "UI_LOOP_CONTROL=true" in pg.text_content("#control-off")}
    ctx.close(); site.close()
    return not seen["buttons shown"] and seen["off note"], seen


def c_loop_prefix(b, var):
    root, ui, d = staged(var, "complete", "prefix")
    site = Site(ui, root)
    base = site.base
    ctx, pg = open_page(b, base + "loop/autonomy-loop/")
    pg.wait_for_function("() => document.querySelectorAll('#stats li').length > 0", timeout=20000)
    link = pg.evaluate("() => { const a = document.querySelector('#fire-table tbody tr:first-child a'); return a ? a.href : null; }")
    seen = {"data reads": sorted(set(site.data_paths)), "fire link": link, "headline": (pg.text_content("#headline") or "")[:40]}
    ctx.close(); site.close()
    ok = (seen["data reads"] == [LOOP_PREFIX + "/data.json"] and (link or "").startswith(base + "loop/autonomy-loop/fire.html?n=")
          and "COMPLETE" in seen["headline"])
    return ok, seen


def deck_seen(b, var, tag, env):
    """[shown, href] of the page's Loop Deck line on loop.localhost and on 127.0.0.1, after one render with `env`."""
    root, ui, d = staged(var, "complete", tag, env=env)
    site = Site(ui, root)
    port = site.srv.server_address[1]
    seen = {"data": d.get("loop_deck"), "port": port}
    for host in ("loop.localhost", "127.0.0.1"):
        ctx, pg = open_page(b, "http://%s:%d/index.html" % (host, port))
        pg.wait_for_function("() => document.querySelectorAll('#stats li').length > 0", timeout=20000)
        seen[host] = pg.evaluate("() => [!document.getElementById('loop-deck-line').hidden, "
                                 "document.getElementById('loop-deck').getAttribute('href')]")
        ctx.close()
    site.close()
    return seen


def c_loop_deck_link(b, var):
    probe = ProbeStub()
    try:
        seen = deck_seen(b, var, "deck-served", {"UI_PORT_HOME": str(probe.port)})
    finally:
        probe.close()
    ok = seen["loop.localhost"] == [True, "//loop-deck.localhost:%d/#/loops" % seen["port"]] and seen["127.0.0.1"] == [False, None]
    return ok, seen


def c_loop_deck_none(b, var):
    seen = deck_seen(b, var, "deck-none", {})
    ok = seen["data"] is None and seen["loop.localhost"] == [False, None] and seen["127.0.0.1"] == [False, None]
    return ok, seen


def c_loop_deck_named(b, var):
    url = "http://deck.localhost:18799/"
    seen = deck_seen(b, var, "deck-named", {"LOOP_DECK_URL": url})
    ok = seen["loop.localhost"] == [True, url + "#/loops"] and seen["127.0.0.1"] == [True, url + "#/loops"]
    return ok, seen


def status_chat(now):
    """The status a renderer gives the Slack chat responder: its lock holder, its state line, three answered messages."""
    return {"schema": "agent-loop-status/v1", "slug": "slack-chat", "generated_at": iso(now), "generated_epoch": int(now),
            "about": "the Slack chat responder, /agent/slack-chat.sh - each message it answered is a fire",
            "renderer": {"stale_after_s": 30}, "log_tail": [],
            "record": {"file": "/wd/slack/chat.state", "at": iso(now - 10), "age_s": 10, "lines": ["POLLING interval=5s handled=2"]},
            "process": {"file": "/wd/slack/chat.lock", "holders": [{"pid": 4100, "cmd": "slack-chat.sh"}], "alive": True},
            "fires": [
                {"n": 3, "begin": iso(now - 30), "end": None, "kind": "model", "text": "<script>window.__pwned=1</script>",
                 "rc": None, "duration_s": None, "posted": None, "outcome": None, "status": "answering"},
                {"n": 2, "begin": iso(now - 200), "end": iso(now - 199), "kind": "status", "text": "status", "rc": None,
                 "duration_s": None, "posted": None, "outcome": "failed", "status": "failed"},
                {"n": 1, "begin": iso(now - 300), "end": iso(now - 285), "kind": "model", "text": "what does the loop do", "rc": 0,
                 "duration_s": 14, "posted": "yes", "outcome": "ok", "status": "ok"}]}


def c_status_page(b, var):
    root, ui, d = staged(var, "complete", "status")
    site = Site(ui, root)
    site.status["slack-chat"] = status_chat(time.time())
    ctx, pg = open_page(b, site.base + "loop/slack-chat/")
    pg.wait_for_function("() => document.querySelectorAll('#status-now li').length > 0", timeout=20000)
    shot(pg, var, "status-slack-chat-1920x1080")
    seen = {"title": pg.text_content("#status-title"),
            "rows": pg.eval_on_selector_all("#status-fires tbody tr", "els => els.map(e => e.querySelector('.pill') ? e.querySelector('.pill').textContent : e.textContent)"),
            "message 3": pg.evaluate("() => { const c = document.querySelector('#status-fires tbody tr:first-child td:last-child'); return c ? c.textContent : null; }"),
            "pwned": pg.evaluate("() => window.__pwned === undefined"),
            "process": pg.text_content("#status-now li:first-child .v")}
    ctx.close(); site.close()
    ok = (seen["title"] == "slack-chat" and seen["rows"] == ["answering", "failed", "ok (rc 0)"] and seen["pwned"]
          and seen["message 3"] == "model: <script>window.__pwned=1</script>" and seen["process"] == "running")
    return ok, seen


# ---------------------------------------------------------------- each check with the control that removes its property
CHECKS = [
    ("a completed loop reads COMPLETE in the headline, the Health tile and the fleet tree, with nothing red",
     c06_complete, [("loop-view.py",
                     '            if hub["state"] == "stopped" and g.get("exists") and g.get("open") == 0 and g.get("done", 0) > 0:',
                     "            if False:")]),
    ("a last fire that failed stays RED, under needs attention and in its row, even with every goal done",
     c06f_failed, [("loop-view.py", '            if last and last["status"] in ("failed", "timeout"):', "            if False:")]),
    ("every state on the page is a word",
     c03_words, [("loop-view/app.js", "text: label !== undefined ? label : (WORD[state] || state || 'unknown') });", "text: '' });")]),
    ("a refresh keeps the keyboard focus on the same command - the same button, or its replacement",
     c10_focus, [("loop-view/app.js", "    if (unchanged('cmds', D.commands)) return;\n", ""),
                 ("loop-view/app.js", "      if (focusKey !== null && k === focusKey) { x.focus({ preventScroll: true }); focusKey = null; }\n", "")]),
    ("the overview says it refreshes, and it reads its data again",
     c11_overview_polls, [("loop-view/app.js", "    overview(); setInterval(overview, REFRESH_MS);\n", "    overview();\n")]),
    ("an ended fire's page is a snapshot that says when it was read, and claims no refresh it does not do",
     c11_snapshot, [("loop-view/app.js", "'; this page does not refresh (reload it for newer data)'", "'; refreshes every 5 s'")]),
    ("a live fire's page says it refreshes until the fire ends, and polls",
     c11_live, [("loop-view/app.js", "          setTimeout(load, REFRESH_MS);\n          return;", "          return;")]),
    ("on a phone the outcome and the last fire are on the first screen, ahead of the loop's details",
     c05p_first_screen, [("loop-view/index.html",
                          '<p class="headline" id="headline"></p>\n<ul class="stats" id="stats"></ul>\n<ul class="stats diag" id="diag" aria-label="Loop details"></ul>',
                          '<ul class="stats diag" id="diag" aria-label="Loop details"></ul>\n<ul class="stats" id="stats"></ul>\n<p class="headline" id="headline"></p>')]),
    ("completed goals are condensed behind their count",
     c05p_goals_condensed, [("loop-view/app.js", "return !i.done; }), done = (g.items || []).filter(function (i) { return i.done; });",
                             "return true; }), done = [];")]),
    ("old data reads stale, in words",
     c_stale, [("loop-view/app.js", "    var age = now() - D.generated_epoch, stale = age > D.renderer.stale_after_s;",
                "    var age = now() - D.generated_epoch, stale = false;")]),
    ("a failed read says so and keeps what was read last",
     c_failed_fetch, [("loop-view/app.js", "    }).catch(function (e) { freshness(null, e.message || String(e)); });\n  }\n  function fireMeta",
                       "    }).catch(function (e) { freshness(null, e.message || String(e)); fill('stats', []); fill('headline', []); });\n  }\n  function fireMeta")]),
    ("no fire yet: the fires table says so and the headline says the loop idles",
     c_no_fires, [("loop-view/app.js", "    if (!rows.length) rows = [el('tr', {}, [el('td', { colspan: 6, text: 'No fire yet: the loop fires once it runs and has goals to fire against.' })])];\n", "")]),
    ("a live fire leads the headline, and its row is marked live",
     c_live_overview, [("loop-view/app.js", "    if (h.live_fire) {\n      var lf", "    if (false) {\n      var lf")]),
    ("the header's text starts where the nav's does at 1920x1080, with the harness stylesheet served",
     c_header_aligned, [("loop-view/style.css", ":root { --hs-max: 1500px; }\n", "")]),
    ("on a phone the header keeps a 16 px gutter, with the harness stylesheet served",
     c_header_gutter_phone, [("loop-view/style.css", ":root { --hs-max: 1500px; }\n",
                              ":root { --hs-max: 1500px; }\n.hs-header { padding: 16px 28px; }\n")]),
    ("Run next fire and Pause loop show the answer read back after the action - here a failure the scripts called fine",
     c38_read_back, [("loop-view/app.js", "    var a = res.after, state =",
                      "    var a = { state: action === 'run' ? 'running' : 'stopped', stop_flag: action === 'pause' }, state ="),
                     ("loop-view/app.js", "fill('act-result', [pill(res.result || 'failed'), ' ', el('span', { text: ACT[action] + ': ' + (res.message || 'no answer') }),",
                      "fill('act-result', [pill('done'), ' ', el('span', { text: ACT[action] + ': ' + (action === 'run' ? 'the loop runs' : 'the STOP flag is set') }),")]),
    ("each action is a same-origin POST carrying the page's X-Loop-Control header",
     c38_requests, [("loop-view/app.js", "headers: { 'X-Loop-Control': '1' } })", "headers: {} })")]),
    ("with the controls off the page offers no action and says how to turn them on",
     c38_off, [("loop-view/app.js", "    var on = !!(D.control && D.control.enabled);", "    var on = true;")]),
    ("under a loop's own address (/loop/autonomy-loop/) the page reads that loop's data and links its fires there",
     c_loop_prefix, [("loop-view/app.js", "  function overview() {\n    get('data.json', true)", "  function overview() {\n    get('/data.json', true)")]),
    ("with the Deck this harness serves reachable, on loop.localhost the page links its Loops view on the sibling host route, and off a *.localhost host it shows no link",
     c_loop_deck_link, [("loop-view/app.js", "    return m ? '//loop-deck.' + m[1] + '/#/loops' : null;", "    return null;")]),
    ("with the Deck neither reachable nor named, the page shows no Loop Deck link",
     c_loop_deck_none, [("loop-view.py", '    return {"route": True, "via": "loop-deck.localhost"} if DECK.reachable(now) else None\n',
                         '    return {"route": True, "via": "loop-deck.localhost"}\n')]),
    ("a Deck named by LOOP_DECK_URL is the link, to its Loops view, on any host",
     c_loop_deck_named, [("loop-view/app.js", "    if (deck && deck.href) return deck.href;\n", "")]),
    ("another loop's page (/loop/slack-chat/) shows its process and its answered messages as fires, every word as text",
     c_status_page, [("loop-view/app.js", "        if (D.fires) {\n          var rows = D.fires.map(", "        if (false) {\n          var rows = D.fires.map(")]),
]


def main():
    shipped = variant("shipped")
    failures = 0
    try:
        with sync_playwright() as p:
            # *.localhost on loopback, as a browser resolves it, so a check can open the page under its host route
            browser = p.chromium.launch(args=["--host-resolver-rules=MAP *.localhost 127.0.0.1"])
            for i, (title, check, mutations) in enumerate(CHECKS, 1):
                ok, seen = check(browser, shipped)
                mok, mseen = check(browser, variant("control-%d" % i, mutations))
                if ok and not mok:
                    print("ok %d - %s: %s; control fails: %s" % (i, title, json.dumps(seen), json.dumps(mseen)), flush=True)
                    continue
                failures += 1
                print("Test-loop-view-ux FAILED %d - %s: %s; control %s: %s" % (
                    i, title, json.dumps(seen) if not ok else "passed", "did NOT fail" if mok else "failed",
                    json.dumps(mseen)), flush=True)
            browser.close()
    finally:
        for h in HOLDERS:
            h.kill()
    if failures:
        print("Test-loop-view-ux FAILED: %d of %d checks (state kept in %s)" % (failures, len(CHECKS), TMP))
        return 1
    shutil.rmtree(TMP, ignore_errors=True)
    print("Test-loop-view-ux succeeded: %d checks, each with its failing control" % len(CHECKS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
