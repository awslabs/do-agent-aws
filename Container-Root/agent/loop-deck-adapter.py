#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Loop Deck harness adapter: the harness's own loops as Loop Deck's inputs (loop-deck-harness-contract.md, LOOP-59).

Loop Deck renders loops (registry rows) against evidence (fire-and-result records, a breaker ledger, a pause flag). In
harness mode it reads ONLY the files under one data directory and probes nothing; this script writes those files from
what the harness's loops leave behind, and nothing else:

  registry.json      the rows: the autonomy loop, slack-watch, slack-chat, comms-watch, kanban-sync, plane-sync, the
                     hindsight seed - regenerated whole on every run; a row is enabled:false when its flag is off, and the
                     autonomy loop's row when its STOP flag is set (the harness never pauses the Deck as a whole)
  runs.jsonl         the single fire-and-result feed, append-only under a lock, one record per source line/stamp, never
                     the same (ts, tag) twice; every record's ts and rc come from the source - where the source has no
                     rc or no timestamp the record says so in its note and never invents one
  loop-ledger.json   breakers: a run of consecutive failed fires of the autonomy loop, by attempts
  state.json         the pause flag: never paused by this adapter (the STOP flag is the loop row's enabled:false)

Sources (the harness's formats, quoted where they are written):
  ${AUTONOMY_LOOP_DIR}/loop.log       "<UTC>Z FIRE N END rc=R duration=Ds outcome=<word>" (loop.sh, loop-once.sh);
                                      "<UTC>Z FIRE N KANBAN <summary>" and "... PLANE <summary>", a failure reading
                                      "... not mirrored (rc=R, see ...)"
  ${SLACK_DIR}/last-watch             "<UTC>Z new=N replies=N deferred=N inbox=N" (slack-watch.sh, after a completed run)
  ${SLACK_DIR}/chat.log               "<UTC>Z CHAT MODEL ts=<slack ts> rc=R duration=Ds posted=<word> ..." (slack-chat.sh)
  ${COMMS_DIR}/watch.log              "cycle: polled=N fresh=N unattended=N next-fire<=Ns" - no timestamp, no rc
  ${HINDSIGHT_SEED_STAMP}             "seeded_at=<UTC>Z", "items=N" (hindsight-seed.sh); the seed's state file says
                                      whether the extraction completed or failed
The Deck's own outputs under out/ are never read or written here.

Usage: loop-deck-adapter.py [--data-dir DIR] [--generator PATH] [--dry-run]
  --generator PATH  run Loop Deck's generator (python3 -I PATH, LOOP_DECK_MODE=harness) after writing; its exit code
                    is reported, not hidden (3 = registry drift, 2 = an input the Deck refuses)
Exit: 0 written (and the generator, when given, exited 0); 2 the data directory cannot be written or an input is
unreadable in a way the adapter cannot describe; 3 the generator reported drift or refused an input.
Environment: LOOP_DECK_DATA_DIR (default /wd/loop-deck), AUTONOMY_LOOP_DIR (/wd/loop), AUTONOMY_LOOP_INTERVAL (300),
SLACK_DIR (/wd/slack), COMMS_DIR (/wd/comms), HINDSIGHT_SEED_STAMP (/wd/hindsight-seed.stamp), HINDSIGHT_SEED_STATE
(${UI_DIR:-/wd/ui}/hindsight-seed.state), and the flags the rows read: AUTONOMY_LOOP, SLACK_WATCH_ENABLED,
SLACK_CHAT_ENABLED, COMMS_WATCH_ENABLED, COMMS_WATCH_INTERVAL (300), KANBAN_BOARD_URL, PLANE_URL, HINDSIGHT_SEED.
"""
import argparse
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys

TS_RE = r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"
END_RE = re.compile(r"^" + TS_RE + r" FIRE (\d+) END rc=(-?\d+) duration=(\d+)s(?: outcome=(\S+))?")
MIRROR_RE = re.compile(r"^" + TS_RE + r" FIRE (\d+) (KANBAN|PLANE) (.*)$")
NOT_MIRRORED_RE = re.compile(r"not mirrored \(rc=(-?\d+)")
WATCH_RE = re.compile(r"^" + TS_RE + r" new=(\d+) replies=(\d+)(?: deferred=(\d+))? inbox=(\d+)")
CHAT_RE = re.compile(r"^" + TS_RE + r" CHAT MODEL ts=(\S+) rc=(-?\d+) duration=(\d+)s(.*)$")
CYCLE_RE = re.compile(r"cycle: polled=(\d+) fresh=(\d+) unattended=(\d+) next-fire<=(\d+)s(?: answered=(\d+))?")
MAX_ATTEMPTS = 3
TAGS = {"loop": "harness-autonomy-loop", "watch": "harness-slack-watch", "chat": "harness-slack-chat",
        "comms": "harness-comms-watch", "kanban": "harness-kanban-sync", "plane": "harness-plane-sync",
        "seed": "harness-hindsight-seed"}


def env(name, default=""):
    return os.environ.get(name, default)


def on(name, default="false"):
    return env(name, default).strip().lower() == "true"


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().split("\n")
    except OSError:
        return []


def note(text, limit=200):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def registry(loop_dir, interval):
    stop = os.path.exists(os.path.join(loop_dir, "STOP"))
    rows = [
        {"slug": "autonomy-loop", "name": "Autonomy loop", "kind": "loop",
         "owner": f"/agent/loop.sh (AUTONOMY_LOOP_INTERVAL={interval})", "cadence_s": interval, "tags": [TAGS["loop"]],
         "enabled": env("AUTONOMY_LOOP", "auto").lower() != "false" and not stop, "depends_on": [],
         "runbook_md": ("Stop: touch " + os.path.join(loop_dir, "STOP") + " (or /agent/loop-stop.sh). Resume: /agent/loop-start.sh "
                        "removes the flag and relaunches. Status: /agent/loop-status.sh. Logs: " + os.path.join(loop_dir, "loop.log")
                        + ", the fires' transcripts under " + os.path.join(loop_dir, "fires") + "/."
                        + (" Currently stopped: the STOP flag is set." if stop else ""))},
        {"slug": "slack-watch", "name": "Slack watch", "kind": "watch",
         "owner": "/agent/slack-watch.sh (per fire from loop.sh, and from slack-chat.sh)", "cadence_s": interval,
         "tags": [TAGS["watch"]], "enabled": on("SLACK_WATCH_ENABLED"), "depends_on": ["autonomy-loop"],
         "runbook_md": "Needs SLACK_BOT_TOKEN and SLACK_CHANNELS. Last run: ${SLACK_DIR}/last-watch; inbox: ${SLACK_DIR}/inbox.jsonl. Check: /agent/slack-doctor.sh."},
        {"slug": "slack-chat", "name": "Slack chat responder", "kind": "loop",
         "owner": "/agent/slack-chat.sh (daemon, polls every SLACK_CHAT_POLL_INTERVAL seconds)", "cadence_s": interval,
         "tags": [TAGS["chat"]], "enabled": on("SLACK_CHAT_ENABLED"), "depends_on": ["slack-watch"],
         "runbook_md": "Start/stop: /agent/slack-chat-start.sh, slack-chat-stop.sh; status: slack-chat-status.sh. Log: ${SLACK_DIR}/chat.log. A model answer is one CHAT MODEL line with its rc and duration."},
        {"slug": "comms-watch", "name": "Comms watch", "kind": "watch",
         "owner": "the communication engine's scheduler.py (comms-watch-start.sh)", "cadence_s": int(env("COMMS_WATCH_INTERVAL", "300") or 300),
         "tags": [TAGS["comms"]], "enabled": on("COMMS_WATCH_ENABLED"), "depends_on": [],
         "runbook_md": "Start/stop: /agent/comms-watch-start.sh, comms-watch-stop.sh; status: comms-watch-status.sh. Log: ${COMMS_DIR}/watch.log (cycle lines carry no timestamp and no exit code; a record's ts is the log's modification time)."},
        {"slug": "kanban-sync", "name": "Goals board sync", "kind": "sync",
         "owner": "/agent/kanban-sync.py (per fire from loop.sh; seeded at container start)", "cadence_s": interval,
         "tags": [TAGS["kanban"]], "enabled": bool(env("KANBAN_BOARD_URL")), "depends_on": ["autonomy-loop"],
         "runbook_md": "The goals file is the source of truth; the board mirrors it both ways. A failed call logs one FIRE N KANBAN line and the fire is unaffected; details in ${AUTONOMY_LOOP_DIR}/kanban-sync.log."},
        {"slug": "plane-sync", "name": "Project board (Plane) sync", "kind": "sync",
         "owner": "/agent/plane-sync.py (per fire from loop.sh)", "cadence_s": interval,
         "tags": [TAGS["plane"]], "enabled": bool(env("PLANE_URL")), "depends_on": ["autonomy-loop"],
         "runbook_md": "Best effort per fire; a failed call logs one FIRE N PLANE line; details in ${AUTONOMY_LOOP_DIR}/plane-sync.log."},
        {"slug": "hindsight-seed", "name": "Memory seed", "kind": "seed",
         "owner": "/agent/hindsight-seed.sh (once per /wd volume, at container start)", "cadence_s": None,
         "tags": [TAGS["seed"]], "enabled": env("HINDSIGHT_SEED", "true").lower() != "false", "depends_on": [],
         "runbook_md": "Status: /agent/hindsight-seed.sh --status; re-seed: --force. The stamp records acceptance; the state file the extraction (complete, extracting, failed)."},
    ]
    return {"schema": "loop-deck-registry/1", "generated_at": iso(datetime.datetime.now(datetime.timezone.utc).timestamp()),
            "source": "do-agent-aws harness adapter 0.1", "loops": rows}


def collect(loop_dir, slack_dir, comms_dir, stamp, state_file):
    """every run record the sources hold right now, and the problems met on the way"""
    records, problems = [], []
    for line in read_lines(os.path.join(loop_dir, "loop.log")):
        m = END_RE.match(line)
        if m:
            ts, fire, rc, dur, outcome = m.groups()
            records.append({"ts": ts, "tag": TAGS["loop"], "rc": int(rc), "dur_s": int(dur),
                            "note": note(f"fire {fire}" + (f" outcome={outcome}" if outcome else ""))})
            continue
        m = MIRROR_RE.match(line)
        if m:
            ts, fire, which, text = m.groups()
            bad = NOT_MIRRORED_RE.search(text)
            records.append({"ts": ts, "tag": TAGS["kanban"] if which == "KANBAN" else TAGS["plane"],
                            "rc": int(bad.group(1)) if bad else 0, "dur_s": None,
                            "note": note(f"fire {fire}: {text}" + ("" if bad else " (rc 0: the line reports no failure; the source logs no duration)"))})
            continue
        if " FIRE " in line and " END " in line:
            problems.append(f"loop.log: an END line the adapter cannot read, skipped (nothing invented): {note(line, 120)}")
    for line in read_lines(os.path.join(slack_dir, "last-watch")):
        m = WATCH_RE.match(line)
        if m:
            records.append({"ts": m.group(1), "tag": TAGS["watch"], "rc": 0, "dur_s": None,
                            "note": note(f"{line[len(m.group(1)) + 1:]} (rc 0: slack-watch.sh writes this stamp only after a completed run; it logs no duration)")})
        elif line.strip():
            problems.append(f"last-watch: a stamp the adapter cannot read, skipped: {note(line, 120)}")
    for line in read_lines(os.path.join(slack_dir, "chat.log")):
        m = CHAT_RE.match(line)
        if m:
            ts, sts, rc, dur, rest = m.groups()
            records.append({"ts": ts, "tag": TAGS["chat"], "rc": int(rc), "dur_s": int(dur), "note": note(f"ts={sts}{rest}")})
    watch_log = os.path.join(comms_dir, "watch.log")
    cycles = [CYCLE_RE.search(l) for l in read_lines(watch_log)]
    cycles = [m for m in cycles if m]
    if cycles:
        last = cycles[-1]
        try:
            mtime = os.stat(watch_log).st_mtime
        except OSError:
            mtime = None
        if mtime is not None:
            records.append({"ts": iso(mtime), "tag": TAGS["comms"], "rc": 0, "dur_s": None,
                            "note": note(f"no ts/rc in the source: ts = watch.log mtime, rc 0 = a cycle was logged; {len(cycles)} cycle line(s); "
                                         f"last: {last.group(0)}")})
    seeded, items, failed = None, None, None
    for line in read_lines(stamp):
        if line.startswith("seeded_at="):
            seeded = line.split("=", 1)[1].strip()
        elif line.startswith("items="):
            items = line.split("=", 1)[1].strip()
    for line in read_lines(state_file):
        if line.startswith("state="):
            failed = line.split("=", 1)[1].strip() == "failed"
    if seeded and re.fullmatch(TS_RE, seeded):
        records.append({"ts": seeded, "tag": TAGS["seed"], "rc": 1 if failed else 0, "dur_s": None,
                        "note": note((f"items={items}; " if items else "") + ("extraction failed (the seed's state file)" if failed
                                     else "accepted by the memory API (the stamp); the extraction state is in the seed's state file"))})
    return records, problems


def ledger(records):
    """breakers: consecutive failed fires of the autonomy loop, keyed by the first fire of the run"""
    items, streak = {}, []
    fires = sorted((r for r in records if r["tag"] == TAGS["loop"]), key=lambda r: r["ts"])
    for r in fires:
        if r["rc"] != 0:
            streak.append(r)
        else:
            streak = []
        if len(streak) >= 2 or (streak and r is fires[-1]):
            first = streak[0]["note"].split()[1] if streak[0]["note"].startswith("fire ") else streak[0]["ts"]
            items[f"autonomy-loop:streak-{first}"] = {"attempts": len(streak), "last_ts": streak[-1]["ts"],
                                                       "note": note(f"{len(streak)} failed fire(s) in a row; last {streak[-1]['note']} rc={streak[-1]['rc']}")}
    return {"schema": "loop-deck-ledger/1", "max_attempts": MAX_ATTEMPTS, "items": items}


def write_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=False)
        f.write("\n")
    os.replace(tmp, path)


def append_runs(path, records):
    """append the records not yet in the file, (ts, tag) being the identity; the file is locked while read and written"""
    with open(path, "a+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        seen = set()
        for line in f.read().split("\n"):
            if line.strip():
                try:
                    o = json.loads(line)
                    seen.add((o.get("ts"), o.get("tag")))
                except ValueError:
                    pass
        new = [r for r in sorted(records, key=lambda r: (r["ts"], r["tag"])) if (r["ts"], r["tag"]) not in seen]
        for r in new:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
        f.flush()
        fcntl.flock(f, fcntl.LOCK_UN)
    return len(new), len(records) - len(new)


VENDORED_GENERATOR = os.environ.get("LOOP_DECK_VENDORED_DIR", "/opt/loop-deck") + "/generate-loop-viz.py"


def main():
    ap = argparse.ArgumentParser(description="write Loop Deck's harness-mode inputs from the harness's own loops")
    ap.add_argument("--data-dir", default=env("LOOP_DECK_DATA_DIR", "/wd/loop-deck"))
    # the vendored Deck's generator (/opt/loop-deck, VENDORED.md) renders out/ after every write when it is there; LOOP_DECK_GENERATOR
    # names another one, LOOP_DECK_GENERATOR= (empty) runs none
    ap.add_argument("--generator", default=env("LOOP_DECK_GENERATOR", VENDORED_GENERATOR if os.path.exists(VENDORED_GENERATOR) else ""),
                    help="Loop Deck's generate-loop-viz.py, run after writing (default: the vendored /opt/loop-deck one when present)")
    ap.add_argument("--dry-run", action="store_true", help="print what would be written, write nothing")
    args = ap.parse_args()
    loop_dir = env("AUTONOMY_LOOP_DIR", "/wd/loop")
    try:
        interval = int(env("AUTONOMY_LOOP_INTERVAL", "300") or 300)
    except ValueError:
        interval = 300
    reg = registry(loop_dir, interval)
    records, problems = collect(loop_dir, env("SLACK_DIR", "/wd/slack"), env("COMMS_DIR", "/wd/comms"),
                                env("HINDSIGHT_SEED_STAMP", "/wd/hindsight-seed.stamp"),
                                env("HINDSIGHT_SEED_STATE", os.path.join(env("UI_DIR", "/wd/ui"), "hindsight-seed.state")))
    led = ledger(records)
    state = {"schema": "loop-deck-state/1", "paused": False, "reason": "", "ts": reg["generated_at"]}
    for p in problems:
        print(f"loop-deck-adapter: WARNING - {p}", file=sys.stderr)
    if args.dry_run:
        print(f"loop-deck-adapter: dry run - {len(reg['loops'])} rows, {len(records)} run record(s) in the sources, "
              f"{len(led['items'])} ledger item(s); would write under {args.data_dir}")
        return 0
    try:
        os.makedirs(args.data_dir, exist_ok=True)
        if not os.access(args.data_dir, os.W_OK):
            raise OSError("not writable")
        write_atomic(os.path.join(args.data_dir, "registry.json"), reg)
        write_atomic(os.path.join(args.data_dir, "loop-ledger.json"), led)
        write_atomic(os.path.join(args.data_dir, "state.json"), state)
        new, old = append_runs(os.path.join(args.data_dir, "runs.jsonl"), records)
    except OSError as e:
        print(f"loop-deck-adapter: ERROR - cannot write the data directory {args.data_dir}: {e}", file=sys.stderr)
        return 2
    print(f"loop-deck-adapter: {len(reg['loops'])} rows ({sum(1 for r in reg['loops'] if r['enabled'])} enabled), "
          f"{new} new run record(s) appended ({old} already recorded), {len(led['items'])} ledger item(s), "
          f"{len(problems)} source line(s) skipped; data dir {args.data_dir}")
    if args.generator:
        gen = subprocess.run([sys.executable, "-I", args.generator],  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- argv list run without a shell; the environment values are operator settings, each passed as one argv word
                             env=dict(os.environ, LOOP_DECK_MODE="harness", LOOP_DECK_DATA_DIR=args.data_dir, PYTHONDONTWRITEBYTECODE="1"))
        if gen.returncode != 0:
            print(f"loop-deck-adapter: the generator exited {gen.returncode}" + (" (registry drift)" if gen.returncode == 3 else ""), file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
