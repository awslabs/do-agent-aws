#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The spoke helper: reads the registry of the harness's agent sessions, checks the spokes' charters and entries, and
# keeps their state files (docs/manual/agents.md "Spoke agents", docs/AGENT-STACK.md).
#
# The registry (SPOKES_REGISTRY, default /agent/spokes/registry.json) is the only source of what runs. It has the
# schema of the fleet watchdog's registry - {"version": 1, "sessions": [...]}, each entry with session_name, workdir,
# launch_cmd, enabled, cooldown_sec, env and note - and the harness's keys beside them:
#   role         hub (the agent you talk to; started by startup.sh), supervisor (/agent/supervisor.sh) or spoke
#   flag         the .env flag that switches the entry on (SPOKE_<NAME>; the hub's is AGENT_TMUX_SESSION); with a flag
#                set, its value decides, and "enabled" is only the default when the flag is unset
#   parent, task the lineage the tmux-agent dashboard shows (@agent_parent, @agent_task; @agent_owner is do-agent-aws)
#   charter      the spoke's charter, the CLAUDE.md of its session: /agent/charters/<name>/charter.md
#   source, ref  where its code comes from: "none" (nothing to fetch), "vendored: <path>" (a tree the image ships under
#                /agent/ or /opt/), or a PUBLIC https URL with a ref (cloned anonymously, so a private one is refused)
#   cycle, cadence_sec  the command one cycle of its loop runs, in its workdir, and how often the supervisor runs it
#   notices      where a cycle's messages for the hub come from: "stdout:<prefix>" (each output line that starts with
#                the prefix) or "jsonl:<file in the workdir>" (each new record's text); the supervisor journals each one
#                as a notice from the spoke (/agent/bus.sh)
#   writes, cost, title, tile, agent_process  what it writes, what it costs, its tile's title, the tile it keeps
#                current, the command name its pane runs while its agent is alive (default claude)
#   page         a path of its own on the home listener (/<name>/): the home page serves the STATUS.html its cycle writes
#                in its workdir there, and its tile links it (home-render.sh)
#   requires, requires_what  the settings its cycle needs, as environment variable NAMES (SLACK_BOT_TOKEN), and one
#                word for what they are (Slack): while one is unset the supervisor reports the spoke "waiting for <what>
#                (<names>)", keeps its session and runs no cycle of it, and restarts nothing
#
# A charter is prose, as its owner wrote it. Its check: a North Star section, a Source section, a section on what it
# writes, and the six rules every spoke carries - loopback only; nothing leaves (or is sent outside) without a human GO;
# read-only on clusters unless a goal says otherwise; never type into another session's menu; ${VAR:?} guards on
# deletions; the charter states what it writes.
#
# Usage:
#   spoke.sh names                     every spoke's session name, in registry order
#   spoke.sh sessions                  every session of the registry with its role, "<name> <role>" a line
#   spoke.sh entry <name> [<key> [--list]]
#                                      the entry as JSON, or one key (a list space separated, or one item a line)
#   spoke.sh flag <name>               the entry's flag
#   spoke.sh enabled <name>            exit 0 when the entry is switched on
#   spoke.sh table                     every session of the registry, "<name> <role> <on> <flag> <requires> <what>
#                                      <agent process>" a line: on is true or false as enabled decides, requires the
#                                      names joined by commas; a missing flag, requires or what is "-"; the agent process
#                                      defaults to claude (what the supervisor reads every pass, in one start)
#   spoke.sh check [<name>...]         check the registry's spokes (all of them by default) and their charters; one line
#                                      per finding and exit 1, exit 0 when there is none
#   spoke.sh check-charter <file>...   the charter checks alone, on any file
#   spoke.sh state <name> [key=value...]
#                                      with no pair: print ${SUPERVISOR_DIR}/<name>/state.json; with pairs: merge them
#                                      in under its lock (an integer, true or false keeps its type, an empty value is null)
#
# Settings: SPOKES_REGISTRY; SUPERVISOR_DIR (default /wd/supervisor, a directory per session); AGENT_TMUX_SESSION_NAME,
# the hub's session name (default agent), which no spoke may take.

SPOKES_REGISTRY=${SPOKES_REGISTRY:-/agent/spokes/registry.json}
SUPERVISOR_DIR=${SUPERVISOR_DIR:-/wd/supervisor}
AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME:-agent}
export SPOKES_REGISTRY SUPERVISOR_DIR AGENT_TMUX_SESSION_NAME

PY=$(cat << 'EOF'
import json, os, re, sys

registry, hub = os.environ["SPOKES_REGISTRY"], os.environ["AGENT_TMUX_SESSION_NAME"]
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}")
RESERVED = {"operator", "human", "system", "root", "broker", "launcher"}
RULES = [
    ("loopback only", r"loopback only"),
    ("nothing leaves without a human GO", r"nothing (leaves|sent outside|is sent outside)\b[^.\n]{0,30}without a human go"),
    ("read-only on clusters unless a goal says otherwise", r"read-only on clusters"),
    ("never type into another session's menu", r"never type into another session'?s menu"),
    ("${VAR:?} guards on deletions", r"\$\{[a-z0-9_]+:\?\}[^.\n]{0,40}(guard|delet|remov)|(guard|delet|remov)[^.\n]{0,40}\$\{[a-z0-9_]+:\?\}"),
    ("the charter states what it writes", r"(what it writes is stated|states what it writes)"),
]
SECTIONS = [("a North Star section", r"north star"), ("a Source section", r"source"), ("a section on what it writes", r"writes")]
# the home listener's own paths (home-render.sh), which no spoke's page may take
HOME_PATHS = {"guide", "headlamp", "memory-api", "comms", "tmux", "tmux-agent", "tmux-help", "transcripts", "loop", "workspaces", "settings", "v1"}


def load():
    try:
        d = json.load(open(registry, encoding="utf-8"))
    except (OSError, ValueError) as e:
        sys.exit(f"spoke.sh: the registry {registry} is not readable JSON ({e})")
    if not isinstance(d, dict) or d.get("version") != 1 or not isinstance(d.get("sessions"), list):
        sys.exit(f"spoke.sh: the registry {registry} is not version 1 with a sessions list")
    return d["sessions"]


def find(name):
    for e in load():
        if isinstance(e, dict) and e.get("session_name") == name:
            return e
    sys.exit(f"spoke.sh: no session {name!r} in the registry {registry}")


def charter_findings(path):
    out = []
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return [f"{path}: no such charter"]
    # the rules are looked for in the text, not in the headings (a "Writes only" heading is not the rule)
    flat = re.sub(r"[*`]", "", re.sub(r"(?m)^#{1,6}\s.*$", "", text)).lower()
    headings = [h.lower() for h in re.findall(r"^#{1,6}\s+(.*)$", text, re.M)]
    for label, rx in SECTIONS:
        if not any(re.search(rx, h) for h in headings):
            out.append(f"{path}: no {label} (a heading that names it)")
    for label, rx in RULES:
        if not re.search(rx, flat):
            out.append(f"{path}: the rule '{label}' is missing")
    return out


def source_findings(where, source, ref):
    if source == "none":
        return []
    if isinstance(source, str) and source.startswith("vendored: "):
        p = source[len("vendored: "):]
        if not (p.startswith("/agent/") or p.startswith("/opt/")):
            return [f"{where}: vendored source {p!r} is not a tree the image ships (under /agent/ or /opt/)"]
        if not re.fullmatch(r"/[A-Za-z0-9._/-]+", p) or "/../" in p + "/":
            return [f"{where}: vendored path {p!r} is not a plain path (no '..', no other characters)"]
        return []
    if isinstance(source, str) and source.startswith("https://"):
        f = []
        if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]+", source):
            f.append(f"{where}: source {source!r} is not a plain public https URL (no user, token, query or fragment)")
        if not isinstance(ref, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", ref):
            f.append(f"{where}: a URL source needs a ref (a branch, tag or commit) that opens with a letter or digit")
        return f
    return [f"{where}: source {source!r} is neither 'none', 'vendored: <path>' nor a public https URL"]


def entry_findings(e, seen):
    where = f"{registry}: {e.get('session_name', '?')}"
    f = []
    n = e.get("session_name")
    if not isinstance(n, str) or not NAME.match(n):
        return [f"{registry}: session_name {n!r} is not a session name (alnum start, [A-Za-z0-9._-], at most 64)"]
    if n.lower() in RESERVED:
        f.append(f"{where}: the name is reserved")
    if n in seen:
        f.append(f"{where}: the name is in the registry twice")
    seen.add(n)
    if e.get("role") not in ("hub", "supervisor", "spoke"):
        f.append(f"{where}: role {e.get('role')!r} is not hub, supervisor or spoke")
    for k in ("workdir", "launch_cmd"):
        if not isinstance(e.get(k), str) or not e.get(k):
            f.append(f"{where}: no {k}")
    wd = e.get("workdir")
    if isinstance(wd, str) and (not wd.startswith("/") or "/../" in wd + "/"):
        f.append(f"{where}: workdir {wd!r} is not an absolute plain path")
    if not isinstance(e.get("cooldown_sec", 0), int) or e.get("cooldown_sec", 0) < 0:
        f.append(f"{where}: cooldown_sec is not a number of seconds")
    env = e.get("env", {})
    if not isinstance(env, dict) or not all(isinstance(k, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", k) and isinstance(v, str)
                                            and not re.search(r"[\x00-\x1f\x7f]", v) for k, v in env.items()):
        f.append(f"{where}: env is not an object of NAME: one-line string")
    if e.get("role") == "hub":
        if n != hub:
            f.append(f"{where}: the hub entry is not the hub session's name ({hub})")
        return f
    if n == hub:
        f.append(f"{where}: a {e.get('role')} takes the hub session's name")
    if e.get("role") == "supervisor":
        if not isinstance(e.get("flag"), str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", e.get("flag") or ""):
            f.append(f"{where}: flag {e.get('flag')!r} is not an .env name")
        return f
    if not isinstance(e.get("flag"), str) or not re.fullmatch(r"SPOKE_[A-Z0-9_]+", e.get("flag") or ""):
        f.append(f"{where}: flag {e.get('flag')!r} is not SPOKE_<NAME>")
    rq, rw = e.get("requires"), e.get("requires_what")
    if rq is not None and not (isinstance(rq, list) and rq and all(isinstance(x, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", x) for x in rq)):
        f.append(f"{where}: requires is not a list of environment variable NAMES")
    if rw is not None and (rq is None or not isinstance(rw, str) or not WORD.fullmatch(rw)):
        f.append(f"{where}: requires_what is not one word (letters, digits, '.', '_', '-') beside a requires list")
    for k in ("title", "cost", "task", "parent"):
        if not isinstance(e.get(k), str) or not e.get(k).strip():
            f.append(f"{where}: no {k}")
    w = e.get("writes")
    if not isinstance(w, list) or not w or not all(isinstance(x, str) and x for x in w):
        f.append(f"{where}: writes is not a list of the paths it writes")
    cyc = e.get("cycle", "")
    if cyc:
        if not isinstance(cyc, str) or not os.access(cyc.split()[0], os.X_OK):
            f.append(f"{where}: the cycle command {cyc!r} is not an executable file in this image")
        if not isinstance(e.get("cadence_sec"), int) or isinstance(e.get("cadence_sec"), bool) or e.get("cadence_sec") < 1:
            f.append(f"{where}: a cycle needs a cadence_sec in seconds")
    nt = e.get("notices")
    if nt is not None and not (isinstance(nt, str) and (re.fullmatch(r"stdout:.+", nt) or re.fullmatch(r"jsonl:[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*", nt))):
        f.append(f"{where}: notices {nt!r} is neither 'stdout:<prefix>' nor 'jsonl:<file in the workdir>'")
    elif isinstance(nt, str) and nt.startswith("jsonl:") and ".." in nt[len("jsonl:"):].split("/"):
        f.append(f"{where}: notices {nt!r} climbs out of the workdir")
    pg = e.get("page")
    if pg is not None and (not isinstance(pg, str) or not re.fullmatch(r"/[a-z0-9][a-z0-9-]*/", pg) or pg.strip("/") in HOME_PATHS):
        f.append(f"{where}: page {pg!r} is not a free path of the home listener (/<name>/ in lowercase, none of its own: {', '.join(sorted(HOME_PATHS))})")
    f += source_findings(where, e.get("source"), e.get("ref"))
    ch = e.get("charter")
    if not isinstance(ch, str) or not ch:
        f.append(f"{where}: no charter")
    else:
        f += charter_findings(ch)
    return f


def enabled(e):
    flag = e.get("flag")
    if flag and flag in os.environ:
        return os.environ[flag] == "true"
    return e.get("enabled") is True


cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "names":
    for e in load():
        if isinstance(e, dict) and e.get("role") == "spoke":
            print(e.get("session_name"))
elif cmd == "sessions":
    for e in load():
        if isinstance(e, dict) and isinstance(e.get("session_name"), str) and NAME.match(e["session_name"]):
            print(e["session_name"], e.get("role"))
elif cmd == "entry":
    e = find(args[0])
    if len(args) == 1:
        print(json.dumps(e, sort_keys=True))
    else:
        v = e.get(args[1])
        if v is None:
            sys.exit(1)
        if isinstance(v, list):
            print("\n".join(v) if args[2:] == ["--list"] else " ".join(v))
        else:
            print(json.dumps(v) if isinstance(v, dict) else v)
elif cmd == "flag":
    print(find(args[0]).get("flag", ""))
elif cmd == "table":
    for e in load():
        if isinstance(e, dict) and isinstance(e.get("session_name"), str) and NAME.match(e["session_name"]):
            rq = [x for x in (e.get("requires") or []) if isinstance(x, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", x)]
            rw = e.get("requires_what")
            rw = rw if isinstance(rw, str) and WORD.fullmatch(rw) else "-"
            print(e["session_name"], e.get("role"), "true" if enabled(e) else "false", e.get("flag") or "-", ",".join(rq) or "-", rw,
                  e.get("agent_process") or "claude")
elif cmd == "enabled":
    sys.exit(0 if enabled(find(args[0])) else 1)
elif cmd == "check":
    seen, f = set(), []
    entries = load()
    names = args or [e.get("session_name") for e in entries if isinstance(e, dict) and e.get("role") == "spoke"]
    if not names:
        f.append(f"{registry}: the registry lists no spoke (nothing to check is not a pass)")
    for e in entries:
        if not isinstance(e, dict):
            f.append(f"{registry}: an entry is not an object")
        elif e.get("session_name") in names or (not args and e.get("role") in ("hub", "supervisor")):
            f += entry_findings(e, seen)
    for n in names:
        if not any(isinstance(e, dict) and e.get("session_name") == n for e in entries):
            f.append(f"{registry}: no session {n!r}")
    print("\n".join(f)) if f else None
    sys.exit(1 if f else 0)
elif cmd == "check-charter":
    f = [x for p in args for x in charter_findings(p)]
    print("\n".join(f)) if f else None
    sys.exit(1 if f else 0)
EOF
)

case "$1" in
	names|sessions|entry|flag|enabled|table|check|check-charter)
		python3 -I -c "${PY}" "$@"
		;;
	state)
		NAME=$2
		shift 2
		echo "${NAME}" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || { echo "$0 state: '${NAME}' is not a session name" >&2; exit 64; }
		STATE=${SUPERVISOR_DIR%/}/${NAME}/state.json
		if [ $# -eq 0 ]; then
			cat "${STATE}" 2>/dev/null || { echo "$0 state: no state recorded for ${NAME} (${STATE})" >&2; exit 1; }
			exit 0
		fi
		mkdir -p "$(dirname "${STATE}")" || exit 1
		# one writer at a time: tmux-session-start.sh records a start, supervisor.sh its passes and cycles
		(
			flock 8
			python3 - "${STATE}" "$@" << 'EOF2'
import json, os, re, sys
path, pairs = sys.argv[1], sys.argv[2:]
try:
    state = json.load(open(path))
    if not isinstance(state, dict):
        state = {}
except (OSError, ValueError):
    state = {}
for p in pairs:
    k, sep, v = p.partition("=")
    if not sep or not re.fullmatch(r"[a-z][a-z0-9_]*", k):
        sys.exit(f"spoke.sh state: '{p}' is not key=value")
    state[k] = None if v == "" else int(v) if re.fullmatch(r"-?[0-9]+", v) else {"true": True, "false": False}.get(v, v)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f, indent=1, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
EOF2
		) 8> "${STATE}.lock"
		;;
	*)
		echo "usage: $0 names | sessions | entry <name> [<key> [--list]] | flag <name> | enabled <name> | table | check [<name>...] | check-charter <file>... | state <name> [key=value...]" >&2
		exit 64
		;;
esac
