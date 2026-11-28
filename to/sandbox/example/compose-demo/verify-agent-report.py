#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Verify the compose-demo agent layer from evidence, never from the model's prose.

Runs inside the sandbox after the agent's headless session, against the same
Docker Engine the agent used. PASS needs every check below:

  report    the report file is one JSON object whose fields carry the expected
            types and values: this run's nonce, the project name, health status
            ok, tests EXPECTED_CHECKS passed and 0 failed, 0 published ports,
            compose_down true
  engine    no container of the project is left (docker ps -a)
  events    the engine's event log since the agent started shows a web container
            of the project whose id starts with the reported instance_id (the
            instance_id is the serving container's hostname) and which exited 0
            when it was stopped - app/server.pl exits 0 only after serving every
            request app/check.pl makes - and at least one tests container of the
            project, every one of which exited 0
  stack     the stack as shipped publishes no port (docker compose config)

Also records the sha256 of the example files, which the host compares with its
own copy to show the agent left them unchanged. Writes a verdict JSON and exits
0 only on PASS.

Scope: this runs inside the sandbox the agent controlled as root, against the
engine the agent used. It catches a wrong, partial or hallucinated report; it is
not proof against an agent that deliberately forges the engine's state. e2e.sh
copies a fresh copy of this script in after the agent session and runs that copy.
Not covered: whether the agent itself read /health (the instance id is also
visible through docker ps) and which ports the agent's own commands published
(only the shipped compose file is checked).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

# Keep in sync with the @checks list in app/check.pl.
EXPECTED_CHECKS = 5
EXAMPLE_FILES = ["compose.yaml", "Dockerfile", "app/server.pl", "app/check.pl"]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)  # nosemgrep: dangerous-subprocess-use-audit -- the example's own fixed argv lists; no shell
    return p.returncode, p.stdout, p.stderr


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--report", required=True)
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--since", required=True, type=int, help="epoch seconds when the agent session started")
    ap.add_argument("--example-dir", required=True)
    ap.add_argument("--verdict", required=True)
    a = ap.parse_args()

    checks = []

    def check(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return bool(ok)

    report = None
    try:
        with open(a.report) as f:
            report = json.load(f)
        check("report is a JSON object", isinstance(report, dict), a.report)
    except (OSError, ValueError) as e:
        check("report is a JSON object", False, f"{a.report}: {e}")
    if not isinstance(report, dict):
        report = {}

    def is_int(v):
        return isinstance(v, int) and not isinstance(v, bool)

    health = report.get("health") if isinstance(report.get("health"), dict) else {}
    tests = report.get("tests") if isinstance(report.get("tests"), dict) else {}
    instance_id = health.get("instance_id") if isinstance(health.get("instance_id"), str) else ""
    check("nonce matches this run", report.get("nonce") == a.nonce, str(report.get("nonce")))
    check("project matches", report.get("project") == a.project, str(report.get("project")))
    check("health.status is ok", health.get("status") == "ok", str(health.get("status")))
    check("health.instance_id looks like a container hostname", re.fullmatch(r"[0-9a-f]{12,64}", instance_id) is not None, instance_id)
    check(f"tests.passed is {EXPECTED_CHECKS}", is_int(tests.get("passed")) and tests.get("passed") == EXPECTED_CHECKS, str(tests.get("passed")))
    check("tests.failed is 0", is_int(tests.get("failed")) and tests.get("failed") == 0, str(tests.get("failed")))
    check("published_ports is 0", is_int(report.get("published_ports")) and report.get("published_ports") == 0, str(report.get("published_ports")))
    check("compose_down is true", report.get("compose_down") is True, str(report.get("compose_down")))

    label = f"label=com.docker.compose.project={a.project}"
    rc, out, err = run(["docker", "ps", "-aq", "--filter", label])
    check("engine: no container of the project is left", rc == 0 and out.strip() == "", (out or err).strip())

    until = int(time.time()) + 1
    rc, out, err = run(["docker", "events", "--since", str(a.since), "--until", str(until),
                        "--filter", "type=container", "--filter", label, "--format", "{{json .}}"])
    events = []
    for line in out.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass

    def attrs(ev):
        return (ev.get("Actor") or {}).get("Attributes") or {}

    def action(ev):
        return ev.get("Action") or ev.get("status") or ""

    def cid(ev):
        return ev.get("id") or (ev.get("Actor") or {}).get("ID", "")

    web_starts = [cid(ev) for ev in events
                  if action(ev) == "start" and attrs(ev).get("com.docker.compose.service") == "web"]
    reported_web_exits = [attrs(ev).get("exitCode") for ev in events
                          if action(ev) == "die" and attrs(ev).get("com.docker.compose.service") == "web"
                          and instance_id and cid(ev).startswith(instance_id)]
    tests_exits = [attrs(ev).get("exitCode") for ev in events
                   if action(ev) == "die" and attrs(ev).get("com.docker.compose.service") == "tests"]
    check("events: the engine log for the window was read", rc == 0 and len(events) > 0,
          f"rc={rc} events={len(events)} {err.strip()}")
    check("events: a web container started whose id starts with the reported instance_id",
          bool(instance_id) and any(c.startswith(instance_id) for c in web_starts),
          f"web starts: {[c[:12] for c in web_starts]}")
    check("events: that web container exited 0 when stopped (it served every check request)",
          bool(reported_web_exits) and all(x == "0" for x in reported_web_exits),
          f"exit codes of the reported web container: {reported_web_exits}")
    check("events: tests containers ran and every one exited 0",
          bool(tests_exits) and all(x == "0" for x in tests_exits), f"tests exit codes: {tests_exits}")

    rc, out, err = run(["docker", "compose", "-p", a.project, "-f", os.path.join(a.example_dir, "compose.yaml"),
                        "config", "--format", "json"])
    published = None
    if rc == 0:
        try:
            cfg = json.loads(out)
            published = sum(len(s.get("ports") or []) for s in cfg.get("services", {}).values())
        except ValueError:
            pass
    check("stack: the shipped compose file publishes no port", published == 0, f"rc={rc} published={published} {err.strip()}")

    sha = {}
    for rel in EXAMPLE_FILES:
        try:
            with open(os.path.join(a.example_dir, rel), "rb") as f:
                sha[rel] = hashlib.sha256(f.read()).hexdigest()
        except OSError as e:
            sha[rel] = f"missing: {e}"

    status = "PASS" if all(c["ok"] for c in checks) else "FAIL"
    verdict = {
        "layer": "compose-demo-agent",
        "status": status,
        "checks": checks,
        "report": report,
        "events_seen": len(events),
        "example_sha256": sha,
    }
    with open(a.verdict, "w") as f:
        json.dump(verdict, f, indent=2)
        f.write("\n")
    for c in checks:
        print(("ok - " if c["ok"] else "not ok - ") + c["name"] + (f" ({c['detail']})" if c["detail"] else ""))
    print(f"{status} - verdict {a.verdict}")
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
